import Foundation

// `types/content.py` + `types/tools.py` (ToolUse / ToolResult), in Swift.
// A conversation is `[Message]`; a message is a role plus content blocks; the
// system prompt is NOT a message (it travels beside the array).

/// `Role` — only user/assistant appear in the message array.
public enum Role: String, Sendable, Codable, Hashable {
    case user, assistant
}

/// `ToolUse`: the model asked for a tool, with JSON input.
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

/// 0.1 name. `ToolUse` is the name; this alias goes away in the next commit.
@available(*, deprecated, renamed: "ToolUse")
public typealias ToolCall = ToolUse

/// `ToolResult`: what a tool produced for one `ToolUse`.
public struct ToolResult: Sendable, Hashable, Codable, Identifiable {
    /// Whether the tool ran; `.error` results reach the model prefixed `ERROR: `.
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
    /// Phase 7: a live control the card draws (flashlight → "Turn off"). UI-only, like `images`: the model never reads it.
    public var control: ToolControl?

    public init(toolUseId: String, name: String, status: Status = .success, content: String, durationMs: Double = 0, images: [ImageBlock] = [], control: ToolControl? = nil) {
        self.toolUseId = toolUseId; self.name = name; self.status = status; self.content = content; self.durationMs = durationMs; self.images = images; self.control = control
    }
    enum CodingKeys: String, CodingKey { case toolUseId, name, status, content, durationMs, images, control }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolUseId = try c.decode(String.self, forKey: .toolUseId)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .success
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs) ?? 0
        images = try c.decodeIfPresent([ImageBlock].self, forKey: .images) ?? []
        control = try? c.decodeIfPresent(ToolControl.self, forKey: .control)   // an unknown future control type reads as none, never fails the thread
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolUseId, forKey: .toolUseId); try c.encode(name, forKey: .name); try c.encode(status, forKey: .status)
        try c.encode(content, forKey: .content); try c.encode(durationMs, forKey: .durationMs)
        if !images.isEmpty { try c.encode(images, forKey: .images) }
        if let control { try c.encode(control, forKey: .control) }
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

/// `ContentBlock.image` (`{"image": {"format", "source": {"bytes"}}}`): an
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

    /// `ImageFormat` (`png`, `jpeg`, `gif`, `webp`) — derived from `mime`.
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

/// How a video is turned into frames for a vision model. Qwen3-VL (mlx-swift-lm) reads a video as
/// evenly spaced frames; every PAIR of frames (temporal patch 2) costs `ceil(h/32)·ceil(w/32)` tokens
/// (16 px patches merged 2×2) after the frame is resized to fit `maxEdge`. The plan is decided where the budget is known (the app's
/// `MemoryBudget.frameBudget`) and travels with the block so a reload renders the same prompt.
public struct VideoFramePlan: Sendable, Hashable, Codable {
    /// Upper bound on sampled frames (evenly spaced over the whole clip). Even numbers waste nothing.
    public var maxFrames: Int
    /// Sampling density cap — `min(duration·fps, maxFrames)` frames are taken. ≤ 2 for Qwen3-VL.
    public var fps: Double
    /// Longest edge of a frame in pixels before it reaches the processor (448 px 16:9 ≈ 112 tokens per frame pair).
    public var maxEdge: Int

    public init(maxFrames: Int = 16, fps: Double = 1, maxEdge: Int = 448) {
        self.maxFrames = max(1, maxFrames); self.fps = max(0.1, min(2, fps)); self.maxEdge = max(56, maxEdge)
    }
    public static let `default` = VideoFramePlan()

    /// Frames this plan samples from a clip of `duration` seconds.
    public func frameCount(duration: TimeInterval) -> Int {
        max(1, min(maxFrames, Int((duration * fps).rounded())))
    }
    /// Pixels per vision token along one edge: Qwen3-VL patch 16 × spatial merge 2 (Qwen2.5-VL would be 28).
    public static let tokenPixels = 32
    /// Vision tokens the frames cost: one token per 32×32 block, two frames per temporal patch.
    public func estimatedTokens(duration: TimeInterval, width: Int?, height: Int?) -> Int {
        let frames = frameCount(duration: duration)
        let (w, h) = Self.fitted(width: width ?? maxEdge, height: height ?? maxEdge, maxEdge: maxEdge)
        let g = Double(Self.tokenPixels)
        // The processor snaps each edge to the NEAREST multiple of 32 (QwenVL.targetSize), not up — measured: a portrait
        // 206×448 frame costs 6×14 = 84 tokens per pair, not 7×14.
        let patches = max(1, Int((Double(w) / g).rounded())) * max(1, Int((Double(h) / g).rounded()))
        return ((frames + 1) / 2) * patches
    }
    /// The size a `w×h` frame has after the long edge is capped at `maxEdge` (never upscaled).
    public static func fitted(width: Int, height: Int, maxEdge: Int) -> (Int, Int) {
        let longest = max(width, height)
        guard longest > maxEdge, longest > 0 else { return (max(1, width), max(1, height)) }
        let k = Double(maxEdge) / Double(longest)
        return (max(1, Int((Double(width) * k).rounded())), max(1, Int((Double(height) * k).rounded())))
    }
    /// A plan that fits `tokenBudget` for this clip: shrinks the frame count first (fewer frames keep
    /// the picture readable), then the edge, never below 2 frames @ 224 px. `nil` when even that misses.
    public static func fitting(tokenBudget: Int, duration: TimeInterval, width: Int?, height: Int?, start: VideoFramePlan = .default) -> VideoFramePlan? {
        var plan = start
        while plan.estimatedTokens(duration: duration, width: width, height: height) > tokenBudget {
            if plan.maxFrames > 2 { plan.maxFrames = max(2, plan.maxFrames / 2); continue }
            if plan.maxEdge > 224 { plan.maxEdge = max(224, plan.maxEdge - 112); continue }
            return nil
        }
        return plan
    }
}

/// `ContentBlock.video`: a clip the user attached. The bytes stay in a FILE (the thread's attachments
/// folder — videos are too big for the JSON history and for a dataset row); the block carries what the
/// UI and the model need without opening it: duration, size, a poster thumbnail, the frame plan, and
/// the spoken words. Qwen3-VL has NO audio input — the audio track is transcribed on device and given
/// to the model as text next to the frames (`transcript`), which the UI shows as its own chip.
public struct VideoBlock: Sendable, Hashable, Codable {
    /// Absolute path of the clip (`<thread>.attachments/<id>.mov|mp4`).
    public var path: String
    /// `video/quicktime`, `video/mp4`.
    public var mime: String
    public var duration: TimeInterval
    /// Pixel size of the source when known.
    public var width: Int?
    public var height: Int?
    /// Poster frame (≤ 256 px JPEG) for chips and History. Not fed to the model.
    public var thumbnail: ImageBlock?
    public var framePlan: VideoFramePlan
    /// What was said in the clip (on-device transcribe), `nil` = no audio track / not transcribed.
    public var transcript: String?

    public init(path: String, mime: String = "video/quicktime", duration: TimeInterval, width: Int? = nil, height: Int? = nil,
                thumbnail: ImageBlock? = nil, framePlan: VideoFramePlan = .default, transcript: String? = nil) {
        self.path = path; self.mime = mime; self.duration = duration; self.width = width; self.height = height
        self.thumbnail = thumbnail; self.framePlan = framePlan; self.transcript = transcript
    }
    public var url: URL { URL(fileURLWithPath: path) }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
    public var fileName: String { url.lastPathComponent }
    /// Frames the plan takes from this clip.
    public var frameCount: Int { framePlan.frameCount(duration: duration) }
    /// Vision tokens the frames cost (estimate; the processor reports the real count).
    public var estimatedTokens: Int { framePlan.estimatedTokens(duration: duration, width: width, height: height) }

    /// `m:ss` for chips.
    public var clock: String { let s = Int(duration.rounded(.down)); return String(format: "%d:%02d", s / 60, s % 60) }

    /// The line a TEXT-ONLY model reads in place of the frames (honest: it cannot see them), and the
    /// transcript line every model gets. Vision runtimes add the frames themselves.
    public var textFallback: String {
        var lines = ["[video attached: \(fileName) (\(clock)) — the frames need a vision model; this model cannot see them]"]
        if let t = transcript, !t.isEmpty { lines.append("[audio transcript: \(t)]") }
        return lines.joined(separator: "\n")
    }
    /// What accompanies the frames for a vision model: the spoken words, if any.
    public var transcriptLine: String? {
        guard let t = transcript, !t.isEmpty else { return nil }
        return "[audio transcript: \(t)]"
    }
}

/// `ContentBlock` — the union of things a message can carry.
public enum ContentBlock: Sendable, Hashable, Codable {
    case text(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    /// Model "thinking" (Qwen3 `<think>`, reasoning deltas). Kept in history so templates can replay it; UIs may hide it.
    case reasoning(String)
    /// A picture (user attachment or tool output). Text models ignore it; vision runtimes feed it to the model.
    case image(ImageBlock)
    /// A video clip (user attachment). Vision runtimes sample frames from the file; text models read `textFallback`.
    case video(VideoBlock)

    /// `.image(data, mime: "image/png")` — the shape the Phase 4 brief names.
    public static func image(_ data: Data, mime: String) -> ContentBlock { .image(ImageBlock(data: data, mime: mime)) }
    public var image: ImageBlock? { if case .image(let i) = self { return i }; return nil }
    public var isImage: Bool { image != nil }
    public var video: VideoBlock? { if case .video(let v) = self { return v }; return nil }
    public var isVideo: Bool { video != nil }

    public var text: String? { if case .text(let s) = self { return s }; return nil }
    public var toolUse: ToolUse? { if case .toolUse(let t) = self { return t }; return nil }
    public var toolResult: ToolResult? { if case .toolResult(let r) = self { return r }; return nil }
    public var isToolUse: Bool { toolUse != nil }
    public var isToolResult: Bool { toolResult != nil }
}

/// `Message`: `{role, content: [ContentBlock]}`.
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
    /// A user turn with pictures and clips: text first, then `.image` blocks, then `.video` blocks.
    public static func user(_ text: String, images: [ImageBlock], videos: [VideoBlock]) -> Message {
        var blocks: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        blocks += images.map(ContentBlock.image)
        blocks += videos.map(ContentBlock.video)
        return Message(role: .user, content: blocks)
    }
    public static func assistant(_ text: String) -> Message { Message(role: .assistant, content: [.text(text)]) }
    public static func assistant(text: String, toolUses: [ToolUse]) -> Message {
        var blocks: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        blocks += toolUses.map(ContentBlock.toolUse)
        return Message(role: .assistant, content: blocks)
    }
    /// The user turn that carries tool results back to the model (`{"role": "user", "content": [{"toolResult": …}]}`).
    public static func toolResults(_ results: [ToolResult]) -> Message {
        Message(role: .user, content: results.map(ContentBlock.toolResult))
    }

    /// All text blocks joined (`AgentResult.__str__` semantics).
    public var text: String { content.compactMap(\.text).joined(separator: "\n") }
    public var reasoning: String { content.compactMap { if case .reasoning(let r) = $0 { return r }; return nil }.joined() }
    public var toolUses: [ToolUse] { content.compactMap(\.toolUse) }
    public var toolResults: [ToolResult] { content.compactMap(\.toolResult) }
    public var hasToolUse: Bool { content.contains { $0.isToolUse } }
    public var hasToolResult: Bool { content.contains { $0.isToolResult } }
    /// Pictures carried by this message (user attachments). Tool-produced images live in `ToolResult.images`.
    public var images: [ImageBlock] { content.compactMap(\.image) }
    public var hasImage: Bool { content.contains { $0.isImage } }
    /// Clips carried by this message (user attachments).
    public var videos: [VideoBlock] { content.compactMap(\.video) }
    public var hasVideo: Bool { content.contains { $0.isVideo } }
    /// Anything a vision runtime must feed to the model besides text.
    public var hasVisualMedia: Bool { hasImage || hasVideo }
    /// The text a TEXT path renders for this message: the typed text plus, per clip, the honest
    /// "needs a vision model" line and the transcript. Vision paths use `text` + frames + `transcriptLine`.
    public var textWithVideoFallback: String {
        let vids = videos
        guard !vids.isEmpty else { return text }
        return ([text] + vids.map(\.textFallback)).filter { !$0.isEmpty }.joined(separator: "\n")
    }
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
            return [["role": "user", "content": textWithVideoFallback]]
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
