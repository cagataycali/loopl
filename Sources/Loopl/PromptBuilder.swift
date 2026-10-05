import Foundation

/// Manual tool prompting for models whose chat template has no `tools`
/// support (or when we could not load a template at all). The output is
/// pinned by `PromptBuilderTests` — change the snapshot deliberately.
public enum PromptBuilder {
    public static func toolSystemPrompt(toolSpecs: [ToolSpec], family: ToolFamily, base: String?) -> String {
        guard !toolSpecs.isEmpty else { return base ?? "" }
        let specs = toolSpecs.map { $0.openAIFunction.compact }.joined(separator: "\n")
        var out = base.map { $0 + "\n\n" } ?? ""
        switch family {
        case .hermes:
            out += """
            # Tools

            You may call one or more functions to assist with the user query.

            You are provided with function signatures within <tools></tools> XML tags:
            <tools>
            \(specs)
            </tools>

            For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
            <tool_call>
            {"name": <function-name>, "arguments": <args-json-object>}
            </tool_call>
            After the tool results arrive, answer the user in plain text.
            """
        case .llama3:
            out += """
            Environment: ipython
            You have access to the following functions. To call a function, respond with a JSON object of the form {"name": function_name, "parameters": {argument: value}} and nothing else.

            \(specs)

            Call at most one function per message. When the function results arrive, answer the user in plain text.
            """
        case .generic:
            out += """
            You can use these tools:
            \(specs)

            To use a tool, reply with ONLY a JSON object inside a ```json fence: {"name": "<tool>", "arguments": {...}}.
            When you receive the tool result, answer the user in plain text.
            """
        }
        return out
    }

    /// 0.1 signature.
    public static func toolSystemPrompt(tools: [any Tool], family: ToolFamily, base: String?) -> String {
        toolSystemPrompt(toolSpecs: tools.map(\.toolSpec), family: family, base: base)
    }

    /// Fold tool results into a user-visible turn and tool uses into assistant
    /// text, for templates that lack a `tool` role (Gemma, SmolLM2). Keeps the
    /// conversation strictly user/assistant alternating with text-only blocks.
    public static func foldToolMessages(_ messages: [Message]) -> [Message] {
        var out: [Message] = []
        for m in messages {
            switch m.role {
            case .user where m.hasToolResult:
                let lines = m.toolResults.map { r in "<tool_response name=\"\(r.name)\" id=\"\(r.toolUseId)\">\n\(r.content)\n</tool_response>" }.joined(separator: "\n")
                if let prev = out.last, prev.role == .user {
                    out[out.count - 1] = .user(prev.text + "\n" + lines)
                } else {
                    out.append(.user(lines))
                }
            case .assistant where m.hasToolUse:
                let rendered = m.toolUses.map { "<tool_call>\n{\"name\": \"\($0.name)\", \"arguments\": \(JSONValue.object($0.input).compact)}\n</tool_call>" }.joined(separator: "\n")
                let text = m.text
                out.append(.assistant((text.isEmpty ? "" : text + "\n") + rendered))
            default:
                // Drop reasoning blocks from history; keep text.
                out.append(Message(role: m.role, content: [.text(m.text)]))
            }
        }
        return out
    }

    /// Plain-text fallback rendering (ChatML) when no tokenizer template exists.
    public static func chatML(systemPrompt: String?, messages: [Message]) -> String {
        var s = ""
        if let sys = systemPrompt, !sys.isEmpty { s += "<|im_start|>system\n\(sys)<|im_end|>\n" }
        for m in foldToolMessages(messages) {
            s += "<|im_start|>\(m.role.rawValue)\n\(m.text)<|im_end|>\n"
        }
        s += "<|im_start|>assistant\n"
        return s
    }
}
