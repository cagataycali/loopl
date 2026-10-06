import Foundation

// Strands `types/content.py` + `types/tools.py` (ToolUse / ToolResult), in Swift.
// A conversation is `[Message]`; a message is a role plus content blocks; the
// system prompt is NOT a message (it travels beside the array, as in Strands).

/// Strands `Role` — only user/assistant appear in the message array.
public enum Role: String, Sendable, Codable, Hashable {
    case user, assistant
}

/// Strands `ToolUse`: the model asked for a tool, with JSON input.
public struct ToolUse: Sendable, Hashable, Codable, Identifiable {
    public var toolUseId: String
    public var name: String
    public var input: [String: JSONValue]

    public init(toolUseId: String = ToolUse.makeId(), name: String, input: [String: JSONValue]) {
        self.toolUseId = toolUseId; self.name = name; self.input = input
    }
    public static func makeId() -> String { "tooluse_" + UUID().uuidString.prefix(8).lowercased() }

    public var id: String { toolUseId }
    /// Compatibility spelling from the 0.1 SDK (`ToolCall.arguments`).
    public var arguments: [String: JSONValue] { input }
}

/// 0.1 name. `ToolUse` is the Strands name; this alias goes away in the next commit.
@available(*, deprecated, renamed: "ToolUse")
public typealias ToolCall = ToolUse

/// Strands `ToolResult`: what a tool produced for one `ToolUse`.
public struct ToolResult: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable, Hashable { case success, error }
    public var toolUseId: String
    public var name: String
    public var status: Status
    /// Text content. loopl tools return a single string (JSON or prose).
    public var content: String
    /// Wall time of the tool call, for the UI; not part of what the model sees.
    public var durationMs: Double
    /// Pictures the tool PRODUCED (e.g. `generate_image`). The transcript renders
    /// them; they are not fed back to the model (token budget stays predictable).
    public var images: [ImageBlock]

    public init(toolUseId: String, name: String, status: Status = .success, content: String, durationMs: Double = 0, images: [ImageBlock] = []) {
        self.toolUseId = toolUseId; self.name = name; self.status = status; self.content = content; self.durationMs = durationMs; self.images = images
    }
    enum CodingKeys: String, CodingKey { case toolUseId, name, status, content, durationMs, images }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolUseId = try c.decode(String.self, forKey: .toolUseId)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .success
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs) ?? 0
        images = try c.decodeIfPresent([ImageBlock].self, forKey: .images) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolUseId, forKey: .toolUseId); try c.encode(name, forKey: .name); try c.encode(status, forKey: .status)
        try c.encode(content, forKey: .content); try c.encode(durationMs, forKey: .durationMs)
        if !images.isEmpty { try c.encode(images, forKey: .images) }
    }
    public var id: String { toolUseId }
    public var isError: Bool { status == .error }
    /// 0.1 spelling.
    public var callId: String { toolUseId }

    public static func error(_ toolUse: ToolUse, _ message: String, durationMs: Double = 0) -> ToolResult {
        ToolResult(toolUseId: toolUse.toolUseId, name: toolUse.name, status: .error, content: message, durationMs: durationMs)
    }

    // MARK: what the model reads

    /// The marker every rendered error result starts with. No chat template renders
    /// `status` (Qwen3/Qwen3.5/Gemma/Llama templates print the tool message's `content`
    /// only, and so do loopl's `<tool_response>` fold and the Apple FM transcript) — so
    /// the word has to be *in* the text the model sees, or a small model cannot tell a
    /// failed call from a result and asks for the same thing again.
    public static let errorPrefix = "ERROR: "
    /// The one-line instruction appended to argument/validation errors.
    public static let retryHint = "Fix the arguments and call the tool again, or answer the user without it."

    /// The text handed to the model for this result — identical to `content` for a
    /// success; for an error it begins with `ERROR: ` exactly once (a leading
    /// "Error:"/"error:" is normalised, nothing else is touched). Every runtime's
    /// prompt path renders tool results through this, never through `content` directly.
    public var promptContent: String {
        guard status == .error else { return content }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let body: String
        if lower.hasPrefix("error:") {
            body = String(trimmed.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
        } else {
            body = trimmed
        }
        return Self.errorPrefix + (body.isEmpty ? "the tool failed without a message" : body)
    }
}

/// Strands `ContentBlock.image` (`{"image": {"format", "source": {"bytes"}}}`): an
/// encoded picture — a user attachment, or something a tool produced.
public struct ImageBlock: Sendable, Hashable, Codable {
    /// Encoded bytes (PNG / JPEG / HEIC / WebP / GIF). Never raw pixels.
    public var data: Data
    /// `image/png`, `image/jpeg`, `image/heic`, `image/webp`, `image/gif`.
    public var mime: String
    /// Pixel size when known (thumbnails, fit badge). `nil` = unknown.
    public var width: Int?
    public var height: Int?
    /// Caption / accessibility label. Tool-produced images should set it.
    public var alt: String?

    public init(data: Data, mime: String, width: Int? = nil, height: Int? = nil, alt: String? = nil) {
        self.data = data; self.mime = mime; self.width = width; self.height = height; self.alt = alt
    }
    /// Sniffs the mime from magic bytes; falls back to `image/png`.
    public init(data: Data, width: Int? = nil, height: Int? = nil, alt: String? = nil) {
        self.init(data: data, mime: ImageBlock.detectMime(data) ?? "image/png", width: width, height: height, alt: alt)
    }

    /// Strands `ImageFormat` (`png`, `jpeg`, `gif`, `webp`) — derived from `mime`.
    public var format: String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": "jpeg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/heic", "image/heif": "heic"
        default: "png"
        }
    }
    public var byteCount: Int { data.count }
    public var pixelCount: Int? { if let width, let height { width * height } else { nil } }

    /// Magic-byte sniffing. PNG, JPEG, GIF, WebP (RIFF…WEBP), HEIC/HEIF (ftyp box).
    public static func detectMime(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "image/gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {   // "ftyp"
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if brand.hasPrefix("hei") || brand.hasPrefix("mif") || brand.hasPrefix("msf") { return "image/heic" }
        }
        return nil
    }
}

/// Strands `ContentBlock` — the union of things a message can carry.
public enum ContentBlock: Sendable, Hashable, Codable {
    case text(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    /// Model "thinking" (Qwen3 `<think>`, reasoning deltas). Kept in history so templates can replay it; UIs may hide it.
    case reasoning(String)
    /// A picture (user attachment or tool output). Text models ignore it; vision runtimes feed it to the model.
    case image(ImageBlock)

    /// `.image(data, mime: "image/png")` — the shape the Phase 4 brief names.
    public static func image(_ data: Data, mime: String) -> ContentBlock { .image(ImageBlock(data: data, mime: mime)) }
    public var image: ImageBlock? { if case .image(let i) = self { return i }; return nil }
    public var isImage: Bool { image != nil }

    public var text: String? { if case .text(let s) = self { return s }; return nil }
    public var toolUse: ToolUse? { if case .toolUse(let t) = self { return t }; return nil }
    public var toolResult: ToolResult? { if case .toolResult(let r) = self { return r }; return nil }
    public var isToolUse: Bool { toolUse != nil }
    public var isToolResult: Bool { toolResult != nil }
}

/// Strands `Message`: `{role, content: [ContentBlock]}`.
public struct Message: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var role: Role
    public var content: [ContentBlock]

    public init(id: UUID = UUID(), role: Role, content: [ContentBlock]) {
        self.id = id; self.role = role; self.content = content
    }

    // Convenience constructors (the 0.1 enum cases, as functions).
    public static func user(_ text: String) -> Message { Message(role: .user, content: [.text(text)]) }
    /// A user turn with pictures: the text block first (if any), then one `.image` block per picture.
    public static func user(_ text: String, images: [ImageBlock]) -> Message {
        var blocks: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        blocks += images.map(ContentBlock.image)
        return Message(role: .user, content: blocks)
    }
    public static func assistant(_ text: String) -> Message { Message(role: .assistant, content: [.text(text)]) }
    public static func assistant(text: String, toolUses: [ToolUse]) -> Message {
        var blocks: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        blocks += toolUses.map(ContentBlock.toolUse)
        return Message(role: .assistant, content: blocks)
    }
    /// The user turn that carries tool results back to the model (Strands: `{"role": "user", "content": [{"toolResult": …}]}`).
    public static func toolResults(_ results: [ToolResult]) -> Message {
        Message(role: .user, content: results.map(ContentBlock.toolResult))
    }

    /// All text blocks joined (Strands `AgentResult.__str__` semantics).
    public var text: String { content.compactMap(\.text).joined(separator: "\n") }
    public var reasoning: String { content.compactMap { if case .reasoning(let r) = $0 { return r }; return nil }.joined() }
    public var toolUses: [ToolUse] { content.compactMap(\.toolUse) }
    public var toolResults: [ToolResult] { content.compactMap(\.toolResult) }
    public var hasToolUse: Bool { content.contains { $0.isToolUse } }
    public var hasToolResult: Bool { content.contains { $0.isToolResult } }
    /// Pictures carried by this message (user attachments). Tool-produced images live in `ToolResult.images`.
    public var images: [ImageBlock] { content.compactMap(\.image) }
    public var hasImage: Bool { content.contains { $0.isImage } }
    /// 0.1 spelling.
    public var toolCalls: [ToolUse] { toolUses }

    /// Encoding is role + content only (ids are local). Decoding mints a fresh id.
    enum CodingKeys: String, CodingKey { case role, content }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode([ContentBlock].self, forKey: .content)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role); try c.encode(content, forKey: .content)
    }
    public static func == (a: Message, b: Message) -> Bool { a.role == b.role && a.content == b.content }
    public func hash(into h: inout Hasher) { h.combine(role); h.combine(content) }
}

// MARK: - Chat-template rendering (provider side)

extension Message {
    /// OpenAI/HF chat-template shaped dictionaries for one message. A user
    /// message carrying tool results becomes one `tool` message per result —
    /// that is what HF templates (Qwen, Llama 3, SmolLM3) expect.
    public var templateDictionaries: [[String: any Sendable]] {
        switch role {
        case .user:
            if hasToolResult {
                return toolResults.map { r in ["role": "tool", "content": r.promptContent, "tool_call_id": r.toolUseId, "name": r.name] }
            }
            return [["role": "user", "content": text]]
        case .assistant:
            var d: [String: any Sendable] = ["role": "assistant", "content": text]
            let uses = toolUses
            if !uses.isEmpty {
                d["tool_calls"] = uses.map { u -> [String: any Sendable] in
                    ["id": u.toolUseId, "type": "function",
                     "function": ["name": u.name, "arguments": JSONValue.object(u.input).anyValue] as [String: any Sendable]]
                }
            }
            let r = reasoning
            if !r.isEmpty { d["reasoning_content"] = r }
            return [d]
        }
    }

    /// The full template input: system prompt first (if any), then every message.
    public static func templateDictionaries(systemPrompt: String?, messages: [Message]) -> [[String: any Sendable]] {
        var out: [[String: any Sendable]] = []
        if let s = systemPrompt, !s.isEmpty { out.append(["role": "system", "content": s]) }
        for m in messages { out += m.templateDictionaries }
        return out
    }
}
