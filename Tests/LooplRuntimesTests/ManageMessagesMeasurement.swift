import XCTest
import Loopl
@testable import LooplRuntimes

/// `manage_messages` with a REAL model (lane P6-B): does a small model reach for it when told the context is long,
/// does the edit actually land (the live history shrinks, the next prompt is shorter), and does it stay away from
/// the tool in a short chat? Seeded history = six finished tool turns (calculator / current_time), ≈ what a long
/// session looks like; the pressure scenario appends tiny-tech's `[History pressure]` line to the user turn.
///
///   LOOPL_AUDIT_DIR=~/loopl-train-models/loopl-0.8b-4bit LOOPL_AUDIT_OUT=~/.tiny/loopl-phase6/manage-messages/evidence \
///   LOOPL_AUDIT_RUNS=3 xcodebuild test -scheme Loopl-Package -destination 'platform=macOS,arch=arm64' \
///   -only-testing:LooplRuntimesTests/ManageMessagesMeasurement
final class ManageMessagesMeasurement: XCTestCase {
    struct Row: Codable {
        var model: String; var scenario: String; var run: Int; var calls: [String]; var status: String; var edited: Bool
        var messagesBefore: Int; var messagesAfter: Int; var promptTokensBefore: Int; var promptTokensAfter: Int
        var answer: String; var pass: Bool; var seconds: Double; var raw: String
    }
    struct Scenario { let name: String; let prompt: String; let seeded: Bool; let expectCall: Bool; let judge: (String, [String], Bool) -> Bool }

    static let pressureLine = "[History pressure] 13 messages / 7 turns ≈ 6k tokens = 75% of the 8k budget. Compact or drop old turns yourself with manage_messages (compact keeps their text); at 100% the oldest turns are compacted, then dropped, automatically."

    static var scenarios: [Scenario] { [
        Scenario(name: "told-long", prompt: "The context is getting long — tidy it up before we continue.", seeded: true, expectCall: true) { _, calls, edited in
            edited && calls.contains { $0.contains("compact") || $0.contains("drop") || $0.contains("clear") }
        },
        Scenario(name: "pressure-line", prompt: "What is 15% of 240?\n\n" + pressureLine, seeded: true, expectCall: true) { answer, _, edited in
            edited && answer.contains("36")
        },
        Scenario(name: "stats", prompt: "How big is our conversation so far — how many turns and tokens?", seeded: true, expectCall: true) { answer, calls, _ in
            calls.contains { $0.contains("stats") || $0.contains("list") } && (answer.contains("turn") || answer.contains("token"))
        },
        Scenario(name: "short-chat-no-call", prompt: "What is 15% of 240?", seeded: false, expectCall: false) { answer, calls, _ in
            !calls.contains { $0.hasPrefix("manage_messages") } && answer.contains("36")
        },
    ] }

    /// Six finished turns, every one a tool cycle — the shape a long agent session has.
    static func seededHistory() -> [Message] {
        var m: [Message] = []
        let qs: [(String, String, String, String)] = [
            ("What is 23*47?", "calculator", "23*47", "23*47 = 1081"), ("And 2^10?", "calculator", "2^10", "2^10 = 1024"),
            ("Time in Istanbul?", "current_time", "Europe/Istanbul", "Monday, 6 October 2026 23:40:12 GMT+3 (Europe/Istanbul)"),
            ("sqrt(2) to 6 places?", "calculator", "sqrt(2)", "sqrt(2) = 1.414214"), ("Time in Tokyo?", "current_time", "Asia/Tokyo", "Tuesday, 7 October 2026 05:40:20 GMT+9 (Asia/Tokyo)"),
            ("What is 1081+1024?", "calculator", "1081+1024", "1081+1024 = 2105"),
        ]
        for (i, q) in qs.enumerated() {
            let id = "tooluse_seed\(i)"
            let arg = q.1 == "calculator" ? "expression" : "timezone"
            m.append(.user(q.0))
            m.append(.assistant(text: "", toolUses: [ToolUse(toolUseId: id, name: q.1, input: [arg: .string(q.2)])]))
            m.append(.toolResults([ToolResult(toolUseId: id, name: q.1, content: q.3 + String(repeating: " ·", count: 120))]))   // padded like a real verbose result
            m.append(.assistant(q.3.components(separatedBy: " = ").last ?? q.3))
        }
        return m
    }

    func testManageMessages() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-manage-messages") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-manage-messages.jsonl"); try? FileManager.default.removeItem(at: file)
        var summary: [String] = []

        for sc in Self.scenarios where only?.contains(sc.name) ?? true {
            var passes = 0
            for i in 1...runs {
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool(), ManageMessagesTool()]
                let history = sc.seeded ? Self.seededHistory() : []
                // The cap counts assistant turns in the WHOLE history, so it is offset by the seed; no sliding window → the seed is what the model sees.
                let agent = Agent(model: model, tools: tools, systemPrompt: MemoryToolsAuditTests.systemPrompt, messages: history,
                                  conversationManager: NullConversationManager(),
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 4 + history.filter { $0.role == .assistant }.count)],
                                  retryStrategy: nil)
                var answer = "", status = "none", edited = false
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name == "manage_messages" }) { status = r.status.rawValue }
                        if case .historyEdited = ev { edited = true }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)"; status = "error" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                let called = calls.contains { $0.hasPrefix("manage_messages") }
                let after = await agent.messages
                let tokBefore = cycles.first?.promptTokens ?? 0, tokAfter = cycles.count > 1 ? (cycles.last?.promptTokens ?? 0) : 0
                let pass = (called == sc.expectCall) && (!sc.expectCall || status == "success") && sc.judge(answer, calls, edited)
                if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, status: status, edited: edited,
                                    messagesBefore: history.count + 1, messagesAfter: after.count, promptTokensBefore: tokBefore, promptTokensAfter: tokAfter,
                                    answer: answer, pass: pass, seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("MM \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") called=\(called) status=\(status) edited=\(edited) msgs \(history.count + 1)→\(after.count) prompt \(tokBefore)→\(tokAfter) calls=\(calls.map { $0.prefix(140) }) · \(answer.prefix(120).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append("\(sc.name): \(passes)/\(runs)")
        }
        let report = "MM SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-manage-messages-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
