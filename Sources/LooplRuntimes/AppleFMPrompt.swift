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
        let mode: Mode = (last?.role == .user && (last?.hasToolResult ?? false)) ? .answer : .call
        return Built(instructions: instructions(toolSpecs: toolSpecs, systemPrompt: systemPrompt, mode: mode),
                     prompt: prompt(messages: messages, mode: mode, insisting: insisting),
                     mode: mode)
    }

    // MARK: instructions

    static func instructions(toolSpecs: [ToolSpec], systemPrompt: String?, mode: Mode) -> String {
        var out = ""
        if let s = systemPrompt, !s.isEmpty { out += s + "\n\n" }
        guard !toolSpecs.isEmpty else { return out.trimmingCharacters(in: .whitespacesAndNewlines) }
        out += "You can use these tools:\n\(toolDocs(toolSpecs))\n\n"
        out += "To use a tool, reply with ONLY a JSON object inside a ```json fence: {\"name\": \"<tool>\", \"arguments\": {...}}.\n"
        switch mode {
        case .call:
            out += "When the result arrives you will be asked to answer in plain text."
        case .answer:
            out += "A result that is already in the conversation has ALREADY been produced for you — never ask for that tool again. Use the values you were given and answer in plain text."
        }
        return out
    }

    /// One compact line per tool: `- name(arg: type, opt?: type) — description`.
    /// Deliberately not JSON — see the note on `tokengeneration Code=10`.
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
                return "\(key)\(required.contains(key) ? "" : "?"): \(type)"
            }.joined(separator: ", ")
            var line = "- \(spec.name)(\(args))"
            let d = spec.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { line += " — \(d)" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: prompt

    static func prompt(messages: [Message], mode: Mode, insisting: Bool) -> String {
        switch mode {
        case .call:
            let lines = transcript(messages)
            if lines.count == 1, case .user(let text) = lines[0] { return text }   // single question: ask it bare
            return lines.map(\.rendered).joined(separator: "\n")
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
            out += results.map { "\($0.name) -> \($0.content)" }.joined(separator: "\n")
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
                for r in m.toolResults { out.append(.toolResult("\(r.name) -> \(r.content)")) }
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
