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
    }
    public var id = UUID()
    public var kind: Kind
    /// Pictures attached to this item — a user turn's attachments, or a tool's produced images (`ToolResult.images`).
    public var images: [ImageBlock] = []
    public init(id: UUID = UUID(), kind: Kind, images: [ImageBlock] = []) { self.id = id; self.kind = kind; self.images = images }
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
    /// Internal (not private): `TranscriptEditing` resets them when the thread is truncated.
    var streamingIndex: Int?
    var reasoningIndex: Int?

    public init() {}

    public mutating func user(_ text: String, images: [ImageBlock] = []) { items.append(.init(kind: .user(text), images: images)); isRunning = true }
    public mutating func note(_ text: String) { items.append(.init(kind: .note(text))) }
    public mutating func clear() { items.removeAll(); metrics = Metrics(); cycle = 0; streamingIndex = nil; reasoningIndex = nil; isRunning = false; lastResult = nil }

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
            // A non-approval interrupt (a hook or a tool asking the human something):
            // show it as a note so no event is silently dropped from the transcript.
            items.append(.init(kind: .note("waiting for input: \(interrupt.name)")))
        case .interruptResolved: break
        case .toolStarted(let use):
            if !items.contains(where: { if case .toolUse(let u, _) = $0.kind { return u.toolUseId == use.toolUseId }; return false }) {
                items.append(.init(kind: .toolUse(use, result: nil)))
            }
        case .toolResult(let r):
            if let idx = items.lastIndex(where: { if case .toolUse(let u, nil) = $0.kind { return u.toolUseId == r.toolUseId }; return false }),
               case .toolUse(let u, _) = items[idx].kind {
                items[idx].kind = .toolUse(u, result: r); items[idx].images = r.images
            } else {
                items.append(.init(kind: .toolUse(ToolUse(toolUseId: r.toolUseId, name: r.name, input: [:]), result: r), images: r.images))
            }
        case .toolResultMessage: break
        case .forceStop(let why): items.append(.init(kind: .note("stopped: \(why)")))
        case .toolsChanged(let mounted): toolsMounted = mounted            // Phase 6: the host shows "mounted for this conversation"
        case .result(let r):
            isRunning = false; lastResult = r
            if r.stopReason == .cancelled { items.append(.init(kind: .note("cancelled"))) }
            return true
        }
        return false
    }
}
