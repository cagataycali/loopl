import XCTest
import Loopl
@testable import LooplRuntimes

/// Phase 6, lane A — `manage_tools` with a REAL model: when the tool the task needs is NOT mounted, does a small model
/// (1) notice, (2) call `manage_tools mount <name>`, and (3) use that tool on its very next step of the SAME turn?
/// Step 3 is the owner's contract ("immediately effective for the language model call we will make") — the registry
/// is read when each request is built, and this test records that the request after the mount carried the tool.
///
/// Run (macOS, MLX): `TEST_RUNNER_LOOPL_AUDIT_DIR=~/loopl-train-models/loopl-0.8b-4bit TEST_RUNNER_LOOPL_AUDIT_OUT=… xcodebuild test
/// -scheme Loopl-Package -destination 'platform=macOS,arch=arm64' -only-testing:LooplRuntimesTests/ManageToolsMeasurement`.
/// Rows → `<model>-managetools.jsonl`, one summary line per scenario.
final class ManageToolsMeasurement: XCTestCase {
    struct Row: Codable {
        var model: String; var scenario: String; var run: Int; var calls: [String]; var specsPerRequest: [[String]]
        var mountedThen: Bool; var usedAfterMount: Bool; var usedSameTurn: Bool; var answer: String; var pass: Bool; var seconds: Double; var raw: String
    }
    struct Scenario { let name: String; let prompt: String; let need: String; let mounted: [String]; let judge: (String) -> Bool }

    /// A deterministic `http` stand-in: same name + spec as the SDK's, no network (the harness runs offline).
    struct HttpStandIn: Tool {
        let name = "http"
        let description = HttpTool().description
        let parameters: JSONValue = HttpTool().parameters
        func call(_ args: [String: JSONValue]) async throws -> String {
            "GET \(args["url"]?.stringValue ?? "?") → 200\n<title>loopl — agents that run on the iPhone</title>\nloopl is a free iOS app and Swift SDK."
        }
    }

    static var scenarios: [Scenario] { [
        Scenario(name: "http-not-mounted", prompt: "Fetch https://loopl.dev and tell me its page title.", need: "http",
                 mounted: ["current_time", "calculator"]) { $0.lowercased().contains("agents that run on the iphone") || $0.lowercased().contains("loopl") },
        Scenario(name: "time-not-mounted", prompt: "What time is it right now?", need: "current_time",
                 mounted: ["calculator", "remember", "recall"]) { a in a.contains(":") || a.lowercased().contains("time") },
        Scenario(name: "calculator-not-mounted", prompt: "What is 4821 * 37?", need: "calculator",
                 mounted: ["current_time", "remember", "recall"]) { $0.contains("178,377") || $0.contains("178377") },
        Scenario(name: "memory-not-mounted", prompt: "Remember that my favourite colour is teal.", need: "remember",
                 mounted: ["current_time", "calculator"]) { _ in true },
    ] }

    func testManageToolsMountsMidTurn() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-managetools") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 3
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let system = e["LOOPL_AUDIT_SYSTEM"] ?? MemoryToolsAuditTests.systemPrompt
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-managetools.jsonl"); try? FileManager.default.removeItem(at: file)
        var summary: [String] = []

        for sc in Self.scenarios where only?.contains(sc.name) ?? true {
            var passes = 0, mounts = 0, sameTurn = 0
            for i in 1...runs {
                let catalog: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpStandIn()]
                let registry = ToolRegistry(catalog: catalog, mounted: sc.mounted)
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                let agent = Agent(model: model, tools: [ManageToolsTool(registry: registry)], systemPrompt: system,
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 5)], retryStrategy: nil, registry: registry)
                var answer = "", specsPerRequest: [[String]] = []
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .toolsChanged(let m) = ev { specsPerRequest.append(m) }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                // Did a manage_tools call mount the needed tool, and was that tool called in a LATER cycle of this turn?
                let mountCycle = cycles.firstIndex { $0.calls.contains { $0.hasPrefix("manage_tools") && $0.contains("mount") && $0.contains(sc.need) && !$0.contains("unmount") } }
                let useCycle = cycles.firstIndex { $0.calls.contains { $0.hasPrefix(sc.need + " ") || $0 == sc.need } }
                let mountedThen = mountCycle != nil
                let usedAfterMount = mountedThen && useCycle != nil && useCycle! > mountCycle!
                let used = useCycle != nil
                let pass = usedAfterMount && sc.judge(answer)
                if mountedThen { mounts += 1 }; if usedAfterMount { sameTurn += 1 }; if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, specsPerRequest: specsPerRequest, mountedThen: mountedThen,
                                    usedAfterMount: usedAfterMount, usedSameTurn: used, answer: answer, pass: pass,
                                    seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("MANAGETOOLS \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") mounted=\(mountedThen) usedAfterMount=\(usedAfterMount) specs=\(specsPerRequest.map { $0.joined(separator: "+") }) calls=\(calls.map { $0.prefix(100) }) · \(answer.prefix(100).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append("\(sc.name): pass \(passes)/\(runs) · mounted \(mounts)/\(runs) · used-after-mount \(sameTurn)/\(runs)")
        }
        let report = "MANAGETOOLS SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-managetools-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
