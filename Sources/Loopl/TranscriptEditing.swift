import Foundation

// MARK: - Editing a conversation after the fact
//
// "Hold a message and edit it": the transcript is the user's view of the thread, so editing,
// retrying and deleting are TRANSCRIPT operations — pure, testable, no SwiftUI, no agent.
// The host (loopl's Engine) then rebuilds the model's history from the kept items with
// `messages` and starts a fresh `Agent` on it (`agent.setMessages`) — the event loop itself
// is untouched: the edited turn is an ordinary `agent.stream([.user(...)])`.

public extension Transcript {
    /// The index of the item with `id`, if it is still in the transcript.
    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    /// The item with `id`.
    func item(_ id: UUID) -> TranscriptItem? { items.first { $0.id == id } }

    /// The user turn an item belongs to: the item itself when it IS a user turn, else the last user
    /// turn before it (what "Retry" on an assistant row re-runs). `nil` when nothing precedes it.
    func userTurn(before id: UUID) -> TranscriptItem? {
        guard let i = index(of: id) else { return nil }
        return items[...i].last { if case .user = $0.kind { return true }; return false }
    }

    /// Everything strictly BEFORE the item with `id`: the item and all that followed it are gone.
    /// Streaming/reasoning cursors and the running flag are reset — the kept part is settled history.
    /// Metrics are kept (they describe what was spent). Unknown id → the transcript unchanged.
    func truncated(before id: UUID) -> Transcript {
        guard let i = index(of: id) else { return self }
        var t = self
        t.items = Array(items[..<i])
        t.isRunning = false
        t.lastResult = nil
        t.resetCursors()
        return t
    }

    /// Everything up to AND INCLUDING the item with `id` ("Delete from here" on the row after it,
    /// or the kept half when regenerating the answer to a user turn).
    func truncated(through id: UUID) -> Transcript {
        guard let i = index(of: id) else { return self }
        var t = self
        t.items = Array(items[...i])
        t.isRunning = false
        t.lastResult = nil
        t.resetCursors()
        return t
    }

    /// The model-facing history that corresponds to the visible items, as `Message`s:
    /// user text (+images) → `user`; assistant text → `assistant`; a tool row → an `assistant`
    /// message carrying the `toolUse` block followed by the `user` message carrying its `toolResult`
    /// (adjacent tool rows of one round fold into one assistant / one user message, like the loop
    /// emits them). Notes, reasoning and approval cards are UI-only and do not reach the model.
    /// A tool row that never got a result (the app was killed mid-call) is dropped so toolUse and
    /// toolResult stay 1:1. Consecutive assistant texts (a thought, then the answer) are joined.
    var messages: [Message] {
        var out: [Message] = []
        var pendingUses: [ToolUse] = []
        var pendingResults: [ToolResult] = []
        var pendingAssistantText = ""

        func flushTools() {
            guard !pendingUses.isEmpty else { pendingAssistantText = ""; return }
            out.append(.assistant(text: pendingAssistantText, toolUses: pendingUses))
            out.append(.toolResults(pendingResults))
            pendingUses.removeAll(); pendingResults.removeAll(); pendingAssistantText = ""
        }
        func flushText() {
            guard !pendingUses.isEmpty || !pendingAssistantText.isEmpty else { return }
            if pendingUses.isEmpty { out.append(.assistant(pendingAssistantText)); pendingAssistantText = "" }
            else { flushTools() }
        }

        for item in items {
            switch item.kind {
            case .user(let s):
                flushText()
                out.append(.user(s.isEmpty && !item.images.isEmpty ? "What's in this image?" : s, images: item.images))
            case .assistant(let s):
                if !pendingUses.isEmpty { flushTools() }
                pendingAssistantText = pendingAssistantText.isEmpty ? s : pendingAssistantText + "\n" + s
            case .toolUse(let use, let result):
                guard let result else { continue }   // never completed → cannot be paired, drop it
                pendingUses.append(use); pendingResults.append(result)
            case .ask(let toolUseId, let request, let answer):
                // An answered question is the tool pair it was (the card holds the MASKED answer — a rebuilt history
                // never carries a password; a card never answered is dropped like an unfinished tool).
                guard let answer else { continue }
                pendingUses.append(ToolUse(toolUseId: toolUseId, name: AskUserTool.toolName, input: request.toolArgs))
                pendingResults.append(ToolResult(toolUseId: toolUseId, name: AskUserTool.toolName, status: .success, content: answer.toolResult.compact))
            case .reasoning, .note, .approval, .agent:
                continue        // a child's rows belong to the child; the parent's history keeps the use_agent tool pair
            }
        }
        flushText()
        // The history handed to the agent must end on the assistant's side: the next thing appended
        // is the (edited) user turn. A dangling user message would put two user turns back to back.
        if out.last?.role == .user, out.last?.toolResults.isEmpty == true { out.removeLast() }
        return out
    }

    private mutating func resetCursors() { streamingIndex = nil; reasoningIndex = nil }
}
