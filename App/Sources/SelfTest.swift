import SwiftUI
import Loopl
import LooplRuntimes
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Headless device proof. Launch with
///   xcrun devicectl device process launch --console --terminate-existing --device <udid> technology.tiny.loopl -- --selftest
/// Options: --selftest-model <catalog id> (default qwen3-1.7b-4bit), --selftest-offline (flip the
/// offline guard before loading: proves inference needs no network), --selftest-prompt "<text>".
/// Prints ONE line `LOOPL_SELFTEST {json}` to stdout, writes Documents/selftest.json, exits 0 (1 on failure).
/// DEBUG builds only — a Release build ignores the argument.
enum SelfTest {
    static var requested: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--selftest")
        #else
        return false
        #endif
    }
    static func arg(_ name: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static func log(_ s: String) { print("[selftest] \(s)"); fflush(stdout) }

    @MainActor
    static func run(settings: AppSettings, store: ModelStore, onLog: @escaping (String) -> Void) async -> Never {
        var report: [String: Any] = ["ok": false, "device": UIDevice.current.model, "os": UIDevice.current.systemVersion,
                                     "ram_physical": MemoryBudget.physical, "ram_available_start": MemoryBudget.available]
        func emit(_ s: String) { log(s); onLog(s) }
        func finish(_ ok: Bool) -> Never {
            report["ok"] = ok
            report["ram_available_end"] = MemoryBudget.available
            let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data()
            let line = String(decoding: data, as: UTF8.self)
            print("LOOPL_SELFTEST \(line)"); fflush(stdout)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? data.write(to: docs.appendingPathComponent("selftest.json"))
            exit(ok ? 0 : 1)
        }
        do {
            let modelId = arg("--selftest-model") ?? "qwen3-1.7b-4bit"
            let offline = CommandLine.arguments.contains("--selftest-offline")
            let prompt = arg("--selftest-prompt") ?? "what time is it in Istanbul and what is 23*47? then remember the answer under the key 'proof' and recall it"
            report["model"] = modelId; report["offline"] = offline; report["prompt"] = prompt
            guard let spec = store.catalog.models.first(where: { $0.id == modelId }) else { throw ModelError("no catalog entry \(modelId)") }

            // 4) Foundation Models availability (iOS 26+), honest reason.
            let fm = AppleFoundationModel.availability()
            report["fm_available"] = fm.available; report["fm_reason"] = fm.reason
            emit("FoundationModels: \(fm.available ? "available" : "unavailable — \(fm.reason)")")

            // 1) download if missing
            NetworkPolicy.setOffline(false)
            store.refresh()
            if store.localDirectory(spec) == nil {
                if offline { throw ModelError("--selftest-offline but \(spec.name) is not on disk; run the online selftest first") }
                emit("downloading \(spec.repo) (\(spec.sizeLabel))…")
                let t0 = Date()
                store.download(spec)
                var lastPct = -10
                while true {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    switch store.states[spec.id] ?? .notDownloaded {
                    case .downloading(let done, let total, let fd, let files):
                        let pct = total > 0 ? Int(Double(done) * 100 / Double(total)) : 0
                        if pct >= lastPct + 10 { lastPct = pct; emit("  \(pct)% · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) · file \(fd + 1)/\(files)") }
                        continue
                    case .downloaded(let bytes):
                        report["download_s"] = Date().timeIntervalSince(t0); report["download_bytes"] = bytes
                        emit("downloaded \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) in \(Int(Date().timeIntervalSince(t0))) s")
                    case .failed(let msg): throw ModelError("download failed: \(msg)")
                    case .paused, .notDownloaded: throw ModelError("download stopped unexpectedly")
                    }
                    break
                }
            } else {
                emit("\(spec.name) already on disk")
            }
            guard let dir = store.localDirectory(spec) else { throw ModelError("model directory missing after download") }

            if offline {
                NetworkPolicy.setOffline(true)
                emit("offline guard ON — HubApi/URLSession paths now refuse")
                do { _ = try await HttpGetTool().call(["url": "https://huggingface.co"]); report["offline_http_refused"] = false }
                catch { report["offline_http_refused"] = true; emit("http_get refused: \(error.localizedDescription)") }
            }

            // 2) load
            let model = MLXModel()
            let tLoad = Date()
            try await model.load(spec, from: dir) { _ in }
            report["load_s"] = Date().timeIntervalSince(tLoad)
            report["ram_available_after_load"] = MemoryBudget.available
            emit("loaded in \(String(format: "%.1f", Date().timeIntervalSince(tLoad))) s · available memory \(MemoryBudget.label(MemoryBudget.available))")

            // 3) agent run with the built-in tools
            var cfg = AgentConfig()
            cfg.family = spec.family
            cfg.params.contextLength = min(8192, spec.ctxNominal)
            cfg.params.maxTokens = 512
            cfg.budget = Budget(maxIterations: 12, maxWallTime: 600)   // a cap only for the unattended proof
            let tools: [any Loopl.Tool] = [CurrentTimeTool(), CalculatorTool(), DeviceInfoTool(), RememberTool(), RecallTool(), HttpGetTool()]
            let agent = Agent(model: model, tools: tools, systemPrompt: AppSettings.defaultSystemPrompt, config: cfg)
            var toolsUsed: [[String: Any]] = []
            var toolRounds = 0
            var answer = ""
            var metrics = Metrics()
            var warnings: [String] = []
            var text = ""
            let tRun = Date()
            for try await e in agent.stream(prompt) {
                switch e {
                case .iterationStarted(let i): emit("iteration \(i)"); text = ""
                case .text(let t): text += t
                case .assistantMessage(let m):
                    if !m.toolCalls.isEmpty { toolRounds += 1 }
                    emit("assistant: \(m.text.prefix(200))\(m.toolCalls.isEmpty ? "" : "  → calls \(m.toolCalls.map(\.name))")")
                    answer = m.text
                case .toolStarted(let c): emit("tool ▶ \(c.name) \(JSONValue.object(c.arguments).compact)")
                case .toolFinished(let r):
                    emit("tool \(r.isError ? "✗" : "✓") \(r.name) (\(Int(r.durationMs)) ms): \(r.content.prefix(120))")
                    toolsUsed.append(["name": r.name, "ms": r.durationMs, "error": r.isError, "result": String(r.content.prefix(300))])
                case .metrics(let m): metrics = m
                case .warning(let w): warnings.append(w); emit("⚠︎ \(w)")
                case .finished(let n, let reason):
                    emit("finished after \(n) iterations (\(reason.rawValue))")
                    report["iterations"] = n; report["finish_reason"] = reason.rawValue
                }
            }
            _ = text
            report["run_s"] = Date().timeIntervalSince(tRun)
            report["answer"] = answer
            report["tool_rounds"] = toolRounds
            report["tools"] = toolsUsed
            report["warnings"] = warnings
            report["ttft_ms"] = metrics.ttftMs
            report["tok_s"] = metrics.tokensPerSecond
            report["prompt_tokens"] = metrics.promptTokens
            report["generated_tokens"] = metrics.generatedTokens
            report["ctx_used"] = metrics.contextUsed; report["ctx_max"] = metrics.contextMax
            report["offline_ok"] = offline
            let has1081 = answer.contains("1081")
            let usedCalc = toolsUsed.contains { ($0["name"] as? String) == "calculator" }
            let usedTime = toolsUsed.contains { ($0["name"] as? String) == "current_time" }
            report["checks"] = ["answer_has_1081": has1081, "used_calculator": usedCalc, "used_current_time": usedTime, "tool_rounds_ge_1": toolRounds >= 1]
            emit("answer: \(answer)")
            await model.unload()
            finish(toolRounds >= 1 && (has1081 || usedCalc))
        } catch {
            report["error"] = error.localizedDescription
            emit("FAILED: \(error.localizedDescription)")
            finish(false)
        }
    }
}

struct SelfTestView: View {
    var settings: AppSettings
    var store: ModelStore
    @State private var lines: [String] = []
    var body: some View {
        VStack(alignment: .leading) {
            Text("loopl self-test").font(.headline)
            ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) } } }
        }
        .padding()
        .task { await SelfTest.run(settings: settings, store: store) { line in lines.append(line) } }
    }
}
