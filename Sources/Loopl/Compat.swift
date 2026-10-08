import Foundation

// 0.1 → 0.2 shims. Deprecated; removed in the next CORE2 commit (see COORDINATION.md).

extension ToolUse {
    @available(*, deprecated, renamed: "init(toolUseId:name:input:)")
    public init(id: String, name: String, arguments: [String: JSONValue]) { self.init(toolUseId: id, name: name, input: arguments) }
}

extension ToolResult {
    @available(*, deprecated, renamed: "init(toolUseId:name:status:content:durationMs:)")
    public init(callId: String, name: String, content: String, isError: Bool, durationMs: Double) {
        self.init(toolUseId: callId, name: name, status: isError ? .error : .success, content: content, durationMs: durationMs)
    }
}

extension HFDownloader {
    /// Tokens are gone — loopl downloads public repos anonymously. The argument is ignored.
    @available(*, deprecated, message: "HFDownloader is anonymous; use init()")
    public init(token: String?) { self.init() }
}

extension Message {
    @available(*, deprecated, renamed: "assistant(text:toolUses:)")
    public static func assistant(text: String, toolCalls: [ToolUse]) -> Message { .assistant(text: text, toolUses: toolCalls) }
}
