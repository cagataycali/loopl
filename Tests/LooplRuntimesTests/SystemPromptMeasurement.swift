import XCTest
import Loopl
@testable import LooplRuntimes

/// `system_prompt` with a REAL model (lane P6-F): does a small model reach for it when the user asks for a STANDING
/// rule, read it when asked what its instructions are, and leave it alone for ordinary questions and one-time asks?
/// Approvals are auto-approved here (the card is the app's job); the store is in memory so nothing on this Mac changes.
///
///   LOOPL_AUDIT_DIR=~/loopl-train-models/loopl-2b-4bit LOOPL_AUDIT_OUT=~/.tiny/loopl-phase6/system-prompt/evidence \
///   LOOPL_AUDIT_RUNS=3 xcodebuild test -scheme Loopl-Package -destination 'platform=macOS,arch=arm64' \
///   -only-testing:LooplRuntimesTests/SystemPromptMeasurement
final class SystemPromptMeasurement: XCTestCase {
    struct Row: Codable {
        var model: String; var scenario: String; var run: Int; var calls: [String]; var status: String; var changed: Bool
        var promptAfter: String; var answer: String; var pass: Bool; var seconds: Double; var raw: String
    }
    struct Scenario { let name: String; let prompt: String; let expectCall: Bool; let judge: (String, [String], String) -> Bool }

    static let base = MemoryToolsAuditTests.systemPrompt

    static var scenarios: [Scenario] { [
        Scenario(name: "standing-rule-turkish", prompt: "Add to your instructions: always answer in Turkish.", expectCall: true) { _, calls, after in
            calls.contains { $0.hasPrefix("system_prompt") && ($0.contains("append") || $0.contains("set")) } && (after.lowercased().contains("turkish") || after.lowercased().contains("türkçe"))   // the 2B writes the rule IN Turkish
        },
        Scenario(name: "standing-rule-name", prompt: "From now on call me Ali in every conversation.", expectCall: true) { _, calls, after in
            calls.contains { $0.hasPrefix("system_prompt") && ($0.contains("append") || $0.contains("set")) } && after.contains("Ali")
        },
        Scenario(name: "get", prompt: "What are your instructions? Show me your system prompt.", expectCall: true) { answer, calls, _ in
            calls.contains { $0.hasPrefix("system_prompt") && $0.contains("get") } && !answer.isEmpty
        },
        Scenario(name: "reset", prompt: "Go back to your default instructions.", expectCall: true) { _, calls, after in
            calls.contains { $0.hasPrefix("system_prompt") && $0.contains("reset") } && after == base
        },
        Scenario(name: "negative-ordinary", prompt: "What is 15% of 240?", expectCall: false) { answer, calls, _ in
            !calls.contains { $0.hasPrefix("system_prompt") } && answer.contains("36")
        },
        Scenario(name: "negative-one-time", prompt: "Answer this one in Turkish: what is the capital of France?", expectCall: false) { answer, calls, _ in
            !calls.contains { $0.hasPrefix("system_prompt") } && answer.lowercased().contains("paris")
        },
    ] }

    func testSystemPrompt() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 2, sizeBytes: 1_300_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-system-prompt") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-system-prompt.jsonl"); try? FileManager.default.removeItem(at: file)
        var summary: [String] = []

        for sc in Self.scenarios where only?.contains(sc.name) ?? true {
            var passes = 0
            for i in 1...runs {
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                // `reset` starts from an edited prompt so there is something to reset; everything else from the app default.
                let start = sc.name == "reset" ? Self.base + "\n\nAlways answer in Turkish." : Self.base
                let store = InMemorySystemPromptStore(prompt: start, defaultPrompt: Self.base)
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool(),
                                         ManageMessagesTool(), SystemPromptTool(store: store)]
                let agent = Agent(model: model, tools: tools, systemPrompt: start, conversationManager: NullConversationManager(),
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 4)], retryStrategy: nil)
                var answer = "", status = "none", changed = false
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name == "system_prompt" }) { status = r.status.rawValue }
                        if case .systemPromptChanged = ev { changed = true }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)"; status = "error" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                let called = calls.contains { $0.hasPrefix("system_prompt") }
                let after = store.read()
                let pass = (called == sc.expectCall) && (!sc.expectCall || status == "success") && sc.judge(answer, calls, after)
                if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, status: status, changed: changed, promptAfter: after,
                                    answer: answer, pass: pass, seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("SP \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") called=\(called) status=\(status) changed=\(changed) calls=\(calls.map { $0.prefix(160) }) · \(answer.prefix(140).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append("\(sc.name): \(passes)/\(runs)")
        }
        let report = "SP SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-system-prompt-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
