import XCTest
import Loopl
@testable import LooplRuntimes

/// End-to-end audit of the tool-calling path with the REAL stack: loopl's `Agent` + `MLXModel` on Metal,
/// the app's tool set and system prompt, a small model from the catalog. Runs only when
/// `LOOPL_AUDIT_DIR` points at a downloaded mlx-community checkpoint (otherwise skipped, CI stays green).
///
/// Every cycle is written to `LOOPL_AUDIT_OUT/<scenario>.jsonl`: the prompt exactly as the model saw it
/// (chat template applied, special tokens kept), the raw decoded output, the parsed tool calls and the
/// tool results that went back. `LOOPL_AUDIT_RUNS` repeats each scenario (default 1); `LOOPL_AUDIT_ONLY`
/// selects scenarios by name (comma list).
///
///     LOOPL_AUDIT_DIR=~/loopl-train-models/Qwen3.5-0.8B-4bit LOOPL_AUDIT_OUT=/tmp/audit LOOPL_AUDIT_RUNS=10 \
///       xcodebuild test -scheme Loopl-Package -destination 'platform=macOS,arch=arm64' \
///       -only-testing:LooplRuntimesTests/ToolCallAuditTests
final class ToolCallAuditTests: XCTestCase {
    static let systemPrompt = "You are loopl, a helpful assistant running fully on this iPhone. Use tools when they help; answer concisely."

    struct Env { let dir: URL; let spec: ModelSpec; let out: URL; let runs: Int; let only: Set<String>? }

    func env() throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else { throw XCTSkip("no config.json at \(dir)") }
        let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        // Same shape as App/Resources/models.json for these rows: hermes family, thinking off.
        let spec = ModelSpec(id: "hub:mlx-community/\(name.lowercased())", name: name, repo: "mlx-community/\(name)", runtime: .mlx, family: .hermes,
                             paramsB: 0.8, sizeBytes: 650_000_000, ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2,
                             chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-toolcall-audit") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 1
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        return Env(dir: url, spec: spec, out: out, runs: runs, only: only)
    }

    // MARK: recording

    struct Cycle: Codable { var prompt: String; var promptTokens: Int; var raw: String; var calls: [String]; var results: [String]; var text: String }
    struct Run: Codable {
        var model: String; var scenario: String; var run: Int
        var cycles: [Cycle] = []
        var finalText = ""; var stopReason = ""; var outcome = ""; var error: String? = nil
        var seconds = 0.0
    }

    /// Records one invocation: traces from the runtime, parsed calls and results from the agent's events.
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var traces: [GenerationTrace] = []
        var calls: [[String]] = []       // per cycle
        var results: [[String]] = []
        var texts: [String] = []
        var pendingCalls: [String] = []
        var pendingResults: [String] = []
        func trace(_ t: GenerationTrace) { lock.lock(); traces.append(t); lock.unlock() }
        func event(_ e: AgentEvent) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case .modelMessage(let m):
                texts.append(m.text)
                pendingCalls = m.toolUses.map { "\($0.name) \(JSONValue.object($0.input).compact)" }
                if pendingCalls.isEmpty { calls.append([]); results.append([]) }
            case .toolResultMessage(let m):
                pendingResults = m.toolResults.map { "[\($0.status.rawValue)] \($0.name): \($0.content)" }
                calls.append(pendingCalls); results.append(pendingResults)
                pendingCalls = []; pendingResults = []
            default: break
            }
        }
        func cycles() -> [Cycle] {
            lock.lock(); defer { lock.unlock() }
            return traces.indices.map { i in
                Cycle(prompt: traces[i].prompt, promptTokens: traces[i].promptTokens, raw: traces[i].raw,
                      calls: i < calls.count ? calls[i] : [], results: i < results.count ? results[i] : [],
                      text: i < texts.count ? texts[i] : "")
            }
        }
    }

    /// The harness must not hang on a model that loops: stop the invocation after `maxCycles` model
    /// calls (the SDK itself has no cap — this is the test's budget, recorded as outcome "capped").
    struct CycleCap: HookProvider {
        let maxCycles: Int
        func registerHooks(_ registry: HookRegistry) {
            registry.addCallback(BeforeModelCallEvent.self) { e in
                let assistantTurns = e.messages.filter { $0.role == .assistant }.count
                if assistantTurns >= maxCycles { e.cancel = "harness: cycle cap \(maxCycles) reached" }
            }
        }
    }

    /// Fault injection: the FIRST call of `tool` gets `error` as an error result instead of running —
    /// the owner's incident replayed (the model's call was fine, the result said it was not).
    final class FirstCallFails: HookProvider, @unchecked Sendable {
        let tool: String; let error: String
        var fired = false
        init(tool: String, error: String) { self.tool = tool; self.error = error }
        func registerHooks(_ registry: HookRegistry) {
            registry.addCallback(BeforeToolCallEvent.self) { [self] e in
                guard e.toolUse.name == tool, !fired else { return }
                fired = true
                e.approval = nil
                e.cancelTool = error    // the agent turns a cancelled call into an error result
            }
        }
    }

    // MARK: scenarios

    struct Scenario {
        let name: String
        let prompt: String
        var hooks: () -> [any HookProvider] = { [] }
        var maxCycles = 8
        /// Classify the run. Returns (outcome, pass).
        let judge: (Run) -> (String, Bool)
    }

    static func toolNames(_ c: Cycle) -> [String] { c.calls.map { String($0.split(separator: " ").first ?? "") } }
    static func allCalls(_ r: Run) -> [String] { r.cycles.flatMap(\.calls) }

    /// Did the model keep issuing the identical call (name + args) after an error result for it?
    static func identicalRepeatAfterError(_ r: Run) -> Bool {
        var lastErrored: String?
        for c in r.cycles {
            for (call, result) in zip(c.calls, c.results) {
                if let e = lastErrored, call == e { return true }
                lastErrored = result.hasPrefix("[error]") ? call : nil
            }
        }
        return false
    }

    static var scenarios: [Scenario] { [
        Scenario(name: "hey", prompt: "hey", maxCycles: 3) { r in
            let calls = allCalls(r)
            return (calls.isEmpty ? "prose" : "tool:\(calls.first!)", calls.isEmpty && !r.finalText.isEmpty)
        },
        Scenario(name: "time-calc", prompt: "What time is it in Istanbul right now, and what is 23*47?") { r in
            let names = Set(allCalls(r).map { String($0.split(separator: " ").first ?? "") })
            let ok = names.contains("current_time") && names.contains("calculator") && r.finalText.contains("1081")
            return (ok ? "both tools + 1081" : "names=\(names.sorted()) text=\(r.finalText.prefix(60))", ok)
        },
        Scenario(name: "http-get", prompt: "Fetch https://httpbin.org/get and tell me what origin IP it reports.") { r in
            let ok = allCalls(r).contains { $0.hasPrefix("http ") && $0.contains("httpbin.org/get") } && r.cycles.last?.results.isEmpty == true && !r.finalText.isEmpty
            return (ok ? "http GET → answer" : "calls=\(allCalls(r)) text=\(r.finalText.prefix(60))", ok)
        },
        Scenario(name: "http-post", prompt: "POST the JSON {\"hello\": \"loopl\"} to https://httpbin.org/post and tell me what the server echoed back in its json field.") { r in
            let ok = allCalls(r).contains { $0.hasPrefix("http ") && $0.contains("POST") && $0.contains("httpbin.org/post") } && r.finalText.lowercased().contains("loopl")
            return (ok ? "http POST → echoed" : "calls=\(allCalls(r)) text=\(r.finalText.prefix(60))", ok)
        },
        Scenario(name: "remember-recall", prompt: "Remember that my favourite colour is teal under the key colour, then recall it and confirm what you stored.") { r in
            let names = allCalls(r).map { String($0.split(separator: " ").first ?? "") }
            let ok = names.contains("remember") && names.contains("recall") && r.finalText.lowercased().contains("teal")
            return (ok ? "remember + recall + teal" : "names=\(names) text=\(r.finalText.prefix(60))", ok)
        },
        // The owner's incident, replayed with the real error text: the first http call "fails" with the
        // validation complaint. Pass = the model reads it and continues sensibly — a corrected/repeated
        // call that then succeeds and an answer, or an honest "it failed" answer. Fail = identical call
        // after the error that fails again (cannot happen here: only the first call is faulted), no
        // answer, or the harness cap.
        Scenario(name: "fail-first-validation",
                 prompt: "Fetch https://httpbin.org/uuid and tell me the uuid it returns.",
                 hooks: { [FirstCallFails(tool: "http", error: "Error: http was not run — missing required parameter 'url'. Call it with arguments like {\"url\": \"https://example.com\"}. Fix the arguments and call it again, or answer without the tool.")] }) { r in
            let httpCalls = allCalls(r).filter { $0.hasPrefix("http ") }
            if r.outcome == "capped" { return ("capped (looping)", false) }
            let recovered = httpCalls.count >= 2 && r.cycles.last?.results.isEmpty == true && !r.finalText.isEmpty && !r.finalText.lowercased().contains("error")
            let honest = httpCalls.count == 1 && !r.finalText.isEmpty && r.cycles.last?.results.isEmpty == true
            if recovered { return ("retried after error → answered", true) }
            if honest { return ("answered honestly after error", true) }
            return ("httpCalls=\(httpCalls.count) text=\(r.finalText.prefix(80))", false)
        },
        // A natural failure: the URL 404s. Pass = the model changes the URL or reports the 404 honestly.
        // Fail = the identical call again and again, or a made-up body.
        Scenario(name: "fail-first-404",
                 prompt: "Fetch https://httpbin.org/jsn and tell me what JSON it returns. If a URL does not work, try to fix it or tell me.") { r in
            if r.outcome == "capped" { return ("capped (looping)", false) }
            let urls = allCalls(r).filter { $0.hasPrefix("http ") }
            let changed = Set(urls).count >= 2
            let honest = r.finalText.contains("404") || r.finalText.lowercased().contains("not found") || r.finalText.lowercased().contains("does not") || r.finalText.lowercased().contains("doesn't")
            if changed { return ("changed URL after 404", true) }
            if honest && !urls.isEmpty { return ("reported 404 honestly", true) }
            return ("urls=\(urls) text=\(r.finalText.prefix(80))", false)
        },
        // A transport-level failure injected once: the model may retry once (transient) or answer honestly.
        Scenario(name: "fail-first-network",
                 prompt: "Fetch https://httpbin.org/ip and tell me the IP.",
                 hooks: { [FirstCallFails(tool: "http", error: "Error: the request failed: could not connect to the server (network unreachable). Try again, use a different URL, or answer without the tool.")] }) { r in
            if r.outcome == "capped" { return ("capped (looping)", false) }
            let ok = !r.finalText.isEmpty && r.cycles.last?.results.isEmpty == true
            return (ok ? "continued after network error" : "text=\(r.finalText.prefix(80))", ok)
        },
        Scenario(name: "chain-6",
                 prompt: "Do these steps one at a time using tools: 1) remember my name is Cagatay under key name, 2) recall the key name, 3) tell me the time in Tokyo, 4) compute 12*12, 5) fetch https://httpbin.org/uuid, 6) then summarise all results in one short paragraph.",
                 maxCycles: 12) { r in
            let names = Set(allCalls(r).map { String($0.split(separator: " ").first ?? "") })
            let ok = names.count >= 4 && !r.finalText.isEmpty && r.outcome != "capped"
            return (ok ? "\(allCalls(r).count) calls over \(r.cycles.count) cycles" : "names=\(names.sorted()) cycles=\(r.cycles.count) text=\(r.finalText.prefix(60))", ok)
        },
    ] }

    // MARK: the run

    func testAuditToolCallingEndToEnd() async throws {
        let env = try env()
        let model = MLXModel()
        try await model.load(env.spec, from: env.dir) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)

        var summary: [String] = []
        var failures: [String] = []
        for scenario in Self.scenarios where env.only?.contains(scenario.name) ?? true {
            let file = env.out.appendingPathComponent("\(env.spec.name)-\(scenario.name).jsonl")
            try? FileManager.default.removeItem(at: file)
            var passes = 0
            for i in 1...env.runs {
                let rec = Recorder()
                await model.setTrace { rec.trace($0) }
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), RememberTool(), RecallTool(), HttpTool()]
                let hooks: [any HookProvider] = [ApprovalPolicy(mode: .never), CycleCap(maxCycles: scenario.maxCycles)] + scenario.hooks()
                let agent = Agent(model: model, tools: tools, systemPrompt: Self.systemPrompt, hooks: hooks, retryStrategy: nil)
                var run = Run(model: env.spec.name, scenario: scenario.name, run: i)
                let t0 = Date()
                do {
                    for try await e in agent.stream(scenario.prompt) {
                        rec.event(e)
                        if case .result(let r) = e { run.finalText = r.message.text; run.stopReason = r.stopReason.rawValue }
                    }
                } catch {
                    run.error = "\(error)"
                }
                run.seconds = Date().timeIntervalSince(t0)
                run.cycles = rec.cycles()
                if run.finalText.hasPrefix("harness: cycle cap") { run.outcome = "capped" }
                let (outcome, pass) = scenario.judge(run)
                if run.outcome != "capped" { run.outcome = outcome } else { run.outcome = "capped: " + outcome }
                if pass { passes += 1 }
                let line = try JSONEncoder().encode(run)
                let h = try FileHandle(forWritingTo: Self.ensure(file))
                try h.seekToEnd(); try h.write(contentsOf: line + Data("\n".utf8)); try h.close()
                print("AUDIT \(env.spec.name) \(scenario.name) run \(i): \(pass ? "PASS" : "FAIL") — \(run.outcome) (\(run.cycles.count) cycles, \(String(format: "%.1f", run.seconds)) s)")
            }
            summary.append("\(scenario.name): \(passes)/\(env.runs)")
            if passes == 0 { failures.append(scenario.name) }
        }
        let report = "AUDIT SUMMARY \(env.spec.name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: env.out.appendingPathComponent("\(env.spec.name)-summary.txt"), atomically: true, encoding: .utf8)
        // The test itself only fails when a scenario never passes — the per-run numbers are the audit's evidence.
        XCTAssertTrue(failures.isEmpty, "scenarios with 0 passes: \(failures)")
    }

    static func ensure(_ file: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        return file
    }
}
