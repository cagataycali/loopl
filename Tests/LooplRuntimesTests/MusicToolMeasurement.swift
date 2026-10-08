import XCTest
import Loopl
import LooplAppleTools
@testable import LooplRuntimes

/// `music` with a REAL model and the fixture player does a small model pick the right `action`
/// from one tool with a six-word enum, and does it carry the number for the volume? The last scenario is relative
/// ("a bit louder") — the model has to read the current volume (40 %) first or guess upward.
final class MusicToolMeasurement: XCTestCase {
    struct Row: Codable { var model: String; var scenario: String; var run: Int; var calls: [String]; var log: [String]; var status: String; var answer: String; var pass: Bool; var seconds: Double; var raw: String }
    struct Scenario { let name: String; let prompt: String; let judge: (String, [String], FixtureMusicSource) -> Bool }

    static var scenarios: [Scenario] { [
        Scenario(name: "pause", prompt: "Pause the music.") { _, _, s in s.log.contains("pause") && s.state == .paused },
        Scenario(name: "next", prompt: "Skip this song.") { _, _, s in s.log.contains("next") && s.index == 1 },
        Scenario(name: "volume-absolute", prompt: "Turn the volume down to 20.") { _, _, s in s.log.contains("volume 20") },
        Scenario(name: "now-playing", prompt: "What song is this?") { a, _, s in s.log.contains("now_playing") && a.contains("Blue in Green") },
        Scenario(name: "volume-louder", prompt: "Make it a bit louder.") { _, _, s in s.volume > 40 && s.volume <= 80 && s.log.contains { $0.hasPrefix("volume ") } },
    ] }

    func testMusicTool() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-music") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        // LOOPL_AUDIT_DEFAULT_ONLY=1 → the tool list a FRESH INSTALL has (default-on Apple tools only); otherwise every available one.
        let defaultOnly = e["LOOPL_AUDIT_DEFAULT_ONLY"] == "1"
        // Availability is read per run, AFTER the fixture is installed — on macOS `music` is only available through the fixture.
        func appleTools() -> [any AppleTool] { AppleTools.available.filter { !defaultOnly || type(of: $0).defaultOn } }
        MusicStore.use(FixtureMusicSource())
        print("MUSIC TOOLSET \(name): \(defaultOnly ? "default-on" : "all available") → \(appleTools().map(\.name))")
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-music\(defaultOnly ? "-default" : "").jsonl"); try? FileManager.default.removeItem(at: file)
        defer { MusicStore.use(nil) }
        var summary: [String] = []

        for sc in Self.scenarios where only?.contains(sc.name) ?? true {
            var passes = 0
            for i in 1...runs {
                let src = FixtureMusicSource(); MusicStore.use(src)
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()]
                    + appleTools().map { $0 as any Tool }
                let agent = Agent(model: model, tools: tools, systemPrompt: MemoryToolsAuditTests.systemPrompt,
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 5)], retryStrategy: nil)
                var answer = "", status = "none"
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name == "music" }) { status = r.status.rawValue }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)"; status = "error" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                let called = calls.contains { $0.hasPrefix("music ") || $0 == "music" }
                let pass = called && status == "success" && sc.judge(answer, calls, src)
                if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, log: src.log, status: status, answer: answer, pass: pass,
                                                       seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("MUSIC \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") called=\(called) status=\(status) log=\(src.log) calls=\(calls.map { $0.prefix(120) }) · \(answer.prefix(110).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append("\(sc.name): \(passes)/\(runs)")
        }
        let report = "MUSIC SUMMARY \(name) [\(defaultOnly ? "default-on tools" : "all tools")]: " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-music-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
