import Foundation

/// Manual tool prompting for models whose chat template has no `tools`
/// support (or when we could not load a template at all). The output is
/// pinned by `PromptBuilderTests` — change the snapshot deliberately.
public enum PromptBuilder {
    public static func toolSystemPrompt(tools: [any AgentTool], family: ToolFamily, base: String?) -> String {
        guard !tools.isEmpty else { return base ?? "" }
        let specs = tools.map { $0.spec.compact }.joined(separator: "\n")
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

    /// Fold tool results into a user-visible turn for templates that lack a
    /// `tool` role (Gemma, SmolLM2). Keeps the conversation strictly
    /// user/assistant alternating.
    public static func foldToolMessages(_ messages: [Message]) -> [Message] {
        var out: [Message] = []
        for m in messages {
            switch m {
            case .tool(let result, let callId, let name):
                let line = "<tool_response name=\"\(name)\" id=\"\(callId)\">\n\(result)\n</tool_response>"
                if case .user(let prev)? = out.last {
                    out[out.count - 1] = .user(prev + "\n" + line)
                } else {
                    out.append(.user(line))
                }
            case .assistant(let text, let calls) where !calls.isEmpty:
                let rendered = calls.map { "<tool_call>\n{\"name\": \"\($0.name)\", \"arguments\": \(JSONValue.object($0.arguments).compact)}\n</tool_call>" }.joined(separator: "\n")
                out.append(.assistant(text: (text.isEmpty ? "" : text + "\n") + rendered, toolCalls: []))
            default:
                out.append(m)
            }
        }
        return out
    }

    /// Plain-text fallback rendering (ChatML) when no tokenizer template exists.
    public static func chatML(_ messages: [Message]) -> String {
        var s = ""
        for m in foldToolMessages(messages) {
            s += "<|im_start|>\(m.role)\n\(m.text)<|im_end|>\n"
        }
        s += "<|im_start|>assistant\n"
        return s
    }
}
