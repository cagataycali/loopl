import Foundation

// `interrupt.py` + `types/interrupt.py` + the interrupt paths of
// `event_loop/event_loop.py` (`_stop_for_interrupts`, the pending-tool-execution
// replay, `_handle_tool_execution`'s merge/filter), in Swift.
//
// One mechanism, two shapes:
//
//  * `.suspend` (loopl's default, what the HITL approval shipped with): the call
//    that raised the interrupt suspends INSIDE the agent actor on a
//    `CheckedContinuation` until `agent.resolve(interrupt:response:)`, a timeout,
//    or cancellation. The stream stays alive and the other tools of the same
//    message keep running — the phone has a UI right there, so there is no
//    reason to unwind to the caller.
// * `.stop` (stop shape): the loop stops, `AgentResult.stopReason` is
//    `.interrupt`, the raised interrupts come back on the result, and the caller
//    resumes with `agent.resume(_:)`. Tool results already produced are kept in
//    `PendingToolExecution` and are NOT re-run.
//
// Approval (the `ApprovalRequest`/`ApprovalDecision` API) is one user of this —
// see `Approval.swift`.

/// `Interrupt`: something a hook or a tool needs a human to answer.
public struct Interrupt: Sendable, Hashable, Codable, Identifiable {
    /// Unique, derived from the scope that raised it (`"tool:<toolUseId>:approval"`).
    public var id: String
    /// The name the hook/tool used. Unique within its scope.
    public var name: String
    /// Why it was raised — anything JSON (an `ApprovalRequest`, a question, a diff).
    public var reason: JSONValue?
    /// The human's answer, once there is one.
    public var response: JSONValue?
    /// Phase 7: how long the agent waits for this interrupt before substituting its timeout answer
    /// (`ask_user` passes `timeout_s`); `nil` = the agent's `approvalTimeout`. Optional so saved state decodes.
    public var timeout: TimeInterval?

    public init(id: String, name: String, reason: JSONValue? = nil, response: JSONValue? = nil, timeout: TimeInterval? = nil) {
        self.id = id; self.name = name; self.reason = reason; self.response = response; self.timeout = timeout
    }
}

/// `InterruptException`: thrown by `InterruptContext.interrupt` /
/// `InterruptScope.interrupt` when there is no answer yet.
public struct InterruptException: Error, Sendable {
    public let interrupt: Interrupt
    public init(_ interrupt: Interrupt) { self.interrupt = interrupt }
}

/// `InterruptResponse`: one answer, by interrupt id.
public struct InterruptResponse: Sendable, Hashable, Codable {
    public var interruptId: String
    public var response: JSONValue
    public init(interruptId: String, response: JSONValue) {
        self.interruptId = interruptId; self.response = response
    }
}

/// `PendingToolExecution`: enough state to resume an interrupted tool
/// cycle WITHOUT calling the model again, keeping the results already produced.
public struct PendingToolExecution: Sendable, Hashable, Codable {
    /// The assistant message whose toolUse blocks were being executed.
    public var assistantMessage: Message
    /// Results completed (or synthesized) before the interrupt stopped the cycle.
    public var completedToolResults: [ToolResult]
    public init(assistantMessage: Message, completedToolResults: [ToolResult]) {
        self.assistantMessage = assistantMessage
        self.completedToolResults = completedToolResults
    }
}

/// How the agent reacts to a raised interrupt.
public enum InterruptMode: String, Sendable, Codable, Hashable, CaseIterable {
    /// Suspend the raising call inside the actor until it is resolved (default).
    case suspend
    /// Stop the event loop, return the interrupts on the result, resume with `agent.resume(_:)`.
    case stop
}

// MARK: - Raising an interrupt

/// `_InterruptState.interrupts` as seen from inside a hook callback or a
/// tool: the answers that already exist, plus somewhere to record a new question.
///
/// `interrupt(_:)` has these semantics — the FIRST call raises
/// (`setdefault` + `raise InterruptException`), and the call after the human
/// answered returns the response, so the hook/tool body is written once and runs
/// twice:
///
///     registry.addCallback(BeforeToolCallEvent.self) { e in
///         guard e.toolUse.name == "delete_tool" else { return }
///         let answer = try e.interrupt("confirm_delete", reason: .string(e.toolUse.name))
///         if answer != .string("yes") { e.cancelTool = "approval was not granted" }
///     }
public struct InterruptContext: Sendable {
    /// Id prefix — `"tool:<toolUseId>"`, `"tools:<messageId>"`, `"model:<cycle>"`.
    public let scope: String
    /// Interrupts the agent already knows about (answered or not), by id.
    public var known: [String: Interrupt]
    /// Interrupts raised during this invocation of the hook/tool.
    public internal(set) var raised: [Interrupt] = []

    public init(scope: String = "", known: [String: Interrupt] = [:]) {
        self.scope = scope; self.known = known
    }

    public func id(for name: String) -> String { scope.isEmpty ? name : "\(scope):\(name)" }

    /// `_Interruptible.interrupt`. Returns the human's response when one
    /// exists; otherwise records the interrupt and throws `InterruptException`.
    @discardableResult
    public mutating func interrupt(_ name: String, reason: JSONValue? = nil, response: JSONValue? = nil,
                                   timeout: TimeInterval? = nil) throws -> JSONValue {
        let id = id(for: name)
        if let existing = known[id], let answer = existing.response { return answer }
        if let response { return response }
        let raisedInterrupt = known[id] ?? Interrupt(id: id, name: name, reason: reason, timeout: timeout)
        if !raised.contains(where: { $0.id == id }) { raised.append(raisedInterrupt) }
        throw InterruptException(raisedInterrupt)
    }
}

/// A hook event a hook callback can raise an interrupt from. The agent injects
/// the context before invoking the callbacks and reads `raised` back afterwards.
public protocol InterruptibleEvent: HookEvent {
    var interruptContext: InterruptContext { get set }
}

public extension InterruptibleEvent {
    /// `event.interrupt(name, reason=…)`.
    @discardableResult
    mutating func interrupt(_ name: String, reason: JSONValue? = nil, response: JSONValue? = nil) throws -> JSONValue {
        try interruptContext.interrupt(name, reason: reason, response: response)
    }
}

/// Raising an interrupt from inside a tool. The `Tool` protocol is unchanged —
/// the agent publishes the context as a task-local around `tool.call(_:)`, which
/// is how a tool body reaches it (threads a `ToolContext` instead).
///
///     func call(_ args: [String: JSONValue]) async throws -> String {
///         let ok = try InterruptScope.interrupt("confirm", reason: .string("rm -rf /"))
///         guard ok == .bool(true) else { return "cancelled" }
///         …
///     }
public enum InterruptScope {
    @TaskLocal public static var context: InterruptContext?

    /// `ToolContext.interrupt`. Throws `InterruptException` the first
    /// time, returns the human's answer when the tool runs again with it.
    /// Throws `ToolError` when the tool is called outside an agent (no context).
    @discardableResult
    public static func interrupt(_ name: String, reason: JSONValue? = nil, timeout: TimeInterval? = nil) throws -> JSONValue {
        guard var ctx = context else {
            throw ToolError("InterruptScope.interrupt(\(name)) outside an agent tool call")
        }
        return try ctx.interrupt(name, reason: reason, timeout: timeout)
    }

    /// True when the tool is running with an agent's interrupt context around it.
    public static var isAvailable: Bool { context != nil }
}

// MARK: - Interrupt state (`_InterruptState`)

/// `_InterruptState`. Lives inside the `Agent` actor, so it needs no
/// lock; every mutation bumps `version` so observers can tell.
struct InterruptState: Sendable {
    var interrupts: [String: Interrupt] = [:]
    var context: [String: JSONValue] = [:]
    var activated = false
    var pendingToolExecution: PendingToolExecution?
    private(set) var version = 0

    mutating func activate() { activated = true; version += 1 }

    /// `deactivate`: everything cleared.
    mutating func deactivate() {
        interrupts = [:]; context = [:]; activated = false; pendingToolExecution = nil; version += 1
    }

    /// `end_tool_cycle`: a completed tool cycle starts the next one clean.
    mutating func endToolCycle() {
        interrupts = [:]; context = [:]; activated = false; pendingToolExecution = nil; version += 1
    }

    /// `resume`: fold the human's answers into the known interrupts.
    /// Throws when an answer names an interrupt that was never raised.
    mutating func resume(_ responses: [InterruptResponse]) throws {
        guard activated else { return }
        for r in responses {
            guard interrupts[r.interruptId] != nil else {
                throw InterruptError("no interrupt found with id \(r.interruptId)")
            }
            interrupts[r.interruptId]?.response = r.response
        }
        context["responses"] = .array(responses.map {
            .object(["interruptId": .string($0.interruptId), "response": $0.response])
        })
        version += 1
    }

    /// `set_pending_tool_results`: the replay filter must skip tools that already ran.
    mutating func setPendingToolResults(_ results: [ToolResult]) {
        guard pendingToolExecution != nil else { return }
        pendingToolExecution?.completedToolResults = results
        version += 1
    }

    /// Record a raised interrupt (`setdefault` — never overwrite an answer).
    mutating func register(_ raised: [Interrupt]) {
        for i in raised where interrupts[i.id] == nil {
            interrupts[i.id] = i
            version += 1
        }
    }

    /// Interrupts still waiting for an answer.
    var unanswered: [Interrupt] { interrupts.values.filter { $0.response == nil }.sorted { $0.id < $1.id } }
}

/// A malformed resume (`agent.resume(_:)` with an id nobody raised).
public struct InterruptError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - The suspend half (generalised out of the HITL approval)

/// The `.suspend` machinery: one place where a raised interrupt parks on a
/// `CheckedContinuation` until someone answers. Generalised from the approval
/// suspend so a hook interrupt, a tool interrupt and an approval all share it.
///
/// It is NOT an actor: it is owned by the `Agent` actor and only ever touched
/// from inside it, exactly like the `pending` dictionary it replaces.
struct InterruptGate: Sendable {
    private var waiting: [String: CheckedContinuation<JSONValue, Never>] = [:]
    private var requests: [String: Interrupt] = [:]
    /// Ids that are about to suspend — an answer arriving before the suspension point is kept here.
    private var arming: Set<String> = []
    private var early: [String: JSONValue] = [:]

    var pending: [Interrupt] { requests.values.sorted { $0.id < $1.id } }
    func isWaiting(_ id: String) -> Bool { waiting[id] != nil }

    mutating func arm(_ id: String) { arming.insert(id) }

    /// Answer a suspended call. Returns false when nothing with that id is
    /// waiting (already answered, timed out, cancelled, or never raised).
    mutating func resolve(_ id: String, _ response: JSONValue) -> Bool {
        requests.removeValue(forKey: id)
        guard let continuation = waiting.removeValue(forKey: id) else {
            if arming.contains(id) { early[id] = response; return true }
            return false
        }
        continuation.resume(returning: response)
        return true
    }

    /// Park `interrupt` until it is resolved. The caller must `await` the
    /// returned continuation body from inside the agent actor.
    mutating func take(_ interrupt: Interrupt) -> JSONValue? {
        arming.remove(interrupt.id)
        if let answer = early.removeValue(forKey: interrupt.id) { return answer }
        requests[interrupt.id] = interrupt
        return nil
    }

    mutating func park(_ id: String, _ continuation: CheckedContinuation<JSONValue, Never>) {
        waiting[id] = continuation
    }

    mutating func forget(_ id: String) {
        waiting.removeValue(forKey: id)
        requests.removeValue(forKey: id)
        arming.remove(id)
        early.removeValue(forKey: id)
    }
}

/// `.stop` mode bookkeeping: which tool uses of the current message raised an
/// interrupt instead of producing a result. Shared between the agent actor and
/// the (nonisolated) `emit` closure the tool executor calls, so it carries its
/// own lock rather than relying on actor isolation.
final class InterruptedToolUses: @unchecked Sendable {
    private var ids: Set<String> = []
    private let lock = NSLock()

    func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    var all: Set<String> { lock.lock(); defer { lock.unlock() }; return ids }
}
