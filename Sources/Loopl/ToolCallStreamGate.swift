import Foundation

/// Provider-side helper: converts a text-only decode stream into Strands
/// `StreamEvent`s, turning tool-call markup (`<tool_call>…</tool_call>`,
/// `<|python_tag|>{…}`, fenced JSON, bare `{"name":…}`) into `toolUse` content
/// blocks — the job Strands' Bedrock/OpenAI providers do with native tool-use
/// deltas, done here for small open models that only speak text.
///
/// Text is forwarded live until the first character that could open a tool
/// call; from there on it is withheld and resolved at `finish()` with
/// `ToolCallParser`, so a UI never shows half a `<tool_call>` tag and the
/// visible text never contains the markup. A hold that turns out not to be a
/// call — a ```swift code block, a fenced JSON object with no `"name"` key
/// within its first 160 characters, a fence whose body is prose — is released
/// as plain text as soon as that is clear, so an answer streams instead of
/// appearing whole at the end. Not thread-safe: one per stream.
public struct ToolCallStreamGate: Sendable {
    public let family: ToolFamily
    private var full = ""
    private var emitted = ""          // raw text consumed from `full` (incl. <think> parts never shown)
    private var emittedVisible = ""   // text actually sent as text deltas
    private var holding = false
    /// Characters of `full` (absolute offset) already judged to be plain text — no opener check applies.
    private var passthroughUntil = 0
    /// A code fence released as plain text is open: its closing ``` is plain too.
    private var plainFenceOpen = false
    private var started = false
    private var textBlockOpen = false
    private var reasoningOpen = false
    private var inThink = false
    private let parser: ToolCallParser
    private let suppress: (@Sendable (ToolUse) -> Bool)?
    /// Calls `suppress` rejected at `finish()` — a provider may react (see `AppleFoundationModel`).
    public private(set) var suppressedCalls: [ToolUse] = []
    /// A text content block is open (a provider replacing text mid-stream needs to know).
    public var isTextBlockOpen: Bool { textBlockOpen }
    /// Text sent as deltas so far.
    public var visibleText: String { emittedVisible }
    /// Characters of a fenced JSON body without a `"name"` key after which it is clearly not a call.
    public static let heldJSONLimit = 160

    /// - Parameter suppress: optional veto on a parsed tool call, applied at
    ///   `finish()`. Providers that prompt tools manually use it to drop a call
    ///   the model merely echoed back (see `ToolCallRepeatGuard`); `nil` (the
    ///   default) keeps every call, which is what the MLX and GGUF runtimes do.
    public init(family: ToolFamily, suppress: (@Sendable (ToolUse) -> Bool)? = nil) {
        self.family = family
        self.suppress = suppress
        parser = ToolCallParser(family: family)
    }

    /// Openers we must not stream through. Order matters only for the prefix check.
    static let openers = ["<tool_call>", "<|tool_call|>", "<function_call>", "<|python_tag|>", "```", "{\""]

    /// Feed one decoded text piece; returns the stream events to emit now.
    public mutating func feed(_ piece: String) -> [StreamEvent] {
        var out: [StreamEvent] = []
        if !started { started = true; out.append(.messageStart(role: .assistant)) }
        full += piece
        if holding {
            let held = String(full.dropFirst(emitted.count))
            guard Self.isClearlyNotACall(held) else { return out }
            // Release: everything held so far is prose; keep its closing fence plain too.
            holding = false
            passthroughUntil = full.count
            plainFenceOpen = held.hasPrefix("```") && !held.dropFirst(3).contains("```")
        }

        // Qwen3 thinking: stream it as reasoning deltas, not text.
        let pending = String(full.dropFirst(emitted.count))
        var textToEmit = ""
        var reasoningToEmit = ""
        var consumed = 0
        var i = pending.startIndex
        scan: while i < pending.endIndex {
            let rest = pending[i...]
            if inThink {
                if rest.hasPrefix("</think>") { inThink = false; i = pending.index(i, offsetBy: 8); consumed = pending.distance(from: pending.startIndex, to: i); continue }
                if Self.isPrefixOfAny(String(rest), ["</think>"]) { break scan }   // might be the closer — wait
                reasoningToEmit.append(rest.first!); i = pending.index(after: i); consumed = pending.distance(from: pending.startIndex, to: i); continue
            }
            let offset = emitted.count + pending.distance(from: pending.startIndex, to: i)
            if offset < passthroughUntil {
                textToEmit.append(rest.first!); i = pending.index(after: i); consumed = pending.distance(from: pending.startIndex, to: i); continue
            }
            if plainFenceOpen {
                if rest.hasPrefix("```") {
                    plainFenceOpen = false
                    textToEmit += "```"; i = pending.index(i, offsetBy: 3); consumed = pending.distance(from: pending.startIndex, to: i); continue
                }
                if Self.isPrefixOfAny(String(rest), ["```"]) { break scan }
                textToEmit.append(rest.first!); i = pending.index(after: i); consumed = pending.distance(from: pending.startIndex, to: i); continue
            }
            if rest.hasPrefix("<think>") { inThink = true; i = pending.index(i, offsetBy: 7); consumed = pending.distance(from: pending.startIndex, to: i); continue }
            if Self.isPrefixOfAny(String(rest), ["<think>"]) && rest.count < 7 { break scan }
            if Self.opensToolCall(String(rest)) {
                holding = true
                break scan
            }
            if Self.isPrefixOfAny(String(rest), Self.openers) { break scan }     // ambiguous tail — wait for more
            textToEmit.append(rest.first!); i = pending.index(after: i); consumed = pending.distance(from: pending.startIndex, to: i)
        }
        if !reasoningToEmit.isEmpty {
            if textBlockOpen { out.append(.contentBlockStop); textBlockOpen = false }
            if !reasoningOpen { out.append(.contentBlockStart(.reasoning)); reasoningOpen = true }
            out.append(.contentBlockDelta(.reasoning(reasoningToEmit)))
        }
        if !textToEmit.isEmpty, !textBlockOpen, emittedVisible.isEmpty {
            textToEmit = String(textToEmit.drop(while: { $0.isWhitespace || $0.isNewline }))   // no leading blank lines after a </think>
        }
        if !textToEmit.isEmpty {
            emittedVisible += textToEmit
            if reasoningOpen { out.append(.contentBlockStop); reasoningOpen = false }
            if !textBlockOpen { out.append(.contentBlockStart(.text)); textBlockOpen = true }
            out.append(.contentBlockDelta(.text(textToEmit)))
        }
        emitted += String(pending.prefix(consumed))
        return out
    }

    /// End of decode. Resolves withheld text into text / toolUse blocks and emits `messageStop`.
    /// `stopReason` is the runtime's reason (`.endTurn` on EOS, `.maxTokens` when the budget/context ran out).
    public mutating func finish(stopReason: StopReason = .endTurn, native: [ToolUse] = []) -> [StreamEvent] {
        var out: [StreamEvent] = []
        if !started { started = true; out.append(.messageStart(role: .assistant)) }
        if reasoningOpen { out.append(.contentBlockStop); reasoningOpen = false }
        let parsed = parser.parse(full)
        // Visible text = parsed text (markup + <think> stripped); emit whatever we have not streamed yet.
        let visible = parsed.text
        let shown = emittedVisible
        var remainder = ""
        if shown.isEmpty {
            remainder = visible
        } else if visible.hasPrefix(shown) {
            remainder = String(visible.dropFirst(shown.count))
        } else {
            let trimmedShown = shown.trimmingCharacters(in: .whitespacesAndNewlines)
            if visible.hasPrefix(trimmedShown) { remainder = String(visible.dropFirst(trimmedShown.count)) }
        }
        remainder = String(remainder.drop(while: { $0.isWhitespace || $0.isNewline }).reversed().drop(while: { $0.isWhitespace || $0.isNewline }).reversed())
        if !shown.isEmpty, !remainder.isEmpty, !shown.hasSuffix(" "), !shown.hasSuffix("\n"), !remainder.hasPrefix(" ") {
            // the withheld tail started mid-sentence — keep whatever separator the model had
            if let gapStart = visible.range(of: trimmedOrSelf(shown))?.upperBound, gapStart < visible.endIndex, visible[gapStart].isWhitespace { remainder = " " + remainder }
        }
        if !remainder.isEmpty || textBlockOpen {
            if !textBlockOpen { out.append(.contentBlockStart(.text)); textBlockOpen = true }
            if !remainder.isEmpty { out.append(.contentBlockDelta(.text(remainder))) }
            out.append(.contentBlockStop); textBlockOpen = false
        }
        var uses = native
        for c in parsed.calls where !uses.contains(where: { $0.name == c.name && $0.input == c.input }) { uses.append(c) }
        if let suppress {
            let vetoed = uses.filter(suppress)
            if !vetoed.isEmpty {
                suppressedCalls += vetoed
                uses.removeAll(where: suppress)
            }
        }
        for u in uses {
            out.append(.contentBlockStart(.toolUse(toolUseId: u.toolUseId, name: u.name)))
            out.append(.contentBlockDelta(.toolUse(input: JSONValue.object(u.input).compact)))
            out.append(.contentBlockStop)
        }
        out.append(.messageStop(stopReason == .endTurn && !uses.isEmpty ? .toolUse : stopReason))
        return out
    }

    // MARK: helpers

    static func isPrefixOfAny(_ s: String, _ candidates: [String]) -> Bool {
        candidates.contains { $0.count > s.count && $0.hasPrefix(s) }
    }
    static func opensToolCall(_ rest: String) -> Bool {
        for o in openers where rest.hasPrefix(o) {
            if o == "{\"" { return rest.hasPrefix("{\"name\"") || rest.count < 7 && "{\"name\"".hasPrefix(rest) }
            return true
        }
        return false
    }
    static func hasClosedMarkup(_ s: String) -> Bool { s.contains("</tool_call>") || s.contains("```\n") }

    /// Fence languages a tool call may use (`ToolCallParser` rule 3).
    static let callFenceLanguages: Set<String> = ["", "json", "JSON", "tool_call", "tool"]

    /// Held text that can no longer be a tool call. Only code fences are ever
    /// released: `<tool_call>`-style markup and a `{"name"` object are calls.
    static func isClearlyNotACall(_ held: String) -> Bool {
        guard held.hasPrefix("```") else { return false }
        let afterFence = held.dropFirst(3)
        guard let nl = afterFence.firstIndex(of: "\n") else { return false }          // language tag still arriving
        let lang = afterFence[..<nl].trimmingCharacters(in: .whitespaces)
        if !callFenceLanguages.contains(lang) { return true }                          // ```swift … — code, not a call
        let body = afterFence[afterFence.index(after: nl)...]
        let trimmed = body.drop(while: { $0.isWhitespace || $0.isNewline })
        guard let first = trimmed.first else { return false }                           // body not started
        if first != "{" { return true }                                                 // prose inside a fence
        if trimmed.contains("\"name\"") { return false }                                 // a call — keep holding
        let closed = trimmed.contains("```")
        return closed || trimmed.count >= heldJSONLimit                                 // a JSON object that is not a call
    }
    private func trimmedOrSelf(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
