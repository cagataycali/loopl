import Foundation

/// A UI-ready view of the conversation, built by folding `AgentEvent`s.
/// Pure (no SwiftUI) so it is unit-testable and shared by every front end.
public struct TranscriptItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case user(String)
        case assistant(String)
        case reasoning(String)
        case toolUse(ToolUse, result: ToolResult?)
        case note(String)
    }
    public var id = UUID()
    public var kind: Kind
    public init(id: UUID = UUID(), kind: Kind) { self.id = id; self.kind = kind }
}

public struct Transcript: Sendable, Hashable {
    public var items: [TranscriptItem] = []
    public var metrics = Metrics()
    public var cycle = 0
    public var isRunning = false
    public var lastResult: AgentResult?
    private var streamingIndex: Int?
    private var reasoningIndex: Int?

    public init() {}

    public mutating func user(_ text: String) { items.append(.init(kind: .user(text))); isRunning = true }
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
        case .toolStarted(let use):
            if !items.contains(where: { if case .toolUse(let u, _) = $0.kind { return u.toolUseId == use.toolUseId }; return false }) {
                items.append(.init(kind: .toolUse(use, result: nil)))
            }
        case .toolResult(let r):
            if let idx = items.lastIndex(where: { if case .toolUse(let u, nil) = $0.kind { return u.toolUseId == r.toolUseId }; return false }),
               case .toolUse(let u, _) = items[idx].kind {
                items[idx].kind = .toolUse(u, result: r)
            } else {
                items.append(.init(kind: .toolUse(ToolUse(toolUseId: r.toolUseId, name: r.name, input: [:]), result: r)))
            }
        case .toolResultMessage: break
        case .forceStop(let why): items.append(.init(kind: .note("stopped: \(why)")))
        case .result(let r):
            isRunning = false; lastResult = r
            if r.stopReason == .cancelled { items.append(.init(kind: .note("cancelled"))) }
            return true
        }
        return false
    }
}
