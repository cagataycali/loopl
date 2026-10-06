import SwiftUI
import Loopl
import LooplRuntimes
import LooplAppleTools
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Headless device proof. Launch with
///   xcrun devicectl device process launch --console --terminate-existing --device <udid> technology.tiny.loopl -- --selftest
/// Options: --selftest-vision (bundled vision-test.png → "what's in the image" + a tool call; default model
/// qwen3.5-0.8b-4bit unless --selftest-model/--selftest-hub says otherwise), --selftest-model <catalog id> (default qwen3-1.7b-4bit), --selftest-hub <owner/repo> (resolve ANY public
/// Hugging Face repo through HubCatalog instead of the catalog — the "any model" proof), --selftest-offline (flip the
/// offline guard before loading: proves inference needs no network), --selftest-prompt "<text>",
/// --selftest-turns <n> (n user turns on ONE agent — the per-runtime context-budget proof: each turn
/// reports estimated prompt tokens, kept messages and metrics.contextReductionCount).
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

    static let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest.log")
    /// stdout (for `devicectl --console`) AND Documents/selftest.log (pull it with `devicectl device copy from` while it runs).
    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        print("[selftest] \(s)"); fflush(stdout)
        if let h = try? FileHandle(forWritingTo: logURL) { try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: logURL) }
    }

    @MainActor
    static func run(settings: AppSettings, store: ModelStore, onLog: @escaping (String) -> Void) async -> Never {
        try? FileManager.default.removeItem(at: logURL)
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
        // --selftest-open-app <url> [--selftest-params '{json}']: the device-tools proof — no model, just the tool.
        // Works on the Simulator (maps://, https://…): the other app comes to the front and the result line says `opened: true`.
        if let url = arg("--selftest-open-app") {
            var input: [String: JSONValue] = ["url": .string(url)]
            if let p = arg("--selftest-params"), let d = p.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: d) { input["params"] = v }
            report["tool"] = "open_app"
            let approval = OpenAppTool().requiresApproval(for: input).map { "\($0.title) · \($0.detail ?? "")" } ?? "none (scheme allowed)"
            emit("approval: \(approval)"); report["approval"] = approval
            do {
                let out = try await OpenAppTool().call(input)
                emit(out); report["result"] = out
                try? await Task.sleep(for: .seconds(2))   // let the other app land before the host screenshots
                finish(out.hasPrefix("opened: true"))
            } catch { emit("open_app failed: \(error)"); report["error"] = "\(error)"; finish(false) }
        }
        do {
            let offline = CommandLine.arguments.contains("--selftest-offline")
            let vision = CommandLine.arguments.contains("--selftest-vision")
            let prompt = arg("--selftest-prompt") ?? (vision
                ? "Describe what you see in the image in one sentence (shapes, colours, any text). Then read the number written in it and use the calculator tool to multiply it by 3."
                : "what time is it in Istanbul and what is 23*47? then remember the answer under the key 'proof' and recall it")
            report["offline"] = offline; report["prompt"] = prompt; report["vision"] = vision
            // The picture the vision proof sends: App/Resources/vision-test.png (red circle, blue square, "LOOPL 42").
            var images: [ImageBlock] = []
            if vision {
                guard let url = Bundle.main.url(forResource: "vision-test", withExtension: "png"), let data = try? Data(contentsOf: url) else {
                    throw ModelError("vision-test.png is not in the app bundle")
                }
                images = [ImageBlock(data: data, mime: "image/png", width: 640, height: 400, alt: "test card")]
                report["image_bytes"] = data.count
            }
            let spec: ModelSpec
            if let hubRepo = arg("--selftest-hub") {
                // The "any model from Hugging Face" path: search-free resolve (repo ?blobs=true + config.json) → ModelSpec → store.add.
                NetworkPolicy.setOffline(false)
                let t0 = Date()
                let resolved = try await HubCatalog().resolve(hubRepo)
                spec = store.add(resolved)
                report["model"] = spec.id; report["hub_repo"] = hubRepo; report["hub_resolve_s"] = Date().timeIntervalSince(t0)
                report["hub_family"] = spec.family.rawValue; report["hub_tools_unverified"] = spec.toolsUnverified ?? false
                report["hub_ctx_nominal"] = spec.ctxNominal; report["hub_ctx_usable"] = spec.ctxUsable8GB; report["hub_size_bytes"] = spec.sizeBytes
                report["hub_fit"] = HubCatalog.Fit.verdict(bytes: spec.sizeBytes, available: MemoryBudget.budget).rawValue
                emit("hub: \(hubRepo) → \(spec.id) · \(spec.runtime.label) · \(spec.sizeLabel) · ctx \(spec.ctxUsable8GB)/\(spec.ctxNominal) · family \(spec.family.rawValue)\(spec.toolsUnverified == true ? " (tools unverified)" : "") · fit \(report["hub_fit"]!) · \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            } else {
                let modelId = arg("--selftest-model") ?? (vision ? "qwen3.5-0.8b-4bit" : "qwen3-1.7b-4bit")
                report["model"] = modelId
                guard let s = store.catalog.models.first(where: { $0.id == modelId }) else { throw ModelError("no catalog entry \(modelId)") }
                spec = s
            }
            if vision, !spec.supportsVision { throw ModelError("\(spec.id) has no vision tower — --selftest-vision needs a vision model (qwen3.5-*, qwen3-vl-*)") }
            report["model_vision"] = spec.supportsVision

            // 4) Foundation Models availability (iOS 26+), honest reason.
            let fm = AppleFoundationModel.availability()
            report["fm_available"] = fm.available; report["fm_reason"] = fm.reason
            emit("FoundationModels: \(fm.available ? "available" : "unavailable — \(fm.reason)")")

            // 1) download if missing
            NetworkPolicy.setOffline(false)
            store.refresh()
            // Apple Intelligence has no weights to fetch (`isDownloadable == false`, empty repo), so the
            // download/localDirectory dance below does not apply to it — without this branch
            // `--selftest-model apple-fm` tried to download "" and died on "model directory missing".
            // This is how the FM runtime gets proven on real hardware (the UI is the only other route).
            if !spec.isDownloadable {
                emit("\(spec.name) needs no download — runtime \(spec.runtime.rawValue)")
            } else if store.localDirectory(spec) == nil {
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
            // Nothing is read from `dir` for a runtime that owns no files; Documents is a valid, existing URL.
            let dir: URL
            if spec.isDownloadable {
                guard let d = store.localDirectory(spec) else { throw ModelError("model directory missing after download") }
                dir = d
            } else {
                dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            }

            if offline {
                NetworkPolicy.setOffline(true)
                emit("offline guard ON — HubApi/URLSession paths now refuse")
                do { _ = try await HttpTool().call(["url": "https://huggingface.co"]); report["offline_http_refused"] = false }
                catch { report["offline_http_refused"] = true; emit("http refused: \(error.localizedDescription)") }
            }

            // 2) load — the runtime the catalog row asks for (MLX or llama.cpp; Apple FM needs no file).
            let model: any Model
            switch spec.runtime {
            case .gguf: model = GGUFModel()
            case .appleFM: model = AppleFoundationModel()
            case .mlx: model = MLXModel()
            }
            report["runtime"] = spec.runtime.rawValue
            let tLoad = Date()
            try await model.load(spec, from: dir) { _ in }
            report["load_s"] = Date().timeIntervalSince(tLoad)
            report["ram_available_after_load"] = MemoryBudget.available
            emit("loaded in \(String(format: "%.1f", Date().timeIntervalSince(tLoad))) s · available memory \(MemoryBudget.label(MemoryBudget.available))")

            // 3) agent run with the built-in tools
            // No caps: the loop runs until the model stops. The unattended proof bounds itself by wall clock below.
            let tools: [any Loopl.Tool] = [CurrentTimeTool(), CalculatorTool(), DeviceInfoTool(), RememberTool(), RecallTool(), HttpTool()]
            let agent = Agent(model: model, tools: tools, systemPrompt: AppSettings.defaultSystemPrompt)
            var toolsUsed: [[String: Any]] = []
            var toolRounds = 0
            var answer = ""
            var metrics = Metrics()
            var warnings: [String] = []
            var text = ""
            let turns = max(1, Int(arg("--selftest-turns") ?? "1") ?? 1)
            var contextTrace: [[String: Any]] = []
            let tRun = Date()
            let deadline = Task { try await Task.sleep(nanoseconds: 600_000_000_000); emit("⚠︎ 10 min wall clock — cancelling the proof") }
            for turn in 0..<turns {
            let turnPrompt = turns == 1 ? prompt : "\(prompt) (turn \(turn + 1) of \(turns))"
            if turns > 1 { emit("── turn \(turn + 1)/\(turns)") }
            let input: Agent.Input = images.isEmpty ? .text(turnPrompt) : .messages([Loopl.Message.user(turnPrompt, images: images)])
            for try await e in agent.stream(input) {
                if deadline.isCancelled == false, Date().timeIntervalSince(tRun) > 600 { break }
                switch e {
                case .startEventLoop(let c): emit("cycle \(c)"); text = ""
                case .text(let t): text += t
                case .textReplace(let s): text = s
                case .modelMessage(let m):
                    if m.hasToolUse { toolRounds += 1 }
                    emit("assistant: \(m.text.prefix(200))\(m.toolUses.isEmpty ? "" : "  → calls \(m.toolUses.map(\.name))")")
                    answer = m.text
                case .toolStarted(let c): emit("tool ▶ \(c.name) \(JSONValue.object(c.input).compact)")
                case .toolResult(let r):
                    emit("tool \(r.isError ? "✗" : "✓") \(r.name) (\(Int(r.durationMs)) ms): \(r.content.prefix(120))")
                    toolsUsed.append(["name": r.name, "ms": r.durationMs, "error": r.isError, "result": String(r.content.prefix(300))])
                case .metrics(let m): metrics = m
                case .throttle(let d): warnings.append("throttled \(Int(d)) s"); emit("⚠︎ model busy, retrying in \(Int(d)) s")
                case .forceStop(let why): warnings.append(why); emit("⚠︎ \(why)")
                case .result(let r):
                    emit("finished after \(r.metrics.cycleCount) cycles (\(r.stopReason.rawValue))")
                    report["iterations"] = r.metrics.cycleCount; report["finish_reason"] = r.stopReason.rawValue
                default: break
                }
            }
            if turns > 1 {
                // The context budget, measured per turn: what the next prompt would cost (chars/4 ESTIMATE),
                // how many messages the manager kept, and how often the loop had to recover from an overflow.
                let msgs = await agent.messages
                let est = TokenEstimator.estimate(messages: msgs, systemPrompt: AppSettings.defaultSystemPrompt, toolSpecs: tools.map(\.toolSpec))
                let window = await model.contextWindow
                let reductions = await agent.eventLoopMetrics.contextReductionCount
                contextTrace.append(["turn": turn + 1, "messages": msgs.count, "est_prompt_tokens": est,
                                     "context_window": window, "context_reductions": reductions,
                                     "ctx_used_reported": metrics.contextUsed, "answer": String(answer.prefix(120))])
                emit("turn \(turn + 1): \(msgs.count) messages · ≈\(est) est. tokens of \(window) · reductions \(reductions)")
            }
            }
            deadline.cancel()
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
            if turns > 1 {
                report["turns"] = turns
                report["context_trace"] = contextTrace
                let window = await model.contextWindow
                let worst = contextTrace.compactMap { $0["est_prompt_tokens"] as? Int }.max() ?? 0
                report["context_window"] = window
                report["worst_est_prompt_tokens"] = worst
                report["context_reductions"] = await agent.eventLoopMetrics.contextReductionCount
                report["context_budget_held"] = worst < window
                emit("context: worst ≈\(worst) est. tokens of \(window) over \(turns) turns (estimate = chars/4)")
            }
            let usedCalc = toolsUsed.contains { ($0["name"] as? String) == "calculator" }
            emit("answer: \(answer)")
            await model.unload()
            if vision {
                // The card shows a red circle, a blue square and "LOOPL 42": the model must see shapes and read the number.
                let all = (answer + " " + toolsUsed.map { "\($0["result"] ?? "")" }.joined(separator: " ")).lowercased()
                let sawShape = all.contains("circle") || all.contains("round") || all.contains("square") || all.contains("rectangle")
                let read42 = all.contains("42") || all.contains("126")
                report["checks"] = ["saw_shape": sawShape, "read_42": read42, "used_calculator": usedCalc, "tool_rounds_ge_1": toolRounds >= 1,
                                    "image_tokens_in_prompt": metrics.promptTokens > 64]
                finish(sawShape && read42 && toolRounds >= 1)
            } else {
                let has1081 = answer.contains("1081")
                let usedTime = toolsUsed.contains { ($0["name"] as? String) == "current_time" }
                report["checks"] = ["answer_has_1081": has1081, "used_calculator": usedCalc, "used_current_time": usedTime, "tool_rounds_ge_1": toolRounds >= 1]
                finish(toolRounds >= 1 && (has1081 || usedCalc))
            }
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
