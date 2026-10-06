import Foundation
import os

private let log = Logger(subsystem: "technology.tiny.loopl", category: "ToolValidation")

// Strands `tools/_validator.py` (`validate_and_prepare_tools`) + `tools/tools.py`
// (`validate_tool_use_name`), plus what a 0.6B model on a phone actually breaks
// and a cloud API never sends.
//
// The contract is Strands': an invalid toolUse is NOT executed and NOT removed
// from the message — it gets an error `ToolResult` in its place, so the toolUse
// list and the toolResult list stay 1:1 and the next prompt still renders
// (hermes folding and every chat template depend on that pairing). The model
// reads the error and usually fixes its own call on the next cycle.

/// Strands `validate_and_prepare_tools`, Swift-shaped: pure, synchronous, testable.
public enum ToolValidation {

    /// What the agent needs after validation.
    public struct Outcome: Sendable, Hashable {
        /// Tool uses that may run (in message order).
        public var valid: [ToolUse]
        /// Error results for the ones that may not (Strands' `tool_results` + `invalid_tool_use_ids`).
        public var results: [ToolResult]
        public init(valid: [ToolUse], results: [ToolResult]) { self.valid = valid; self.results = results }
    }

    /// Strands tool-name rule: present, `^[a-zA-Z0-9_-]+$`, at most 64 characters.
    public static let maxNameLength = 64

    /// Strands `validate_tool_use_name`. Returns the complaint, or `nil` when the name is fine.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "tool name missing" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        if !name.allSatisfy(allowed.contains) { return "tool_name=<\(name)> | invalid tool name pattern" }
        if name.count > maxNameLength {
            return "tool_name=<\(name)>, tool_name_max_length=<\(maxNameLength)> | invalid tool name length"
        }
        return nil
    }

    /// Validate every tool use of one assistant message against the tools it may call.
    ///
    /// Unknown tool names are deliberately NOT rejected here: the agent's own
    /// "Unknown tool: … Available tools: …" result is the message small models
    /// recover from best, and it already carries the tool list.
    public static func validateAndPrepare(toolUses: [ToolUse], tools: [any Tool]) -> Outcome {
        var valid: [ToolUse] = []
        var results: [ToolResult] = []
        var seen: Set<String> = []
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        for use in toolUses {
            // 1. Strands: the name.
            if let problem = nameProblem(use.name) {
                log.debug("rejected tool call \(use.name, privacy: .public) \(JSONValue.object(use.input).compact, privacy: .public): \(problem, privacy: .public)")
                results.append(.error(use, "Error: \(problem)"))
                continue
            }
            // 2. loopl: a repeated toolUseId would corrupt the result list.
            if !seen.insert(use.toolUseId).inserted {
                results.append(.error(use, "Error: duplicate toolUseId \(use.toolUseId) in one message. Give every tool call its own id."))
                continue
            }
            // 3. loopl: the input against the tool's JSON schema (unknown tool → the agent explains).
            // Tools that validate their own input (StructuredOutputTool) keep their error message.
            guard let tool = byName[use.name], !tool.validatesOwnInput else { valid.append(use); continue }
            switch repair(input: use.input, schema: tool.parameters) {
            case .ok(let input):
                var fixed = use
                fixed.input = input
                valid.append(fixed)
            case .invalid(let complaint):
                log.debug("rejected tool call \(use.name, privacy: .public) \(JSONValue.object(use.input).compact, privacy: .public): \(complaint, privacy: .public)")
                results.append(.error(use, "Error: \(complaint)"))
            }
        }
        return Outcome(valid: valid, results: results)
    }

    // MARK: - schema repair

    enum Repair: Sendable {
        case ok([String: JSONValue])
        case invalid(String)
    }

    /// Validate `input` against a JSON-schema object, coercing what small models
    /// reliably get wrong (quoted numbers, a bare-string argument) and refusing
    /// the rest with a message that says what to send instead.
    ///
    /// Supported keywords: `type`, `properties`, `required`, `enum`. Anything else
    /// is ignored rather than guessed — there is no JSON-Schema engine on-device.
    static func repair(input: [String: JSONValue], schema: JSONValue) -> Repair {
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        var out = input

        // A bare string where an object was expected: `"arguments": "12*12"`.
        // `ToolCallParser` hands that over as `["_": .string(…)]` or as a lone unnamed value.
        if let lifted = liftBareString(out, properties: properties, required: required) { out = lifted }

        // Keys the model spelled differently: `URL` → `url`, `uri`/`link`/`endpoint` → `url`.
        out = renameAliases(out, properties: properties, required: required)

        // A loose value next to named ones (`<method=HEAD>` then a bare URL): it is the one required
        // parameter still missing, when exactly one is.
        if case .string(let loose)? = out["_"], properties["_"] == nil {
            let missing = required.filter { out[$0] == nil || out[$0] == .null }
            if missing.count == 1 { out[missing[0]] = .string(loose); out.removeValue(forKey: "_") }
        }

        // Coerce + type-check the properties the schema describes.
        for (key, value) in out {
            guard let spec = properties[key] else { continue }       // extra keys are passed through
            switch coerce(value, to: spec) {
            case .value(let fixed): out[key] = fixed
            case .problem(let complaint): return .invalid("parameter '\(key)': \(complaint)")
            }
        }

        // Required properties.
        let missing = required.filter { out[$0] == nil || out[$0] == .null }
        if !missing.isEmpty {
            // A concrete example, not a type placeholder: a 0.8B model copies `{"url": "https://example.com"}`
            // verbatim with the right value, but read `{"url": <string>}` as "call it with the string url".
            let shape = required.map { key -> String in
                "\"\(key)\": \(exampleValue(for: key, spec: properties[key]).compact)"
            }.joined(separator: ", ")
            return .invalid("missing required parameter\(missing.count > 1 ? "s" : "") \(missing.sorted().map { "'\($0)'" }.joined(separator: ", ")). Call it with arguments like {\(shape)}.")
        }
        return .ok(out)
    }

    /// Alternative spellings a model uses for a parameter. Applied only when the schema's own key
    /// is absent and the alias is not itself a declared property.
    static let aliases: [String: [String]] = [
        "url": ["uri", "link", "href", "endpoint", "address", "website", "site", "target"],
        "method": ["http_method", "verb", "type"],
        "body": ["data", "payload", "content", "json"],
        "headers": ["header"],
        "timeout": ["timeout_seconds", "timeout_s"],
        "expression": ["expr", "input", "query"],
        "timezone": ["tz", "time_zone", "zone"],
    ]

    static func renameAliases(_ input: [String: JSONValue], properties: [String: JSONValue], required: [String]) -> [String: JSONValue] {
        guard !properties.isEmpty else { return input }
        var out = input
        for (key, value) in input where properties[key] == nil {
            // Case-insensitive / snake-vs-camel spelling of a declared property.
            let folded = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            if let canonical = properties.keys.first(where: { $0.lowercased().replacingOccurrences(of: "_", with: "") == folded }), out[canonical] == nil {
                out[canonical] = value; out.removeValue(forKey: key); continue
            }
            // A known alias of a declared property.
            if let canonical = properties.keys.first(where: { aliases[$0]?.contains(key.lowercased()) ?? false }), out[canonical] == nil {
                out[canonical] = value; out.removeValue(forKey: key)
            }
        }
        return out
    }

    /// Example value for the "Call it with …" complaint: the schema's own `examples`/`example`
    /// first, then an `enum` member, then a key-aware guess (`url` → an https URL), then a type default.
    static func exampleValue(for key: String, spec: JSONValue?) -> JSONValue {
        if let ex = spec?["examples"]?.arrayValue?.first { return ex }
        if let ex = spec?["example"], ex != .null { return ex }
        if let first = spec?["enum"]?.arrayValue?.first { return first }
        let lower = key.lowercased()
        if lower.contains("url") || lower.contains("uri") || lower.contains("link") { return .string("https://example.com") }
        switch spec?["type"]?.stringValue ?? "string" {
        case "number", "integer": return .number(1)
        case "boolean": return .bool(true)
        case "array": return .array([])
        case "object": return .object([:])
        case "null": return .null
        default: return .string("…")
        }
    }

    /// `ToolCallParser` keys a non-object `arguments` under `_`; a model may also
    /// put the whole argument in the first property. When the schema wants exactly
    /// one required scalar, lift the bare string into it.
    private static func liftBareString(_ input: [String: JSONValue],
                                       properties: [String: JSONValue],
                                       required: [String]) -> [String: JSONValue]? {
        guard input.count == 1, let (key, value) = input.first,
              case .string(let text) = value,
              properties[key] == nil else { return nil }
        let target: String
        if required.count == 1 { target = required[0] }
        else if properties.count == 1, let only = properties.keys.first { target = only }
        else { return nil }
        return [target: .string(text)]
    }

    /// Either the (possibly coerced) value, or why it cannot be used.
    public enum Coerced: Sendable {
        case value(JSONValue)
        case problem(String)
    }

    /// Coerce one value to the type its schema asks for, or say why it cannot be used.
    /// Small models quote everything, so `"3"` for a number and `"yes"` for a boolean are
    /// accepted; anything genuinely wrong is refused with the expected and the actual type.
    public static func coerce(_ value: JSONValue, to spec: JSONValue) -> Coerced {
        if let allowed = spec["enum"]?.arrayValue, !allowed.isEmpty, !allowed.contains(value) {
            return .problem("expected one of \(allowed.map(\.compact).joined(separator: ", ")), got \(value.compact)")
        }
        guard let type = spec["type"]?.stringValue else { return .value(value) }
        switch type {
        case "string":
            if case .string = value { return .value(value) }
            if case .null = value { return .problem("expected string, got null") }
            // A model that answers a string question with a number means the digits.
            return .value(.string(value.compact.trimmingCharacters(in: CharacterSet(charactersIn: "\""))))
        case "number", "integer":
            if case .number(let n) = value {
                if type == "integer", n != n.rounded() { return .problem("expected integer, got \(n)") }
                return .value(value)
            }
            if case .string(let s) = value, let n = Double(s.trimmingCharacters(in: .whitespaces)) {
                if type == "integer", n != n.rounded() { return .problem("expected integer, got \(s)") }
                return .value(.number(n))
            }
            return .problem("expected \(type), got \(jsonTypeName(value)) \(value.compact)")
        case "boolean":
            if case .bool = value { return .value(value) }
            if case .string(let s) = value {
                switch s.lowercased() {
                case "true", "yes", "1": return .value(.bool(true))
                case "false", "no", "0": return .value(.bool(false))
                default: break
                }
            }
            if case .number(let n) = value, n == 0 || n == 1 { return .value(.bool(n == 1)) }
            return .problem("expected boolean, got \(jsonTypeName(value)) \(value.compact)")
        case "array":
            if case .array = value { return .value(value) }
            // A single item where a list was expected is the model's most common list mistake.
            if case .null = value { return .problem("expected array, got null") }
            return .value(.array([value]))
        case "object":
            if case .object = value { return .value(value) }
            if case .string(let s) = value, let parsed = JSONValue.parse(s), parsed.objectValue != nil {
                return .value(parsed)
            }
            return .problem("expected object, got \(jsonTypeName(value)) \(value.compact)")
        case "null":
            if case .null = value { return .value(value) }
            return .problem("expected null, got \(jsonTypeName(value))")
        default:
            return .value(value)
        }
    }

    static func jsonTypeName(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}
