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

    /// The visible text with calls removed, and the calls found in it.
    public struct Result: Sendable, Equatable {
        public var text: String
        public var calls: [ToolUse]
        public var hasCalls: Bool { !calls.isEmpty }
    }

    public func parse(_ raw: String) -> Result {
        var text = raw
        var calls: [ToolUse] = []

        // 1. Explicit markup — accepted for every family (models drift between dialects).
        for pattern in Self.markupPatterns {
            let (rest, found) = Self.extract(pattern: pattern, from: text)
            text = rest; calls += found
        }
        // 1b. Qwen3.5 / Qwen3-Coder XML dialect: `<function=name><parameter=k>v</parameter></function>`,
        // with or without the `<tool_call>` wrapper (the wrapper alone, with a non-JSON body, is left by step 1).
        let (restXML, foundXML) = Self.extractXMLFunctions(from: text)
        text = restXML; calls += foundXML
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

    static func extract(pattern: String, from text: String) -> (String, [ToolUse]) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return (text, []) }
        let ns = text as NSString
        var calls: [ToolUse] = []
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

    static func extractPythonTag(from text: String) -> (String, [ToolUse]) {
        let tag = "<|python_tag|>"
        guard text.contains(tag) else { return (text, []) }
        var calls: [ToolUse] = []
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
    static func call(from value: JSONValue) -> ToolUse? {
        var obj = value.objectValue
        if let fn = obj?["function"]?.objectValue { obj = fn }
        guard var obj else { return nil }
        // `{"http": {"url": …}}` — the call keyed by its tool name and nothing else.
        if obj.count == 1, let (key, nested) = obj.first, let inner = nested.objectValue,
           inner["name"] == nil, ToolValidation.nameProblem(key) == nil {
            obj = ["name": .string(key), "arguments": .object(inner)]
        }
        let nameKey = ["name", "tool", "tool_name", "function_name"].first { obj[$0]?.stringValue != nil }
        guard let nameKey, let name = obj[nameKey]?.stringValue, !name.isEmpty else { return nil }
        var args: JSONValue
        if let wrapped = obj["arguments"] ?? obj["parameters"] ?? obj["args"] ?? obj["input"] {
            args = wrapped
        } else {
            // FLAT call — `{"name": "http", "url": "https://…", "method": "GET"}`. Qwen3.5-0.8B wrote
            // every http call this way under the hermes prompt (5/5, 2026-10-06); the remaining
            // top-level keys ARE the arguments.
            var flat = obj
            for k in Self.envelopeKeys { flat.removeValue(forKey: k) }
            args = .object(flat)
        }
        if let s = args.stringValue { args = JSONValue.parse(s) ?? .object(["_": .string(s)]) }   // a bare string → `_` (ToolValidation lifts it into the lone required key)
        let id = obj["id"]?.stringValue ?? ToolUse.makeId()
        return ToolUse(toolUseId: id, name: name, input: args.objectValue ?? [:])
    }

    /// Keys that describe the call envelope, never an argument.
    static let envelopeKeys: Set<String> = ["name", "tool", "tool_name", "function_name", "function", "id", "type", "index", "call_id", "tool_call_id"]

    // MARK: - XML dialect (Qwen3.5, Qwen3-Coder)

    /// `<function=NAME> … </function>`, the format Qwen3.5's own chat template asks for. The
    /// 0.8B model also emits every sloppy variant seen below (captured 2026-10-06 against
    /// mlx-community/Qwen3.5-0.8B-4bit); all of them are read:
    ///   <parameter=url>\nhttps://…\n</parameter>   official
    ///   <url>\nhttps://…\n</parameter>             key as tag name, mismatched closer
    ///   <body>{"hello": 1}</body>                   key as tag name, matching closer
    ///   <url=https://…>  /  <method="PUT">          inline value
    ///   <method=HEAD>\nhttps://example.com\n</parameter>   inline value followed by a bare value → `_`
    /// Values that parse as JSON (objects, numbers, booleans) are kept typed — the template
    /// itself renders non-strings with `tojson`.
    static func extractXMLFunctions(from text: String) -> (String, [ToolUse]) {
        guard text.contains("<function=") else { return (text, []) }
        let pattern = #"(?:<tool_call>\s*)?<function=([^>\s]+)>([\s\S]*?)(?:</function>\s*(?:</tool_call>)?|</tool_call>|$)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let ns = text as NSString
        var calls: [ToolUse] = []
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard ToolValidation.nameProblem(name) == nil else { continue }
            let args = xmlParameters(ns.substring(with: m.range(at: 2)))
            calls.insert(ToolUse(toolUseId: ToolUse.makeId(), name: name, input: args), at: 0)
            out = (out as NSString).replacingCharacters(in: m.range, with: "")
        }
        return (out, calls)
    }

    static func xmlParameters(_ body: String) -> [String: JSONValue] {
        var args: [String: JSONValue] = [:]
        var loose: [String] = []
        // Tokenise into tags `<…>` and the text between them.
        let tagRe = try! NSRegularExpression(pattern: #"<([^<>]+)>"#)
        let ns = body as NSString
        var cursor = 0
        var pendingKey: String?
        func flushText(_ upTo: Int) {
            let raw = ns.substring(with: NSRange(location: cursor, length: upTo - cursor)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }
            if let key = pendingKey { args[key] = xmlValue(raw); pendingKey = nil } else { loose.append(raw) }
        }
        for m in tagRe.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            flushText(m.range.location)
            let tag = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            cursor = m.range.location + m.range.length
            if tag.hasPrefix("/") { pendingKey = nil; continue }                       // any closer
            var key = tag, inline: String?
            if let eq = tag.firstIndex(of: "=") {
                key = String(tag[..<eq]).trimmingCharacters(in: .whitespaces)
                inline = String(tag[tag.index(after: eq)...])
            }
            if key == "parameter" || key == "param" || key == "arg" {
                // `<parameter=url>` — the value is the text up to the next tag.
                guard let inline, !inline.isEmpty else { continue }
                pendingKey = inline.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")); continue
            }
            guard ToolValidation.nameProblem(key) == nil else { continue }               // not a parameter tag
            if let inline, !inline.isEmpty {
                args[key] = xmlValue(inline.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
                pendingKey = nil
            } else {
                pendingKey = key                                                        // `<url>` … value follows
            }
        }
        flushText(ns.length)
        if !loose.isEmpty, args["_"] == nil { args["_"] = .string(loose.joined(separator: "\n")) }
        return args
    }

    static func xmlValue(_ raw: String) -> JSONValue {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, "{[".contains(first) || first.isNumber || t == "true" || t == "false" || t == "null",
           let parsed = JSONValue.parse(t) {
            return parsed
        }
        return .string(t)
    }
}
