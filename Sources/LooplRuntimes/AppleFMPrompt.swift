import Foundation
import Loopl

/// Prompt rendering for Apple Foundation Models.
///
/// Apple FM takes a *system* string (`instructions`) plus one *prompt* string;
/// it has no chat template, no tool-call tokens and no `tool` role, so the
/// conversation has to be flattened by hand. Two findings from measuring the
/// real model (macOS 26.4.1, 2026-10-06) shape every choice here:
///
/// 1. **Never echo tool markup back at it.** Flattening the history with
///    `PromptBuilder.foldToolMessages` renders the exchange as
///    `Assistant: <tool_call>{…}</tool_call>` + `<tool_response …>`. Shown that,
///    FM mimicked the nearest example and re-emitted the *identical* call
///    instead of answering — 3 times out of 3. Downstream, the event loop
///    correctly executed the tool again and answered twice: the P0 "ran
///    `current_time` twice" bug. Rendering the same round as
///    "Tools have already been run for you. Results: …" + "answer in plain
///    text" produced a plain answer 3 times out of 3.
/// 2. **Never put raw JSON schemas in `instructions`.** Any instruction string
///    containing the OpenAI function JSON made generation fail outright with
///    `com.apple.tokengeneration Code=10` on macOS 26.4. Compact one-line tool
///    docs work, and cost a fraction of FM's 4096-token window.
public enum AppleFMPrompt {
    /// What this turn is for.
    public enum Mode: String, Sendable {
        /// No results pending: the model may answer or ask for a tool.
        case call
        /// Tool results just came back: the model is asked to answer in plain text.
        case answer
    }

    public struct Built: Sendable {
        public var instructions: String
        public var prompt: String
        public var mode: Mode
    }

    /// Render the conversation for one FM generation.
    public static func build(messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?,
                            insisting: Bool = false) -> Built {
        let last = messages.last
        // Answer mode only when every result of the last cycle succeeded: an `ERROR:` result
        // keeps the model in call mode so it can read the error and call again with corrected
        // arguments (or answer without the tool) — the owner's "no RepeatBreaker" rule means
        // the error text is the ONLY thing standing between the model and an identical retry.
        let results = (last?.role == .user) ? (last?.toolResults ?? []) : []
        let mode: Mode = (!results.isEmpty && results.allSatisfy { $0.status == .success }) ? .answer : .call
        return Built(instructions: instructions(toolSpecs: toolSpecs, systemPrompt: systemPrompt, mode: mode),
                     prompt: prompt(messages: messages, mode: mode, insisting: insisting),
                     mode: mode)
    }

    // MARK: instructions

    static func instructions(toolSpecs: [ToolSpec], systemPrompt: String?, mode: Mode) -> String {
        var out = ""
        if let s = systemPrompt, !s.isEmpty { out += s + "\n\n" }
        guard !toolSpecs.isEmpty else { return out.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Measured on the real model (macOS 26.4.1, 2026-10-06, 3 runs each): with the
        // previous wording "hey" became a fenced tool call 3/3 (and `{"name": "hello"}`
        // 1/2 with no such tool). This wording: greetings/small talk → prose 6/6, the
        // time question → exactly one `current_time` call 3/3, arithmetic → one
        // `calculator` call 3/3. Order matters: "answer directly" comes before the tools.
        out += "Answer the user directly in plain text. Greetings, small talk and anything you already know need no tool.\n\n"
        out += "Tools you may call ONLY when the request genuinely needs one:\n\(toolDocs(toolSpecs))\n\n"
        out += "To call a tool, reply with ONLY this, nothing else: ```json\n{\"name\": \"<one of the tool names above>\", \"arguments\": {...}}\n```\n"
        switch mode {
        case .call:
            out += "Never invent a tool name. Never answer in JSON. When a result arrives you will be asked to answer in plain text."
        case .answer:
            out += "Never answer in JSON. A result that is already in the conversation has ALREADY been produced for you — never ask for that tool again. Use the values you were given and answer in plain text."
        }
        return out
    }

    /// One compact line per tool: `- name — description. Arguments: a (type), b (type, optional).`
    /// Deliberately not JSON — see the note on `tokengeneration Code=10` — and deliberately
    /// not a signature: shown `current_time(timezone?: string)`, FM wrote
    /// `current_time("Europe/Istanbul")` as its answer 1–2 times in 6 (a pseudo-call no
    /// parser should accept); the prose form produced the JSON call 6/6.
    public static func toolDocs(_ specs: [ToolSpec]) -> String {
        specs.map { spec in
            let schema = spec.inputSchema.objectValue ?? [:]
            let props = schema["properties"]?.objectValue ?? [:]
            let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            let order = props.keys.sorted { a, b in
                let ra = required.contains(a), rb = required.contains(b)
                return ra == rb ? a < b : ra
            }
            let args = order.map { key -> String in
                let p = props[key]?.objectValue ?? [:]
                let type = p["type"]?.stringValue ?? "string"
                return "\(key) (\(type)\(required.contains(key) ? "" : ", optional"))"
            }.joined(separator: ", ")
            var line = "- \(spec.name)"
            let d = spec.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { line += " — \(d)" }
            if !args.isEmpty { line += (line.hasSuffix(".") ? " " : ". ") + "Arguments: \(args)." }
            return line
        }.joined(separator: "\n")
    }

    // MARK: pseudo-calls

    /// `current_time("Europe/Istanbul")`, `current_time "Europe/Istanbul"` or
    /// `current_time -- timezone=Europe/Istanbul` as the whole reply: the model meant a
    /// tool call and wrote a signature instead (seen 1–2 times in 8 with a terse system
    /// prompt). Returns the tool name when `text` is one short line that starts with a
    /// known tool name followed by anything but a letter (so "current_time is a tool…"
    /// stays prose), and the runtime re-asks once, insisting.
    public static func pseudoCall(in text: String, toolNames: [String]) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 160, !t.contains("\n") else { return nil }
        for name in toolNames where t.hasPrefix(name) {
            let rest = t.dropFirst(name.count).drop(while: { $0 == " " })
            if let c = rest.first, !c.isLetter { return name }
        }
        return nil
    }

    // MARK: prompt

    static func prompt(messages: [Message], mode: Mode, insisting: Bool) -> String {
        switch mode {
        case .call:
            let lines = transcript(messages)
            var out: String
            if lines.count == 1, case .user(let text) = lines[0] { out = text }   // single question: ask it bare
            else { out = lines.map(\.rendered).joined(separator: "\n") }
            if insisting {
                out += "\n\n(If a tool is needed, reply with ONLY the JSON object in a ```json fence exactly as instructed — a tool is never used by writing its name. Otherwise answer in plain text.)"
            }
            return out
        case .answer:
            let results = messages.last?.toolResults ?? []
            let history = transcript(messages.dropLast())
            var out = ""
            if history.count > 1 {
                out += history.dropLast().map(\.rendered).joined(separator: "\n") + "\n\n"
            }
            let question = history.last(where: { if case .user = $0 { return true }; return false })?.text ?? history.last?.text ?? ""
            out += "The user asked: \(question)\n\n"
            out += "Tools have already been run for you. Results:\n"
            out += results.map { "\($0.name) -> \($0.promptContent)" }.joined(separator: "\n")
            out += "\n\n"
            out += insisting
                ? "Answer the user's question now, in plain text, using those results. Output no JSON, no code fence and no tool name — just the sentence the user should read."
                : "Answer the user's question in plain text using those results. Do not output JSON."
            return out
        }
    }

    /// The conversation as plain labelled lines, with every trace of tool
    /// *markup* removed: a tool-call-only assistant turn disappears (its result
    /// is what matters) and tool results become one `Tool result (name): …` line.
    enum Line: Sendable {
        case user(String), assistant(String), toolResult(String)
        var text: String {
            switch self { case .user(let t), .assistant(let t), .toolResult(let t): return t }
        }
        var rendered: String {
            switch self {
            case .user(let t): return "User: \(t)"
            case .assistant(let t): return "Assistant: \(t)"
            case .toolResult(let t): return "Tool result: \(t)"
            }
        }
    }

    static func transcript(_ messages: some Sequence<Message>) -> [Line] {
        var out: [Line] = []
        for m in messages {
            switch m.role {
            case .user where m.hasToolResult:
                for r in m.toolResults { out.append(.toolResult("\(r.name) -> \(r.promptContent)")) }
            case .user:
                let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(.user(t)) }
            case .assistant:
                let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(.assistant(t)) }       // a tool-call-only turn renders as nothing
            }
        }
        return out
    }
}
