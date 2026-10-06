import XCTest
import Loopl
import LooplAppleTools
@testable import LooplRuntimes

/// Owner (2026-10-06 15:2xZ): "recall and remember tools are not working in the app". MEASURE before fixing: the real
/// stack (`Agent` + `MLXModel` on Metal), the APP's prompt and the APP's full tool list, the conversations a person
/// actually has — remember in one turn, ask in the next; ask again after a "relaunch" (a fresh Agent over the same
/// `NotesStore`); Turkish; no key spelled out. Runs only with `LOOPL_AUDIT_DIR`; writes
/// `LOOPL_AUDIT_OUT/<model>-mem-<scenario>.jsonl` (prompt as the model saw it, raw output, calls, results, text).
///
///     LOOPL_AUDIT_DIR=~/loopl-train-models/Qwen3.5-0.8B-4bit LOOPL_AUDIT_OUT=/tmp/mem LOOPL_AUDIT_RUNS=3 \
///       xcodebuild test -scheme Loopl-Package -destination 'platform=macOS,arch=arm64' \
///       -only-testing:LooplRuntimesTests/MemoryToolsAuditTests
final class MemoryToolsAuditTests: XCTestCase {
    /// `AppSettings.defaultSystemPrompt` — what build 9+ sends (PR #89: nothing in front of it).
    static let systemPrompt = "You are loopl, a helpful assistant running fully on this device. Use tools when they help; answer concisely."

    /// `device_info` lives in the app target (UIKit); the model only sees its spec, so a same-spec stand-in keeps the prompt faithful.
    struct DeviceInfoStandIn: Tool {
        let name = "device_info"
        let description = "Battery level and state, available memory for this app, total RAM, OS version, offline-mode flag and thermal state of this iPhone."
        let parameters: JSONValue = ToolSchema.object([:])
        func call(_ args: [String: JSONValue]) async throws -> String { "model: iPhone (iOS 26.4)\nbattery: 81% unplugged\nthermal: nominal\noffline mode: off" }
    }
    /// The app's `Engine.activeTools` with every tool on: SDK built-ins in order, then the Apple tools in Settings order.
    static var appTools: [any Tool] {
        [CurrentTimeTool(), CalculatorTool(), DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()] + AppleTools.all.map { $0 as any Tool }
    }

    struct Turn: Codable { var user: String; var freshAgent: Bool; var cycles: [ToolCallAuditTests.Cycle]; var text: String; var stopReason: String }
    struct Run: Codable { var model: String; var scenario: String; var run: Int; var turns: [Turn] = []; var notesAfter: [String: String] = [:]; var outcome = ""; var seconds = 0.0 }

    struct Scenario {
        let name: String
        /// (prompt, startANewAgent) — a new agent over the same NotesStore is the app relaunched / model switched.
        let turns: [(String, Bool)]
        let judge: (Run) -> (String, Bool)
    }

    static func calls(_ t: Turn) -> [String] { t.cycles.flatMap(\.calls) }
    static func names(_ t: Turn) -> [String] { calls(t).map { String($0.split(separator: " ").first ?? "") } }
    static func lower(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil) }

    static var scenarios: [Scenario] { [
        // The owner's literal case: store in one turn, ask in the next (same conversation).
        Scenario(name: "name-same-conversation", turns: [("Remember that my name is Çağatay.", false), ("What is my name?", false)]) { r in
            let stored = r.notesAfter.values.contains { lower($0).contains("cagatay") }
            let remembered = names(r.turns[0]).contains("remember")
            let answered = lower(r.turns[1].text).contains("cagatay")
            return ("remember=\(remembered) stored=\(stored) answer=\(answered)", remembered && stored && answered)
        },
        // Relaunch: a fresh agent (empty conversation) must reach for `recall` to know the name.
        Scenario(name: "name-after-relaunch", turns: [("Remember that my name is Çağatay.", false), ("What is my name?", true)]) { r in
            let recalled = names(r.turns[1]).contains("recall")
            let answered = lower(r.turns[1].text).contains("cagatay")
            return ("recall=\(recalled) answer=\(answered) calls=\(calls(r.turns[1]))", recalled && answered)
        },
        // Two facts, then "recall everything" after a relaunch.
        Scenario(name: "recall-everything", turns: [("Remember that I live in Istanbul.", false), ("Remember that my favourite colour is teal.", false), ("Recall everything you know about me.", true)]) { r in
            let t = lower(r.turns[2].text)
            let recalled = names(r.turns[2]).contains("recall")
            let both = t.contains("istanbul") && t.contains("teal")
            return ("recall=\(recalled) istanbul+teal=\(both) notes=\(r.notesAfter.count) calls=\(calls(r.turns[2]))", recalled && both)
        },
        // No key spelled out + a question that does not repeat the stored words.
        Scenario(name: "no-key-phrasing", turns: [("Please remember: I take my coffee black, no sugar.", false), ("How do I like my coffee?", true)]) { r in
            let t = lower(r.turns[1].text)
            let ok = names(r.turns[1]).contains("recall") && (t.contains("black") || t.contains("no sugar"))
            return ("calls=\(calls(r.turns[1])) text=\(r.turns[1].text.prefix(80))", ok)
        },
        // Turkish, both turns.
        Scenario(name: "turkish", turns: [("Adımın Çağatay olduğunu hatırla.", false), ("Benim adım ne?", true)]) { r in
            let ok = names(r.turns[1]).contains("recall") && lower(r.turns[1].text).contains("cagatay")
            return ("calls0=\(calls(r.turns[0])) calls1=\(calls(r.turns[1])) text=\(r.turns[1].text.prefix(80))", ok)
        },
    ] }

    func testMemoryToolsWithTheAppPromptAndTools() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-memory-audit") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 1
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }

        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)

        var summary: [String] = []; var failures: [String] = []
        for scenario in Self.scenarios where only?.contains(scenario.name) ?? true {
            let file = out.appendingPathComponent("\(name)-mem-\(scenario.name).jsonl")
            try? FileManager.default.removeItem(at: file)
            var passes = 0
            for i in 1...runs {
                NotesStore.save([:])                       // every run starts with an empty memory
                var run = Run(model: name, scenario: scenario.name, run: i)
                let t0 = Date()
                var agent: Agent? = nil
                for (prompt, fresh) in scenario.turns {
                    if agent == nil || fresh {
                        agent = Agent(model: model, tools: Self.appTools, systemPrompt: Self.systemPrompt,
                                      hooks: [ApprovalPolicy(mode: .never), ToolCallAuditTests.CycleCap(maxCycles: 6)], retryStrategy: nil)
                    }
                    let rec = ToolCallAuditTests.Recorder()
                    await model.setTrace { rec.trace($0) }
                    var turn = Turn(user: prompt, freshAgent: fresh, cycles: [], text: "", stopReason: "")
                    do {
                        for try await ev in agent!.stream(prompt) {
                            rec.event(ev)
                            if case .result(let r) = ev { turn.text = r.message.text; turn.stopReason = r.stopReason.rawValue }
                        }
                    } catch { turn.text = "ERROR \(error)"; turn.stopReason = "error" }
                    turn.cycles = rec.cycles()
                    run.turns.append(turn)
                }
                run.seconds = Date().timeIntervalSince(t0)
                run.notesAfter = NotesStore.all()
                let (outcome, pass) = scenario.judge(run)
                run.outcome = outcome
                if pass { passes += 1 }
                let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file))
                try h.seekToEnd(); try h.write(contentsOf: try JSONEncoder().encode(run) + Data("\n".utf8)); try h.close()
                print("MEM-AUDIT \(name) \(scenario.name) run \(i): \(pass ? "PASS" : "FAIL") — \(outcome) (\(String(format: "%.1f", run.seconds)) s)")
            }
            summary.append("\(scenario.name): \(passes)/\(runs)")
            if passes == 0 { failures.append(scenario.name) }
        }
        let report = "MEM-AUDIT SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-mem-summary.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(failures.isEmpty, "memory scenarios with 0 passes: \(failures)")
    }
}
