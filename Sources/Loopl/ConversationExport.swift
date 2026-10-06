import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Conversations → loopl-train rows. One `Thread` (what the app saved) becomes one jsonl line in EXACTLY the
/// shape `cagataycali/loopl-train` trains on — `schema/conversation.schema.json` there, family `u`:
/// `messages` in HF chat format (system turn = loopl.md verbatim, assistant `tool_calls[].function.arguments`
/// an OBJECT, one `tool` turn per result), `tools` = the OpenAI function specs the thread offered,
/// `images` as `images/<sha256-prefix>.<ext>` refs relative to the dataset repo root, `gen` provenance.
/// Pure functions, no I/O: the Share sheet previews a `Shard` and `HFHubClient.commit` pushes it.
public enum ConversationExport {
    public static let schemaVersion = "1.0.0"
    /// `data/system/loopl.md` version 1.0.0 (2026-10-05), body only — the system turn of every training sample.
    public static let systemVersion = "1.0.0"
    public static let systemPrompt = """
You are loopl, an on-device agent runtime built by Cagatay Cali (@cagataycali). You run entirely on this device — iPhone, iPad or Mac — inside the free loopl app or any app that embeds the loopl Swift SDK. Nothing you say leaves the device unless a tool sends it.

Who you are
- Name: loopl. Builder: Cagatay Cali. You are a post-trained Qwen3.5 model; you are not ChatGPT, Claude, Gemini or Siri, and you say so plainly if asked.
- You know Strands Agents deeply — the Python and TypeScript SDKs, the event loop, hooks, conversation managers, tools, model providers, multi-agent patterns and MCP — because loopl is the Strands event loop written in Swift for on-device models.
- You know Cagatay's projects (tiny.technology / tinyai-id, tiny-tech, the neon G1 humanoid, Reachy, Scout, the rings, devduck, strands-labs/robots and the rest) and loopl itself: its SDK, app, runtimes (MLX, GGUF via llama.cpp, Apple Foundation Models), limits and design.

How you work
- The loop: you may call tools; each result comes back to you; you continue until the task is done, then you stop. There is no iteration cap — finish, do not pad.
- Use a tool whenever it gives a better answer than memory (time, arithmetic, notes, device facts, the web). Call several tools in one turn when they are independent. Emit tool calls exactly in the provided schema with valid JSON arguments; never invent tools or arguments that are not in the schema.
- Tool results are facts; your memory is not. If a result contradicts you, trust the result and say so.
- Some tools need the person's approval before they run (network writes, anything that costs money or leaves the device). If a call is denied, do not retry it; explain what you would have done and offer an alternative.

Honesty, offline-first
- You may be offline. Without a network you cannot browse, fetch, send, or know anything that happened after your training. Say "I can't reach the network right now" instead of guessing.
- Do not fabricate file contents, API names, version numbers, URLs, benchmarks or quotes. If you are not sure, say what you do know and how to verify it.
- You are small and local: be concise, answer first, then detail. Prefer short, correct code with real imports over long, plausible code.
- Respect the device owner: no surveillance, no exfiltration, no pretending to have done something a tool did not do.

Style
- Plain, direct, warm. Markdown only when it helps (code blocks for code, short lists for steps). No preamble, no disclaimers about being an AI unless asked.
"""

    // MARK: Input

    /// A saved conversation as the exporter sees it. Built by the app from its History; tests build it directly.
    public struct Thread: Sendable, Hashable {
        public var id: String
        public var title: String?
        public var messages: [Message]
        public var tools: [ToolSpec]
        public var modelId: String?
        public var updated: Date
        public init(id: String, title: String? = nil, messages: [Message], tools: [ToolSpec] = [], modelId: String? = nil, updated: Date = Date()) {
            self.id = id; self.title = title; self.messages = messages; self.tools = tools; self.modelId = modelId; self.updated = updated
        }
    }

    /// What the review sheet lets the person switch off before anything leaves the device.
    public struct Redaction: Sendable, Hashable, Codable {
        public var stripImages = false
        public var stripToolResults = false
        public var anonymiseURLs = false
        public init(stripImages: Bool = false, stripToolResults: Bool = false, anonymiseURLs: Bool = false) {
            self.stripImages = stripImages; self.stripToolResults = stripToolResults; self.anonymiseURLs = anonymiseURLs
        }
        public static let none = Redaction()
    }

    public struct Options: Sendable, Hashable {
        public var redaction = Redaction.none
        public var appVersion = "0.2"
        public var platform = "iOS"
        /// Fixed clock for byte-stable output in tests; nil = now.
        public var now: Date? = nil
        public init(redaction: Redaction = .none, appVersion: String = "0.2", platform: String = "iOS", now: Date? = nil) {
            self.redaction = redaction; self.appVersion = appVersion; self.platform = platform; self.now = now
        }
    }

    public enum ExportError: LocalizedError, Equatable {
        case noUserTurn(String), noAssistantAnswer(String)
        public var errorDescription: String? {
            switch self {
            case .noUserTurn(let t): "\(t): nothing was asked"
            case .noAssistantAnswer(let t): "\(t): no finished assistant answer to learn from"
            }
        }
    }

    // MARK: Output

    public struct ImageFile: Sendable, Hashable {
        public var path: String      // "images/<12 hex>.png" — relative to the dataset repo root
        public var data: Data
    }

    public struct Record: Sendable, Hashable {
        public var id: String
        public var json: JSONValue
        public var images: [ImageFile]
        public var turns: Int            // user + assistant turns (what the person sees)
        public var toolCalls: Int
        public var line: String { json.compact }
    }

    /// One push = one shard: `data/train-<timestamp>.jsonl` + the image files it references.
    public struct Shard: Sendable, Hashable {
        public var records: [Record]
        public var skipped: [String]      // "<title>: <reason>"
        public var timestamp: String      // yyyyMMdd'T'HHmmss'Z'
        public var path: String { "data/train-\(timestamp).jsonl" }
        public var jsonl: String { records.map(\.line).joined(separator: "\n") + (records.isEmpty ? "" : "\n") }
        public var images: [ImageFile] { Array(Set(records.flatMap(\.images))).sorted { $0.path < $1.path } }
        public var toolCalls: Int { records.reduce(0) { $0 + $1.toolCalls } }
        public var byteCount: Int { jsonl.utf8.count + images.reduce(0) { $0 + $1.data.count } }
    }

    // MARK: Convert

    public static func record(_ thread: Thread, options: Options = Options()) throws -> Record {
        let title = thread.title ?? String(thread.messages.first?.text.prefix(40) ?? "conversation")
        var urls = URLAnonymiser(enabled: options.redaction.anonymiseURLs)
        var out: [JSONValue] = [.object(["role": "system", "content": .string(systemPrompt)])]
        var images: [ImageFile] = []
        var imageRefs: [JSONValue] = []
        var toolCalls = 0, turns = 0
        var pending: [String: ToolUse] = [:]   // tool-call ids waiting for a result

        for m in thread.messages {
            switch m.role {
            case .user:
                let results = m.toolResults
                if !results.isEmpty {
                    for r in results where pending[r.toolUseId] != nil {
                        pending[r.toolUseId] = nil
                        let content = options.redaction.stripToolResults ? "[tool result removed before sharing]" : urls.scrub(r.content)
                        out.append(.object(["role": "tool", "tool_call_id": .string(r.toolUseId), "content": .string(content)]))
                    }
                    continue
                }
                let text = urls.scrub(m.text)
                let pics = options.redaction.stripImages ? [] : m.images
                if pics.isEmpty {
                    guard !text.isEmpty else { continue }
                    out.append(.object(["role": "user", "content": .string(text)]))
                } else {
                    var parts: [JSONValue] = []
                    for p in pics {
                        let file = imageFile(p); images.append(file); imageRefs.append(.string(file.path))
                        parts.append(.object(["type": "image"]))
                    }
                    parts.append(.object(["type": "text", "text": .string(text.isEmpty ? "What do you see?" : text)]))
                    out.append(.object(["role": "user", "content": .array(parts)]))
                }
                turns += 1
            case .assistant:
                let text = urls.scrub(m.text)
                var obj: [String: JSONValue] = ["role": "assistant", "content": .string(text)]
                let uses = m.toolUses
                if !uses.isEmpty {
                    obj["tool_calls"] = .array(uses.map { u in
                        pending[u.toolUseId] = u
                        let args = JSONValue.object(u.input.mapValues { urls.scrub($0) })
                        return .object(["id": .string(u.toolUseId), "type": "function",
                                        "function": .object(["name": .string(u.name), "arguments": args])])
                    })
                    toolCalls += uses.count
                } else if text.isEmpty { continue }     // reasoning-only or empty assistant turn
                out.append(.object(obj))
                turns += 1
            }
        }
        // A call whose result never came back cannot be learned from: drop the unanswered calls from the tail.
        if !pending.isEmpty {
            out = out.filter { msg in
                guard let calls = msg["tool_calls"]?.arrayValue else { return true }
                return !calls.contains { pending[$0["id"]?.stringValue ?? ""] != nil }
            }
        }
        guard out.contains(where: { $0["role"]?.stringValue == "user" }) else { throw ExportError.noUserTurn(title) }
        // The row must END with a plain assistant answer; trim anything after the last one.
        while let last = out.last, !(last["role"]?.stringValue == "assistant" && last["tool_calls"] == nil) {
            out.removeLast()
            if out.count <= 1 { break }
        }
        guard out.count >= 3, out.last?["role"]?.stringValue == "assistant" else { throw ExportError.noAssistantAnswer(title) }
        // Images referenced only by trimmed turns must go too (count must equal the image parts kept).
        let keptParts = out.reduce(0) { $0 + (($1["content"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "image" }.count) }
        if keptParts < imageRefs.count { imageRefs = Array(imageRefs.prefix(keptParts)); images = Array(images.prefix(keptParts)) }

        let id = "u-" + sha256Hex(thread.id).prefix(10)
        var gen: [String: JSONValue] = [
            "generator": .string("loopl-app/\(options.appVersion)"),
            "ts": .string(iso8601(options.now ?? Date())),
            "system_version": .string(systemVersion),
            "platform": .string(options.platform),
            "thread": .string(String(id.dropFirst(2))),
            "redaction": .object(["strip_images": .bool(options.redaction.stripImages),
                                  "strip_tool_results": .bool(options.redaction.stripToolResults),
                                  "anonymise_urls": .bool(options.redaction.anonymiseURLs)]),
        ]
        if let modelId = thread.modelId { gen["model"] = .string(modelId) }
        var row: [String: JSONValue] = [
            "id": .string(id), "family": "u", "split": "train",
            "messages": .array(out),
            "tools": .array(thread.tools.map(\.openAIFunction)),
            "source": .array([]),
            "gen": .object(gen),
        ]
        if !imageRefs.isEmpty { row["images"] = .array(imageRefs) }
        return Record(id: id, json: .object(row), images: images, turns: turns, toolCalls: toolCalls)
    }

    public static func shard(_ threads: [Thread], options: Options = Options()) -> Shard {
        var records: [Record] = [], skipped: [String] = []
        for t in threads {
            do { records.append(try record(t, options: options)) }
            catch { skipped.append(error.localizedDescription) }
        }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        return Shard(records: records, skipped: skipped, timestamp: f.string(from: options.now ?? Date()))
    }

    /// Dataset card for a repo the app created (HF needs the YAML header to show the viewer); appended-to on later pushes.
    public static func readme(repo: String, shards: [String], rows: Int, appVersion: String = "0.2") -> String {
        """
        ---
        license: other
        language: [en]
        task_categories: [text-generation]
        tags: [loopl, loopl-conversations, agents, tool-use, conversations, sft]
        pretty_name: \(repo.split(separator: "/").last.map(String.init) ?? repo)
        configs:
          - config_name: default
            data_files:
              - split: train
                path: data/*.jsonl
        ---

        # \(repo)

        Conversations shared from the **loopl** app (v\(appVersion)) — private, pushed by its owner, one shard per push.
        Rows follow `cagataydev/loopl-train`'s `schema/conversation.schema.json` (family `u`): HF chat `messages` with the loopl
        system turn, `tools` the thread offered, `images/` for pictures. Train with loopl's *Train* tab or `train/loopl_sft.py`.

        Shards: \(shards.count) · rows: \(rows)
        \(shards.map { "- `\($0)`" }.joined(separator: "\n"))
        """
    }

    // MARK: Validate (mirrors schema/conversation.schema.json + loopl-train validate.check)

    /// Structural problems with a row, empty when it is a valid loopl-train record. Mirrors the shared JSON Schema
    /// (`Tests/LooplTests/Fixtures/hub/conversation.schema.json`) so the app can refuse to push a bad row offline.
    public static func validate(_ row: JSONValue) -> [String] {
        var errs: [String] = []
        guard let o = row.objectValue else { return ["row is not an object"] }
        let id = o["id"]?.stringValue ?? ""
        if id.range(of: #"^[a-z]-[0-9a-f]{6,}$"#, options: .regularExpression) == nil { errs.append("id '\(id)' must match <family>-<hex>") }
        if !["a", "b", "c", "d", "e", "f", "g", "h", "u"].contains(o["family"]?.stringValue ?? "") { errs.append("family must be a–h or u") }
        if let s = o["split"]?.stringValue, !["train", "eval"].contains(s) { errs.append("split must be train|eval") }
        guard let msgs = o["messages"]?.arrayValue else { return errs + ["messages missing"] }
        if msgs.count < 3 { errs.append("messages needs system + user + assistant") }
        if msgs.first?["role"]?.stringValue != "system" || (msgs.first?["content"]?.stringValue ?? "").isEmpty { errs.append("messages[0] must be a non-empty system turn") }
        if let last = msgs.last, last["role"]?.stringValue != "assistant" || last["tool_calls"] != nil { errs.append("must end with a plain assistant answer") }
        if !msgs.contains(where: { $0["role"]?.stringValue == "user" }) { errs.append("no user turn") }
        let toolNames = Set((o["tools"]?.arrayValue ?? []).compactMap { $0["function"]?["name"]?.stringValue })
        for t in o["tools"]?.arrayValue ?? [] {
            if t["type"]?.stringValue != "function" || t["function"]?["name"]?.stringValue == nil || t["function"]?["parameters"]?.objectValue == nil { errs.append("tools[] entries need type=function, function.name, function.parameters") ; break }
        }
        var pending = Set<String>(), imageParts = 0
        for (i, m) in msgs.enumerated() {
            let role = m["role"]?.stringValue ?? ""
            if !["system", "user", "assistant", "tool"].contains(role) { errs.append("messages[\(i)] bad role '\(role)'") ; continue }
            if role != "assistant", m["tool_calls"] != nil { errs.append("messages[\(i)] \(role) turn carries tool_calls") }
            if let parts = m["content"]?.arrayValue {
                for p in parts {
                    switch p["type"]?.stringValue { case "image": imageParts += 1; case "text": break; default: errs.append("messages[\(i)] part type must be image|text") }
                }
            } else if m["content"]?.stringValue == nil { errs.append("messages[\(i)] content must be a string or parts") }
            if role == "tool" {
                guard let cid = m["tool_call_id"]?.stringValue else { errs.append("messages[\(i)] tool turn without tool_call_id"); continue }
                if m["content"]?.stringValue == nil { errs.append("messages[\(i)] tool content must be a string") }
                if pending.remove(cid) == nil { errs.append("messages[\(i)] tool result without matching call \(cid)") }
            }
            for c in m["tool_calls"]?.arrayValue ?? [] {
                guard let cid = c["id"]?.stringValue, !cid.isEmpty else { errs.append("messages[\(i)] tool_call without id"); continue }
                if let t = c["type"]?.stringValue, t != "function" { errs.append("messages[\(i)] tool_call type must be function") }
                let name = c["function"]?["name"]?.stringValue ?? ""
                if name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) == nil { errs.append("messages[\(i)] bad tool name '\(name)'") }
                if c["function"]?["arguments"]?.objectValue == nil { errs.append("messages[\(i)] \(name) arguments must be an object") }
                if !toolNames.isEmpty, !toolNames.contains(name) { errs.append("messages[\(i)] calls \(name) which tools[] does not offer") }
                pending.insert(cid)
            }
        }
        if !pending.isEmpty { errs.append("tool call(s) without result: \(pending.sorted().joined(separator: ","))") }
        let refs = o["images"]?.arrayValue ?? []
        if refs.count != imageParts { errs.append("images (\(refs.count)) must match image parts (\(imageParts))") }
        for r in refs where (r.stringValue ?? "").range(of: #"^images/[0-9a-f]{10,64}\.(png|jpg|jpeg|webp)$"#, options: .regularExpression) == nil {
            errs.append("image ref '\(r.stringValue ?? "")' must be images/<hex>.<png|jpg|jpeg|webp>")
        }
        if let v = o["gen"]?["system_version"]?.stringValue, v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) == nil { errs.append("gen.system_version must be semver") }
        return errs
    }

    // MARK: Helpers

    static func imageFile(_ img: ImageBlock) -> ImageFile {
        let ext = img.format == "jpg" || img.format == "jpeg" ? "jpg" : (img.format == "webp" ? "webp" : "png")
        return ImageFile(path: "images/\(sha256Hex(img.data).prefix(12)).\(ext)", data: img.data)
    }

    static func sha256Hex(_ s: String) -> String { sha256Hex(Data(s.utf8)) }
    static func sha256Hex(_ d: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        #else
        var h: UInt64 = 1469598103934665603   // FNV-1a fallback (non-Apple builds only)
        for b in d { h ^= UInt64(b); h = h &* 1099511628211 }
        return String(format: "%016llx%016llx", h, h ^ 0x9E3779B97F4A7C15)
        #endif
    }

    static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }

    /// Replaces every URL with a stable placeholder (`https://example.com/u1`, `/u2`, …) per record, so the
    /// shape of a conversation survives but no real host or path leaves the device.
    struct URLAnonymiser {
        var enabled: Bool
        private var map: [String: String] = [:]
        private static let rx = try! NSRegularExpression(pattern: #"https?://[^\s"'<>()\[\]]+"#)
        init(enabled: Bool) { self.enabled = enabled }
        mutating func scrub(_ s: String) -> String {
            guard enabled, !s.isEmpty else { return s }
            let ns = s as NSString
            var out = s
            for m in Self.rx.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let url = ns.substring(with: m.range)
                let key = url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                if map[key] == nil { map[key] = "https://example.com/u\(map.count + 1)" }
                let r = Range(m.range, in: out)!
                out.replaceSubrange(r, with: map[key]! + url.dropFirst(key.count))
            }
            return out
        }
        mutating func scrub(_ v: JSONValue) -> JSONValue {
            guard enabled else { return v }
            switch v {
            case .string(let s): return .string(scrub(s))
            case .array(let a): return .array(a.map { scrub($0) })
            case .object(let o): return .object(o.mapValues { scrub($0) })
            default: return v
            }
        }
    }
}
