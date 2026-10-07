import Foundation

/// A UI-ready view of the conversation, built by folding `AgentEvent`s.
/// Pure (no SwiftUI) so it is unit-testable and shared by every front end.
public struct TranscriptItem: Identifiable, Sendable, Hashable {
    /// What a row of the transcript shows.
    public enum Kind: Sendable, Hashable {
        case user(String)
        case assistant(String)
        case reasoning(String)
        case toolUse(ToolUse, result: ToolResult?)
        /// A tool call waiting for the human (`decision == nil`) or already answered.
        case approval(ApprovalRequest, decision: ApprovalDecision?)
        case note(String)
        /// A sub-agent (`use_agent`): header + its own nested transcript — the card the UI draws under the parent's tool row.
        case agent(SubAgentRun)
        /// Phase 7 `ask_user`: a question for the human (`answer == nil` → the card is waiting) or its settled state.
        /// Replaces the tool's own row; `toolUseId` is what the card answers through `agent.resolve(interrupt:)`.
        case ask(toolUseId: String, AskUserRequest, answer: AskUserAnswer?)
    }
    public var id = UUID()
    public var kind: Kind
    /// Pictures attached to this item — a user turn's attachments, or a tool's produced images (`ToolResult.images`).
    public var images: [ImageBlock] = []
    /// Phase 7: how many times the user tapped this tool row's control (the result shown is the LATEST one). 0 = never.
    public var controlTaps = 0
    /// Clips attached to a user turn (Phase 8). The file stays on disk; the block carries the poster + transcript.
    public var videos: [VideoBlock] = []
    public init(id: UUID = UUID(), kind: Kind, images: [ImageBlock] = [], videos: [VideoBlock] = []) { self.id = id; self.kind = kind; self.images = images; self.videos = videos }
}

/// The conversation as a UI renders it: rows built from agent events, plus metrics.
public struct Transcript: Sendable, Hashable {
    public var items: [TranscriptItem] = []
    public var metrics = Metrics()
    public var cycle = 0
    public var isRunning = false
    public var lastResult: AgentResult?
    /// Phase 6: the tool names the agent is offered in this conversation, as last announced by `.toolsChanged`
    /// (`nil` until the agent said anything — the host then shows its own defaults).
    public var toolsMounted: [String]?
    /// Approval cards still waiting for an answer.
    public var pendingApprovals: [ApprovalRequest] {
        items.compactMap { if case .approval(let r, nil) = $0.kind { return r }; return nil }
    }
    /// `ask_user` cards still waiting for an answer (toolUseIds).
    public var pendingAsks: [String] {
        items.compactMap { if case .ask(let id, _, nil) = $0.kind { return id }; return nil }
    }
    /// Internal (not private): `TranscriptEditing` resets them when the thread is truncated.
    var streamingIndex: Int?
    var reasoningIndex: Int?

    public init() {}

    public mutating func user(_ text: String, images: [ImageBlock] = [], videos: [VideoBlock] = []) { items.append(.init(kind: .user(text), images: images, videos: videos)); isRunning = true }
    public mutating func note(_ text: String) { items.append(.init(kind: .note(text))) }

    /// The host stopped the turn and the agent could not report it (STOP-LOCATION 2026-10-07 — the fallback behind
    /// `Agent.cancelRun()`): tool rows still open become "Tool execution cancelled", approval cards still waiting are
    /// denied as stopped, running sub-agent cards end, cursors reset, one "stopped" note. No-op when nothing runs.
    public static let stoppedNote = "Stopped"
    /// One line when a turn ends because something went wrong (the agent's `.forceStop`, or the host catching the same
    /// error): plain words first, the reason as the model/runtime gave it. IMPROVE-5: the host used to add a second
    /// `error: …` note with the identical text, so a failure read "stopped: X" *and* "error: X".
    public static func failureNote(_ why: String) -> String {
        let reason = why.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "Couldn't finish this answer." : "Couldn't finish this answer — \(reason)"
    }
    public mutating func stopped(_ note: String = Transcript.stoppedNote) {
        var touched = isRunning
        for i in items.indices {
            switch items[i].kind {
            case .toolUse(let u, nil):
                items[i].kind = .toolUse(u, result: .error(u, "Tool execution cancelled")); touched = true
            case .approval(let r, nil):
                items[i].kind = .approval(r, decision: .deny(reason: "stopped")); touched = true
            case .agent(var run) where !run.status.isFinished:
                run.status = .stopped; run.endedAt = Date(); run.transcript.stopped(note); items[i].kind = .agent(run); touched = true
            default: break
            }
        }
        isRunning = false; streamingIndex = nil; reasoningIndex = nil
        if touched { items.append(.init(kind: .note(note))) }
    }
    public mutating func clear() { items.removeAll(); metrics = Metrics(); cycle = 0; streamingIndex = nil; reasoningIndex = nil; isRunning = false; lastResult = nil }

    /// Phase 7 (controls): the result of a control TAP on the tool row `toolUseId` (the row's original call). The row keeps
    /// its arguments and id; its result becomes the fresh one (content, control, pictures) so the card shows the truth —
    /// "flashlight: off" with a "Turn on" switch — and `controlTaps` counts it. The row is NOT duplicated: a tap is not a
    /// model turn. An ERROR result (denied approval, torch busy) does not replace the row — the card keeps the last true
    /// state and the host shows the error elsewhere. Returns false when the row is gone or the result is an error.
    @discardableResult
    public mutating func applyControlResult(for toolUseId: String, _ r: ToolResult) -> Bool {
        guard !r.isError,
              let idx = items.lastIndex(where: { if case .toolUse(let u, _) = $0.kind { return u.toolUseId == toolUseId }; return false }),
              case .toolUse(let u, _) = items[idx].kind else { return false }
        var fresh = r; fresh.toolUseId = toolUseId
        items[idx].kind = .toolUse(u, result: fresh)
        items[idx].images = r.images
        items[idx].controlTaps += 1
        return true
    }

    /// Fold one event. Returns true when the loop ended.
    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> Bool {
        switch event {
        case .initEventLoop: break
        case .startEventLoop(let c):
            cycle = c; streamingIndex = nil; reasoningIndex = nil
        case .modelStreamChunk: break
        case .text(let t):
            if let idx = streamingIndex, case .assistant(let s) = items[idx].kind {
                items[idx].kind = .assistant(s + t)
            } else {
                items.append(.init(kind: .assistant(t))); streamingIndex = items.count - 1
            }
        case .textReplace(let s):
            if let idx = streamingIndex, case .assistant = items[idx].kind {
                items[idx].kind = .assistant(s)
            } else if !s.isEmpty {
                items.append(.init(kind: .assistant(s))); streamingIndex = items.count - 1
            }
        case .reasoning(let r):
            if let idx = reasoningIndex, case .reasoning(let s) = items[idx].kind {
                items[idx].kind = .reasoning(s + r)
            } else {
                items.append(.init(kind: .reasoning(r))); reasoningIndex = items.count - 1
            }
        case .toolUseStream: break
        case .metrics(let m): metrics = m
        case .modelMessage(let m):
            let text = m.text
            if let idx = streamingIndex {
                if text.isEmpty { items.remove(at: idx) } else { items[idx].kind = .assistant(text) }
                streamingIndex = nil
            } else if !text.isEmpty {
                items.append(.init(kind: .assistant(text)))
            }
            reasoningIndex = nil
        case .throttle(let d): items.append(.init(kind: .note("model busy — retrying in \(Int(d)) s")))
        case .approvalRequested(let req):
            if !items.contains(where: { if case .approval(let r, _) = $0.kind { return r.id == req.id }; return false }) {
                items.append(.init(kind: .approval(req, decision: nil)))
            }
        case .approvalResolved(let id, let decision):
            if let idx = items.lastIndex(where: { if case .approval(let r, _) = $0.kind { return r.id == id }; return false }),
               case .approval(let r, _) = items[idx].kind {
                items[idx].kind = .approval(r, decision: decision)
            }
        case .interruptRaised(let interrupt):
            if let toolUseId = AskUserTool.toolUseId(fromInterruptId: interrupt.id),
               let reason = interrupt.reason, let request = AskUserRequest(interruptReason: reason) {
                // `ask_user`: the question takes the place of the tool's own row (it was started just before).
                if let idx = items.lastIndex(where: { if case .toolUse(let u, nil) = $0.kind { return u.toolUseId == toolUseId }; return false }) {
                    items[idx].kind = .ask(toolUseId: toolUseId, request, answer: nil)
                } else if !items.contains(where: { if case .ask(let id, _, _) = $0.kind { return id == toolUseId }; return false }) {
                    items.append(.init(kind: .ask(toolUseId: toolUseId, request, answer: nil)))
                }
            } else {
                // Any other non-approval interrupt (a hook or a tool asking the human something):
                // show it as a note so no event is silently dropped from the transcript.
                items.append(.init(kind: .note("waiting for input: \(interrupt.name)")))
            }
        case .interruptResolved(let id, let response):
            if let toolUseId = AskUserTool.toolUseId(fromInterruptId: id),
               let idx = items.lastIndex(where: { if case .ask(let t, _, nil) = $0.kind { return t == toolUseId }; return false }),
               case .ask(_, let request, _) = items[idx].kind {
                // Passwords never reach the transcript: the card keeps the masked answer, only the tool result has the value.
                items[idx].kind = .ask(toolUseId: toolUseId, request, answer: AskUserAnswer(interruptResponse: response).masked(for: request))
            }
        case .toolStarted(let use):
            if !items.contains(where: { if case .toolUse(let u, _) = $0.kind { return u.toolUseId == use.toolUseId }; return false }) {
                items.append(.init(kind: .toolUse(use, result: nil)))
            }
        case .toolResult(let r):
            if let idx = items.lastIndex(where: { if case .toolUse(let u, nil) = $0.kind { return u.toolUseId == r.toolUseId }; return false }),
               case .toolUse(let u, _) = items[idx].kind {
                items[idx].kind = .toolUse(u, result: r); items[idx].images = r.images
            } else if let idx = items.lastIndex(where: { if case .ask(let id, _, _) = $0.kind { return id == r.toolUseId }; return false }) {
                // The ask card already holds the (masked) answer; a card still open here (an error result) settles as cancelled.
                if case .ask(let id, let request, nil) = items[idx].kind { items[idx].kind = .ask(toolUseId: id, request, answer: .cancelled) }
            } else {
                items.append(.init(kind: .toolUse(ToolUse(toolUseId: r.toolUseId, name: r.name, input: [:]), result: r), images: r.images))
            }
        case .toolResultMessage: break
        case .historyEdited(let edit): items.append(.init(kind: .note(edit.summary)))   // quiet marker; the rows above stay — the user's record is untouched
        case .systemPromptChanged(let change): items.append(.init(kind: .note(change.summary)))   // Phase 6 F: "system prompt … by the agent · revert in Settings"
        case .forceStop(let why): items.append(.init(kind: .note(Self.failureNote(why))))
        case .toolsChanged(let mounted): toolsMounted = mounted            // Phase 6: the host shows "mounted for this conversation"
        case .result(let r):
            isRunning = false; lastResult = r
            if r.stopReason == .cancelled {
                // The placeholder the history needs is not a thing the model said — one quiet line, not two.
                if let last = items.indices.last, case .assistant(let t) = items[last].kind, t == Agent.cancelledPlaceholder { items.remove(at: last) }
                items.append(.init(kind: .note(Self.stoppedNote)))
            }
            return true
        case .childStarted(let info):
            // Right after the parent's `use_agent` row when it is here (several children of one turn stack in order);
            // at the end otherwise (a background child's late events after the turn).
            guard agentIndex(info.id) == nil else { break }
            let item = TranscriptItem(kind: .agent(SubAgentRun(info: info)))
            if let parent = items.lastIndex(where: { if case .toolUse(let u, _) = $0.kind { return u.toolUseId == info.parentToolUseId }; return false }) {
                var at = parent + 1
                while at < items.count, case .agent = items[at].kind { at += 1 }    // after its siblings
                items.insert(item, at: at)
            } else {
                items.append(item)
            }
        case .child(let id, let event):
            if let idx = agentIndex(id), case .agent(var run) = items[idx].kind {
                run.transcript.apply(event)
                if case .result = event, run.endedAt == nil { run.endedAt = Date() }
                items[idx].kind = .agent(run)
            }
        case .childStatus(let id, let status):
            if let idx = agentIndex(id), case .agent(var run) = items[idx].kind {
                run.status = status
                if status.isFinished, run.endedAt == nil { run.endedAt = Date() }
                if status == .background { run.info.background = true }
                items[idx].kind = .agent(run)
            }
        }
        return false
    }

    /// The `.agent` row of a child id.
    public func agentIndex(_ id: String) -> Int? {
        items.firstIndex { if case .agent(let r) = $0.kind { return r.info.id == id }; return false }
    }
    /// Every child shown in this transcript (nested ones excluded).
    public var agents: [SubAgentRun] { items.compactMap { if case .agent(let r) = $0.kind { return r }; return nil } }
}
