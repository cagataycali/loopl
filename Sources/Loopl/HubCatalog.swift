import Foundation

/// Any model on Hugging Face, turned into a `ModelSpec` at runtime.
///
/// Anonymous by default (no token, no account); pass `token:` and the same calls also see the
/// user's PRIVATE repos (`mine(author:)`, private `repo`/`config`) — the token is only ever an
/// `Authorization: Bearer` header to `host`. `GET /api/models?search=…`
/// for MLX (`author=mlx-community`) and GGUF (`filter=gguf`), `GET /api/models/<repo>?blobs=true`
/// for the file list with sizes, and the repo's `config.json` for the context
/// window + quantization. Everything the UI shows is derived here, in pure
/// functions pinned by tests on saved API responses (`Tests/LooplTests/Fixtures/hub`).
///
/// Network goes through `NetworkPolicy.session` and honours the offline switch;
/// responses are cached on disk so a repo you browsed once still renders offline.
public struct HubCatalog: Sendable {
    public var host = "https://huggingface.co"
    public var cache: HubCache? = HubCache()
    /// `nil` → anonymous. Consulted per request (see `HFTokenProvider`).
    public var token: HFTokenProvider?
    public init(token: HFTokenProvider? = nil) { self.token = token }
    var bearer: String? { token?().flatMap { $0.isEmpty ? nil : $0 } }

    // MARK: - Types

    /// Which runnable format to search for: MLX safetensors or GGUF.
    public enum Kind: String, Sendable, CaseIterable, Identifiable, Codable {
        case mlx, gguf
        public var id: String { rawValue }
        public var label: String { self == .mlx ? "MLX" : "GGUF" }
        public var runtime: RuntimeKind { self == .mlx ? .mlx : .gguf }
    }

    /// One search result row — enough for a list without a second request.
    public struct Hit: Sendable, Hashable, Identifiable, Codable {
        public var id: String                 // "mlx-community/Qwen3-1.7B-4bit"
        public var kind: Kind
        public var downloads: Int
        public var likes: Int
        public var gated: Bool
        public var pipeline: String?          // "text-generation"
        public var modelType: String?         // config.model_type (MLX) or gguf.architecture
        public var bits: Int?                 // quantization_config.bits (MLX)
        public var ctx: Int?                  // gguf.context_length (GGUF only in search)
        public var sizeBytes: Int64?          // gguf.total, or estimated from safetensors param count + bits
        public var paramsB: Double?
        public var lastModified: String?
        /// Only the owner's token sees these (`expand[]=private`); anonymous search never returns one.
        public var isPrivate: Bool = false
        /// Top-level file names (`expand[]=siblings`) — the vision badge reads them (`HubCatalog.isVision(files:)`); nil on older cached rows.
        public var files: [String]? = nil

        public var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
        public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
        /// Hub search also returns ASR/TTS/embedding/vision checkpoints; chat needs a text generator.
        /// Vision-language repos (image-text-to-text) pass when loopl can run them (MLX only).
        public var isTextGeneration: Bool {
            if isVision { return kind == .mlx }
            if let pipeline, pipeline != "text-generation" { return false }
            let t = (modelType ?? "").lowercased(), n = name.lowercased()
            for bad in ["asr", "tts", "embedding", "rerank", "clip", "whisper", "omni", "audio", "speech", "mtp", "_mtp"] {
                if t.contains(bad) || n.contains(bad) { return false }
            }
            return true
        }
        /// A vision-language checkpoint (`HubCatalog.isVision`) — files first, then the Hub's tags, then the architecture.
        public var isVision: Bool { HubCatalog.isVision(repo: id, pipeline: pipeline, modelType: modelType, files: files) }
    }

    /// A file of a search hit, with its size.
    public struct File: Sendable, Hashable, Codable {
        public var path: String
        public var size: Int64
        public init(path: String, size: Int64) { self.path = path; self.size = size }
        public var isGGUF: Bool { path.lowercased().hasSuffix(".gguf") }
        /// "Q4_K_M" from "Qwen_Qwen3-1.7B-Q4_K_M.gguf".
        public var quant: String? {
            guard isGGUF else { return nil }
            let stem = (path as NSString).deletingPathExtension
            guard let r = stem.range(of: #"(IQ[1-4]_[A-Z_]+|Q[2-8]_(K_[SML]|K|[01])|Q[2-8]|F16|BF16|F32|MXFP4)$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return String(stem[r]).uppercased()
        }
    }

    /// The parts of a repo's `config.json` loopl reads: architecture, context, quantisation, vision.
    public struct Config: Sendable, Hashable, Codable {
        public var modelType: String?
        public var architectures: [String]
        public var maxPositionEmbeddings: Int?
        public var bits: Int?
        public var groupSize: Int?
        /// `vision_config` (or `visual`/`vision_tower`) is in config.json → the checkpoint carries a vision tower. This is the
        /// truth the badge and `ModelSpec.vision` follow: a text-only export of a vision architecture (model_type still
        /// `qwen3_5`, the merge dropped the tower) has none. nil = not read.
        public var hasVisionConfig: Bool? = nil
        public init(modelType: String? = nil, architectures: [String] = [], maxPositionEmbeddings: Int? = nil, bits: Int? = nil, groupSize: Int? = nil,
                    hasVisionConfig: Bool? = nil) {
            self.modelType = modelType; self.architectures = architectures; self.maxPositionEmbeddings = maxPositionEmbeddings; self.bits = bits; self.groupSize = groupSize
            self.hasVisionConfig = hasVisionConfig
        }
    }

    /// Repo detail (`?blobs=true`): the file list with sizes plus whatever metadata the Hub inlines.
    public struct Repo: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var sha: String?
        public var gated: Bool
        public var downloads: Int
        public var likes: Int
        public var pipeline: String?
        public var files: [File]
        public var modelType: String?         // config.model_type or gguf.architecture
        public var ggufContext: Int?
        public var paramsB: Double?           // from safetensors param count
        public var lastModified: String?
        public var isPrivate: Bool = false
        /// The repo's Hub tags (`loopl`, `mlx`, `gguf`…).
        public var tags: [String]? = nil
        public init(id: String, sha: String?, gated: Bool, downloads: Int, likes: Int, pipeline: String?, files: [File],
                    modelType: String?, ggufContext: Int?, paramsB: Double?, lastModified: String?, isPrivate: Bool = false, tags: [String]? = nil) {
            self.id = id; self.sha = sha; self.gated = gated; self.downloads = downloads; self.likes = likes; self.pipeline = pipeline
            self.files = files; self.modelType = modelType; self.ggufContext = ggufContext; self.paramsB = paramsB; self.lastModified = lastModified
            self.isPrivate = isPrivate; self.tags = tags
        }

        public var kind: Kind { files.contains(where: \.isGGUF) && !files.contains(where: { $0.path.hasSuffix(".safetensors") }) ? .gguf : .mlx }
        /// A vision-language checkpoint (`HubCatalog.isVision`): the file list decides when the architecture alone cannot.
        public var isVision: Bool { HubCatalog.isVision(repo: id, pipeline: pipeline, modelType: modelType, files: files.map(\.path)) }
        public var ggufFiles: [File] { files.filter(\.isGGUF).filter { !$0.path.contains("/") }.sorted { $0.size < $1.size } }
        public var mlxFiles: [File] { files.filter { HFDownloader.wanted(.init(path: $0.path, size: $0.size, type: "file")) } }
        public var mlxBytes: Int64 { mlxFiles.reduce(0) { $0 + $1.size } }
        /// The quant we download when the user does not pick: Q4_K_M, else the closest 4-bit, else the smallest.
        public var preferredGGUF: File? {
            let one = ggufFiles.filter { !$0.path.lowercased().contains("imatrix") }
            return one.first { $0.quant == "Q4_K_M" } ?? one.first { ($0.quant ?? "").hasPrefix("Q4") } ?? one.first
        }
    }

    /// Why a repo could not be searched or resolved into a `ModelSpec`.
    public enum HubError: LocalizedError, Equatable {
        case offline, http(Int, String), noWeights(String), badJSON(String), visionGGUF(String)
        /// 401/403 with NO token: private or gated — a Hugging Face token would help.
        case signInRequired(String)
        /// 401/403 WITH a token: this account cannot read it.
        case noAccess(String)
        @available(*, deprecated, renamed: "signInRequired")
        public static func gated(_ repo: String) -> HubError { .signInRequired(repo) }
        public var errorDescription: String? {
            switch self {
            case .offline: "offline mode is on — browsing Hugging Face needs the network (models already on this device still load)"
            case .http(let c, let p): "Hugging Face answered HTTP \(c) for \(p)"
            case .signInRequired(let r): "\(r) is private or gated — sign in to Hugging Face in Settings to use it"
            case .noAccess(let r): "your Hugging Face account can't read \(r) — it is private or gated; check access on huggingface.co"
            case .noWeights(let r): "\(r) has no MLX safetensors and no .gguf file loopl can run"
            case .badJSON(let p): "unexpected response for \(p)"
            case .visionGGUF(let r): "\(r) is a vision model in GGUF — loopl runs vision models through MLX only; pick an mlx-community build"
            }
        }
    }

    // MARK: - Fit

    /// Will it run here? Never blocks — the badge is advice, the download button stays.
    public enum Fit: String, Sendable, Codable {
        case green, amber, red
        /// Weights + KV cache + activations ≈ 1.3 × the weights. Green ≤ 60 % of what iOS lets this
        /// process grow to, amber ≤ 90 %, red beyond (it may still load with a small context).
        public static func verdict(bytes: Int64, available: Int64) -> Fit {
            guard available > 0 else { return .amber }
            let need = Double(bytes) * 1.3
            if need <= Double(available) * 0.6 { return .green }
            if need <= Double(available) * 0.9 { return .amber }
            return .red
        }
        public var label: String {
            switch self { case .green: "fits"; case .amber: "tight"; case .red: "too big" }
        }
    }

    // MARK: - Family

    /// The tool-call grammar a repo probably speaks, and whether loopl has proven it on-device.
    public struct FamilyGuess: Sendable, Hashable {
        public var family: ToolFamily
        /// `true` when loopl has run this family's tool-call grammar on-device (curated catalog rows);
        /// `false` → the UI shows "tool calls unverified" and the generic fallback parser is tried too.
        public var verified: Bool
        public var label: String
    }

    /// Chat-template / tool-call dialect from the architecture and the repo name.
    public static func detectFamily(repo: String, modelType: String?) -> FamilyGuess {
        let r = repo.lowercased(), t = (modelType ?? "").lowercased()
        func has(_ s: String...) -> Bool { s.contains { r.contains($0) || t.contains($0) } }
        if has("qwen3", "qwen2", "qwen") { return .init(family: .hermes, verified: true, label: "Qwen") }
        if has("hermes") { return .init(family: .hermes, verified: true, label: "Hermes") }
        if has("smollm3") { return .init(family: .hermes, verified: true, label: "SmolLM3") }
        if has("phi") { return .init(family: .hermes, verified: true, label: "Phi") }
        if has("smollm") { return .init(family: .generic, verified: true, label: "SmolLM") }   // before llama: SmolLM2 is a llama architecture
        if has("llama") { return .init(family: .llama3, verified: true, label: "Llama 3") }
        if has("gemma") { return .init(family: .generic, verified: true, label: "Gemma") }
        if has("deepseek") { return .init(family: .generic, verified: true, label: "DeepSeek") }
        if has("mistral", "mixtral", "ministral") { return .init(family: .generic, verified: false, label: "Mistral") }
        if has("granite") { return .init(family: .hermes, verified: false, label: "Granite") }
        if has("gpt-oss", "gpt_oss") { return .init(family: .generic, verified: false, label: "gpt-oss") }
        if has("olmo") { return .init(family: .generic, verified: false, label: "OLMo") }
        if has("internlm", "glm", "yi-", "exaone", "falcon", "starcoder", "stablelm", "nemotron") {
            return .init(family: .generic, verified: false, label: modelType ?? "generic")
        }
        return .init(family: .generic, verified: false, label: modelType?.isEmpty == false ? modelType! : "unknown")
    }

    /// Architectures mlx-swift-lm 3.32.3's MLXVLM factory can instantiate (its `VLMTypeRegistry`).
    public static let visionModelTypes: Set<String> = [
        "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_vl_moe", "qwen3_5", "qwen3_5_moe", "gemma3", "gemma4", "idefics3", "smolvlm",
        "fastvlm", "llava_qwen2", "pixtral", "paligemma", "mistral3", "lfm2_vl", "glm_ocr",
    ]

    /// Files only a checkpoint WITH an image processor ships. A vision architecture whose export dropped the tower
    /// (loopl v1: `qwen3_5` merged without `visual.*`) has none of them.
    public static let visionProcessorFiles: Set<String> = ["preprocessor_config.json", "processor_config.json", "video_preprocessor_config.json"]

    /// Does this checkpoint carry a vision tower loopl can drive? Truth order: `pipeline_tag` from the Hub
    /// (`image-text-to-text`), then the FILE LIST when we have it (an image processor config = a tower; a vision
    /// `model_type` with no processor files and a `text-generation` tag = a text-only export), then `model_type`
    /// (config.json) and the name for un-tagged mirrors (`…-VL-…`). `qwen3_5_text` / `*-Text` are text-only.
    /// When config.json itself was read, prefer `Config.hasVisionConfig` (see `spec(for:config:)`).
    public static func isVision(repo: String, pipeline: String?, modelType: String?, files: [String]? = nil) -> Bool {
        let t = (modelType ?? "").lowercased(), r = repo.lowercased()
        if t == "qwen3_5_text" || r.hasSuffix("-text") || r.contains("-text-") { return false }
        if let pipeline, pipeline == "image-text-to-text" || pipeline == "video-text-to-text" { return true }
        if let files, !files.isEmpty {
            let names = Set(files.map { ($0 as NSString).lastPathComponent })
            if !names.isDisjoint(with: visionProcessorFiles) { return true }
            // The Hub listed the files and none is an image processor: a vision model_type is then the base
            // architecture's name, not a tower (loopl-*-4bit, qwen3_5 text-only exports).
            if names.contains("config.json") || names.contains { $0.hasSuffix(".safetensors") } { return false }
        }
        if !t.isEmpty, visionModelTypes.contains(t) { return true }
        let name = r.split(separator: "/").last.map(String.init) ?? r
        return name.contains("-vl-") || name.hasSuffix("-vl") || name.contains("_vl_") || name.contains("smolvlm") || name.contains("fastvlm")
    }

    /// Weights the fit badge must budget. A vision tower adds its own activations and the image
    /// tokens' KV (≤ 1280 tokens per picture on Qwen3-VL at the default budget) ≈ +15 % over text.
    public static func fitBytes(weights: Int64, vision: Bool) -> Int64 {
        vision ? Int64(Double(weights) * 1.15) : weights
    }

    /// Quantization from the repo name when config.json does not say ("…-4bit", "…-8bit", "…-bf16" → 16).
    public static func bitsFromName(_ name: String) -> Int? {
        let n = name.lowercased()
        if let r = n.range(of: #"(?<![0-9])([2-8])[-_]?bit"#, options: .regularExpression) {
            return Int(String(n[r].first!))
        }
        if n.contains("bf16") || n.contains("fp16") || n.contains("-f16") { return 16 }
        if n.contains("fp32") || n.contains("-f32") { return 32 }
        if n.contains("mxfp4") || n.contains("nvfp4") || n.contains("-q4") { return 4 }
        if n.contains("-q8") { return 8 }
        return nil
    }

    /// Billions of parameters from a repo name ("Qwen3-1.7B-4bit" → 1.7, "SmolLM2-360M" → 0.36).
    public static func paramsB(fromName name: String) -> Double? {
        let n = name.replacingOccurrences(of: "_", with: "-")
        if let r = n.range(of: #"(\d+(?:\.\d+)?)[bB](?![a-zA-Z0-9])"#, options: .regularExpression) {
            return Double(n[r].dropLast().filter { "0123456789.".contains($0) })
        }
        if let r = n.range(of: #"(\d{3,4})[mM](?![a-zA-Z0-9])"#, options: .regularExpression) {
            return Double(n[r].dropLast()).map { $0 / 1000 }
        }
        return nil
    }

    /// Context we budget on an 8 GB phone: the model's own limit, capped by what its size leaves for KV cache.
    public static func ctxUsable8GB(paramsB: Double?, ctxNominal: Int) -> Int {
        let cap: Int = switch paramsB ?? 2 {
        case ..<1.0: 16384
        case ..<2.5: 8192
        case ..<5.0: 8192
        case ..<9.0: 4096
        default: 2048
        }
        return max(512, min(ctxNominal, cap))
    }

    // MARK: - Parsing (pure)

    public static func parseSearch(_ data: Data, kind: Kind) throws -> [Hit] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HubError.badJSON("search") }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let config = row["config"] as? [String: Any] ?? [:]
            let gguf = row["gguf"] as? [String: Any]
            let st = row["safetensors"] as? [String: Any]
            let bits = ((config["quantization_config"] as? [String: Any])?["bits"] as? Int) ?? Self.bitsFromName(id)
            var size: Int64? = (gguf?["total"] as? NSNumber)?.int64Value
            var params: Double? = nil
            if let total = (st?["total"] as? NSNumber)?.doubleValue, total > 0 {
                params = total / 1e9
                if size == nil {
                    // Per-dtype counts when the Hub sends them (always for safetensors repos) — a mixed
                    // export (quantised LLM + bf16 vision tower) is 20-30 % bigger than params × bits/8.
                    let byDtype = Self.dtypeCounts(st?["parameters"])
                    size = byDtype.isEmpty ? Self.estimateMLXBytes(params: total, bits: bits)
                                            : Self.mlxBytes(parameters: byDtype, bits: bits,
                                                            groupSize: (config["quantization_config"] as? [String: Any])?["group_size"] as? Int)
                }
            }
            if params == nil { params = paramsB(fromName: id) }
            return Hit(id: id, kind: kind,
                       downloads: (row["downloads"] as? NSNumber)?.intValue ?? 0,
                       likes: (row["likes"] as? NSNumber)?.intValue ?? 0,
                       gated: Self.gatedFlag(row["gated"]),
                       pipeline: row["pipeline_tag"] as? String,
                       modelType: (config["model_type"] as? String) ?? (gguf?["architecture"] as? String),
                       bits: bits,
                       ctx: (gguf?["context_length"] as? NSNumber)?.intValue,
                       sizeBytes: size, paramsB: params,
                       lastModified: row["lastModified"] as? String,
                       isPrivate: (row["private"] as? Bool) ?? false,
                       files: (row["siblings"] as? [[String: Any]]).map { $0.compactMap { $0["rfilename"] as? String } })
        }
    }

    /// A user's own repos (`/api/models?author=…`): every format mixed together, so the kind is read
    /// per row — `gguf` metadata or the `gguf` tag → GGUF; the `mlx` tag / library → MLX; anything else
    /// (full-precision transformers checkpoints, LoRA adapters, robot policies…) is dropped because loopl
    /// cannot run it. Vision detection is the same `isVision` the search path uses.
    public static func parseMine(_ data: Data) throws -> [Hit] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HubError.badJSON("mine") }
        var out: [Hit] = []
        for row in rows {
            guard let kind = Self.kind(ofRow: row), let one = try? parseSearch(JSONSerialization.data(withJSONObject: [row]), kind: kind).first else { continue }
            out.append(one)
        }
        return out
    }

    static func kind(ofRow row: [String: Any]) -> Kind? {
        let tags = Set((row["tags"] as? [String] ?? []).map { $0.lowercased() })
        let library = (row["library_name"] as? String)?.lowercased()
        if row["gguf"] != nil || tags.contains("gguf") || library == "gguf" { return .gguf }
        if tags.contains("mlx") || library == "mlx" { return .mlx }
        return nil
    }

    public static func parseRepo(_ data: Data) throws -> Repo {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = row["id"] as? String else { throw HubError.badJSON("repo") }
        let config = row["config"] as? [String: Any] ?? [:]
        let gguf = row["gguf"] as? [String: Any]
        let st = row["safetensors"] as? [String: Any]
        let files: [File] = (row["siblings"] as? [[String: Any]] ?? []).compactMap { s in
            guard let p = s["rfilename"] as? String else { return nil }
            return File(path: p, size: (s["size"] as? NSNumber)?.int64Value ?? 0)
        }
        return Repo(id: id, sha: row["sha"] as? String, gated: Self.gatedFlag(row["gated"]),
                    downloads: (row["downloads"] as? NSNumber)?.intValue ?? 0, likes: (row["likes"] as? NSNumber)?.intValue ?? 0,
                    pipeline: row["pipeline_tag"] as? String, files: files,
                    modelType: (config["model_type"] as? String) ?? (gguf?["architecture"] as? String),
                    ggufContext: (gguf?["context_length"] as? NSNumber)?.intValue,
                    paramsB: (st?["total"] as? NSNumber).map { $0.doubleValue / 1e9 },
                    lastModified: row["lastModified"] as? String,
                    isPrivate: (row["private"] as? Bool) ?? false,
                    tags: row["tags"] as? [String])
    }

    public static func parseConfig(_ data: Data) throws -> Config {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HubError.badJSON("config.json") }
        let q = (row["quantization"] as? [String: Any]) ?? (row["quantization_config"] as? [String: Any])
        // Multimodal configs nest the LLM: text_config.max_position_embeddings.
        let text = row["text_config"] as? [String: Any]
        return Config(modelType: row["model_type"] as? String,
                      architectures: row["architectures"] as? [String] ?? [],
                      maxPositionEmbeddings: ((row["max_position_embeddings"] ?? text?["max_position_embeddings"]) as? NSNumber)?.intValue,
                      bits: (q?["bits"] as? NSNumber)?.intValue, groupSize: (q?["group_size"] as? NSNumber)?.intValue,
                      hasVisionConfig: Self.hasVisionConfig(row))
    }

    /// `vision_config` (Qwen-VL, Qwen3.5, Gemma 3, SmolVLM…), `visual` (older Qwen-VL) or `vision_tower` at the top level of config.json.
    public static func hasVisionConfig(_ row: [String: Any]) -> Bool {
        for k in ["vision_config", "visual", "vision_tower", "vision_encoder"] where row[k] is [String: Any] { return true }
        return false
    }

    /// 4-bit MLX weights ≈ params × bits/8 × 1.125 (scales + biases per group of 64). Pinned on the curated rows.
    ///
    /// Only a fallback now: it assumes EVERY parameter is quantised, so it reads 16-33 % low on a
    /// vision export (the tower stays bf16) and ~6 % high at 8 bits. Prefer ``mlxBytes(parameters:bits:groupSize:)``
    /// whenever the Hub sent the per-dtype breakdown.
    public static func estimateMLXBytes(params: Double, bits: Int?) -> Int64 {
        Int64(params * Double(bits ?? 16) / 8 * (bits == nil ? 1 : 1.125))
    }

    /// `safetensors.parameters` → `["U32": 751894528, "BF16": 101091392]`, dropping anything unreadable.
    static func dtypeCounts(_ any: Any?) -> [String: Double] {
        guard let raw = any as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (dtype, n) in raw {
            guard let count = (n as? NSNumber)?.doubleValue, count > 0 else { continue }
            out[dtype.uppercased()] = count
        }
        return out
    }

    /// Bytes per element of a safetensors dtype (unknown names fall back to 4).
    static func dtypeBytes(_ dtype: String) -> Double {
        switch dtype {
        case "F64", "I64", "U64": 8
        case "F32", "I32", "U32": 4
        case "F16", "BF16", "I16", "U16": 2
        case "U8", "I8", "BOOL", "F8_E4M3", "F8_E5M2", "F8_E8M0": 1
        default: 4
        }
    }

    /// Weights on disk from the Hub's per-dtype parameter counts — the number the Mine/collection rows show
    /// and the number the file list will confirm.
    ///
    /// The Hub reports a quantised MLX tensor by its LOGICAL parameter count under `U32` (the packed
    /// storage dtype), so a quantised parameter costs `bits/8` plus its share of the per-group scale and
    /// bias (two 16-bit values per `group_size`, 64 unless config.json says otherwise). Everything else
    /// (bf16 vision tower, embeddings a converter left alone, f32 norms) costs its own dtype.
    ///
    /// Measured against the Hub's real `siblings[].size` on 2026-10-06: ≤ 0.02 % off on
    /// `cagataydev/loopl-{0.8b,2b,4b}-4bit` (625.2 / 1722.3 / 3034.3 MB), `mlx-community/Qwen3-VL-2B-Instruct-4bit`,
    /// `Qwen3-1.7B-4bit`, `Qwen3-8B-8bit`, `Llama-3.2-1B-Instruct-4bit` and the bf16 `cagataydev/loopl-0.8b`,
    /// where ``estimateMLXBytes(params:bits:)`` was -23.3 %, -27.7 %, -15.9 %, -32.8 % and +5.9 % out.
    public static func mlxBytes(parameters: [String: Double], bits: Int?, groupSize: Int? = nil) -> Int64 {
        let group = Double(max(1, groupSize ?? 64))
        var total = 0.0
        for (dtype, count) in parameters {
            // `bits == nil` or 16+ → nothing was quantised; U32 then really is a 4-byte tensor (rope caches…).
            if let bits, bits < 16, dtype == "U32" {
                total += count * (Double(bits) / 8 + 4 / group)
            } else {
                total += count * dtypeBytes(dtype)
            }
        }
        return Int64(total)
    }

    static func gatedFlag(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return !s.isEmpty && s != "false" }   // "auto" / "manual"
        return false
    }

    // MARK: - Spec

    /// A runnable `ModelSpec` for a Hub repo. GGUF needs the file to download; MLX takes the whole repo.
    public static func spec(for repo: Repo, config: Config?, ggufFile: File? = nil) throws -> ModelSpec {
        let kind: Kind = ggufFile != nil ? .gguf : repo.kind
        let file = kind == .gguf ? (ggufFile ?? repo.preferredGGUF) : nil
        if kind == .gguf, file == nil { throw HubError.noWeights(repo.id) }
        if kind == .mlx, !repo.files.contains(where: { $0.path.hasSuffix(".safetensors") }) { throw HubError.noWeights(repo.id) }
        let bytes = kind == .gguf ? (file?.size ?? 0) : repo.mlxBytes
        let name = repo.id.split(separator: "/").last.map(String.init) ?? repo.id
        let params = repo.paramsB ?? paramsB(fromName: name)
        let ctx = config?.maxPositionEmbeddings ?? repo.ggufContext ?? 4096
        let guess = detectFamily(repo: repo.id, modelType: config?.modelType ?? repo.modelType)
        var id = "hub:" + repo.id.lowercased()
        if let file { id += ":" + file.path.lowercased() }
        // config.json read → its `vision_config` is the truth; otherwise the Hub's tag + file list (`Repo.isVision`).
        let vision = config?.hasVisionConfig ?? repo.isVision
        if vision, kind == .gguf { throw HubError.visionGGUF(repo.id) }
        var notes = "From Hugging Face · \(guess.label)"
        if vision { notes += " · vision" }
        if !guess.verified { notes += " · tool calls unverified" }
        let qwen3 = repo.id.lowercased().contains("qwen3")
        return ModelSpec(id: id, name: name.replacingOccurrences(of: "_", with: " "), repo: repo.id,
                         runtime: kind.runtime, family: guess.family, paramsB: params ?? 0, sizeBytes: bytes,
                         ctxNominal: ctx, ctxUsable8GB: ctxUsable8GB(paramsB: params, ctxNominal: ctx),
                         minRAMGB: (Double(fitBytes(weights: bytes, vision: vision)) * 1.3 / 1e9).rounded(.up), gated: repo.gated,
                         notes: notes, revision: nil, file: file?.path, temperature: nil,
                         chatTemplateKwargs: qwen3 ? ["enable_thinking": .bool(false)] : nil,
                         toolsUnverified: guess.verified ? nil : true, vision: vision ? true : nil)
    }

    // MARK: - Network

    /// Bearer only on `host` (see `HFDownloader.request`).
    public func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("loopl/0.3 (iOS)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = bearer, HFDownloader.sameHost(url, host) { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func denied(_ repo: String) -> HubError { bearer == nil ? .signInRequired(repo) : .noAccess(repo) }

    /// GET with the disk cache: offline → cached or `HubError.offline`; online → network, falling back to a stale copy on failure.
    /// `repo:` names the repository for the 401/403 message (defaults to the URL's last path component).
    func fetch(_ url: URL, ttl: TimeInterval, repo: String? = nil, cacheable: Bool = true) async throws -> Data {
        // Authenticated answers are cached under a separate key: a private listing must never be served
        // to the anonymous path (after Remove), and the public cache must not shadow a now-visible private repo.
        let key = bearer == nil ? url : Self.cacheKey(url)
        let cache = cacheable ? self.cache : nil
        if let cache, let hit = cache.read(key, maxAge: ttl) { return hit }
        if NetworkPolicy.isOffline {
            if let cache, let stale = cache.read(key, maxAge: .infinity) { return stale }
            throw HubError.offline
        }
        do {
            let (data, resp) = try await NetworkPolicy.session.data(for: request(url))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw denied(repo ?? url.lastPathComponent) }
            guard code == 200 else { throw HubError.http(code, url.path) }
            cache?.write(key, data)
            return data
        } catch let e as HubError {
            throw e
        } catch {
            if let cache, let stale = cache.read(key, maxAge: .infinity) { return stale }
            throw error
        }
    }

    /// Cache key for an authenticated request: the URL with a marker fragment (never sent on the wire).
    static func cacheKey(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.fragment = "auth"
        return c.url ?? url
    }

    public func searchURL(_ query: String, kind: Kind, limit: Int = 30) -> URL {
        var c = URLComponents(string: "\(host)/api/models")!
        var q: [URLQueryItem] = []
        if !query.isEmpty { q.append(URLQueryItem(name: "search", value: query)) }
        q += [URLQueryItem(name: "sort", value: "downloads"), URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: String(limit))]
        switch kind {
        case .mlx: q.append(URLQueryItem(name: "author", value: "mlx-community"))
        case .gguf: q.append(URLQueryItem(name: "filter", value: "gguf"))
        }
        // The plain listing is ids + downloads only; `expand[]` inlines config (model_type, bits),
        // safetensors (param count → size estimate), gguf (ctx, total) and gated — one request per search.
        for f in ["config", "safetensors", "gguf", "gated", "pipeline_tag", "lastModified", "likes", "downloads", "siblings"] {
            q.append(URLQueryItem(name: "expand[]", value: f))
        }
        c.queryItems = q
        return c.url!
    }

    /// Top text-generation repos for a query (by downloads). Empty query → the most downloaded.
    /// Gated rows are dropped: even with a token the user must accept the terms on huggingface.co first.
    public func search(_ query: String, kind: Kind, limit: Int = 30) async throws -> [Hit] {
        let data = try await fetch(searchURL(query, kind: kind, limit: limit), ttl: 3600)
        return try Self.parseSearch(data, kind: kind).filter { !$0.gated }
    }

    /// `GET /api/models?author=<me>` — with the owner's token this includes PRIVATE repos.
    public func mineURL(author: String, limit: Int = 500) -> URL {
        var c = URLComponents(string: "\(host)/api/models")!
        var q: [URLQueryItem] = [URLQueryItem(name: "author", value: author), URLQueryItem(name: "sort", value: "lastModified"),
                                 URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: String(limit))]
        for f in ["config", "safetensors", "gguf", "gated", "pipeline_tag", "lastModified", "likes", "downloads", "private", "library_name", "tags", "siblings"] {
            q.append(URLQueryItem(name: "expand[]", value: f))
        }
        c.queryItems = q
        return c.url!
    }

    /// The user's own runnable repos (MLX + GGUF, private and public), newest first. Needs the token
    /// for the private ones; anonymous it still works and lists the public ones. Short TTL: the user
    /// comes here right after a training job pushed a new repo.
    public func mine(author: String) async throws -> [Hit] {
        let data = try await fetch(mineURL(author: author), ttl: 120, repo: author)
        return try Self.parseMine(data).filter { $0.isTextGeneration }
    }

    /// Every repo the author owns (any library — the bf16 `transformers` twins the Train screen needs are not MLX/GGUF rows) with the
    /// loopl card metadata: `loopl_round` (rounds of continual tuning closed) and `loopl_parent` (an export's bf16 repo). 2-min TTL like `mine`.
    public struct OwnedRepo: Sendable, Hashable, Identifiable {
        public var id: String
        public var library: String?
        public var tags: [String]
        public var looplRound: Int?
        public var looplParent: String?
        public init(id: String, library: String? = nil, tags: [String] = [], looplRound: Int? = nil, looplParent: String? = nil) {
            self.id = id; self.library = library; self.tags = tags; self.looplRound = looplRound; self.looplParent = looplParent
        }
    }

    public func ownedURL(author: String, limit: Int = 500) -> URL {
        var c = URLComponents(string: "\(host)/api/models")!
        var q: [URLQueryItem] = [URLQueryItem(name: "author", value: author), URLQueryItem(name: "sort", value: "lastModified"),
                                 URLQueryItem(name: "limit", value: String(limit))]
        for f in ["cardData", "library_name", "tags", "private"] { q.append(URLQueryItem(name: "expand[]", value: f)) }
        c.queryItems = q
        return c.url!
    }

    public func owned(author: String) async throws -> [OwnedRepo] {
        try Self.parseOwned(try await fetch(ownedURL(author: author), ttl: 120, repo: author))
    }

    public static func parseOwned(_ data: Data) throws -> [OwnedRepo] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HubError.badJSON("owned") }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let card = row["cardData"] as? [String: Any] ?? [:]
            let round = (card["loopl_round"] as? NSNumber)?.intValue ?? (card["loopl_round"] as? String).flatMap(Int.init)
            return OwnedRepo(id: id, library: row["library_name"] as? String, tags: row["tags"] as? [String] ?? [],
                             looplRound: round, looplParent: card["loopl_parent"] as? String)
        }
    }

    public func repo(_ id: String) async throws -> Repo {
        let data = try await fetch(URL(string: "\(host)/api/models/\(id)?blobs=true")!, ttl: 86_400, repo: id)
        return try Self.parseRepo(data)
    }

    public func config(_ repo: String) async throws -> Config? {
        let url = URL(string: "\(host)/\(repo)/resolve/main/config.json")!
        do { return try Self.parseConfig(try await fetch(url, ttl: 86_400 * 7, repo: repo)) }
        catch HubError.http(404, _) { return nil }   // GGUF repos usually have none
    }

    /// Search hit → downloadable spec (repo detail + config.json, two cached requests).
    public func resolve(_ repoId: String, ggufFile: File? = nil) async throws -> ModelSpec {
        let r = try await repo(repoId)
        if r.gated { throw denied(repoId) }
        let c = r.kind == .mlx || r.files.contains { $0.path == "config.json" } ? try await config(repoId) : nil
        return try Self.spec(for: r, config: c, ggufFile: ggufFile)
    }
}

/// Tiny disk cache for Hub JSON (Caches/, purgeable). Key = a readable prefix of the URL + FNV-1a of the whole URL.
public struct HubCache: Sendable {
    public var directory: URL
    public init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? base.appendingPathComponent("loopl-hub", isDirectory: true)
    }
    public func path(_ url: URL) -> URL {
        let s = url.absoluteString
        let readable = String(s.dropFirst("https://huggingface.co/".count).unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.prefix(60))
        return directory.appendingPathComponent(readable + "-" + Self.fnv1a(s) + ".json")
    }
    /// 64-bit FNV-1a, hex — stable across launches, no CryptoKit dependency.
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
    public func read(_ url: URL, maxAge: TimeInterval) -> Data? {
        let p = path(url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p.path), let m = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(m) <= maxAge else { return nil }
        return try? Data(contentsOf: p)
    }
    public func write(_ url: URL, _ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: path(url), options: .atomic)
    }
    public func clear() { try? FileManager.default.removeItem(at: directory) }
}
