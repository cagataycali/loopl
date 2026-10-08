import Foundation

// `ask_user` — the agent asks the HUMAN mid-turn with a native form (port of tiny-tech
// src/agent/interact.ts `use_interact`). The model emits a small TYPED spec (`AskUserRequest`),
// the app draws it as a card in the transcript, and the answer comes back as the tool result.
//
// It is NOT a new mechanism: the tool raises an `Interrupt` named `ask_user` through
// `InterruptScope.interrupt`, exactly the way the HITL approval suspends a call — the agent emits
// `.interruptRaised`, parks the call on the gate, and runs the tool again with the answer once
// `agent.resolve(interrupt:response:)` arrives (or the timeout substitutes `.null`). One suspend path,
// one resume path, one place a human answer lands. The card is pure presentation.
//
// Privacy rule: a `password` field's value reaches the model only inside this tool's result (so it can
// be used); `AskUserAnswer.masked` is what the transcript, History and any export keep (`••••`).

/// What the model asks for. Flat, few required fields, enums — a 0.8B model must be able to emit it.
public struct AskUserRequest: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case confirm, select, multiselect, input, buttons, form, message
    }
    public struct Option: Sendable, Hashable, Codable, Identifiable {
        public var value: String
        public var label: String
        public var id: String { value }
        public init(value: String, label: String? = nil) { self.value = value; self.label = label ?? value }
    }
    public struct Field: Sendable, Hashable, Codable, Identifiable {
        public enum Kind: String, Sendable, Codable, CaseIterable { case text, password, number, toggle }
        public var name: String
        public var label: String
        public var type: Kind
        public var `default`: String?
        public var required: Bool
        public var id: String { name }
        public init(name: String, label: String? = nil, type: Kind = .text, default: String? = nil, required: Bool = false) {
            self.name = name; self.label = label ?? name; self.type = type; self.default = `default`; self.required = required
        }
    }

    public var type: Kind
    public var text: String
    public var title: String?
    public var options: [Option]
    public var `default`: String?
    public var fields: [Field]
    /// Seconds the agent waits before answering `{ok:false, timeout:true}` for the model. Clamped 5…3600.
    public var timeoutSeconds: Int

    public static let defaultTimeout = 180
    public static let timeoutRange = 5...3600

    public init(type: Kind, text: String, title: String? = nil, options: [Option] = [], default: String? = nil,
                fields: [Field] = [], timeoutSeconds: Int = AskUserRequest.defaultTimeout) {
        self.type = type; self.text = text; self.title = title; self.options = options; self.default = `default`
        self.fields = fields; self.timeoutSeconds = min(max(timeoutSeconds, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
    }

    /// The model's arguments → a request, or a `ToolError` that says exactly what to fix (the repair signal).
    /// Loose option shapes are accepted (`"a"`, `{value,label}`, `["a","A"]`), like interact.ts `normalizeOptions`.
    public init(args: [String: JSONValue]) throws {
        guard let raw = args["type"]?.stringValue?.lowercased(), let kind = Kind(rawValue: raw) else {
            throw ToolError("ask_user: type must be one of \(Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let text = args["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw ToolError("ask_user: text (the question) is required") }
        let options = Self.normalizeOptions(args["options"])
        let fields = try Self.normalizeFields(args["fields"])
        switch kind {
        case .select, .multiselect, .buttons:
            guard options.count >= 1 else { throw ToolError("ask_user: options required for \(kind.rawValue), e.g. [\"a\", \"b\"]") }
        case .form:
            guard !fields.isEmpty else { throw ToolError("ask_user: fields required for form, e.g. [{\"name\": \"email\", \"type\": \"text\"}]") }
        case .confirm, .input, .message: break
        }
        var timeout = Self.defaultTimeout
        if let t = args["timeout_s"]?.doubleValue ?? args["timeout_sec"]?.doubleValue, t.isFinite, t > 0 { timeout = Int(t) }
        let def: String? = switch args["default"] {
        case .string(let s)?: s
        case .bool(let b)?: b ? "true" : "false"
        case .number(let n)?: JSONValue.number(n).compact
        default: nil
        }
        self.init(type: kind, text: text, title: args["title"]?.stringValue, options: options, default: def,
                  fields: fields, timeoutSeconds: timeout)
    }

    static func normalizeOptions(_ raw: JSONValue?) -> [Option] {
        guard let items = raw?.arrayValue else {
            if let one = raw?.stringValue, !one.isEmpty { return [Option(value: one)] }      // a single string instead of an array
            return []
        }
        var seen = Set<String>()
        return items.compactMap { item -> Option? in
            let option: Option?
            switch item {
            case .string(let s): option = s.isEmpty ? nil : Option(value: s)
            case .number, .bool: option = Option(value: item.compact)
            case .array(let pair):
                guard let v = pair.first?.stringValue ?? pair.first.map(\.compact) else { return nil }
                option = Option(value: v, label: pair.dropFirst().first?.stringValue)
            case .object(let o):
                let v = o["value"]?.stringValue ?? o["value"].map(\.compact) ?? o["label"]?.stringValue ?? o["title"]?.stringValue
                guard let v, !v.isEmpty else { return nil }
                option = Option(value: v, label: o["label"]?.stringValue ?? o["title"]?.stringValue)
            case .null: option = nil
            }
            guard let option, seen.insert(option.value).inserted else { return nil }
            return option
        }
    }

    static func normalizeFields(_ raw: JSONValue?) throws -> [Field] {
        guard let items = raw?.arrayValue else { return [] }
        var seen = Set<String>()
        return try items.compactMap { item -> Field? in
            switch item {
            case .string(let name):
                guard !name.isEmpty, seen.insert(name).inserted else { return nil }
                return Field(name: name)
            case .object(let o):
                guard let name = o["name"]?.stringValue ?? o["label"]?.stringValue, !name.isEmpty else {
                    throw ToolError("ask_user: every form field needs a name, e.g. {\"name\": \"email\"}")
                }
                guard seen.insert(name).inserted else { return nil }
                let kind = o["type"]?.stringValue.flatMap { Field.Kind(rawValue: $0.lowercased()) }
                    ?? (name.lowercased().contains("password") ? .password : .text)
                let def: String? = switch o["default"] {
                case .string(let s)?: s
                case .bool(let b)?: b ? "true" : "false"
                case .number(let n)?: JSONValue.number(n).compact
                default: nil
                }
                return Field(name: name, label: o["label"]?.stringValue, type: kind, default: def,
                             required: o["required"]?.boolValue ?? false)
            default: return nil
            }
        }
    }

    /// Names of the password fields — the values the transcript must never show.
    public var secretFieldNames: Set<String> { Set(fields.filter { $0.type == .password }.map(\.name)) }

    // MARK: interrupt reason round-trip (like `ApprovalRequest.interruptReason`)

    public var interruptReason: JSONValue {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8),
              let value = JSONValue.parse(text) else {
            return .object(["type": .string(type.rawValue), "text": .string(text)])
        }
        return value
    }
    public init?(interruptReason: JSONValue) {
        guard let data = interruptReason.compact.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskUserRequest.self, from: data) else { return nil }
        self = decoded
    }
    /// The spec as the model sent it (what History saves as the tool's `args`).
    public var toolArgs: [String: JSONValue] {
        var o: [String: JSONValue] = ["type": .string(type.rawValue), "text": .string(text)]
        if let title { o["title"] = .string(title) }
        if !options.isEmpty { o["options"] = .array(options.map { $0.label == $0.value ? .string($0.value) : .object(["value": .string($0.value), "label": .string($0.label)]) }) }
        if let d = `default` { o["default"] = .string(d) }
        if !fields.isEmpty {
            o["fields"] = .array(fields.map { f in
                var fo: [String: JSONValue] = ["name": .string(f.name), "type": .string(f.type.rawValue)]
                if f.label != f.name { fo["label"] = .string(f.label) }
                if let d = f.default { fo["default"] = .string(d) }
                if f.required { fo["required"] = .bool(true) }
                return .object(fo)
            })
        }
        if timeoutSeconds != Self.defaultTimeout { o["timeout_s"] = .number(Double(timeoutSeconds)) }
        return o
    }
}

/// The human's answer (or the lack of one). `value` is the typed JSON the model reads.
public enum AskUserAnswer: Sendable, Hashable, Codable {
    case answered(JSONValue)
    case cancelled
    case timedOut

    public static let mask = "••••"

    /// The interrupt `response` the card sends (`agent.resolve(interrupt:response:)`).
    public var interruptResponse: JSONValue {
        switch self {
        case .answered(let v): .object(["value": v])
        case .cancelled: .object(["cancelled": .bool(true)])
        case .timedOut: .null                       // what the agent substitutes when nobody answers
        }
    }
    public init(interruptResponse r: JSONValue) {
        if r == .null { self = .timedOut; return }
        if r["timeout"]?.boolValue == true { self = .timedOut; return }
        if r["cancelled"]?.boolValue == true { self = .cancelled; return }
        self = .answered(r["value"] ?? r)
    }

    /// The tool result the model reads.
    public var toolResult: JSONValue {
        switch self {
        case .answered(let v): .object(["ok": .bool(true), "value": v])
        case .cancelled: .object(["ok": .bool(false), "cancelled": .bool(true)])
        case .timedOut: .object(["ok": .bool(false), "timeout": .bool(true)])
        }
    }
    /// Parse a saved/returned tool result back (History reopening an answered card).
    public init?(toolResult text: String) {
        guard let v = JSONValue.parse(text), let ok = v["ok"]?.boolValue else { return nil }
        if ok { self = .answered(v["value"] ?? .null); return }
        if v["timeout"]?.boolValue == true { self = .timedOut } else { self = .cancelled }
    }

    /// Same answer with every password field's value replaced by `mask` — the only form the UI, History and exports keep.
    public func masked(for request: AskUserRequest) -> AskUserAnswer {
        let secrets = request.secretFieldNames
        guard case .answered(let v) = self, case .object(var o) = v, !secrets.isEmpty else { return self }
        for k in secrets where o[k] != nil { if o[k]?.stringValue?.isEmpty == false { o[k] = .string(Self.mask) } }
        return .answered(.object(o))
    }

    /// One quiet line for a settled card: "Yes", "Margherita", "3 picked", "Sent", "Cancelled", "No answer in time".
    public func summary(for request: AskUserRequest) -> String {
        switch self {
        case .cancelled: return "Cancelled"
        case .timedOut: return "No answer in time"
        case .answered(let v):
            switch request.type {
            case .confirm: return v.boolValue == true ? "Yes" : "No"
            case .message: return "Seen"
            case .select, .buttons:
                let raw = v.stringValue ?? v.compact
                return request.options.first { $0.value == raw }?.label ?? raw
            case .multiselect:
                let picked = v.arrayValue?.compactMap { item in item.stringValue.map { raw in request.options.first { $0.value == raw }?.label ?? raw } } ?? []
                return picked.isEmpty ? "None picked" : picked.joined(separator: ", ")
            case .input: return v.stringValue.map { $0.isEmpty ? "Sent (empty)" : $0 } ?? v.compact
            case .form: return "Submitted"
            }
        }
    }
}

/// The tool. Default ON. Raises the interrupt; the host's card answers it.
public struct AskUserTool: Tool {
    public init() {}
    public static let toolName = "ask_user"
    public static let interruptName = "ask_user"
    public let name = AskUserTool.toolName
    public let description = "Ask the user a question with a native form and wait for the answer. Use it ONLY when you cannot proceed without a decision, a missing detail, a credential or a preference — never for something the user already said and never for ordinary questions you can answer. type: confirm (yes/no → true/false) | select (pick ONE of options) | multiselect (pick MANY of options → array) | input (free text, optional default) | buttons (short choice row, options) | form (several fields at once: fields=[{name,label,type: text|password|number|toggle,default,required}] → {name: value}) | message (show information, user taps Continue). Ask ONE question that gathers everything you need (prefer form or select over several inputs), then continue with the value. Result JSON: {\"ok\":true,\"value\":…} or {\"ok\":false,\"cancelled\":true} / {\"ok\":false,\"timeout\":true} — when ok is false, stop and say so; do not ask again. Never repeat a password value in your reply."
    public let parameters: JSONValue = ["type": "object", "properties": [
        "type": ["type": "string", "enum": .array(AskUserRequest.Kind.allCases.map { .string($0.rawValue) }),
                 "description": "confirm | select | multiselect | input | buttons | form | message"],
        "text": ["type": "string", "description": "the question or message, one or two sentences"],
        "title": ["type": "string", "description": "short heading above the question (optional)"],
        "options": ["type": "array", "items": ["type": "string"], "description": "select / multiselect / buttons: 2-8 choices (strings; {value,label} objects also accepted)"],
        "default": ["type": "string", "description": "input: prefilled text; select/buttons: the preselected option"],
        "fields": ["type": "array", "items": ["type": "object", "properties": [
            "name": ["type": "string"], "label": ["type": "string"],
            "type": ["type": "string", "enum": ["text", "password", "number", "toggle"]],
            "default": ["type": "string"], "required": ["type": "boolean"]], "required": ["name"]],
                   "description": "form: 1-8 fields; the answer is {name: value} (toggle → true/false, number → number)"],
        "timeout_s": ["type": "integer", "description": "seconds to wait for the answer (default 180, 5-3600)"]],
        "required": ["type", "text"]]
    /// The tool decodes its own input and its errors say what to fix; the schema pre-check would reject the loose
    /// option/field shapes we deliberately accept.
    public var validatesOwnInput: Bool { true }

    /// `"tool:<toolUseId>:ask_user"` — the interrupt id the card answers through `agent.resolve(interrupt:)`.
    public static func interruptId(toolUseId: String) -> String { "tool:\(toolUseId):\(interruptName)" }
    /// `"tool:<toolUseId>:ask_user"` → `<toolUseId>`; nil for any other interrupt.
    public static func toolUseId(fromInterruptId id: String) -> String? {
        let parts = id.split(separator: ":")
        guard parts.count >= 3, parts.first == "tool", parts.last == Substring(interruptName) else { return nil }
        return parts.dropFirst().dropLast().joined(separator: ":")
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let request = try AskUserRequest(args: args)
        guard InterruptScope.isAvailable else {
            throw ToolError("ask_user: no one to ask here — this tool only works inside an agent run with a UI")
        }
        // First pass raises (throws InterruptException → the agent shows the card and parks this call);
        // the second pass, after the human answered, returns the response.
        let response = try InterruptScope.interrupt(Self.interruptName, reason: request.interruptReason,
                                                    timeout: TimeInterval(request.timeoutSeconds))
        return AskUserAnswer(interruptResponse: response).toolResult.compact
    }
}
