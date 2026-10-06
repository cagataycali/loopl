import Foundation
import Loopl
import LooplAppleTools

/// `--design-fixture [scene]` (DEBUG only): fills the chat with a fixed
/// transcript so screenshots and design work need no model. Scenes:
/// `empty` · `streaming` (default) · `tool` · `offline` · `downloading` · `approval` (a POST waiting
/// for the human; tapping Approve/Deny scripts the follow-up) · `live` (a scripted
/// replay streamed over ~8 s — text chunks, two tool calls, final answer — for motion
/// captures; `--design-loop` repeats it). Never a runtime —
/// the SDK's FakeModel stays in Tests/.
enum DesignFixture {
    static var requested: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--design-fixture")
        #else
        return false
        #endif
    }
    static var scene: String {
        guard let i = CommandLine.arguments.firstIndex(of: "--design-fixture"), i + 1 < CommandLine.arguments.count,
              !CommandLine.arguments[i + 1].hasPrefix("-") else { return "streaming" }
        return CommandLine.arguments[i + 1]
    }

    /// The `tool` scene opens its tool rows so a screenshot shows the args/result card.
    static var expandTools: Bool { requested && scene == "tool" }

    /// `--design-tab chat|models|settings` picks the pane the fixture opens on.
    static var initialPane: RootView.Pane {
        #if DEBUG
        guard let i = CommandLine.arguments.firstIndex(of: "--design-tab"), i + 1 < CommandLine.arguments.count else { return .chat }
        switch CommandLine.arguments[i + 1] { case "models": return .models; case "settings": return .settings; default: return .chat }
        #else
        return .chat
        #endif
    }

    @MainActor static func apply(to engine: Engine, settings: AppSettings) {
        let specId = scene == "vision" ? "qwen3.5-0.8b-4bit" : "qwen3-0.6b-4bit"
        let spec = engine.store.catalog.models.first { $0.id == specId } ?? engine.store.catalog.models.first!
        engine.readiness = .ready(spec)
        settings.showPerformance = CommandLine.arguments.contains("--design-perf")
        settings.offline = scene == "offline"
        var t = Transcript()
        switch scene {
        case "empty", "offline":
            break
        case "downloading":
            engine.readiness = .downloading(spec, done: 162_000_000, total: spec.sizeBytes)
        case "live":
            engine.transcript = t
            Task { await replayLive(engine, loop: CommandLine.arguments.contains("--design-loop")) }
            return
        case "jump":
            // Streaming-jitter repro: a long Markdown answer in token-sized chunks (~40/s, like Qwen3.5-0.8B on a 16 Pro)
            // that overflows the viewport, so scroll-follow + per-chunk layout are both exercised.
            engine.transcript = t
            Task { await replayJump(engine) }
            return
        case "history":
            // Share to Hugging Face: three archived conversations (one with tool calls, one plain, one whose
            // only tool row never finished — the review sheet shows that one as skipped). Chat stays empty.
            // `--design-signed-out` forgets the Hugging Face token first (the sheet's token step is reachable
            // only when there is none; a previous fixture run may have stored one).
            if CommandLine.arguments.contains("--design-signed-out") { try? HFAccount.shared.clear() }
            seedHistory(engine, spec: spec)
        case "approval":
            t.user("Post a note to my notes API saying the build is green.")
            t.apply(.startEventLoop(cycle: 1))
            t.apply(.text("I'll post it now."))
            let use = approvalUse
            t.apply(.modelMessage(.assistant(text: "I'll post it now.", toolUses: [use])))
            t.apply(.approvalRequested(HttpTool().requiresApproval(for: use.input)!.with(id: use.toolUseId)))
        case "apple":
            // On-device Apple tools: detect_language and generate_voice run FOR REAL through the
            // tools; generate_image runs for real where ImagePlayground is available (device with
            // Apple Intelligence) and otherwise shows the flat ImageCodec fixture, labelled as such.
            engine.transcript = t
            Task { await replayApple(engine) }
            return
        case "tool":
            t.user("What time is it in Istanbul, and what is 23 × 47?")
            t.apply(.startEventLoop(cycle: 1))
            t.apply(.text("Let me check both."))
            let c1 = ToolUse(toolUseId: "tooluse_1", name: "current_time", input: ["timezone": .string("Europe/Istanbul")])
            let c2 = ToolUse(toolUseId: "tooluse_2", name: "calculator", input: ["expression": .string("23*47")])
            t.apply(.modelMessage(.assistant(text: "Let me check both.", toolUses: [c1, c2])))
            t.apply(.toolStarted(c1)); t.apply(.toolResult(ToolResult(toolUseId: "tooluse_1", name: "current_time", content: "2026-10-05T06:14:09+03:00 (Europe/Istanbul, Sunday)", durationMs: 2.1)))
            t.apply(.toolStarted(c2)); t.apply(.toolResult(ToolResult(toolUseId: "tooluse_2", name: "calculator", content: "23*47 = 1081", durationMs: 0.4)))
            t.apply(.startEventLoop(cycle: 2))
            t.apply(.text("It's **06:14** on Sunday morning in Istanbul, and 23 × 47 = **1081**."))
            t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("It's **06:14** on Sunday morning in Istanbul, and 23 × 47 = **1081**."), metrics: EventLoopMetrics())))
        case "edit":
            // Hold-to-edit (lane EDIT-MESSAGE): a settled two-turn thread; holding "And in Tokyo?" → Edit /
            // Copy / Delete from here, holding an answer → Copy / Retry. Save & regenerate and Retry are
            // scripted (`regenerate`) because the fixture has no model behind it.
            t.user("What time is it in Istanbul?")
            t.apply(.startEventLoop(cycle: 1))
            let c = ToolUse(toolUseId: "tooluse_e1", name: "current_time", input: ["timezone": .string("Europe/Istanbul")])
            t.apply(.modelMessage(.assistant(text: "", toolUses: [c])))
            t.apply(.toolStarted(c)); t.apply(.toolResult(ToolResult(toolUseId: "tooluse_e1", name: "current_time", content: "2026-10-06T06:14:09+03:00 (Europe/Istanbul, Tuesday)", durationMs: 1.8)))
            t.apply(.startEventLoop(cycle: 2))
            t.apply(.text("It's **06:14** on Tuesday morning in Istanbul."))
            t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("It's **06:14** on Tuesday morning in Istanbul."), metrics: EventLoopMetrics())))
            t.user("And in Tokyo?")
            t.apply(.startEventLoop(cycle: 1))
            t.apply(.text("Tokyo is six hours ahead of Istanbul, so it's **12:14** there."))
            t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("Tokyo is six hours ahead of Istanbul, so it's **12:14** there."), metrics: EventLoopMetrics())))
        case "vision":
            // The exact exchange the macOS proof produced with Qwen3.5-0.8B-4bit on Tests/…/Fixtures/vision-test.png.
            let png = Bundle.main.url(forResource: "vision-test", withExtension: "png").flatMap { try? Data(contentsOf: $0) } ?? Data()
            let img = ImageBlock(data: png, mime: "image/png", width: 640, height: 400, alt: "test card: red circle, blue square, LOOPL 42")
            t.user("What do you see? Then multiply the number by 3.", images: [img])
            t.apply(.startEventLoop(cycle: 1))
            t.apply(.text("A red circle and a blue square on a paper background, with **LOOPL 42** written underneath."))
            let c = ToolUse(toolUseId: "tooluse_v1", name: "calculator", input: ["expression": .string("42 * 3")])
            t.apply(.modelMessage(.assistant(text: "A red circle and a blue square on a paper background, with **LOOPL 42** written underneath.", toolUses: [c])))
            t.apply(.toolStarted(c)); t.apply(.toolResult(ToolResult(toolUseId: "tooluse_v1", name: "calculator", content: "42 * 3 = 126", durationMs: 0.3)))
            t.apply(.startEventLoop(cycle: 2))
            t.apply(.text("42 × 3 = **126**."))
            t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("42 × 3 = **126**."), metrics: EventLoopMetrics())))
        default: // streaming
            t.user("Explain what an agent loop is, in three short points, with a Swift example.")
            t.apply(.startEventLoop(cycle: 1))
            t.apply(.text("""
            An agent loop is the smallest program that lets a language model *act*:

            1. **Ask** — the model reads the conversation and either answers or asks for a tool.
            2. **Act** — the app runs the tool and appends the result as a new message.
            3. **Repeat** — the model reads the result and continues, until it answers plainly.

            ```swift
            let agent = Agent(model: model, tools: [Clock(), Calculator()])
            for try await event in agent.stream("what time is it in Istanbul?") {
                if case .text(let delta) = event { print(delta, terminator: "") }
            }
            ```

            loopl never caps the number of rounds — the only limit is the model's context window, which it
            """))
            var m = Metrics(); m.ttftMs = 212; m.tokensPerSecond = 41.7; m.promptTokens = 318; m.generatedTokens = 156; m.contextUsed = 474; m.contextMax = 8192
            t.apply(.metrics(m))
        }
        engine.transcript = t
    }

    /// `history` scene: fixed ids so the UITest and the proof push are reproducible run to run.
    @MainActor static func seedHistory(_ engine: Engine, spec: ModelSpec) {
        let tools: [ToolSpec] = [CurrentTimeTool().toolSpec, CalculatorTool().toolSpec]
        let day: TimeInterval = 86_400
        let threads: [SavedConversation] = [
            SavedConversation(id: UUID(uuidString: "8A6C0A1E-0001-4D8B-9B3C-5E0D2F7A1001")!, title: "What time is it in Istanbul, and what is 23 × 47?",
                              updated: Date().addingTimeInterval(-2 * 3600), modelName: spec.name,
                              items: [.user("What time is it in Istanbul, and what is 23 × 47?"),
                                      .assistant("Let me check both."),
                                      .tool(name: "current_time", args: ["timezone": .string("Europe/Istanbul")], result: "2026-10-06 07:41 (Europe/Istanbul, UTC+3)", isError: false, ms: 1.2),
                                      .tool(name: "calculator", args: ["expression": .string("23*47")], result: "23*47 = 1081", isError: false, ms: 0.4),
                                      .assistant("It is **07:41** in Istanbul, and 23 × 47 = **1081**.")],
                              modelId: spec.repo, tools: tools),
            SavedConversation(id: UUID(uuidString: "8A6C0A1E-0002-4D8B-9B3C-5E0D2F7A1002")!, title: "Explain what an agent loop is, in three short points",
                              updated: Date().addingTimeInterval(-day), modelName: spec.name,
                              items: [.user("Explain what an agent loop is, in three short points"),
                                      .assistant("1. **Ask** — the model reads the conversation and either answers or asks for a tool.\n2. **Act** — the app runs the tool and appends the result.\n3. **Repeat** — until the model answers plainly. loopl never caps the rounds.")],
                              modelId: spec.repo, tools: tools),
            SavedConversation(id: UUID(uuidString: "8A6C0A1E-0003-4D8B-9B3C-5E0D2F7A1003")!, title: "Fetch https://loopl.dev and summarise it",
                              updated: Date().addingTimeInterval(-3 * day), modelName: spec.name,
                              items: [.user("Fetch https://loopl.dev and summarise it"),
                                      .tool(name: "http", args: ["url": .string("https://loopl.dev")], result: nil, isError: false, ms: 0)],
                              modelId: spec.repo, tools: tools + [HttpTool().toolSpec]),
        ]
        threads.reversed().forEach { engine.archive.upsert($0) }
    }

    static let approvalUse = ToolUse(toolUseId: "tooluse_post", name: "http",
                                     input: ["method": "POST", "url": "https://notes.example.com/api/notes",
                                             "headers": ["Authorization": "Bearer n0tes-secret", "Accept": "application/json"],
                                             "body": ["text": "Build is green ✓", "tags": ["ci", "loopl"]]])

    /// The `approval` scene has no agent behind it: script what the loop would do after the card is answered.
    @MainActor static func resolve(_ engine: Engine, _ req: ApprovalRequest, _ decision: ApprovalDecision) async {
        func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        _ = engine.transcript.apply(.approvalResolved(id: req.id, decision))
        let use = ToolUse(toolUseId: req.id, name: req.toolName, input: decision.input(default: req.input) ?? req.input)
        await sleep(0.35)
        if decision.isApproved {
            _ = engine.transcript.apply(.toolStarted(use)); engine.haptics.emit(.toolStart)
            await sleep(1.1)
            _ = engine.transcript.apply(.toolResult(ToolResult(toolUseId: use.toolUseId, name: use.name,
                                                               content: "HTTP 201 application/json\n{\"id\":\"n_8f21\",\"text\":\"Build is green ✓\"}", durationMs: 1086)))
            engine.haptics.emit(.toolFinish)
            await sleep(0.5)
            _ = engine.transcript.apply(.startEventLoop(cycle: 2))
            await sleep(0.3)
            for w in "Posted — your note **n_8f21** is saved.".split(separator: " ") { _ = engine.transcript.apply(.text(String(w) + " ")); await sleep(0.04) }
        } else {
            _ = engine.transcript.apply(.toolResult(.error(use, "Tool call denied by the user. Do not retry it; continue without it.")))
            await sleep(0.5)
            _ = engine.transcript.apply(.startEventLoop(cycle: 2))
            await sleep(0.3)
            for w in "Okay — I won't post it. Tell me if you'd like it changed first.".split(separator: " ") { _ = engine.transcript.apply(.text(String(w) + " ")); await sleep(0.04) }
        }
        _ = engine.transcript.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("done"), metrics: EventLoopMetrics())))
    }

    /// The `edit` scene has no agent: script the regenerated answer to an edited / retried user turn.
    @MainActor static func regenerate(_ engine: Engine, text: String, images: [ImageBlock]) async {
        func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        engine.haptics.emit(.send)
        engine.transcript.user(text, images: images)
        await sleep(0.8)
        _ = engine.transcript.apply(.startEventLoop(cycle: 1))
        let lower = text.lowercased()
        let cities: [(String, (String, String, String))] = [("tokyo", ("Tokyo", "12:14", "six hours ahead")), ("london", ("London", "04:14", "two hours behind")),
                    ("new york", ("New York", "23:14 (Monday)", "seven hours behind")), ("berlin", ("Berlin", "05:14", "one hour behind")),
                    ("sydney", ("Sydney", "14:14", "eight hours ahead"))]
        // The LAST city named wins, so "Tokyo → London" edits answer about London.
        let city = cities.compactMap { k, v in lower.range(of: k).map { ($0.lowerBound, v) } }.max { $0.0 < $1.0 }?.1 ?? ("there", "the same", "")
        let answer = city.2.isEmpty ? "I'd need a city to compare with Istanbul — which one did you mean?"
                                    : "\(city.0) is \(city.2) of Istanbul time, so it's **\(city.1)** there right now."
        for tok in tokenize(answer) { _ = engine.transcript.apply(.text(tok)); await sleep(0.03) }
        _ = engine.transcript.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant(answer), metrics: EventLoopMetrics())))
    }

    @MainActor static func replayApple(_ engine: Engine) async {
        func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        let t0 = Date()
        engine.transcript.user("Draw a black smart ring on a slate tile, and tell me what language \"Merhaba dünya, bugün hava çok güzel\" is.")
        engine.haptics.emit(.send)
        await sleep(0.8)
        _ = engine.transcript.apply(.startEventLoop(cycle: 1))
        _ = engine.transcript.apply(.text("On it — drawing the ring and checking the language."))
        let c1 = ToolUse(toolUseId: "tooluse_a1", name: "generate_image", input: ["prompt": .string("a black smart ring on a slate tile, studio light"), "style": .string("illustration")])
        let c2 = ToolUse(toolUseId: "tooluse_a2", name: "detect_language", input: ["text": .string("Merhaba dünya, bugün hava çok güzel")])
        _ = engine.transcript.apply(.modelMessage(.assistant(text: "On it — drawing the ring and checking the language.", toolUses: [c1, c2])))
        _ = engine.transcript.apply(.toolStarted(c1)); engine.haptics.emit(.toolStart)
        _ = engine.transcript.apply(.toolStarted(c2)); engine.haptics.emit(.toolStart)
        // detect_language: the real tool.
        let langText = (try? await DetectLanguageTool().call(c2.input)) ?? "language: undetermined"
        _ = engine.transcript.apply(.toolResult(ToolResult(toolUseId: c2.toolUseId, name: c2.name, content: langText, durationMs: 3))); engine.haptics.emit(.toolFinish)
        // generate_image: real when the device can; otherwise the fixture image, labelled.
        var imageResult: ToolResult
        if GenerateImageTool.availability().available, let out = try? await GenerateImageTool().callOutput(c1.input) {
            imageResult = ToolResult(toolUseId: c1.toolUseId, name: c1.name, content: out.text, durationMs: Date().timeIntervalSince(t0) * 1000, images: out.images)
        } else {
            await sleep(1.6)
            let reason = GenerateImageTool.availability().reason
            if let cg = ImageCodec.testImage(width: 1024, height: 1024), let block = try? ImageCodec.jpeg(cg, alt: "design fixture — not a generated image (\(reason))") {
                imageResult = ToolResult(toolUseId: c1.toolUseId, name: c1.name, content: "DESIGN FIXTURE: generate_image is unavailable here (\(reason)); showing a flat placeholder image, 1024×1024.", durationMs: 1612, images: [block])
            } else {
                imageResult = .error(c1, reason)
            }
        }
        _ = engine.transcript.apply(.toolResult(imageResult)); engine.haptics.emit(imageResult.isError ? .error : .toolFinish)
        await sleep(0.5)
        _ = engine.transcript.apply(.startEventLoop(cycle: 2))
        let answer = "Here's the ring. The sentence is **Turkish** — \"Hello world, the weather is lovely today.\""
        _ = engine.transcript.apply(.text(answer))
        _ = engine.transcript.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant(answer), metrics: EventLoopMetrics())))
    }

    /// Streams the `tool` scene over time the way a real run looks: ~30 chunks/s text, two tool
    /// calls that take a moment, a second cycle, the answer. Drives the engine's haptic bus too.
    @MainActor static func replayLive(_ engine: Engine, loop: Bool) async {
        func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func stream(_ text: String, cps: Double = 30) async {
            var buf = ""
            for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                buf += (buf.isEmpty ? "" : " ") + word
                _ = engine.transcript.apply(.text(String(word) + " "))
                await sleep(1 / cps)
            }
        }
        repeat {
            engine.transcript.clear()
            await sleep(1.2)
            engine.transcript.user("What time is it in Istanbul, and what is 23 × 47?")
            engine.haptics.emit(.send)
            await sleep(0.9)
            _ = engine.transcript.apply(.startEventLoop(cycle: 1))
            await stream("Let me check both of those for you.")
            let c1 = ToolUse(toolUseId: "tooluse_1", name: "current_time", input: ["timezone": .string("Europe/Istanbul")])
            let c2 = ToolUse(toolUseId: "tooluse_2", name: "calculator", input: ["expression": .string("23*47")])
            _ = engine.transcript.apply(.modelMessage(.assistant(text: "Let me check both of those for you.", toolUses: [c1, c2])))
            await sleep(0.3)
            _ = engine.transcript.apply(.toolStarted(c1)); engine.haptics.emit(.toolStart)
            await sleep(0.25)
            _ = engine.transcript.apply(.toolStarted(c2)); engine.haptics.emit(.toolStart)
            await sleep(1.4)
            _ = engine.transcript.apply(.toolResult(ToolResult(toolUseId: "tooluse_1", name: "current_time", content: "2026-10-05T06:14:09+03:00 (Europe/Istanbul, Sunday)", durationMs: 1402))); engine.haptics.emit(.toolFinish)
            await sleep(0.6)
            _ = engine.transcript.apply(.toolResult(ToolResult(toolUseId: "tooluse_2", name: "calculator", content: "23*47 = 1081", durationMs: 0.4))); engine.haptics.emit(.toolFinish)
            await sleep(0.5)
            _ = engine.transcript.apply(.startEventLoop(cycle: 2))
            await sleep(0.4)
            await stream("It's **06:14** on Sunday morning in Istanbul, and 23 × 47 = **1081**. Both answers came from tools running on this iPhone — nothing left the device.")
            var m = Metrics(); m.ttftMs = 212; m.tokensPerSecond = 41.7; m.promptTokens = 318; m.generatedTokens = 56; m.contextUsed = 374; m.contextMax = 8192
            _ = engine.transcript.apply(.metrics(m))
            _ = engine.transcript.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("done"), metrics: EventLoopMetrics())))
            await sleep(3)
        } while loop
    }
}

extension DesignFixture {
    /// The text the `jump` scene streams — bold, lists, a code fence, long paragraphs: every reflow case.
    static let jumpAnswer = """
    An **agent loop** is the smallest program that lets a language model *act* instead of only answering. Here is how loopl runs it on this phone, step by step.

    1. **Ask** — the model reads the whole conversation and either answers or asks for a tool with a structured call.
    2. **Act** — the app runs that tool locally (clock, calculator, `http` with your approval) and appends the result as a new message.
    3. **Repeat** — the model reads the result and continues; there is no cap on rounds, only the context window.

    ```swift
    let agent = Agent(model: model, tools: [Clock(), Calculator()])
    for try await event in agent.stream("what time is it in Istanbul?") {
        if case .text(let delta) = event { print(delta, terminator: "") }
    }
    ```

    Why does this matter on a device? Because every token is produced *here*: nothing leaves the phone, the loop keeps running on a plane, and a tool result is just another message the model gets to read. The runtime streams each chunk as it is decoded, so the first words appear after a few hundred milliseconds even on a 0.8B model.

    - MLX models run through `mlx-swift`, GGUF models through `llama.cpp`, and Apple's on-device model through FoundationModels.
    - Tool calls are parsed from the stream as they form, so a call can start before the sentence around it is finished.
    - When the context fills up, older tool results are trimmed first and the request is retried once.

    That is the whole algorithm: **ask, act, repeat** — the same cycle Strands Agents runs in Python, ported to Swift so it works with the model in your pocket.
    """

    /// Splits text into token-sized pieces (2–5 characters, markers like `**` and backticks often alone), the way a BPE stream arrives.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []; var buf = ""
        var rng = SystemRandomNumberGenerator()
        for ch in s {
            buf.append(ch)
            let cut = buf.count >= 5 || (buf.count >= 2 && Int.random(in: 0..<3, using: &rng) == 0) || ch == "\n" || (buf.count >= 2 && buf.hasSuffix("**"))
            if cut { out.append(buf); buf = "" }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    @MainActor static func replayJump(_ engine: Engine) async {
        func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        engine.transcript.clear()
        await sleep(1.0)
        engine.transcript.user("Explain what an agent loop is and how loopl runs it on my phone.")
        await sleep(0.6)
        _ = engine.transcript.apply(.startEventLoop(cycle: 1))
        for piece in tokenize(jumpAnswer) {
            _ = engine.transcript.apply(.text(piece))
            await sleep(1.0 / 40)
        }
        var m = Metrics(); m.ttftMs = 298; m.tokensPerSecond = 43; m.promptTokens = 212; m.generatedTokens = 420; m.contextUsed = 632; m.contextMax = 8192
        _ = engine.transcript.apply(.metrics(m))
        _ = engine.transcript.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant(jumpAnswer), metrics: EventLoopMetrics())))
    }
}

private extension ApprovalRequest {
    func with(id: String) -> ApprovalRequest { var c = self; c.id = id; return c }
}
