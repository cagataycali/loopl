import Foundation

// `hooks/registry.py` + `hooks/events.py`.

/// `HookEvent`. `shouldReverseCallbacks` is true for the "After…"
/// events so hooks unwind in the opposite order they were entered.
public protocol HookEvent: Sendable {
    static var shouldReverseCallbacks: Bool { get }
}
public extension HookEvent { static var shouldReverseCallbacks: Bool { false } }

/// `HookProvider`: an object that registers several callbacks at once
/// (the retry strategy and the sliding-window manager are providers).
public protocol HookProvider: Sendable {
    func registerHooks(_ registry: HookRegistry)
}

/// `HookRegistry`. Callbacks are keyed by the concrete event type and
/// may mutate the event (`inout`) — that is how a hook cancels a tool, asks
/// for a model retry, or rewrites the messages before a model call.
public final class HookRegistry: @unchecked Sendable {
    /// A hook callback: it may mutate the event it is given.
    public typealias Callback<E: HookEvent> = @Sendable (inout E) async throws -> Void
    private struct Entry { let call: @Sendable (inout any HookEvent) async throws -> Void }
    private var callbacks: [ObjectIdentifier: [Entry]] = [:]
    private let lock = NSLock()

    public init() {}

    public func addCallback<E: HookEvent>(_ type: E.Type, _ callback: @escaping Callback<E>) {
        let entry = Entry { erased in
            guard var typed = erased as? E else { return }
            try await callback(&typed)
            erased = typed
        }
        lock.lock(); defer { lock.unlock() }
        callbacks[ObjectIdentifier(type), default: []].append(entry)
    }

    public func addHook(_ provider: any HookProvider) { provider.registerHooks(self) }

    public func hasCallbacks<E: HookEvent>(for type: E.Type) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(callbacks[ObjectIdentifier(type)] ?? []).isEmpty
    }

    /// `invoke_callbacks_async`: run every callback for the event's
    /// type, in registration order (reversed for After… events).
    private func entries<E: HookEvent>(for type: E.Type) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return callbacks[ObjectIdentifier(type)] ?? []
    }

    @discardableResult
    public func invoke<E: HookEvent>(_ event: E) async throws -> E {
        let list = entries(for: E.self)
        guard !list.isEmpty else { return event }
        var erased: any HookEvent = event
        for entry in (E.shouldReverseCallbacks ? list.reversed() : list) {
            try await entry.call(&erased)
        }
        return (erased as? E) ?? event
    }
}

// MARK: - Events

/// `BeforeInvocationEvent`: once per `agent(…)` call, before the loop.
/// `messages` is the new input; a hook may rewrite it. `cancel` stops the invocation.
public struct BeforeInvocationEvent: HookEvent {
    public var messages: [Message]
    public var cancel: String? = nil
    public init(messages: [Message]) { self.messages = messages }
}

/// `AfterInvocationEvent`: always fires (also on error), reversed order.
public struct AfterInvocationEvent: HookEvent {
    public static var shouldReverseCallbacks: Bool { true }
    public var result: AgentResult?
    public var error: String?
    public init(result: AgentResult?, error: String?) { self.result = result; self.error = error }
}

/// `BeforeModelCallEvent`: before each model stream. The sliding-window
/// manager trims `messages` here when the projected prompt would overflow.
public struct BeforeModelCallEvent: HookEvent {
    public var messages: [Message]
    public var systemPrompt: String?
    public var projectedInputTokens: Int
    public var contextWindow: Int
    public var cancel: String? = nil
    public init(messages: [Message], systemPrompt: String?, projectedInputTokens: Int, contextWindow: Int) {
        self.messages = messages; self.systemPrompt = systemPrompt; self.projectedInputTokens = projectedInputTokens; self.contextWindow = contextWindow
    }
}

/// `AfterModelCallEvent`: either `stopResponse` or `error` is set.
/// Setting `retry = true` makes the loop call the model again (the retry
/// strategy does this with backoff).
public struct AfterModelCallEvent: HookEvent {
    public static var shouldReverseCallbacks: Bool { true }
    /// What the model returned when its call ended normally.
    public struct ModelStopResponse: Sendable { public var stopReason: StopReason; public var message: Message }
    public var stopResponse: ModelStopResponse?
    public var error: (any Error)?
    public var retry = false
    public init(stopResponse: ModelStopResponse?, error: (any Error)?) { self.stopResponse = stopResponse; self.error = error }
}

/// `BeforeToolsEvent`: the assistant message with all its toolUse blocks, before any runs.
/// A hook may raise an interrupt here (`try event.interrupt("…")`) — see `Interrupt.swift`.
public struct BeforeToolsEvent: HookEvent, InterruptibleEvent {
    public var message: Message
    public var cancel: String? = nil
    public var interruptContext = InterruptContext()
    public init(message: Message) { self.message = message }
}

/// `AfterToolsEvent`: the toolResult user message, before it is appended.
/// Guaranteed to fire once for every `BeforeToolsEvent` — including when a BeforeTools hook
/// throws, a tool throws, the cycle is cancelled, or an interrupt stops the loop (it is
/// built and invoked in a `finally`).
public struct AfterToolsEvent: HookEvent {
    public static var shouldReverseCallbacks: Bool { true }
    public var message: Message
    /// `after_tools_event.end_turn`: set it and the loop ends the turn *without*
    /// calling the model again — the content below becomes the final assistant message.
    public var endTurn: EndTurn?
    /// `invocation_state["request_state"]`: shared scratch space. Setting
    /// `requestState["stopEventLoop"] = true` stops the loop after this tool cycle,
    /// keeping the cycle's own stop reason (`tool_use`).
    public var requestState: [String: JSONValue]

    /// What `endTurn` puts in the final assistant message (accepts `True`, a string, or content blocks).
    public enum EndTurn: Sendable, Hashable {
        /// A neutral one-liner ("Turn ended early by hook after tool execution").
        case flag
        case text(String)
        case content([ContentBlock])

        public var content: [ContentBlock] {
            switch self {
            case .flag: [.text("Turn ended early by hook after tool execution")]
            case .text(let t): [.text(t)]
            case .content(let c): c
            }
        }
    }

    public init(message: Message, requestState: [String: JSONValue] = [:]) {
        self.message = message; self.requestState = requestState
    }
}

/// `BeforeToolCallEvent`: per tool. A hook may swap `toolUse`, replace
/// `selectedTool`, or `cancelTool` with a message that becomes the error result.
/// loopl adds `approval`: pre-filled from `tool.requiresApproval(for:)`; a hook
/// sets it to `nil` to auto-approve (`ApprovalPolicy`) or sets one to demand a
/// human decision — the agent suspends the call until `resolve(approval:)`.
public struct BeforeToolCallEvent: HookEvent, InterruptibleEvent {
    public var toolUse: ToolUse
    public var selectedTool: (any Tool)?
    public var cancelTool: String? = nil
    public var approval: ApprovalRequest? = nil
    public var interruptContext = InterruptContext()
    public init(toolUse: ToolUse, selectedTool: (any Tool)?, approval: ApprovalRequest? = nil) {
        self.toolUse = toolUse; self.selectedTool = selectedTool; self.approval = approval
    }
}

/// `AfterToolCallEvent`: per tool, reversed order; `result` is mutable.
public struct AfterToolCallEvent: HookEvent {
    public static var shouldReverseCallbacks: Bool { true }
    public var toolUse: ToolUse
    public var selectedTool: (any Tool)?
    public var result: ToolResult
    public var error: (any Error)?
    public var cancelMessage: String?
    public init(toolUse: ToolUse, selectedTool: (any Tool)?, result: ToolResult, error: (any Error)? = nil, cancelMessage: String? = nil) {
        self.toolUse = toolUse; self.selectedTool = selectedTool; self.result = result; self.error = error; self.cancelMessage = cancelMessage
    }
}

/// `MessageAddedEvent`: every append to `agent.messages`.
public struct MessageAddedEvent: HookEvent {
    public var message: Message
    public init(message: Message) { self.message = message }
}
