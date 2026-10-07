import Foundation

// Sub-agents (`use_agent`) — the on-device port of tiny-tech's spawn_agents / wake rail
// (src/agent/spawn-tools.ts, spawn-state.ts, wake.ts), shaped for ONE model on ONE phone:
//
//  - A child is a full `Agent` on the SAME loaded model (there is one set of weights) with ONLY the tools the
//    parent listed. Model access is serialised by `ModelGate` (FIFO): while a child generates, the parent's
//    next model call waits for that ONE call to finish, and vice versa — children queue, they never interleave
//    tokens on the Metal device. Three children may be alive at once (`SubAgentHub.maxConcurrent`); a fourth is
//    `queued` until a slot frees.
//  - Depth 1 by construction: the child's tool list is validated against the parent's registry and `use_agent`
//    is refused by name, so a child cannot spawn (same rationale as spawn-tools.ts: nobody reads a fan-out of a
//    fan-out).
//  - Events: the child's own `AgentEvent`s are forwarded verbatim, wrapped as `.child(id, event)`, preceded by
//    `.childStarted(info)` and bracketed by `.childStatus`. While the parent's `use_agent` call is waiting they
//    ride the parent's stream (a TaskLocal sink the agent installs around `tool.call`); once the call returns
//    (`wait:false`, or the inline window expired) the run is DETACHED and the same events flow through
//    `SubAgentHub.detachedEvents()` so the host keeps the card live after the parent's turn ended.
//  - Envelope: every run has an id (`agent_<base36 time><4 hex>` — tiny-tech's ticket rule) that `status`,
//    `result` and `stop` accept; summaries are persisted as JSON so a relaunch can still answer `result`.
//  - Wake: a DETACHED run finishing calls `onFinished(envelope)` once — the host turns it into a synthetic user
//    turn "[use_agent <id> finished] <result>" on the parent (wake.ts: one in flight, FIFO, never while the
//    user is typing, "no human typed this").

// MARK: - Contract types (shared with the UI — see ~/.tiny/loopl-phase6/COORDINATION.md)

/// What a child is: the one record the UI needs to draw its card header, emitted once as `.childStarted`.
public struct SubAgentInfo: Sendable, Hashable, Codable {
    /// Envelope id — also the handle for `use_agent status/result/stop`.
    public var id: String
    /// The parent's `use_agent` `ToolUse.toolUseId` — the ToolRow this child's card nests under.
    public var parentToolUseId: String
    /// ≤ 40 characters: the first line of the system prompt, else "agent N".
    public var name: String
    public var systemPrompt: String
    public var input: String
    /// The ONLY tools this child has (validated names).
    public var tools: [String]
    /// Spawned with `wait:false`.
    public var background: Bool
    public var startedAt: Date
    public init(id: String, parentToolUseId: String, name: String, systemPrompt: String, input: String, tools: [String], background: Bool, startedAt: Date = Date()) {
        self.id = id; self.parentToolUseId = parentToolUseId; self.name = name; self.systemPrompt = systemPrompt
        self.input = input; self.tools = tools; self.background = background; self.startedAt = startedAt
    }

    /// `name` from a system prompt: its first line, clipped — or "agent N".
    public static func name(from systemPrompt: String, ordinal: Int) -> String {
        let line = systemPrompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else { return "agent \(ordinal)" }
        let sentence = line.split(separator: ".").first.map(String.init) ?? line
        let clipped = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.count <= 40 ? clipped : String(clipped.prefix(39)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Where a child is. `background` = detached from the parent's call (still running).
public enum SubAgentStatus: String, Sendable, Codable, Hashable {
    case queued, running, background, done, failed, stopped
    public var isFinished: Bool { self == .done || self == .failed || self == .stopped }
}

/// The persisted summary of one run — what `use_agent status/result` return.
public struct SubAgentEnvelope: Sendable, Hashable, Codable, Identifiable {
    public var id: String { info.id }
    public var info: SubAgentInfo
    public var status: SubAgentStatus
    /// Final answer text (done), clipped to `SubAgentHub.resultBudget`.
    public var result: String?
    /// Why it failed / was stopped.
    public var error: String?
    public var endedAt: Date?
    public var toolCalls: Int
    public var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(info.startedAt) }
    public init(info: SubAgentInfo, status: SubAgentStatus, result: String? = nil, error: String? = nil, endedAt: Date? = nil, toolCalls: Int = 0) {
        self.info = info; self.status = status; self.result = result; self.error = error; self.endedAt = endedAt; self.toolCalls = toolCalls
    }

    /// The JSON the model reads back.
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "status": .string(status.rawValue), "name": .string(info.name),
            "tools": .array(info.tools.map(JSONValue.string)), "elapsed_s": .number(Double(Int(elapsed))),
            "tool_calls": .number(Double(toolCalls)),
        ]
        if let result { o["result"] = .string(result) }
        if let error { o["error"] = .string(error) }
        if !status.isFinished { o["pending"] = .bool(true) }
        return .object(o)
    }
}

/// `TranscriptItem.Kind.agent`: a child as the transcript shows it — header + its own nested rows.
public struct SubAgentRun: Sendable, Hashable {
    public var info: SubAgentInfo
    public var status: SubAgentStatus
    /// The child's own transcript (assistant text, tool rows, approval cards, notes) — render with the same row views.
    public var transcript: Transcript
    public var endedAt: Date?
    public var resultText: String? { transcript.lastResult?.text }
    public var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(info.startedAt) }
    public init(info: SubAgentInfo, status: SubAgentStatus = .queued, transcript: Transcript = Transcript(), endedAt: Date? = nil) {
        self.info = info; self.status = status; self.transcript = transcript; self.endedAt = endedAt
    }
}

// MARK: - Child event sink (the parent's stream, while `use_agent` is waiting)

/// Installed by `Agent.runTool` around `tool.call` as a TaskLocal: a tool that spawns children forwards their
/// events here so they ride the PARENT's event stream (`.childStarted` / `.child` / `.childStatus`).
public struct ChildEventSink: Sendable {
    public let parentToolUseId: String
    public let yield: @Sendable (AgentEvent) -> Void
    public init(parentToolUseId: String, yield: @Sendable @escaping (AgentEvent) -> Void) {
        self.parentToolUseId = parentToolUseId; self.yield = yield
    }
}

extension Agent {
    /// The sink of the `use_agent` call running right now (nil outside a tool call).
    @TaskLocal public static var childSink: ChildEventSink?
}

// MARK: - ModelGate (one set of weights, FIFO)

/// Serialises `model.stream` calls across every agent sharing one loaded model. `Agent.setModelGate` makes the
/// agent acquire it for the duration of each model call; children get the same gate from the hub. Fair FIFO:
/// the parent asking while a child generates waits exactly one child model call, never the whole child run.
public final class ModelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}

    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    public var waiting: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    public func acquire() async {
        if tryAcquire() { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if !park(c) { c.resume() }      // freed between the two checks → ours now
        }
    }
    /// Take the gate when it is free (sync).
    private func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true; return true
    }
    /// Queue a waiter; false when the gate turned out free (the caller owns it, `busy` set).
    private func park(_ c: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !busy { busy = true; return false }
        waiters.append(c); return true
    }

    public func release() {
        lock.lock()
        if waiters.isEmpty { busy = false; lock.unlock(); return }
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()      // ownership passes directly: `busy` stays true
    }
}

// MARK: - SubAgentHub

/// What the hub needs from its host to build a child: the model (and gate) the parent uses, the tools it may hand
/// out by name, the hooks every agent gets (approval policy…). Read at spawn time, so a model switch is honoured.
public struct SubAgentContext: Sendable {
    public var model: any Model
    public var gate: ModelGate
    /// Every tool the parent could offer, by name — the child's list is a subset. `use_agent` is never in it.
    public var availableTools: [String: any Tool]
    public var hooks: [any HookProvider]
    public var approvalTimeout: TimeInterval
    public init(model: any Model, gate: ModelGate, availableTools: [any Tool], hooks: [any HookProvider] = [], approvalTimeout: TimeInterval = 120) {
        self.model = model; self.gate = gate
        self.availableTools = Dictionary(availableTools.filter { $0.name != UseAgentTool.toolName }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.hooks = hooks; self.approvalTimeout = approvalTimeout
    }
}

/// Owns every child of one host (one per Engine): slots, queue, envelopes, the detached event stream, the wake hook.
public actor SubAgentHub {
    /// Children alive at once (running or background). A fourth is `queued`.
    public static let maxConcurrent = 3
    /// `wait:true` returns inline within this; past it the run is detached and `{pending:true}` comes back.
    public static let inlineWait: TimeInterval = 45
    /// Result text handed back to the parent / into the wake turn (wake.ts WAKE_RESULT_MAX).
    public static let resultBudget = 2000
    /// Finished envelopes older than this are pruned from disk at the next spawn.
    public static let pruneAfter: TimeInterval = 24 * 3600

    private struct Run {
        var envelope: SubAgentEnvelope
        var agent: Agent?
        var task: Task<Void, Never>?
        var sink: ChildEventSink?
        var input: String
        var waiters: [CheckedContinuation<SubAgentEnvelope, Never>] = []
    }
    private var runs: [String: Run] = [:]
    private var order: [String] = []                 // spawn order (list / queue fairness)
    private var ordinal = 0
    private var detached: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private let directory: URL?
    /// The wake rail: fires ONCE per DETACHED run when it finishes (any outcome). Attached runs return inline.
    private var onFinished: (@Sendable (SubAgentEnvelope) -> Void)?
    /// Injectable clock + id for tests.
    nonisolated let now: @Sendable () -> Date

    /// - directory: where envelope summaries persist (nil = memory only).
    public init(directory: URL? = nil, now: @Sendable @escaping () -> Date = { Date() }) {
        self.directory = directory; self.now = now
    }

    public func setOnFinished(_ cb: (@Sendable (SubAgentEnvelope) -> Void)?) { onFinished = cb }

    // MARK: ids

    /// `agent_<base36 ms><4 hex>` — recognisable in a transcript, safe as a filename.
    public static func makeId(now: Date = Date()) -> String {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let rand = String(format: "%04x", Int.random(in: 0...0xffff))
        return "agent_" + String(ms, radix: 36) + rand
    }
    public static func isValidId(_ id: String) -> Bool {
        id.hasPrefix("agent_") && id.count <= 40 && id.dropFirst(6).allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: spawn

    /// Validate the child's tool names against the context. Returns the tools, or the sentence the model reads.
    public static func validateTools(_ names: [String], against context: SubAgentContext) -> Result<[any Tool], ToolError> {
        var out: [any Tool] = []
        var seen = Set<String>()
        for raw in names {
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, !seen.contains(n) else { continue }
            seen.insert(n)
            if n == UseAgentTool.toolName { return .failure(ToolError("children cannot spawn agents (depth 1) — leave use_agent out of tools")) }
            guard let t = context.availableTools[n] else {
                let known = context.availableTools.keys.sorted().joined(separator: ", ")
                return .failure(ToolError("unknown tool '\(n)' — the child may only use tools you have: \(known)"))
            }
            out.append(t)
        }
        return .success(out)
    }

    /// Start a child. Returns its envelope id immediately; the run begins when a slot is free. `.childStarted` and the
    /// first status ride the parent's sink (so the card exists before `use_agent` returns); a background child is
    /// detached right after.
    @discardableResult
    public func spawn(systemPrompt: String, input: String, tools: [any Tool], background: Bool,
                      context: SubAgentContext, sink: ChildEventSink?) -> String {
        ordinal += 1
        lastGate = context.gate
        let id = Self.makeId(now: now())
        let info = SubAgentInfo(id: id, parentToolUseId: sink?.parentToolUseId ?? "",
                                name: SubAgentInfo.name(from: systemPrompt, ordinal: ordinal),
                                systemPrompt: systemPrompt, input: input, tools: tools.map(\.name),
                                background: background, startedAt: now())
        let agent = Agent(model: context.model, tools: tools, systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                          hooks: context.hooks, approvalTimeout: context.approvalTimeout)
        runs[id] = Run(envelope: SubAgentEnvelope(info: info, status: .queued), agent: agent, sink: sink, input: input)
        order.append(id)
        emit(id, .childStarted(info))
        emit(id, .childStatus(id: id, .queued))
        pump(gate: context.gate)
        if background { detach(id) }
        pruneDisk()
        return id
    }

    private var active: Int { runs.values.filter { $0.envelope.status == .running || ($0.envelope.status == .background && $0.task != nil) }.count }

    /// Start queued runs while slots are free (spawn order).
    private func pump(gate: ModelGate) {
        for id in order {
            guard active < Self.maxConcurrent else { return }
            guard let run = runs[id], run.task == nil, !run.envelope.status.isFinished, let agent = run.agent else { continue }
            let input = run.input
            if run.envelope.status == .queued { setStatus(id, run.sink == nil ? .background : .running) }   // a detached child never shows "running"
            runs[id]?.task = Task { [weak self] in
                await agent.setModelGate(gate)
                var final: AgentResult?
                var failure: String?
                do {
                    for try await e in agent.stream(input) {
                        if case .result(let r) = e { final = r }
                        await self?.emit(id, .child(id: id, e))
                    }
                } catch is CancellationError {
                    failure = "stopped"
                } catch {
                    failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
                // A cancelled consumer ends the stream without `.result` — that is a stop, not a failure.
                if Task.isCancelled { failure = "stopped" }
                await self?.finish(id, result: final, error: failure)
            }
        }
    }

    private func finish(_ id: String, result: AgentResult?, error: String?) {
        guard var run = runs[id], !run.envelope.status.isFinished else { return }
        let wasDetached = run.sink == nil
        run.task = nil
        run.envelope.endedAt = now()
        run.envelope.toolCalls = result?.metrics.toolCallCount ?? run.envelope.toolCalls
        if let result, error == nil, result.stopReason != .cancelled {
            run.envelope.result = Self.clip(result.text)
            run.envelope.status = .done
        } else if error == "stopped" || result?.stopReason == .cancelled {
            run.envelope.status = .stopped; run.envelope.error = "stopped"
        } else {
            run.envelope.status = .failed; run.envelope.error = error ?? "no result"
        }
        runs[id] = run
        emit(id, .childStatus(id: id, run.envelope.status))
        persist(run.envelope)
        run.waiters.forEach { $0.resume(returning: run.envelope) }
        runs[id]?.waiters = []
        runs[id]?.agent = nil
        // Wake only when nobody is reading the result right now (wake.ts "claim": a `result` call waiting on this run
        // delivers it to the parent inline, so a wake on top would say the same thing twice).
        if wasDetached && run.waiters.isEmpty { onFinished?(run.envelope) }
        // A slot freed → the next queued child starts (its gate is the one every child shares).
        if let gate = lastGate { pump(gate: gate) }
    }
    private var lastGate: ModelGate?

    private func setStatus(_ id: String, _ s: SubAgentStatus, emitStatus: Bool = true) {
        guard var run = runs[id] else { return }
        run.envelope.status = s
        runs[id] = run
        if emitStatus { emit(id, .childStatus(id: id, s)) }
        persist(run.envelope)
    }

    static func clip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= resultBudget ? t : String(t.prefix(resultBudget)) + "… [clipped]"
    }

    // MARK: waiting / detaching

    /// Wait for the run to finish, up to `timeout`. Returns the envelope either way; when still running the run is
    /// DETACHED (events move to `detachedEvents()`, status `.background`, and the wake fires on finish).
    public func wait(_ id: String, timeout: TimeInterval) async -> SubAgentEnvelope? {
        guard let run = runs[id] else { return nil }
        if run.envelope.status.isFinished { return run.envelope }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.detach(id)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<SubAgentEnvelope, Never>) in
                guard var run = runs[id], !run.envelope.status.isFinished else { c.resume(returning: runs[id]!.envelope); return }
                run.waiters.append(c); runs[id] = run
            }
        } onCancel: {
            // The parent's turn was cancelled while waiting: the child keeps running detached (the user stopped the
            // parent, not the child) — `stop` or a thread switch ends it.
            Task { [weak self] in await self?.detach(id) }
        }
    }

    /// Hand the run to the background: its remaining events go to `detachedEvents()`, waiters get `{pending}`.
    public func detach(_ id: String) {
        guard var run = runs[id], !run.envelope.status.isFinished else { return }
        run.envelope.info.background = true
        if run.envelope.status == .running { run.envelope.status = .background }
        runs[id] = run
        emit(id, .childStatus(id: id, .background))      // still through the parent's sink: its transcript sees the hand-off
        runs[id]?.sink = nil
        persist(run.envelope)
        run.waiters.forEach { $0.resume(returning: run.envelope) }
        runs[id]?.waiters = []
    }

    // MARK: status / result / stop

    public func envelope(_ id: String) -> SubAgentEnvelope? { runs[id]?.envelope ?? load(id) }
    public func list() -> [SubAgentEnvelope] { order.compactMap { runs[$0]?.envelope } }
    public var running: [SubAgentEnvelope] { list().filter { !$0.status.isFinished } }

    /// Cancel one child (its agent task is cancelled; status `.stopped`).
    public func stop(_ id: String) -> Bool {
        guard let run = runs[id], !run.envelope.status.isFinished else { return false }
        if let task = run.task { task.cancel() } else { finish(id, result: nil, error: "stopped") }   // queued: never started
        return true
    }
    /// Thread switch / clear: every live child is cancelled (documented: a child belongs to the thread that spawned it).
    public func stopAll() { for id in order where runs[id]?.envelope.status.isFinished == false { _ = stop(id) } }

    /// Answer an approval card that came from a child (`.child(id, .approvalRequested(req))`).
    public func resolve(child id: String, approval toolUseId: String, _ decision: ApprovalDecision) async -> Bool {
        guard let agent = runs[id]?.agent else { return false }
        return await agent.resolve(approval: toolUseId, decision)
    }
    /// Answer any other interrupt raised inside a child (Phase 7 `ask_user`: `.child(id, .interruptRaised(i))`).
    public func resolve(child id: String, interrupt interruptId: String, response: JSONValue) async -> Bool {
        guard let agent = runs[id]?.agent else { return false }
        return await agent.resolve(interrupt: interruptId, response: response)
    }

    // MARK: event routing

    /// Events of DETACHED runs (background children), already wrapped. The host folds them into its transcript.
    public nonisolated func detachedEvents() -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let key = UUID()
            Task { await self.subscribe(key, continuation) }
            continuation.onTermination = { _ in Task { await self.unsubscribe(key) } }
        }
    }
    private func subscribe(_ key: UUID, _ c: AsyncStream<AgentEvent>.Continuation) { detached[key] = c }
    private func unsubscribe(_ key: UUID) { detached[key] = nil }

    private func emit(_ id: String, _ event: AgentEvent) {
        if let sink = runs[id]?.sink { sink.yield(event) } else { for c in detached.values { c.yield(event) } }
    }

    // MARK: persistence (summaries only — the transcript lives with the thread)

    private func persist(_ e: SubAgentEnvelope) {
        guard let directory, Self.isValidId(e.id) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(e.id + ".json")
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: url, options: .atomic) }
    }
    private func load(_ id: String) -> SubAgentEnvelope? {
        guard let directory, Self.isValidId(id), let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".json")) else { return nil }
        var e = try? JSONDecoder().decode(SubAgentEnvelope.self, from: data)
        // A run that was alive when the app died is not running now — say so instead of spinning.
        if let s = e?.status, !s.isFinished { e?.status = .failed; e?.error = "the app was closed while this agent ran" }
        return e
    }
    private func pruneDisk() {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = now().addingTimeInterval(-Self.pruneAfter)
        for f in files where f.pathExtension == "json" {
            if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }
}

// MARK: - use_agent

/// `use_agent {action: run|status|result|stop, system_prompt?, input?, tools?, wait?, id?}`.
public struct UseAgentTool: Tool {
    public static let toolName = "use_agent"
    public let name = UseAgentTool.toolName
    public let description =
        "Delegate a task to a sub-agent: a fresh agent with its own system_prompt, one input and ONLY the tools you list (names from your own tool list; it cannot spawn agents). " +
        "action run: wait (default true) returns the child's final answer inline when it finishes within \(Int(SubAgentHub.inlineWait)) s — otherwise, or with wait:false, you get {pending:true, id} and are WOKEN with the result when it finishes; keep answering the user meanwhile. " +
        "action status/result/stop take id. Use it for a side task you can run while answering (fetch and summarise a page, check the calendar) or a long one in the background. " +
        "Children share the one on-device model, so they take turns with you; at most \(SubAgentHub.maxConcurrent) at once."
    public let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["run", "status", "result", "stop"], "description": "run a new sub-agent, or status/result/stop by id"],
            "system_prompt": ["type": "string", "description": "run: who the child is and what it must do (first line names it)"],
            "input": ["type": "string", "description": "run: the task, as one user message"],
            "tools": ["type": "array", "items": ["type": "string"], "description": "run: the only tools the child may use, e.g. [\"http\"] (never use_agent)"],
            "wait": ["type": "boolean", "description": .string("run: true (default) waits up to \(Int(SubAgentHub.inlineWait)) s for the answer; false returns at once with an id and wakes you when done")],
            "id": ["type": "string", "description": "status/result/stop: the agent id from run"],
        ],
        "required": ["action"],
    ]
    let hub: SubAgentHub
    /// Read at call time: the model, gate, tools and hooks of the parent right now.
    let context: @Sendable () async -> SubAgentContext?

    public init(hub: SubAgentHub, context: @Sendable @escaping () async -> SubAgentContext?) {
        self.hub = hub; self.context = context
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let action = args["action"]?.stringValue?.lowercased() ?? (args["input"] != nil ? "run" : "")
        switch action {
        case "run": return try await run(args)
        case "status", "result":
            guard let id = args["id"]?.stringValue, !id.isEmpty else { throw ToolError("\(action) needs id (from run)") }
            guard let env = await hub.envelope(id) else { throw ToolError("no agent \(id) — ids come from use_agent run and live for this session") }
            if action == "result", !env.status.isFinished {
                // Measured (SubAgentLiveTests, loopl-2b): told "do not poll", the model still called `result` right after
                // `wait:false`, three cycles in a row. So `result` WAITS (up to the inline window) instead of bouncing —
                // the poll becomes the wait, the answer lands in one call, and the wake is claimed (no double delivery).
                if let settled = await hub.wait(id, timeout: SubAgentHub.inlineWait), settled.status.isFinished { return settled.json.compact }
                return JSONValue.object(["id": .string(id), "status": .string(env.status.rawValue), "pending": .bool(true),
                                         "note": .string("still running after \(Int(env.elapsed + SubAgentHub.inlineWait)) s — you will be woken with the result; answer the user now and do not call result again this turn")]).compact
            }
            return env.json.compact
        case "stop":
            guard let id = args["id"]?.stringValue, !id.isEmpty else { throw ToolError("stop needs id") }
            let ok = await hub.stop(id)
            return ok ? "stopped \(id)" : "nothing to stop: \(id) is not running"
        default:
            throw ToolError("action must be run, status, result or stop")
        }
    }

    private func run(_ args: [String: JSONValue]) async throws -> String {
        let input = (args["input"]?.stringValue ?? args["task"]?.stringValue ?? args["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw ToolError("run needs input — the task for the child, as one message") }
        let systemPrompt = (args["system_prompt"]?.stringValue ?? args["system"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let names: [String] = args["tools"]?.arrayValue?.compactMap(\.stringValue)
            ?? args["tools"]?.stringValue.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } } ?? []
        let wait = args["wait"]?.boolValue ?? true
        guard let context = await context() else { throw ToolError("no model is loaded — a sub-agent needs the same model you run on") }
        let tools: [any Tool]
        switch SubAgentHub.validateTools(names, against: context) {
        case .success(let t): tools = t
        case .failure(let e): throw e
        }
        let live = await hub.running.count
        let sink = Agent.childSink
        let id = await hub.spawn(systemPrompt: systemPrompt, input: input, tools: tools, background: !wait, context: context, sink: sink)
        let queuedNote = live >= SubAgentHub.maxConcurrent ? " It is queued behind \(live) running agents and starts when one finishes." : ""
        if !wait {
            return JSONValue.object(["ok": .bool(true), "pending": .bool(true), "id": .string(id),
                                     "note": .string("Sub-agent started in the background.\(queuedNote) You will be woken with \"[use_agent \(id) finished] <result>\" — do not poll status now; tell the user it is running and finish your answer.")]).compact
        }
        guard let env = await hub.wait(id, timeout: SubAgentHub.inlineWait) else { throw ToolError("agent \(id) vanished") }
        if env.status.isFinished { return env.json.compact }
        return JSONValue.object(["ok": .bool(true), "pending": .bool(true), "id": .string(id),
                                 "note": .string("Still working after \(Int(SubAgentHub.inlineWait)) s — moved to the background.\(queuedNote) You will be woken with \"[use_agent \(id) finished] <result>\" — do not poll status now; tell the user it is running and finish your answer.")]).compact
    }
}

// MARK: - Wake turn

public enum SubAgentWake {
    /// The synthetic user turn the parent runs when a background child finishes (wake.ts buildWakePrompt, shortened
    /// for a small on-device model). States that no human typed it.
    public static func prompt(for e: SubAgentEnvelope) -> String {
        let outcome: String
        switch e.status {
        case .done: outcome = e.result?.isEmpty == false ? e.result! : "(no output)"
        case .failed: outcome = "FAILED: \(e.error ?? "unknown error")"
        case .stopped: outcome = "STOPPED before finishing"
        default: outcome = e.result ?? "(still running)"
        }
        return "[use_agent \(e.id) finished] \(e.info.name) (\(e.status.rawValue), \(Int(e.elapsed)) s, task: \"\(flat(e.info.input, 200))\")\n" +
            "Result: \(outcome)\n\n" +
            "No human typed this. Use the result to finish what the user asked; reply in a few sentences. Do not start new work the user did not ask for."
    }
    static func flat(_ s: String, _ max: Int) -> String {
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.count <= max ? t : String(t.prefix(max)) + "…"
    }
    /// The one-line transcript note shown for a wake (the model gets `prompt(for:)`; the person sees this).
    public static func line(for e: SubAgentEnvelope) -> String {
        // Plain words for the chat (IMPROVE-3 audit: "[use_agent agent_i finished] issues · done · 73 s" leaked the
        // envelope). The bracketed form stays in `prompt(for:)` — that one is for the model.
        let outcome: String
        switch e.status {
        case .done: outcome = "finished"
        case .failed: outcome = "failed"
        case .stopped: outcome = "was stopped"
        default: outcome = e.status.rawValue
        }
        return "\(prefix)\(e.info.name) \(outcome) · \(spokenElapsed(e.elapsed))"
    }
    static func spokenElapsed(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "\(t) s" : t % 60 == 0 ? "\(t / 60) min" : "\(t / 60) min \(t % 60) s"
    }
    /// Recognise a wake line in a transcript (`.note` with this prefix).
    public static let prefix = "Helper "
}
