import Foundation

/// A tool the agent may call (`AgentTool`). `parameters` is a JSON Schema object.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    func call(_ args: [String: JSONValue]) async throws -> String
    /// Human-in-the-loop: return a request when this input should be shown to a
    /// person before running (default `nil` — see `Approval.swift`).
    func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest?
    /// `true` when the tool decodes and complains about its own input (e.g.
    /// `StructuredOutputTool`, whose error result IS the repair signal). The
    /// agent's schema pre-check (`ToolValidation`) then leaves the input alone.
    /// Default `false`.
    var validatesOwnInput: Bool { get }
    /// A runtime this tool merely wraps. When the agent's model *is* that runtime
    /// the tool is not offered (and not run): asking Apple Intelligence to call an
    /// `apple_intelligence` tool makes a 3B model summarise "hey" in a loop.
    /// Default `nil` — offered to every model.
    var redundantWithRuntime: RuntimeKind? { get }
    /// Image-producing tools implement this (and make `call(_:)` return the prose only). Default wraps `call(_:)`.
    func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput
    /// Image-consuming tools implement this. `images` are the pictures attached to the latest user message (most recent
    /// last); the default ignores them and calls `callOutput`. These two are protocol REQUIREMENTS, not extension-only
    /// methods: the agent holds `any Tool`, and an extension method on an existential binds statically to the default —
    /// `describe_image` never saw a picture and `generate_image` never returned one until ToolsE2ETests caught it (2026-10-06).
    func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput
}

extension Tool {
    public var redundantWithRuntime: RuntimeKind? { nil }
    /// Whether this tool is offered to a model of `kind` (see `redundantWithRuntime`).
    public func isOffered(to kind: RuntimeKind) -> Bool { redundantWithRuntime != kind }
}

/// Throw from a tool to hand the model a message it can act on — the call becomes an `ERROR:` result.
public struct ToolError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// `ToolSpec`: what the model is told about a tool.
public struct ToolSpec: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
    /// OpenAI-style function spec — the shape HF chat templates understand.
    public var openAIFunction: JSONValue {
        .object(["type": "function",
                 "function": .object(["name": .string(name), "description": .string(description), "parameters": inputSchema])])
    }
}

extension Tool {
    public var validatesOwnInput: Bool { false }
    public var toolSpec: ToolSpec { ToolSpec(name: name, description: description, inputSchema: parameters) }
    /// OpenAI-style function spec (0.1 name, kept).
    public var spec: JSONValue { toolSpec.openAIFunction }
}

extension Array where Element == ToolSpec {
    /// `[[String: Any]]` for `applyChatTemplate(messages:tools:)`.
    public var templateDictionaries: [[String: any Sendable]] {
        map { ($0.openAIFunction.anyValue as? [String: any Sendable]) ?? [:] }
    }
}

/// Tool specs as `[[String: Any]]` for `applyChatTemplate(messages:tools:)` (0.1 helper).
public func toolSpecs(_ tools: [any Tool]) -> [[String: any Sendable]] {
    tools.map(\.toolSpec).templateDictionaries
}

/// Build a JSON-schema `parameters` object with less typing:
/// `ToolSchema.object(["expression": .string("e.g. 23*47")], required: ["expression"])`.
public enum ToolSchema {
    public static func object(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": "object", "properties": .object(props), "required": .array(required.map(JSONValue.string))])
    }
    public static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    public static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    public static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
}

/// A tool from a closure — for showcases and tests.
public struct ClosureTool: Tool {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    let body: @Sendable ([String: JSONValue]) async throws -> String
    public init(name: String, description: String, parameters: JSONValue = ToolSchema.object([:]),
                _ body: @Sendable @escaping ([String: JSONValue]) async throws -> String) {
        self.name = name; self.description = description; self.parameters = parameters; self.body = body
    }
    public func call(_ args: [String: JSONValue]) async throws -> String { try await body(args) }
}

// MARK: - Tools that produce or consume pictures (Phase 4, APPLE-TOOLS)

/// What a tool hands back: the text the model reads, plus pictures the
/// transcript renders (`ToolResult.images`). `call(_:)` returning a String is
/// `ToolOutput(text:)` — the image-aware entry points below default to it.
public struct ToolOutput: Sendable, Hashable {
    public var text: String
    public var images: [ImageBlock]
    /// Phase 7 (CONTROLS): an optional live control the result card draws — "Turn off" under a flashlight result,
    /// a mini player under `music`, a map pin under `location`. Not part of what the model reads.
    public var control: ToolControl?
    public init(text: String, images: [ImageBlock] = [], control: ToolControl? = nil) { self.text = text; self.images = images; self.control = control }
}

// MARK: - Control affordances on tool results (Phase 7, CONTROLS)

/// What a control tap runs: the SAME tool, with these arguments, through the agent's normal tool path
/// (hooks + approval policy apply, the registry may mount it, the result replaces the card's). Never a hidden call.
public struct ControlAction: Sendable, Hashable, Codable {
    public var tool: String
    public var args: [String: JSONValue]
    public init(tool: String, args: [String: JSONValue] = [:]) { self.tool = tool; self.args = args }
}

/// A typed, tiny UI affordance a tool may attach to its result (`ToolOutput.control` → `ToolResult.control`).
/// The card renders it live; the model never sees it (so no token cost and a 0.8B model cannot mis-emit it — the
/// TOOL decides what control fits its own result). Persisted with the result, re-rendered from History.
public enum ToolControl: Sendable, Hashable {
    /// One switch — `on` is the state the result reports; the tap runs `action` (flashlight on → "Turn off").
    case toggle(label: String, on: Bool, action: ControlAction)
    /// One plain button that re-runs something (vibrate → "Vibrate again").
    case button(label: String, action: ControlAction)
    /// A mini player: title line + pause/play, previous, next, volume — every button is a `ControlAction` on `tool` (music).
    case player(Player)
    /// A pin on a small map (location); the whole card opens Maps.
    case mapPin(lat: Double, lon: Double, label: String?)
    /// Counts down to `until` (timers, "stops by itself at…").
    case timer(until: Date, label: String?)
    /// Opens a URL scheme / https link ("Open in Calendar", "Open in Reminders").
    case link(label: String, url: String)

    public struct Player: Sendable, Hashable, Codable {
        public var title: String
        public var subtitle: String?
        public var playing: Bool
        /// 0–100 when the tool knows it, else nil (slider hidden).
        public var volume: Int?
        /// The tool every button calls (`music`); the card sends `{action: pause|play|next|previous}` and
        /// `{action: volume, level: N}` — the music tool's own schema, nothing invented.
        public var tool: String
        public init(title: String, subtitle: String? = nil, playing: Bool, volume: Int? = nil, tool: String = "music") {
            self.title = title; self.subtitle = subtitle; self.playing = playing; self.volume = volume; self.tool = tool
        }
    }

    /// The `type` discriminator in JSON (History files, fixtures, the dataset's control-tap family).
    public var typeName: String {
        switch self {
        case .toggle: "toggle"; case .button: "button"; case .player: "player"
        case .mapPin: "mapPin"; case .timer: "timer"; case .link: "link"
        }
    }
    /// Short spoken form for accessibility and tests ("Turn off", "player: Song — playing").
    public var accessibilitySummary: String {
        switch self {
        case .toggle(let label, let on, _): "\(label), currently \(on ? "on" : "off")"
        case .button(let label, _): label
        case .player(let p): "player: \(p.title), \(p.playing ? "playing" : "paused")"
        case .mapPin(_, _, let label): "map pin\(label.map { ": \($0)" } ?? "")"
        case .timer(_, let label): "timer\(label.map { ": \($0)" } ?? "")"
        case .link(let label, _): label
        }
    }
}

extension ToolControl: Codable {
    private enum K: String, CodingKey { case type, label, on, action, player, lat, lon, until, url }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "toggle":
            self = .toggle(label: try c.decode(String.self, forKey: .label), on: try c.decode(Bool.self, forKey: .on),
                           action: try c.decode(ControlAction.self, forKey: .action))
        case "button":
            self = .button(label: try c.decode(String.self, forKey: .label), action: try c.decode(ControlAction.self, forKey: .action))
        case "player":
            self = .player(try c.decode(Player.self, forKey: .player))
        case "mapPin":
            self = .mapPin(lat: try c.decode(Double.self, forKey: .lat), lon: try c.decode(Double.self, forKey: .lon),
                           label: try c.decodeIfPresent(String.self, forKey: .label))
        case "timer":
            self = .timer(until: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .until)),
                          label: try c.decodeIfPresent(String.self, forKey: .label))
        case "link":
            self = .link(label: try c.decode(String.self, forKey: .label), url: try c.decode(String.self, forKey: .url))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown control type \(type)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .toggle(let label, let on, let action):
            try c.encode(label, forKey: .label); try c.encode(on, forKey: .on); try c.encode(action, forKey: .action)
        case .button(let label, let action):
            try c.encode(label, forKey: .label); try c.encode(action, forKey: .action)
        case .player(let p): try c.encode(p, forKey: .player)
        case .mapPin(let lat, let lon, let label):
            try c.encode(lat, forKey: .lat); try c.encode(lon, forKey: .lon); try c.encodeIfPresent(label, forKey: .label)
        case .timer(let until, let label):
            try c.encode(until.timeIntervalSince1970, forKey: .until); try c.encodeIfPresent(label, forKey: .label)
        case .link(let label, let url):
            try c.encode(label, forKey: .label); try c.encode(url, forKey: .url)
        }
    }
}

extension Tool {
    /// Image-producing tools override this (and make `call(_:)` return the prose only).
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        ToolOutput(text: try await call(args))
    }
    /// Image-consuming tools override this. `images` are the pictures attached to
    /// the latest user message (most recent last); the default ignores them.
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput {
        try await callOutput(args)
    }
}
