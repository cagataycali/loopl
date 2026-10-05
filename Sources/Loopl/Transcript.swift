import Foundation

/// A UI-ready view of the conversation, built by folding `AgentEvent`s.
/// Pure (no SwiftUI) so it is unit-testable and shared by every front end.
public struct TranscriptItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case user(String)
        case assistant(String)
        case toolCall(ToolCall, result: ToolResult?)
        case warning(String)
        case note(String)
    }
    public var id = UUID()
    public var kind: Kind
    public init(id: UUID = UUID(), kind: Kind) { self.id = id; self.kind = kind }
}

public struct Transcript: Sendable, Hashable {
    public var items: [TranscriptItem] = []
    public var metrics = Metrics()
    public var iteration = 0
    public var isRunning = false
    private var streamingIndex: Int?

    public init() {}

    public mutating func user(_ text: String) { items.append(.init(kind: .user(text))); isRunning = true }
    public mutating func note(_ text: String) { items.append(.init(kind: .note(text))) }
    public mutating func clear() { items.removeAll(); metrics = Metrics(); iteration = 0; streamingIndex = nil; isRunning = false }

    /// Fold one event. Returns true when the loop ended.
    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> Bool {
        switch event {
        case .iterationStarted(let i):
            iteration = i; streamingIndex = nil
        case .text(let t):
            if let idx = streamingIndex, case .assistant(let s) = items[idx].kind {
                items[idx].kind = .assistant(s + t)
            } else {
                items.append(.init(kind: .assistant(t))); streamingIndex = items.count - 1
            }
        case .metrics(let m): metrics = m
        case .assistantMessage(let m):
            if let idx = streamingIndex {
                if m.text.isEmpty { items.remove(at: idx) } else { items[idx].kind = .assistant(m.text) }   // markup stripped
                streamingIndex = nil
            } else if !m.text.isEmpty {
                items.append(.init(kind: .assistant(m.text)))
            }
        case .toolStarted(let call):
            items.append(.init(kind: .toolCall(call, result: nil)))
        case .toolFinished(let r):
            if let idx = items.lastIndex(where: { if case .toolCall(let c, nil) = $0.kind { return c.id == r.callId }; return false }),
               case .toolCall(let c, _) = items[idx].kind {
                items[idx].kind = .toolCall(c, result: r)
            }
        case .warning(let w): items.append(.init(kind: .warning(w)))
        case .finished(let n, let reason):
            isRunning = false
            if reason != .answered { items.append(.init(kind: .note("stopped: \(reason.rawValue) after \(n) iteration\(n == 1 ? "" : "s")"))) }
            return true
        }
        return false
    }
}
