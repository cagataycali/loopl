import Foundation

// Strands `hooks/registry.py` + `hooks/events.py`.

/// Strands `HookEvent`. `shouldReverseCallbacks` is true for the "After…"
/// events so hooks unwind in the opposite order they were entered.
public protocol HookEvent: Sendable {
    static var shouldReverseCallbacks: Bool { get }
}
public extension HookEvent { static var shouldReverseCallbacks: Bool { false } }

/// Strands `HookProvider`: an object that registers several callbacks at once
/// (the retry strategy and the sliding-window manager are providers).
public protocol HookProvider: Sendable {
    func registerHooks(_ registry: HookRegistry)
}

/// Strands `HookRegistry`. Callbacks are keyed by the concrete event type and
/// may mutate the event (`inout`) — that is how a hook cancels a tool, asks
/// for a model retry, or rewrites the messages before a model call.
public final class HookRegistry: @unchecked Sendable {
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

    /// Strands `invoke_callbacks_async`: run every callback for the event's
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

/// Strands `BeforeInvocationEvent`: once per `agent(…)` call, before the loop.
/// `messages` is the new input; a hook may rewrite it. `cancel` stops the invocation.
public struct BeforeInvocationEvent: HookEvent {
    public var messages: [Message]
    public var cancel: String? = nil
    public init(messages: [Message]) { self.messages = messages }
}

/// Strands `AfterInvocationEvent`: always fires (also on error), reversed order.
public struct AfterInvocationEvent: HookEvent {
    public static var shouldReverseCallbacks: Bool { true }
    public var result: AgentResult?
    public var error: String?
    public init(result: AgentResult?, error: String?) { self.result = result; self.error = error }
}

/// Strands `BeforeModelCallEvent`: before each model stream. The sliding-window
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

/// Strands `AfterModelCallEvent`: either `stopResponse` or `error` is set.
/// Setting `retry = true` makes the loop call the model again (the retry
/// strategy does this with backoff).
public struct AfterModelCallEvent: HookEvent {
    public static var shouldReverseCallbacks: Bool { true }
    public struct ModelStopResponse: Sendable { public var stopReason: StopReason; public var message: Message }
    public var stopResponse: ModelStopResponse?
    public var error: (any Error)?
    public var retry = false
    public init(stopResponse: ModelStopResponse?, error: (any Error)?) { self.stopResponse = stopResponse; self.error = error }
}

/// Strands `BeforeToolsEvent`: the assistant message with all its toolUse blocks, before any runs.
public struct BeforeToolsEvent: HookEvent {
    public var message: Message
    public var cancel: String? = nil
    public init(message: Message) { self.message = message }
}

/// Strands `AfterToolsEvent`: the toolResult user message, before it is appended.
public struct AfterToolsEvent: HookEvent {
    public static var shouldReverseCallbacks: Bool { true }
    public var message: Message
    public init(message: Message) { self.message = message }
}

/// Strands `BeforeToolCallEvent`: per tool. A hook may swap `toolUse`, replace
/// `selectedTool`, or `cancelTool` with a message that becomes the error result.
public struct BeforeToolCallEvent: HookEvent {
    public var toolUse: ToolUse
    public var selectedTool: (any Tool)?
    public var cancelTool: String? = nil
    public init(toolUse: ToolUse, selectedTool: (any Tool)?) { self.toolUse = toolUse; self.selectedTool = selectedTool }
}

/// Strands `AfterToolCallEvent`: per tool, reversed order; `result` is mutable.
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

/// Strands `MessageAddedEvent`: every append to `agent.messages`.
public struct MessageAddedEvent: HookEvent {
    public var message: Message
    public init(message: Message) { self.message = message }
}
