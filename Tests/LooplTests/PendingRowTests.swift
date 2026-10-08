import Testing
import Loopl
import LooplUI
import SwiftUI

/// The "…" row between the user's send and the first token (IMPROVE audit #4): shown only while the agent is
/// running and nothing of its answer is on screen yet, gone the moment text, reasoning or a tool row arrives.
struct PendingRowTests {
    typealias View = AgentTranscriptView<EmptyView, EmptyView>

    @Test func idleTranscriptShowsNothing() {
        var t = Transcript()
        #expect(!View.showsPending(t))
        t.user("hi"); t.isRunning = false
        #expect(!View.showsPending(t))
    }

    @Test func afterSendBeforeFirstToken() {
        var t = Transcript()
        t.user("What time is it?")                       // user() sets isRunning
        #expect(View.showsPending(t))
        t.apply(.startEventLoop(cycle: 1))
        #expect(View.showsPending(t), "a cycle starting is not yet an answer")
    }

    @Test func firstTextHidesIt() {
        var t = Transcript(); t.user("hi")
        t.apply(.startEventLoop(cycle: 1)); t.apply(.text("H"))
        #expect(!View.showsPending(t))
    }

    @Test func reasoningAndToolRowsHideIt() {
        var t = Transcript(); t.user("hi"); t.apply(.startEventLoop(cycle: 1))
        t.apply(.reasoning("thinking"))
        #expect(!View.showsPending(t))
        var u = Transcript(); u.user("hi"); u.apply(.startEventLoop(cycle: 1))
        let call = ToolUse(toolUseId: "c1", name: "calculator", input: ["expression": .string("1+1")])
        u.apply(.modelMessage(.assistant(text: "", toolUses: [call]))); u.apply(.toolStarted(call))
        #expect(!View.showsPending(u), "a running tool row is already visible progress")
    }

    @Test func backBetweenCycles() {
        // Tool finished, model is being asked again: the last item is the tool row (its own ✓ is enough) — no row.
        var t = Transcript(); t.user("hi"); t.apply(.startEventLoop(cycle: 1))
        let call = ToolUse(toolUseId: "c1", name: "calculator", input: ["expression": .string("1+1")])
        t.apply(.modelMessage(.assistant(text: "", toolUses: [call]))); t.apply(.toolStarted(call))
        t.apply(.toolResult(ToolResult(toolUseId: "c1", name: "calculator", content: "2", durationMs: 1)))
        t.apply(.startEventLoop(cycle: 2))
        #expect(!View.showsPending(t))
    }

    @Test func endOfTurnHidesIt() {
        var t = Transcript(); t.user("hi"); t.apply(.startEventLoop(cycle: 1))
        t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("x"), metrics: EventLoopMetrics())))
        #expect(!t.isRunning); #expect(!View.showsPending(t))
    }
}
