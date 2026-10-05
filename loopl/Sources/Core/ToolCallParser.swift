import Foundation

/// Which tool-calling dialect a model family speaks when it is prompted
/// manually (no native tool-call tokens from the runtime).
public enum ToolFamily: String, Sendable, Codable, CaseIterable {
    /// Qwen 2.5/3, Hermes, SmolLM3, Phi-4-mini: `<tool_call>{"name":…,"arguments":{…}}</tool_call>`
    case hermes
    /// Llama 3.1/3.2: `<|python_tag|>{…}` or a bare `{"name":…,"parameters":{…}}` message
    case llama3
    /// Gemma, SmolLM2 & co: fenced ```json … ``` or a bare JSON object with name + arguments
    case generic
}

/// Pure text → tool calls. Returns the visible text with the call markup
/// removed plus every call found. Never throws: malformed JSON is simply
/// not a call (the model then sees its own text echoed back as an answer).
public struct ToolCallParser: Sendable {
    public var family: ToolFamily
    public init(family: ToolFamily) { self.family = family }

    public struct Result: Sendable, Equatable {
        public var text: String
        public var calls: [ToolCall]
        public var hasCalls: Bool { !calls.isEmpty }
    }

    public func parse(_ raw: String) -> Result {
        var text = raw
        var calls: [ToolCall] = []

        // 1. Explicit markup — accepted for every family (models drift between dialects).
        for pattern in Self.markupPatterns {
            let (rest, found) = Self.extract(pattern: pattern, from: text)
            text = rest; calls += found
        }
        // 2. Llama 3.x python tag: everything after the tag until end/next tag is JSON.
        if calls.isEmpty || family == .llama3 {
            let (rest, found) = Self.extractPythonTag(from: text)
            text = rest; calls += found
        }
        // 3. Fenced ```json {…} ``` blocks.
        if calls.isEmpty {
            let (rest, found) = Self.extract(pattern: #"```(?:json|tool_call|tool)?\s*(\{[\s\S]*?\})\s*```"#, from: text)
            text = rest; calls += found
        }
        // 4. The whole message (or its tail) is a bare JSON object with a name.
        if calls.isEmpty, let obj = Self.bareObject(in: text), let call = Self.call(from: obj.value) {
            calls.append(call)
            text.removeSubrange(obj.range)
        }
        // Thinking blocks are chatter, never a call target — strip closed ones from the visible text.
        text = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        return Result(text: text.trimmingCharacters(in: .whitespacesAndNewlines), calls: calls)
    }

    // MARK: - internals

    static let markupPatterns: [String] = [
        #"<tool_call>\s*([\s\S]*?)\s*</tool_call>"#,
        #"<\|tool_call\|>\s*([\s\S]*?)\s*(?:<\|/tool_call\|>|<\|tool_call_end\|>|$)"#,   // Gemma 3n / Granite style
        #"<function_call>\s*([\s\S]*?)\s*</function_call>"#,
    ]

    static func extract(pattern: String, from text: String) -> (String, [ToolCall]) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return (text, []) }
        let ns = text as NSString
        var calls: [ToolCall] = []
        var out = text
        // Walk matches back to front so removals keep earlier ranges valid.
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let body = ns.substring(with: m.range(at: 1))
            if let v = JSONValue.parse(body) ?? JSONValue.parse(repairTrailing(body)) ?? JSONValue.parse(closeBraces(body)), let call = call(from: v) {
                calls.insert(call, at: 0)
                out = (out as NSString).replacingCharacters(in: m.range, with: "")
            }
        }
        return (out, calls)
    }

    static func extractPythonTag(from text: String) -> (String, [ToolCall]) {
        let tag = "<|python_tag|>"
        guard text.contains(tag) else { return (text, []) }
        var calls: [ToolCall] = []
        var pieces = text.components(separatedBy: tag)
        let head = pieces.removeFirst()
        var leftovers = head
        for piece in pieces {
            // The payload runs to the end-of-message marker or end of text.
            var body = piece
            for stop in ["<|eom_id|>", "<|eot_id|>"] { body = body.components(separatedBy: stop).first ?? body }
            if let obj = bareObject(in: body), let call = call(from: obj.value) {
                calls.append(call)
                var rest = body; rest.removeSubrange(obj.range); leftovers += rest
            } else {
                leftovers += piece
            }
        }
        return (leftovers, calls)
    }

    /// Finds the first balanced `{…}` object in `text` that parses as JSON.
    static func bareObject(in text: String) -> (value: JSONValue, range: Range<String.Index>)? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": if depth == 0 { start = i }; depth += 1
                case "}":
                    depth -= 1
                    if depth == 0, let s = start {
                        let candidate = String(text[s...i])
                        if let v = JSONValue.parse(candidate), v.objectValue != nil { return (v, s..<text.index(after: i)) }
                        start = nil
                    }
                    if depth < 0 { depth = 0 }
                default: break
                }
            }
            i = text.index(after: i)
        }
        // Unbalanced (model got cut off) — try closing it.
        if let s = start, depth > 0 {
            let candidate = String(text[s...]) + String(repeating: "}", count: depth)
            if let v = JSONValue.parse(candidate), v.objectValue != nil { return (v, s..<text.endIndex) }
        }
        return nil
    }

    /// A call cut off by max_tokens: `{"name": "x", "arguments": {"k": "v"` → close what is open.
    static func closeBraces(_ s: String) -> String {
        var depth = 0, inString = false, escaped = false
        for ch in s {
            if inString { if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false } }
            else if ch == "\"" { inString = true } else if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
        }
        guard depth > 0 else { return s }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) + (inString ? "\"" : "") + String(repeating: "}", count: depth)
    }

    static func repairTrailing(_ s: String) -> String {
        s.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
    }

    /// `{"name": "...", "arguments"|"parameters": {...}}` (also tolerates
    /// OpenAI's nested `{"function": {...}}` and a JSON-string `arguments`).
    static func call(from value: JSONValue) -> ToolCall? {
        var obj = value.objectValue
        if let fn = obj?["function"]?.objectValue { obj = fn }
        guard let obj, let name = obj["name"]?.stringValue, !name.isEmpty else { return nil }
        var args = obj["arguments"] ?? obj["parameters"] ?? obj["args"] ?? .object([:])
        if let s = args.stringValue, let parsed = JSONValue.parse(s) { args = parsed }
        let id = obj["id"]?.stringValue ?? ToolCall.makeId()
        return ToolCall(id: id, name: name, arguments: args.objectValue ?? [:])
    }
}
