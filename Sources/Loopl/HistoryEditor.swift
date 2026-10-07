import Foundation

// `manage_messages` — turn-aware surgery on the agent's OWN working context.
// Port of tiny-tech `src/agent/manage-messages.ts` (itself a port of devduck's
// manage_messages.py). The hard-won invariants travel intact:
//
// - a TURN = one real user query + every tool cycle it triggered
// - the ACTIVE turn (the one executing this very tool call) is never dropped,
//   compacted or cleared — surgery only touches messages BEFORE it
// - any surgery that orphans a toolUse gets a synthetic toolResult injected
//   (chat templates render tool calls and results as pairs; one orphan breaks
//   every later prompt), and structure is validated before history is replaced
// - reasoning blocks are kept whole or go with the tool blocks they accompanied;
//   a reasoning-only message is never edited
//
// Everything here is PURE: `[Message]` in, `[Message]` + a report out. The agent
// (`Agent.editHistory`) is the only writer of the live array; the app's
// Transcript / History is built from events and keeps the user's full record —
// what shrinks is the context the model sees on its next call.

/// What one edit did — the agent emits it (`AgentEvent.historyEdited`) so a UI can
/// show a quiet "N turns compacted by the agent" marker.
public struct HistoryEdit: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Codable { case drop, dropTools = "drop_tools", compact, clear }
    public var action: Action
    /// Turns touched (dropped / compacted / cleared); tool calls removed for `drop_tools`.
    public var turnsAffected: Int
    public var toolBlocksRemoved: Int
    public var messagesBefore: Int
    public var messagesAfter: Int
    public init(action: Action, turnsAffected: Int, toolBlocksRemoved: Int, messagesBefore: Int, messagesAfter: Int) {
        self.action = action; self.turnsAffected = turnsAffected; self.toolBlocksRemoved = toolBlocksRemoved
        self.messagesBefore = messagesBefore; self.messagesAfter = messagesAfter
    }
    /// The transcript marker — one quiet line, plain words.
    public var summary: String {
        // Plain words (IMPROVE-3 audit): "compacted", "agent" and "context" read as developer voice in the chat.
        func turns(_ n: Int) -> String { n == 1 ? "1 turn" : "\(n) turns" }
        switch action {
        case .compact: return "The model tidied \(turns(turnsAffected)) of notes · your conversation is unchanged"
        case .drop: return "The model set aside \(turns(turnsAffected)) · your conversation is unchanged"
        case .clear: return "The model started its notes over (\(turns(turnsAffected))) · your conversation is unchanged"
        case .dropTools:
            let n = turnsAffected
            return "The model set aside \(n == 1 ? "1 tool result" : "\(n) tool results") · your conversation is unchanged"
        }
    }
}

public enum HistoryEditor {
    /// `[start, end)` message indices of one turn.
    public struct Turn: Sendable, Hashable { public var start: Int; public var end: Int }

    /// Error text handed to the model (`ERROR: manage_messages …` after the result prefix).
    public struct Failure: LocalizedError, Sendable, Hashable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { "manage_messages: " + message }
    }

    public enum Action: String, Sendable, CaseIterable, Codable {
        case list, listTools = "list_tools", stats, drop, dropTools = "drop_tools", compact, clear
    }

    /// One call's arguments, already parsed from the model's JSON (`Request.init(args:)` is lenient — see there).
    public struct Request: Sendable, Hashable {
        public var action: Action
        /// Turn indices (droppable turns are numbered 0… oldest first; the active turn has no number).
        public var turns: [Int] = []
        public var start: Int?
        public var end: Int?
        public var role: Role?
        public var toolIds: [String] = []
        public var toolName: String?
        /// `compact`: turns kept with their tool detail intact (default 3).
        public var keepLast: Int?
        public var summaryLength: Int = 80
        public init(action: Action) { self.action = action }

        /// Lenient parse of what a small model emits: `turns` as `[0,1]`, `"0,1"`, or one number; `tool_ids`
        /// as array or comma string; `keep_last` / `keep` / `keep_recent` for the same thing.
        public init(args: [String: JSONValue]) throws {
            guard let raw = args["action"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let action = Action(rawValue: raw) ?? Action(rawValue: raw.replacingOccurrences(of: " ", with: "_")) ?? Request.alias(raw) else {
                throw Failure("missing or unknown action — one of \(Action.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            self.init(action: action)
            turns = Request.ints(args["turns"] ?? args["turn"])
            start = Request.int(args["start"]); end = Request.int(args["end"])
            if let r = args["role"]?.stringValue?.lowercased() { role = Role(rawValue: r) }
            toolIds = Request.strings(args["tool_ids"] ?? args["tool_id"] ?? args["ids"] ?? args["id"])
            toolName = (args["tool_name"] ?? args["name"] ?? args["tool"])?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if toolName?.isEmpty == true { toolName = nil }
            keepLast = Request.int(args["keep_last"] ?? args["keep"] ?? args["keep_recent"] ?? args["keep_turns"])
            if let n = Request.int(args["summary_len"] ?? args["summary_length"]), n > 0 { summaryLength = n }
        }
        static func alias(_ s: String) -> Action? {
            switch s {
            case "tools", "calls", "list_calls": .listTools
            case "status", "size", "count", "info": .stats
            case "remove", "delete", "drop_turns": .drop
            case "remove_tools", "delete_tools", "drop_tool", "drop_calls": .dropTools
            case "compress", "summarize", "shrink", "trim": .compact
            case "reset", "wipe", "clear_all": .clear
            case "show", "history", "messages": .list
            default: nil
            }
        }
        static func int(_ v: JSONValue?) -> Int? {
            guard let v else { return nil }
            if let d = v.doubleValue, d == d.rounded(), abs(d) < 1e9 { return Int(d) }
            return nil
        }
        static func ints(_ v: JSONValue?) -> [Int] {
            guard let v else { return [] }
            switch v {
            case .array(let a): return a.compactMap(int)
            case .number: return [int(v)].compactMap { $0 }
            case .string(let s): return s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            default: return []
            }
        }
        static func strings(_ v: JSONValue?) -> [String] {
            guard let v else { return [] }
            switch v {
            case .array(let a): return a.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .string(let s): return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: return []
            }
        }
    }

    /// The replacement history (equal to the input for read-only actions), the text the model reads,
    /// and the edit to announce (nil when nothing changed).
    public struct Outcome: Sendable, Hashable {
        public var messages: [Message]
        public var text: String
        public var edit: HistoryEdit?
        public var changed: Bool { edit != nil }
    }

    // MARK: - turns

    /// A REAL user query — not a tool-result carrier.
    static func isUserQuery(_ m: Message) -> Bool { m.role == .user && !m.hasToolResult }
    static func hasTool(_ m: Message) -> Bool { m.content.contains { $0.isToolUse || $0.isToolResult } }
    static func hasReasoning(_ m: Message) -> Bool { m.content.contains { if case .reasoning = $0 { return true }; return false } }
    static func toolBlockCount(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + $1.content.filter { $0.isToolUse || $0.isToolResult }.count }
    }

    /// Parse messages into turns. A turn starts at a real user query and consumes every assistant reply +
    /// toolResult carrier until the next real query. Leading orphans (preamble a previous surgery left)
    /// belong to no turn.
    public static func parseTurns(_ messages: [Message]) -> [Turn] {
        var turns: [Turn] = []
        var i = 0
        while i < messages.count {
            if isUserQuery(messages[i]) {
                let start = i
                i += 1
                while i < messages.count, !isUserQuery(messages[i]) { i += 1 }
                turns.append(Turn(start: start, end: i))
            } else {
                i += 1
            }
        }
        return turns
    }

    /// toolUse ids that have no matching toolResult anywhere in the array.
    public static func pendingToolUseIds(_ messages: [Message]) -> [String] {
        var uses: [String] = [], results = Set<String>()
        for m in messages {
            for b in m.content {
                if let u = b.toolUse { uses.append(u.toolUseId) } else if let r = b.toolResult { results.insert(r.toolUseId) }
            }
        }
        var seen = Set<String>()
        return uses.filter { !results.contains($0) && seen.insert($0).inserted }
    }

    /// The active turn: last real user query through the end. While a tool executes (this one included)
    /// its toolUse sits unresolved in this tail — dropping it would tear the very cycle we are inside of.
    public static func activeTurnStart(_ messages: [Message]) -> Int? {
        messages.lastIndex(where: isUserQuery)
    }

    /// Tool ids inside the active turn (plus `selfId`, this call's own toolUseId).
    public static func activeToolIds(_ messages: [Message], selfId: String? = nil) -> Set<String> {
        var ids = Set<String>()
        if let start = activeTurnStart(messages) {
            for m in messages[start...] {
                for b in m.content {
                    if let u = b.toolUse { ids.insert(u.toolUseId) } else if let r = b.toolResult { ids.insert(r.toolUseId) }
                }
            }
        }
        if let selfId { ids.insert(selfId) }
        return ids
    }

    /// Everything before the active turn is fair game; the active turn always survives untouched.
    public static func splitActive(_ messages: [Message]) -> (droppable: [Message], active: [Message]) {
        guard let s = activeTurnStart(messages) else { return ([], messages) }
        return (Array(messages[..<s]), Array(messages[s...]))
    }

    // MARK: - repair + validation

    public static let syntheticResultText = "[conversation modified - synthetic result]"

    static func synthetic(_ use: ToolUse) -> ToolResult {
        ToolResult(toolUseId: use.toolUseId, name: use.name, status: .success, content: syntheticResultText)
    }

    /// Repair every incomplete tool cycle: a toolUse with no toolResult gets a synthetic result right after its
    /// assistant message — merged INTO the real carrier when one follows (a separate user message inserted
    /// before it would create user→user), otherwise as a new carrier. Critical after ANY surgery.
    public static func fixIncompleteToolCycles(_ messages: [Message]) -> [Message] {
        let pending = Set(pendingToolUseIds(messages))
        guard !pending.isEmpty else { return messages }
        var out: [Message] = []
        var i = 0
        while i < messages.count {
            let m = messages[i]
            out.append(m)
            defer { i += 1 }
            guard m.role == .assistant else { continue }
            let mine = m.toolUses.filter { pending.contains($0.toolUseId) }
            guard !mine.isEmpty else { continue }
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            let nextIsCarrier = next?.role == .user && next?.hasToolResult == true
            let covered = Set(nextIsCarrier ? (next?.toolResults.map(\.toolUseId) ?? []) : [])
            let missing = mine.filter { !covered.contains($0.toolUseId) }
            guard !missing.isEmpty else { continue }
            if nextIsCarrier, var carrier = next {
                carrier.content += missing.map { .toolResult(synthetic($0)) }
                out.append(carrier)
                i += 1   // carrier consumed
            } else {
                out.append(.toolResults(missing.map(synthetic)))
            }
        }
        return out
    }

    public struct Validation: Sendable, Hashable {
        public var ok: Bool
        public var error: String
        public var warnings: [String]
    }

    /// Broken tool pairing is a HARD error (templates render pairs). Same-role adjacency is only a warning:
    /// the prompt builders merge or accept it, and legal surgery produces it.
    public static func validateStructure(_ messages: [Message]) -> Validation {
        let pending = pendingToolUseIds(messages)
        if !pending.isEmpty {
            return Validation(ok: false, error: "\(pending.count) toolUse without toolResult: \(pending.prefix(3).joined(separator: ", "))", warnings: [])
        }
        var adjacent = 0
        for i in 1..<max(1, messages.count) where messages[i - 1].role == messages[i].role { adjacent += 1 }
        return Validation(ok: true, error: "", warnings: adjacent > 0 ? ["\(adjacent) same-role adjacency(ies) — tolerated, the prompt builder merges these"] : [])
    }

    // MARK: - surgery (pure)

    /// Remove specific toolUse/toolResult blocks by id. Editing a message also drops its reasoning blocks
    /// (prior-turn reasoning may be omitted, never left beside altered siblings); emptied messages go.
    public static func removeToolBlocks(_ messages: [Message], ids: Set<String>) -> [Message] {
        var out: [Message] = []
        for var m in messages {
            let hasTarget = m.content.contains { b in
                if let u = b.toolUse { return ids.contains(u.toolUseId) }
                if let r = b.toolResult { return ids.contains(r.toolUseId) }
                return false
            }
            guard hasTarget else { out.append(m); continue }
            let kept = m.content.filter { b in
                if let u = b.toolUse { return !ids.contains(u.toolUseId) }
                if let r = b.toolResult { return !ids.contains(r.toolUseId) }
                if case .reasoning = b { return false }
                return true
            }
            if kept.count == m.content.count { out.append(m) } else if !kept.isEmpty { m.content = kept; out.append(m) }
        }
        return out
    }

    /// Strip ALL tool blocks from the given turns, keeping text/image blocks — the compact operation.
    /// Reasoning goes with the tool blocks it accompanied; reasoning-only messages stay whole; emptied messages go.
    public static func stripToolBlocks(_ messages: [Message], turnIndices: Set<Int>, turns: [Turn]) -> [Message] {
        var strip = Set<Int>()
        for t in turnIndices where t >= 0 && t < turns.count { strip.formUnion(turns[t].start..<turns[t].end) }
        var out: [Message] = []
        for (i, var m) in messages.enumerated() {
            guard strip.contains(i) else { out.append(m); continue }
            let tool = hasTool(m)
            let kept = m.content.filter { b in
                if b.isToolUse || b.isToolResult { return false }
                if tool, case .reasoning = b { return false }
                return true
            }
            if kept.count == m.content.count { out.append(m) } else if !kept.isEmpty { m.content = kept; out.append(m) }
        }
        return out
    }

    // MARK: - views

    /// One-line preview of a message's blocks.
    public static func summarize(_ content: [ContentBlock], maxLength: Int = 80) -> String {
        var parts: [String] = []
        for b in content.prefix(3) {
            switch b {
            case .text(let t):
                let flat = t.replacingOccurrences(of: "\n", with: " ")
                parts.append("\"" + String(flat.prefix(maxLength)) + (flat.count > maxLength ? "…" : "") + "\"")
            case .toolUse(let u): parts.append("toolUse:\(u.name)")
            case .toolResult(let r): parts.append("toolResult:\(r.name)")
            case .reasoning: parts.append("[reasoning]")
            case .image: parts.append("[image]")
            case .video: parts.append("[video]")
            }
        }
        if content.count > 3 { parts.append("+\(content.count - 3) more") }
        return parts.isEmpty ? "(empty)" : parts.joined(separator: " | ")
    }

    /// Every tool call with pairing status — the `list_tools` view's data.
    public struct ToolCall: Sendable, Hashable {
        public var toolUseId: String
        public var name: String
        public var messageIndex: Int
        public var result: ToolResult?
        public var argsPreview: String
        public var hasResult: Bool { result != nil }
    }

    public static func allToolCalls(_ messages: [Message]) -> [ToolCall] {
        var results: [String: ToolResult] = [:]
        for m in messages { for r in m.toolResults { results[r.toolUseId] = r } }
        var calls: [ToolCall] = []
        for (i, m) in messages.enumerated() {
            for u in m.toolUses {
                calls.append(ToolCall(toolUseId: u.toolUseId, name: u.name, messageIndex: i, result: results[u.toolUseId],
                                      argsPreview: String(JSONValue.object(u.input).compact.prefix(80))))
            }
        }
        return calls
    }

    /// `turns` / `start` / `end` → a set of turn indices (`start` alone = through the last turn; `end` alone = from 0).
    public static func resolveTurnIndices(count: Int, turns: [Int], start: Int?, end: Int?) -> Set<Int> {
        var idx = Set(turns)
        if let start, let end { if start < end { idx.formUnion(start..<end) } }
        else if let start { if start < count { idx.formUnion(start..<count) } }
        else if let end { if end > 0 { idx.formUnion(0..<end) } }
        return idx
    }

    // MARK: - the actions

    public static let defaultKeepTurns = 3

    /// Apply one request to a history. Pure: returns the replacement + report, throws `Failure` for a bad request.
    /// `selfId` is this call's own toolUseId (so `drop_tools` cannot remove the call that is running);
    /// `projectedTokens` (the agent's measured+estimated prompt size) improves `stats` when known.
    public static func apply(_ req: Request, to messages: [Message], selfId: String? = nil, projectedTokens: Int? = nil) throws -> Outcome {
        func unchanged(_ text: String) -> Outcome { Outcome(messages: messages, text: text, edit: nil) }
        let maxLen = max(8, req.summaryLength)

        switch req.action {
        case .list:
            guard !messages.isEmpty else { return unchanged("No messages") }
            if let role = req.role {
                let rows = messages.enumerated().filter { $0.element.role == role }
                return unchanged(([ "\(rows.count) \(role.rawValue) messages:" ] + rows.map { "  [\($0.offset)] \(summarize($0.element.content, maxLength: maxLen))" }).joined(separator: "\n"))
            }
            let (droppable, _) = splitActive(messages)
            let turns = parseTurns(messages)
            let droppableCount = parseTurns(droppable).count
            var lines = ["\(turns.count) turns (\(messages.count) messages). Turn numbers below are what drop/compact take; the ACTIVE turn cannot be edited."]
            var covered = Set<Int>()
            for (ti, t) in turns.enumerated() {
                let active = ti >= droppableCount
                lines.append("--- turn \(active ? "ACTIVE" : String(ti)) (msgs \(t.start)-\(t.end - 1)) ---")
                for i in t.start..<t.end {
                    covered.insert(i)
                    lines.append("  [\(i)] \(messages[i].role.rawValue): \(summarize(messages[i].content, maxLength: maxLen))")
                }
            }
            let orphans = messages.indices.filter { !covered.contains($0) }
            if !orphans.isEmpty {
                lines.append("--- preamble (no turn) ---")
                for i in orphans { lines.append("  [\(i)] \(messages[i].role.rawValue): \(summarize(messages[i].content, maxLength: maxLen))") }
            }
            return unchanged(lines.joined(separator: "\n"))

        case .listTools:
            let calls = allToolCalls(messages)
            guard !calls.isEmpty else { return unchanged("No tool calls found") }
            let active = activeToolIds(messages, selfId: selfId)
            var lines = ["\(calls.count) tool calls:"]
            for (i, c) in calls.enumerated() {
                let lock = active.contains(c.toolUseId) ? " 🔒(active)" : ""
                lines.append("\(i). \(c.hasResult ? "✅" : "⏳") \(c.name)\(lock)  id=\(c.toolUseId)")
                lines.append("   args: \(c.argsPreview)")
                if let r = c.result { lines.append("   result (\(r.status.rawValue)): \(String(r.content.replacingOccurrences(of: "\n", with: " ").prefix(80)))") }
            }
            lines.append("Use drop_tools with tool_ids or tool_name to remove non-active calls.")
            return unchanged(lines.joined(separator: "\n"))

        case .stats:
            guard !messages.isEmpty else { return unchanged("No messages") }
            let turns = parseTurns(messages)
            var counts: [String: Int] = [:]
            for m in messages { for b in m.content { counts[blockName(b), default: 0] += 1 } }
            let pending = pendingToolUseIds(messages)
            var byName: [String: Int] = [:]
            for c in allToolCalls(messages) { byName[c.name, default: 0] += 1 }
            let top = byName.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { "\($0.key)(\($0.value))" }.joined(separator: ", ")
            let user = messages.filter { $0.role == .user }.count
            let estimate = messages.reduce(0) { $0 + TokenEstimator.estimate($1) }
            let tokens = projectedTokens ?? estimate
            let droppable = parseTurns(splitActive(messages).droppable).count
            var text = """
            Turns: \(turns.count) (\(droppable) droppable + the active one)
            Messages: \(messages.count) (user: \(user), assistant: \(messages.count - user))
            Context: ≈\(tokens) tokens\(projectedTokens == nil ? " (estimated from shape)" : " (last model call's usage + new messages)")
            Blocks: \(counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
            Top tools: \(top.isEmpty ? "none" : top)
            Pending toolUse (no result): \(pending.count)
            """
            if !pending.isEmpty { text += "\n⚠️ \(pending.count) toolUse block(s) without a result — the running tool cycle accounts for the one running now" }
            return unchanged(text)

        case .drop:
            let (droppable, active) = splitActive(messages)
            guard !droppable.isEmpty else { return unchanged("No droppable messages (only the active turn exists)") }
            let turns = parseTurns(droppable)
            let idx = resolveTurnIndices(count: turns.count, turns: req.turns, start: req.start, end: req.end)
            guard !idx.isEmpty else { throw Failure("specify turns (e.g. [0,1]) or start/end — droppable turns: 0-\(turns.count - 1)") }
            let inRange = idx.filter { $0 >= 0 && $0 < turns.count }
            guard !inRange.isEmpty else { throw Failure("no such turn(s): \(idx.sorted().map(String.init).joined(separator: ", ")) (droppable turns: 0-\(turns.count - 1))") }
            var dropIdx = Set<Int>()
            for t in inRange { dropIdx.formUnion(turns[t].start..<turns[t].end) }
            var kept = droppable.enumerated().filter { !dropIdx.contains($0.offset) }.map(\.element)
            kept = fixIncompleteToolCycles(kept)
            let next = kept + active
            try check(next)
            let edit = HistoryEdit(action: .drop, turnsAffected: inRange.count, toolBlocksRemoved: toolBlockCount(messages) - toolBlockCount(next),
                                   messagesBefore: messages.count, messagesAfter: next.count)
            return Outcome(messages: next, text: "Dropped \(inRange.count) turn(s) (\(dropIdx.count) messages). Remaining: \(parseTurns(kept).count) turns + active turn (\(next.count) messages total)", edit: edit)

        case .dropTools:
            guard !req.toolIds.isEmpty || req.toolName != nil else { throw Failure("drop_tools needs tool_ids or tool_name (see list_tools)") }
            let active = activeToolIds(messages, selfId: selfId)
            var ids = Set<String>()
            for id in req.toolIds {
                if active.contains(id) { throw Failure("cannot drop active tool call \(id) — it belongs to the turn running now") }
                ids.insert(id)
            }
            if let name = req.toolName {
                for c in allToolCalls(messages) where c.name == name && !active.contains(c.toolUseId) { ids.insert(c.toolUseId) }
            }
            guard !ids.isEmpty else { return unchanged("No droppable tool calls found" + (req.toolName.map { " for \($0)" } ?? "")) }
            let (droppable, activeMsgs) = splitActive(messages)
            guard !droppable.isEmpty else { return unchanged("No droppable messages (only the active turn exists)") }
            var modified = removeToolBlocks(droppable, ids: ids)
            modified = fixIncompleteToolCycles(modified)
            let stillThere = Set(allToolCalls(modified).map(\.toolUseId))
            let gone = ids.filter { !stillThere.contains($0) }
            guard !gone.isEmpty else { throw Failure("drop_tools removed nothing — \(ids.sorted().prefix(3).joined(separator: ", ")) not found before the active turn") }
            let next = modified + activeMsgs
            try check(next)
            var text = "Dropped \(gone.count) tool call(s): \(gone.sorted().prefix(5).joined(separator: ", "))\(gone.count > 5 ? "…" : "")"
            let survived = ids.subtracting(gone)
            if !survived.isEmpty { text += "\n⚠️ \(survived.count) survived (could not be removed): \(survived.sorted().prefix(5).joined(separator: ", "))" }
            let edit = HistoryEdit(action: .dropTools, turnsAffected: gone.count, toolBlocksRemoved: toolBlockCount(messages) - toolBlockCount(next),
                                   messagesBefore: messages.count, messagesAfter: next.count)
            return Outcome(messages: next, text: text, edit: edit)

        case .compact:
            let (droppable, active) = splitActive(messages)
            guard !droppable.isEmpty else { return unchanged("No compactable messages (only the active turn exists)") }
            let turns = parseTurns(droppable)
            guard !turns.isEmpty else { return unchanged("No complete turns found to compact") }
            var idx = resolveTurnIndices(count: turns.count, turns: req.turns, start: req.start, end: req.end)
            if idx.isEmpty {
                let keep = max(0, req.keepLast ?? defaultKeepTurns)
                guard turns.count > keep else { return unchanged("Only \(turns.count) turn(s) before this one — nothing to compact (keeping the last \(keep))") }
                idx = Set(0..<(turns.count - keep))
            }
            let before = toolBlockCount(droppable)
            var compacted = stripToolBlocks(droppable, turnIndices: idx, turns: turns)
            compacted = fixIncompleteToolCycles(compacted)
            let removed = before - toolBlockCount(compacted)
            guard removed > 0 || compacted.count != droppable.count else {
                return unchanged("Nothing to compact — the selected turn(s) carry no tool calls. Use drop to remove whole turns.")
            }
            let next = compacted + active
            try check(next)
            let edit = HistoryEdit(action: .compact, turnsAffected: idx.count, toolBlocksRemoved: removed, messagesBefore: messages.count, messagesAfter: next.count)
            return Outcome(messages: next, text: "Compacted \(idx.count) turn(s), removed \(removed) tool blocks (their text stays). Messages: \(droppable.count) → \(compacted.count) + active turn", edit: edit)

        case .clear:
            let (droppable, active) = splitActive(messages)
            let turnCount = parseTurns(droppable).count
            guard !droppable.isEmpty else { return unchanged("Nothing to clear (only the active turn exists)") }
            let edit = HistoryEdit(action: .clear, turnsAffected: turnCount, toolBlocksRemoved: toolBlockCount(droppable), messagesBefore: messages.count, messagesAfter: active.count)
            return Outcome(messages: active, text: "Cleared \(turnCount) turn(s) (\(droppable.count) messages), preserved the active turn", edit: edit)
        }
    }

    /// Structure gate before anything is handed back as the new history. The active turn is allowed its own
    /// unresolved toolUse (the call running right now); everything edited must pair up.
    static func check(_ next: [Message]) throws {
        let (edited, active) = splitActive(next)
        let v = validateStructure(edited)
        guard v.ok else { throw Failure("refused — the edited history is broken: \(v.error)") }
        // Nothing before the active turn may answer an active toolUse, and the active turn is untouched by
        // construction — so the only pending ids allowed in `next` are the active turn's own.
        let allowed = Set(pendingToolUseIds(active))
        let stray = pendingToolUseIds(next).filter { !allowed.contains($0) }
        guard stray.isEmpty else { throw Failure("refused — the edited history is broken: \(stray.count) toolUse without toolResult: \(stray.prefix(3).joined(separator: ", "))") }
    }

    static func blockName(_ b: ContentBlock) -> String {
        switch b {
        case .text: "text"
        case .toolUse: "toolUse"
        case .toolResult: "toolResult"
        case .reasoning: "reasoning"
        case .image: "image"
        case .video: "video"
        }
    }
}

// MARK: - the tool

/// `manage_messages`: the agent inspects and edits its OWN working context. Reaches the live agent through
/// `ToolContext.current` (set by `Agent.runTool`); outside an agent call it reports that honestly.
///
/// The description is written for SMALL models (0.8B–4B): it says WHEN to call it and what the two
/// actions that matter do, in one breath each — every clause here was shaped by `ManageMessagesMeasurement`.
public struct ManageMessagesTool: Tool {
    public init() {}
    public let name = "manage_messages"
    public let description = "Your own conversation context: measure it or shrink it. Call with action=stats when asked how big, how long or how many turns/tokens this conversation is — it is the only way to know. When the context is getting long (many turns, many tool results) or you are told it is long, call action=compact: it removes old tool calls and results but keeps every message's text (default keeps the last 3 turns in full; keep_last to change). action=drop removes whole old turns by number (turns=[0,1]); action=clear keeps only the current turn; action=list shows turns with their numbers; action=list_tools lists tool calls with ids for action=drop_tools (tool_ids or tool_name). The current turn is never removed. The user's visible chat history is not changed — only what you see."
    public let parameters: JSONValue = ["type": "object", "properties": [
        "action": ["type": "string", "enum": .array(HistoryEditor.Action.allCases.map { .string($0.rawValue) }),
                   "description": "compact (default choice when the context is long) | drop | clear | stats | list | list_tools | drop_tools"],
        "turns": ["type": "array", "items": ["type": "integer"], "description": "turn numbers for drop or compact, e.g. [0,1] (from list; oldest is 0)"],
        "keep_last": ["type": "integer", "description": "compact: how many recent turns keep their tool detail (default 3)"],
        "tool_ids": ["type": "array", "items": ["type": "string"], "description": "drop_tools: tool call ids from list_tools"],
        "tool_name": ["type": "string", "description": "drop_tools: remove every call to this tool"],
        "start": ["type": "integer", "description": "first turn number (inclusive) instead of turns"],
        "end": ["type": "integer", "description": "last turn number (exclusive) instead of turns"],
        "role": ["type": "string", "enum": ["user", "assistant"], "description": "list: only this role"]],
        "required": ["action"]]

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let request = try HistoryEditor.Request(args: args)
        guard let context = ToolContext.current else {
            throw ToolError("manage_messages: no live agent in this context — the tool only works inside an agent run")
        }
        let outcome = try await context.agent.editHistory(request, selfToolUseId: context.toolUseId)
        return outcome.text
    }
}
