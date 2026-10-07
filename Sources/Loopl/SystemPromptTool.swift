import Foundation

// `system_prompt` — the agent reads or changes its OWN system prompt (Phase 6, lane F; owner 2026-10-07:
// "we also need to add the system_prompt tool to update own system prompt").
//
// Decision: the prompt is GLOBAL — "its own system prompt" is the one user-editable Settings field every model
// gets (PR #89 removed the baked-in persona; identity lives in the model weights). So a change applies to the
// next model call of the SAME turn (the `Agent` reads `systemPrompt` when it builds each request, like the tool
// list) AND to every later conversation, through the host's `SystemPromptStore`. Every write is HITL: the
// approval card shows old → new so the user understands the model is changing its own future behaviour.

/// Where the prompt lives for the host (the app: Settings › System prompt, UserDefaults; tests: in memory).
/// `read` is synchronous because the approval preview is built before the tool runs, on the agent's actor.
public protocol SystemPromptStore: Sendable {
    /// The prompt in force right now.
    func read() -> String
    /// What `reset` restores.
    var defaultPrompt: String { get }
    /// How the current prompt came to be ("default 1.1.0", "edited by the user", "changed by you at 21:04").
    func origin() -> String
    /// Persist `change.after` as the prompt, attributed to the agent (the host keeps a short history for Revert).
    func write(_ change: SystemPromptChange) async
}

/// One edit the agent made to its prompt — the `AgentEvent.systemPromptChanged` payload and the host's history entry.
public struct SystemPromptChange: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Codable { case set, append, reset }
    public var action: Action
    public var before: String
    public var after: String
    public var at: Date
    public init(action: Action, before: String, after: String, at: Date = Date()) {
        self.action = action; self.before = before; self.after = after; self.at = at
    }
    /// The transcript marker — one quiet line, plain words.
    public var summary: String {
        switch action {
        case .set: "The model replaced its instructions · undo in Settings › System prompt"
        case .append: "The model added a rule to its instructions · undo in Settings › System prompt"
        case .reset: "The model went back to the default instructions · undo in Settings › System prompt"
        }
    }
}

/// A store that lives in memory (showcases, tests). Thread-safe; keeps the full change list.
public final class InMemorySystemPromptStore: SystemPromptStore, @unchecked Sendable {
    private let lock = NSLock()
    private var prompt: String
    private var changes: [SystemPromptChange] = []
    public let defaultPrompt: String
    public init(prompt: String, defaultPrompt: String? = nil) { self.prompt = prompt; self.defaultPrompt = defaultPrompt ?? prompt }
    public func read() -> String { lock.withLock { prompt } }
    public func origin() -> String {
        lock.withLock {
            if let last = changes.last { return "changed by you at \(SystemPromptTool.clock.string(from: last.at))" }
            return prompt == defaultPrompt ? "default" : "edited by the user"
        }
    }
    public func write(_ change: SystemPromptChange) async { lock.withLock { prompt = change.after; changes.append(change) } }
    public var history: [SystemPromptChange] { lock.withLock { changes } }
}

public struct SystemPromptTool: Tool {
    public let store: any SystemPromptStore
    public init(store: any SystemPromptStore) { self.store = store }

    public static let toolName = "system_prompt"
    public var name: String { Self.toolName }
    /// Written for small models (measured on loopl-2b, SystemPromptMeasurement): the trigger phrases, the exact
    /// calls, and the two negatives ("ordinary question", "one-time request") in one breath.
    public var description: String {
        // v2 (measured on loopl-2b, SystemPromptMeasurement): v1 scored append 6/6 · reset 3/3 · negatives 6/6 but `get` 0/3 — the
        // model RECITED its prompt from memory. v2 names that case first and says why the call matters (the exact, current text).
        "Read or change your own system prompt — the standing instructions you follow in every conversation. When the user asks what your instructions or your system prompt are, call {\"action\": \"get\"} and quote its result — never recite from memory, only the tool has the exact current text. When the user asks you to add, change or drop a rule that should hold from now on (\"always answer in Turkish\", \"call me Ali\", \"be brief from now on\"): {\"action\": \"append\", \"text\": \"<the new rule>\"} adds it; {\"action\": \"set\", \"text\": \"<the whole new prompt>\"} replaces everything; {\"action\": \"reset\"} restores the default. The user approves every change before it applies. Do not call it for an ordinary question or a one-time request."
    }
    public var parameters: JSONValue {
        ToolSchema.object([
            "action": ["type": "string", "enum": ["get", "set", "append", "reset"], "description": "get | set | append | reset"],
            "text": ToolSchema.string("the new rule to add (append) or the whole new prompt (set); not used by get / reset"),
        ], required: ["action"])
    }

    /// Characters of each side shown on the approval card before "…".
    public static let previewLimit = 420
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()

    // MARK: what the model asked for

    enum Plan: Equatable {
        case get
        case change(SystemPromptChange.Action, after: String)
        case noop(String)
    }

    /// Lenient for small models: action case-insensitive, `text` also accepted as `prompt`/`content`/`value`.
    static func plan(_ args: [String: JSONValue], current: String, defaultPrompt: String) throws -> Plan {
        let action = args["action"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let text = (args["text"] ?? args["prompt"] ?? args["content"] ?? args["value"] ?? args["instruction"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch action {
        case "get", "read", "show":
            return .get
        case "set", "replace":
            guard !text.isEmpty else { throw ToolError("set needs text: the whole new system prompt. Use append to add one rule, get to read the current one.") }
            return text == current ? .noop("already your system prompt — nothing changed.") : .change(.set, after: text)
        case "append", "add":
            guard !text.isEmpty else { throw ToolError("append needs text: the rule to add to your instructions.") }
            if current.range(of: text, options: .caseInsensitive) != nil { return .noop("already in your instructions — nothing changed.") }
            let joined = current.trimmingCharacters(in: .whitespacesAndNewlines)
            return .change(.append, after: joined.isEmpty ? text : joined + "\n\n" + text)
        case "reset", "default":
            return current == defaultPrompt ? .noop("your system prompt is already the default — nothing changed.") : .change(.reset, after: defaultPrompt)
        default:
            throw ToolError("unknown action \"\(action)\". Use get, set, append or reset.")
        }
    }

    // MARK: HITL — every write stops at a card with an old → new preview

    public func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
        let current = store.read()
        guard case .change(let action, let after)? = try? Self.plan(input, current: current, defaultPrompt: store.defaultPrompt) else { return nil }
        let title: String, detail: String
        switch action {
        case .set: title = "Replace my instructions"; detail = "Replaces the system prompt I follow in every conversation, from my next step on."
        case .append: title = "Add to my instructions"; detail = "Adds a standing rule to the system prompt I follow in every conversation, from my next step on."
        case .reset: title = "Reset my instructions"; detail = "Puts the app's default system prompt back, from my next step on."
        }
        return ApprovalRequest(toolName: name, title: title, bodyPreview: Self.preview(action: action, before: current, after: after),
                               detail: detail + " You can revert it any time in Settings › System prompt.", risk: .medium, input: input)
    }

    /// Diff-style, truncated: `− old` / `+ new` for set and reset; for append the unchanged head is one dim line and
    /// only the added paragraph is `+`.
    public static func preview(action: SystemPromptChange.Action, before: String, after: String) -> String {
        func cut(_ s: String) -> String {
            let one = s.replacingOccurrences(of: "\n\n", with: " ¶ ").replacingOccurrences(of: "\n", with: " ")
            return one.count > previewLimit ? String(one.prefix(previewLimit - 1)) + "…" : one
        }
        switch action {
        case .append:
            let added = after.hasPrefix(before.trimmingCharacters(in: .whitespacesAndNewlines)) ? String(after.dropFirst(before.trimmingCharacters(in: .whitespacesAndNewlines).count)).trimmingCharacters(in: .whitespacesAndNewlines) : after
            return "  \(before.isEmpty ? "(no instructions yet)" : "…\(before.count) chars kept")\n+ \(cut(added))"
        case .set, .reset:
            return "− \(cut(before))\n+ \(cut(after))"
        }
    }

    // MARK: run

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let current = store.read()
        switch try Self.plan(args, current: current, defaultPrompt: store.defaultPrompt) {
        case .get:
            return "Your system prompt (\(store.origin()), \(current.count) chars):\n\(current)"
        case .noop(let why):
            return why
        case .change(let action, let after):
            let change = SystemPromptChange(action: action, before: current, after: after)
            // The running agent first (the next model call of THIS turn reads it), then the host's store (every later conversation).
            if let agent = ToolContext.current?.agent { await agent.changeSystemPrompt(change) }
            await store.write(change)
            let where_ = "It applies from your next step and to every new conversation; the user can revert it in Settings › System prompt."
            switch action {
            case .reset: return "System prompt reset to the app default (\(after.count) chars). \(where_)"
            case .set: return "System prompt replaced (\(current.count) → \(after.count) chars). \(where_)"
            case .append: return "System prompt extended (\(current.count) → \(after.count) chars). \(where_)"
            }
        }
    }
}
