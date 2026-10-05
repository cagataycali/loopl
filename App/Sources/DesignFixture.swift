import Foundation
import Loopl

/// `--design-fixture [scene]` (DEBUG only): fills the chat with a fixed
/// transcript so screenshots and design work need no model. Scenes:
/// `empty` · `streaming` (default) · `tool` · `offline`. Never a runtime —
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

    @MainActor static func apply(to engine: Engine, settings: AppSettings) {
        let spec = engine.store.catalog.models.first { $0.id == "qwen3-0.6b-4bit" } ?? engine.store.catalog.models.first!
        engine.readiness = .ready(spec)
        settings.showPerformance = CommandLine.arguments.contains("--design-perf")
        if scene == "offline" { settings.offline = true }
        var t = Transcript()
        switch scene {
        case "empty":
            break
        case "downloading":
            engine.readiness = .downloading(spec, done: 162_000_000, total: spec.sizeBytes)
        case "tool":
            t.user("What time is it in Istanbul, and what is 23 × 47?")
            t.apply(.iterationStarted(1))
            t.apply(.text("Let me check both."))
            let c1 = ToolCall(id: "call_1", name: "current_time", arguments: ["timezone": .string("Europe/Istanbul")])
            let c2 = ToolCall(id: "call_2", name: "calculator", arguments: ["expression": .string("23*47")])
            t.apply(.assistantMessage(.assistant(text: "Let me check both.", toolCalls: [c1, c2])))
            t.apply(.toolStarted(c1)); t.apply(.toolFinished(ToolResult(callId: "call_1", name: "current_time", content: "2026-10-05T06:14:09+03:00 (Europe/Istanbul, Sunday)", isError: false, durationMs: 2.1)))
            t.apply(.toolStarted(c2)); t.apply(.toolFinished(ToolResult(callId: "call_2", name: "calculator", content: "23*47 = 1081", isError: false, durationMs: 0.4)))
            t.apply(.iterationStarted(2))
            t.apply(.text("It's **06:14** on Sunday morning in Istanbul, and 23 × 47 = **1081**."))
            t.apply(.finished(iterations: 2, reason: .answered))
        default: // streaming
            t.user("Explain what an agent loop is, in three short points, with a Swift example.")
            t.apply(.iterationStarted(1))
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
}
