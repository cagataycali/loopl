import Testing
import Foundation
import Loopl
import LooplUI
import SwiftUI

/// The chip on a sub-agent's card: `SubAgentStatus` plus the one derived state — a child whose
/// transcript holds an unanswered approval is *waiting for you*, whatever the hub calls it.
struct AgentCardStateTests {
    static let info = SubAgentInfo(id: "agent_1", parentToolUseId: "tooluse_a1", name: "notes", systemPrompt: "You post notes.", input: "Post it", tools: ["http"], background: false)
    static func run(_ status: SubAgentStatus, pending: Bool = false, result: String? = nil) -> SubAgentRun {
        var t = Transcript(); t.isRunning = !status.isFinished
        if pending { t.apply(.approvalRequested(ApprovalRequest(id: "tooluse_p", toolName: "http", title: "POST x", method: "POST", url: "https://x"))) }
        if let result { t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant(result), metrics: EventLoopMetrics()))) }
        return SubAgentRun(info: info, status: status, transcript: t, endedAt: status.isFinished ? Date() : nil)
    }

    @Test func mirrorsTheHubStatus() {
        #expect(AgentCardState(Self.run(.queued)) == .queued)
        #expect(AgentCardState(Self.run(.running)) == .running)
        #expect(AgentCardState(Self.run(.background)) == .background)
        #expect(AgentCardState(Self.run(.done)) == .done)
        #expect(AgentCardState(Self.run(.failed)) == .failed)
        #expect(AgentCardState(Self.run(.stopped)) == .stopped)
    }

    @Test func pendingApprovalWins_whileRunningOrBackground_notOnceFinished() {
        #expect(AgentCardState(Self.run(.running, pending: true)) == .waiting)
        #expect(AgentCardState(Self.run(.background, pending: true)) == .waiting, "a background child needing a human is the loudest state")
        var done = Self.run(.failed); done.transcript.apply(.approvalRequested(ApprovalRequest(id: "x", toolName: "http", title: "t")))
        #expect(AgentCardState(done) == .failed, "a finished child never says waiting")
    }

    @Test func foldDefaultsAndLabels() {
        #expect(AgentCardState.running.defaultExpanded && AgentCardState.waiting.defaultExpanded)
        for s in [AgentCardState.queued, .background, .done, .failed, .stopped] { #expect(!s.defaultExpanded, "\(s) folds by default") }
        #expect(AgentCardState.waiting.label == "waiting for you")
        #expect([AgentCardState.done, .failed, .stopped].allSatisfy(\.isFinished) && ![AgentCardState.running, .waiting, .background, .queued].contains(where: \.isFinished))
    }

    @Test func transcriptViewListsOnlyUnfinishedBackgroundChildren() {
        var t = Transcript()
        t.user("go")
        let use = ToolUse(toolUseId: "tooluse_a1", name: "use_agent", input: ["wait": .bool(false)])
        t.apply(.modelMessage(.assistant(text: "", toolUses: [use])))
        t.apply(.toolStarted(use))
        var bg = Self.info; bg.background = true
        t.apply(.childStarted(bg)); t.apply(.childStatus(id: bg.id, .background))
        var fg = Self.info; fg.id = "agent_2"
        t.apply(.childStarted(fg)); t.apply(.childStatus(id: fg.id, .running))
        typealias View = AgentTranscriptView<EmptyView, EmptyView>
        #expect(View.backgroundAgents(t).map(\.info.id) == ["agent_1"])
        t.apply(.childStatus(id: bg.id, .done))
        #expect(View.backgroundAgents(t).isEmpty)
    }
}
