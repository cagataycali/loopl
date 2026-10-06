import Foundation
struct ReverseString: Tool {                       // struct <AnyName>: Tool, init with no arguments
    let name = "reverse_string"                     // 1-64 chars: letters, digits, _ -
    let description = "Reverses the given text."    // tells the model when to use it
    let inputSchema: [String: Any] = ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
    func call(_ args: [String: Any]) async throws -> String {
        guard let text = args["text"] as? String else { throw ToolError("text is required") }
        return String(text.reversed())
    }
}
