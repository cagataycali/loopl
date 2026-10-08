import XCTest
import Loopl
import LooplAppleTools
@testable import LooplRuntimes

/// `location` with a REAL model and the fixture source same recipe as the other measurements.
/// The third scenario is the chain the tool exists for — location → `http` open-meteo with the coordinates.
final class LocationToolMeasurement: XCTestCase {
    struct Row: Codable { var model: String; var scenario: String; var run: Int; var calls: [String]; var results: [String]; var status: String; var answer: String; var pass: Bool; var seconds: Double; var raw: String }
    struct Scenario { let name: String; let prompt: String; let wantPrecise: Bool?; let judge: (String, [String]) -> Bool }

    static var scenarios: [Scenario] { [
        Scenario(name: "where-am-i", prompt: "Where am I right now?", wantPrecise: false) { a, _ in a.lowercased().contains("hoboken") },
        Scenario(name: "exact-still-coarse", prompt: "Give me my exact GPS coordinates.", wantPrecise: false) { a, _ in a.contains("40.74") && a.contains("-74.03") && !a.contains("40.744") },
        Scenario(name: "weather-chain", prompt: "What's the weather like where I am?", wantPrecise: nil) { a, calls in
            calls.contains { $0.hasPrefix("http ") && $0.contains("open-meteo") && ($0.contains("40.74") || $0.contains("latitude")) } && a.range(of: #"-?\d+(\.\d+)?\s*°?\s*[CF]?"#, options: .regularExpression) != nil },
    ] }

    func testLocationTool() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-location") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-location.jsonl"); try? FileManager.default.removeItem(at: file)
        defer { LocationStore.use(nil) }
        var summary: [String] = []

        for sc in Self.scenarios {
            var passes = 0
            for i in 1...runs {
                let src = FixtureLocationSource(); LocationStore.use(src)
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()]
                    + AppleTools.available.map { $0 as any Tool }
                let agent = Agent(model: model, tools: tools, systemPrompt: MemoryToolsAuditTests.systemPrompt,
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 5)], retryStrategy: nil)
                var answer = "", status = "none"
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name == "location" }) { status = r.status.rawValue }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)"; status = "error" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                let called = calls.contains { $0.hasPrefix("location ") || $0 == "location" }
                let preciseOK = sc.wantPrecise.map { want in src.requests.last == want } ?? true
                let pass = called && status == "success" && preciseOK && sc.judge(answer, calls)
                if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, results: cycles.flatMap(\.results), status: status, answer: answer, pass: pass,
                                    seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("LOCATION \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") called=\(called) status=\(status) precise=\(src.requests) calls=\(calls.map { $0.prefix(120) }) · \(answer.prefix(110).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append("\(sc.name): \(passes)/\(runs)")
        }
        let report = "LOCATION SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-location-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
