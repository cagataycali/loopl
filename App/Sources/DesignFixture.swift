import Foundation
import Loopl

/// `--design-fixture [scene]` (DEBUG only): fills the chat with a fixed
/// transcript so screenshots and design work need no model. Scenes:
/// `empty` · `streaming` (default) · `tool` · `offline` · `downloading` · `live` (a scripted
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
        let spec = engine.store.catalog.models.first { $0.id == "qwen3-0.6b-4bit" } ?? engine.store.catalog.models.first!
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
