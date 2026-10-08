import XCTest
import Loopl
@testable import LooplRuntimes

/// proof on the REAL stack (Agent + MLXModel on Metal, the app's prompt + tool list + `use_agent`):
/// (a) the parent delegates a fetch to a child with ONLY `http`, the child's answer comes back inline and the parent
/// uses it; (b) a background child (`wait:false`) returns `{pending}` at once, the hub's wake hook fires when it ends and
/// the wake turn makes the parent deliver the number. Runs only with `LOOPL_AUDIT_DIR`; writes
/// `LOOPL_AUDIT_OUT/<model>-use-agent.jsonl` (prompt as seen, raw output, calls, child events, final text).
///
///     LOOPL_AUDIT_DIR=~/loopl-train-models/loopl-2b-4bit LOOPL_AUDIT_OUT=/tmp/loopl-evidence LOOPL_AUDIT_RUNS=3 \
///       xcodebuild test -scheme Loopl-Package -destination 'platform=macOS,arch=arm64' \
///       -only-testing:LooplRuntimesTests/SubAgentLiveTests
final class SubAgentLiveTests: XCTestCase {
    /// The app default + the directive loopl-train's app-default.md adds (one sentence; `LOOPL_AUDIT_SYSTEM` overrides).
    static let systemPrompt = ProcessInfo.processInfo.environment["LOOPL_AUDIT_SYSTEM"] ??
        MemoryToolsAuditTests.systemPrompt + " Use use_agent for a side task or a long one: run spawns a sub-agent with only the tools you list; wait:false runs it in the background and you are woken with the result."

    struct Run: Codable {
        var model: String; var scenario: String; var run: Int
        var cycles: [ToolCallAuditTests.Cycle] = []
        var childEvents: [String] = []
        var finalText = ""; var wakeText = ""; var useAgentResult = ""; var useAgentResults: [String] = []; var outcome = ""; var pass = false; var seconds = 0.0
    }

    func testUseAgentLive() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 2, sizeBytes: 1_700_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 4, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-use-agent") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-use-agent.jsonl"); try? FileManager.default.removeItem(at: file)
        var summary: [String] = []

        for scenario in ["inline-http", "background-wake"] {
            var passes = 0
            for i in 1...runs {
                let hub = SubAgentHub()
                let lateTask = DetachedCollector(hub).task
                let gate = ModelGate()
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                let base: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()]
                let useAgent = UseAgentTool(hub: hub) { SubAgentContext(model: model, gate: gate, availableTools: base, hooks: [ApprovalPolicy(mode: .mutating)]) }
                let agent = Agent(model: model, tools: base + [useAgent], systemPrompt: Self.systemPrompt,
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 10)], retryStrategy: nil)
                await agent.setModelGate(gate)
                let finished = SABoxLive<SubAgentEnvelope>()
                // Only the background scenario waits on it; an expectation that is created and never waited on fails the test.
                let woke: XCTestExpectation? = scenario == "background-wake" ? expectation(description: "wake \(scenario) \(i)") : nil
                woke?.assertForOverFulfill = false
                await hub.setOnFinished { env in finished.value = env; woke?.fulfill() }

                var r = Run(model: name, scenario: scenario, run: i)
                let prompt = scenario == "inline-http"
                    ? "Use use_agent to delegate this to a sub-agent that has only the http tool: fetch https://example.com and report the page's <title>. Wait for it, then tell me the title."
                    : "Start a sub-agent in the background (use_agent with wait: false, tools: [\"calculator\"]) to compute 48213 * 7 exactly. Don't wait for it — just tell me it's running."
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(prompt)) {
                        rec.event(ev)
                        switch ev {
                        case .childStarted, .child, .childStatus: r.childEvents.append(Self.label(ev))
                        case .child(_, .approvalRequested(let req)):
                            r.childEvents.append("child approval \(req.title)")
                        case .approvalRequested(let req): _ = await agent.resolve(approval: req.id, .approve)
                        case .toolResult(let res) where res.name == "use_agent": r.useAgentResult = res.content; r.useAgentResults.append(res.content)
                        case .result(let res): r.finalText = res.message.text
                        default: break
                        }
                        if case .child(let id, .approvalRequested(let req)) = ev { _ = await hub.resolve(child: id, approval: req.id, .approve) }
                    }
                } catch { r.finalText = "ERROR \(error)" }
                r.cycles = rec.cycles()
                let calls = r.cycles.flatMap(\.calls)
                let spawned = calls.contains { $0.hasPrefix("use_agent") }

                if scenario == "inline-http" {
                    let childFetched = r.childEvents.contains { $0.hasPrefix("child toolStarted http") }
                    let gotTitle = r.useAgentResult.localizedCaseInsensitiveContains("example domain")
                    let used = r.finalText.localizedCaseInsensitiveContains("example domain")
                    r.pass = spawned && childFetched && gotTitle && used
                    r.outcome = "spawned=\(spawned) childFetched=\(childFetched) childResultHasTitle=\(gotTitle) parentUsedIt=\(used)"
                    lateTask.cancel()
                } else {
                    let pending = r.useAgentResults.contains { $0.contains("\"pending\":true") }
                    let backgrounded = calls.contains { $0.hasPrefix("use_agent") && $0.contains("false") }
                    // Two legitimate endings: (a) the parent called `result`, which waited, and delivered the number itself
                    // (the wake is then CLAIMED — the hub must not fire it); (b) the parent answered and the hub's wake
                    // fires → the host runs the synthetic turn on the SAME parent (what Engine.drainWakes does).
                    let env0 = await hub.envelope(spawnedId(calls, r.useAgentResults))
                    let deliveredInline = env0?.status == .done && r.finalText.replacingOccurrences(of: ",", with: "").contains("337491")
                    if deliveredInline {
                        r.childEvents.append("delivered inline via result (wake claimed)")
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        XCTAssertNil(finished.value, "wake must not fire when `result` delivered the answer inline")
                        if let env0 { finished.value = env0 }
                        woke?.fulfill(); if let woke { await fulfillment(of: [woke], timeout: 1) }
                    } else {
                        if let woke { await fulfillment(of: [woke], timeout: 180) }
                        _ = await lateTask.value
                        if let env = finished.value {
                            r.childEvents.append("wake \(env.status.rawValue) result=\(env.result ?? "-")")
                            do {
                                for try await ev in agent.stream(.text(SubAgentWake.prompt(for: env))) {
                                    rec.event(ev)
                                    if case .result(let res) = ev { r.wakeText = res.message.text }
                                }
                            } catch { r.wakeText = "ERROR \(error)" }
                            r.cycles = rec.cycles()
                        }
                    }
                    let childRight = (finished.value?.result ?? "").replacingOccurrences(of: ",", with: "").contains("337491")
                    let delivered = deliveredInline || r.wakeText.replacingOccurrences(of: ",", with: "").contains("337491")
                    r.pass = spawned && backgrounded && pending && childRight && delivered
                    r.outcome = "spawned=\(spawned) wait:false=\(backgrounded) pending=\(pending) childResult=\(childRight) delivered=\(delivered) via=\(deliveredInline ? "result-inline" : "wake")"
                }
                r.seconds = Date().timeIntervalSince(t0)
                if r.pass { passes += 1 }
                let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
                if !FileManager.default.fileExists(atPath: file.path) { try? Data().write(to: file) }
                if let data = try? enc.encode(r), let h = try? FileHandle(forWritingTo: file) {
                    h.seekToEndOfFile(); h.write(data); h.write("\n".data(using: .utf8)!); try? h.close()
                }
                print("[use_agent live] \(scenario) run \(i): \(r.pass ? "PASS" : "FAIL") — \(r.outcome) (\(Int(r.seconds)) s) final=\(r.finalText.prefix(160)) wake=\(r.wakeText.prefix(160))")
                await hub.stopAll()
            }
            summary.append("\(scenario) \(passes)/\(runs)")
        }
        print("[use_agent live] \(name): " + summary.joined(separator: " · "))
        try (summary.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("\(name)-use-agent-summary.txt"), atomically: true, encoding: .utf8)
    }

    /// The id the parent's first `use_agent run` produced (from its tool result JSON).
    func spawnedId(_ calls: [String], _ results: [String]) -> String {
        for r in results { if let range = r.range(of: "agent_[a-z0-9]+", options: .regularExpression) { return String(r[range]) } }
        return ""
    }

    static func label(_ ev: AgentEvent) -> String {
        switch ev {
        case .childStarted(let i): "childStarted \(i.name) tools=\(i.tools) bg=\(i.background)"
        case .childStatus(_, let s): "childStatus \(s.rawValue)"
        case .child(_, .toolStarted(let u)): "child toolStarted \(u.name) \(JSONValue.object(u.input).compact.prefix(120))"
        case .child(_, .toolResult(let r)): "child toolResult \(r.name) \(r.status.rawValue) \(r.content.prefix(120))"
        case .child(_, .result(let r)): "child result \(r.text.prefix(200))"
        case .child(_, .approvalRequested(let q)): "child approvalRequested \(q.title)"
        case .child: "child …"
        default: "\(ev)".prefix(60).description
        }
    }
}

/// Drains `hub.detachedEvents()` until the child settles (what Engine's subscription does in the app).
final class DetachedCollector: Sendable {
    let task: Task<[String], Never>
    init(_ hub: SubAgentHub) {
        task = Task {
            var n: [String] = []
            for await ev in hub.detachedEvents() {
                n.append(SubAgentLiveTests.label(ev))
                if case .childStatus(_, let s) = ev, s.isFinished { break }
            }
            return n
        }
    }
}

final class SABoxLive<T>: @unchecked Sendable { var value: T?; init() {} }
