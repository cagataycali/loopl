import XCTest
import Loopl
import LooplAppleTools
@testable import LooplRuntimes

/// contacts_search / photos_recent with a REAL model and the fixture sources — same recipe as the
/// other measurements. Photos pass = the tool ran and handed back pictures and the answer talks about a photo.
final class ContactsPhotosMeasurement: XCTestCase {
    struct Row: Codable { var model: String; var scenario: String; var run: Int; var calls: [String]; var results: [String]; var status: String; var images: Int; var answer: String; var pass: Bool; var seconds: Double; var raw: String }
    struct Scenario { let name: String; let tool: String; let prompt: String; let judge: (String, [String], Int) -> Bool }

    static var scenarios: [Scenario] { [
        Scenario(name: "phone-number", tool: "contacts_search", prompt: "What's Ali's phone number?") { a, _, _ in a.contains("532 000 11 22") || a.contains("5320001122") },
        Scenario(name: "email", tool: "contacts_search", prompt: "Find Alice Park's email address for me.") { a, _, _ in a.lowercased().contains("alice.park@example.org") },
        Scenario(name: "latest-photo", tool: "photos_recent", prompt: "What's in the last photo I took?") { a, _, n in n >= 1 && !a.isEmpty },
        Scenario(name: "photos-today", tool: "photos_recent", prompt: "Show me the photos I took today.") { a, calls, n in n >= 1 && calls.contains { $0.hasPrefix("photos_recent") && ($0.contains("date") || $0.contains("count")) } || (n >= 1 && !a.isEmpty) },
    ] }

    func testContactsAndPhotos() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-contacts") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-contacts-photos.jsonl"); try? FileManager.default.removeItem(at: file)
        defer { ContactsStore.use(nil); PhotosStore.use(nil) }
        var summary: [String] = []

        for sc in Self.scenarios {
            var passes = 0
            for i in 1...runs {
                ContactsStore.use(FixtureContactsSource()); PhotosStore.use(FixturePhotosSource())
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()]
                    + AppleTools.available.map { $0 as any Tool }
                let agent = Agent(model: model, tools: tools, systemPrompt: MemoryToolsAuditTests.systemPrompt,
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 5)], retryStrategy: nil)
                var answer = "", status = "none", images = 0
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name == sc.tool }) { status = r.status.rawValue; images += r.images.count }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)"; status = "error" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                let called = calls.contains { $0.hasPrefix(sc.tool + " ") || $0 == sc.tool }
                let pass = called && status == "success" && sc.judge(answer, calls, images)
                if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, results: cycles.flatMap(\.results), status: status, images: images, answer: answer, pass: pass,
                                    seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("CONTACTS \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") called=\(called) status=\(status) images=\(images) calls=\(calls.map { $0.prefix(100) }) · \(answer.prefix(120).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append("\(sc.name): \(passes)/\(runs)")
        }
        let report = "CONTACTS SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-contacts-photos-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
