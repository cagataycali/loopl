import Foundation

/// Any public model on Hugging Face, turned into a `ModelSpec` at runtime.
///
/// Anonymous Hub API only (no token, no account): `GET /api/models?search=…`
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
    public init() {}

    // MARK: - Types

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

        public var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
        public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
        /// Hub search also returns ASR/TTS/embedding/vision checkpoints; chat needs a text generator.
        public var isTextGeneration: Bool {
            if let pipeline, pipeline != "text-generation" { return false }
            let t = (modelType ?? "").lowercased(), n = name.lowercased()
            for bad in ["asr", "tts", "embedding", "rerank", "_vl", "vl-", "-vl", "clip", "whisper", "omni", "audio", "speech", "mtp", "_mtp"] {
                if t.contains(bad) || n.contains(bad) { return false }
            }
            return true
        }
    }

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

    public struct Config: Sendable, Hashable, Codable {
        public var modelType: String?
        public var architectures: [String]
        public var maxPositionEmbeddings: Int?
        public var bits: Int?
        public var groupSize: Int?
        public init(modelType: String? = nil, architectures: [String] = [], maxPositionEmbeddings: Int? = nil, bits: Int? = nil, groupSize: Int? = nil) {
            self.modelType = modelType; self.architectures = architectures; self.maxPositionEmbeddings = maxPositionEmbeddings; self.bits = bits; self.groupSize = groupSize
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
        public init(id: String, sha: String?, gated: Bool, downloads: Int, likes: Int, pipeline: String?, files: [File],
                    modelType: String?, ggufContext: Int?, paramsB: Double?, lastModified: String?) {
            self.id = id; self.sha = sha; self.gated = gated; self.downloads = downloads; self.likes = likes; self.pipeline = pipeline
            self.files = files; self.modelType = modelType; self.ggufContext = ggufContext; self.paramsB = paramsB; self.lastModified = lastModified
        }

        public var kind: Kind { files.contains(where: \.isGGUF) && !files.contains(where: { $0.path.hasSuffix(".safetensors") }) ? .gguf : .mlx }
        public var ggufFiles: [File] { files.filter(\.isGGUF).filter { !$0.path.contains("/") }.sorted { $0.size < $1.size } }
        public var mlxFiles: [File] { files.filter { HFDownloader.wanted(.init(path: $0.path, size: $0.size, type: "file")) } }
        public var mlxBytes: Int64 { mlxFiles.reduce(0) { $0 + $1.size } }
        /// The quant we download when the user does not pick: Q4_K_M, else the closest 4-bit, else the smallest.
        public var preferredGGUF: File? {
            let one = ggufFiles.filter { !$0.path.lowercased().contains("imatrix") }
            return one.first { $0.quant == "Q4_K_M" } ?? one.first { ($0.quant ?? "").hasPrefix("Q4") } ?? one.first
        }
    }

    public enum HubError: LocalizedError {
        case offline, http(Int, String), gated(String), noWeights(String), badJSON(String)
        public var errorDescription: String? {
            switch self {
            case .offline: "offline mode is on — browsing Hugging Face needs the network (models already on this device still load)"
            case .http(let c, let p): "Hugging Face answered HTTP \(c) for \(p)"
            case .gated(let r): "\(r) is gated — loopl downloads public models only"
            case .noWeights(let r): "\(r) has no MLX safetensors and no .gguf file loopl can run"
            case .badJSON(let p): "unexpected response for \(p)"
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
            let bits = (config["quantization_config"] as? [String: Any])?["bits"] as? Int
            var size: Int64? = (gguf?["total"] as? NSNumber)?.int64Value
            var params: Double? = nil
            if let total = (st?["total"] as? NSNumber)?.doubleValue, total > 0 {
                params = total / 1e9
                if size == nil { size = Self.estimateMLXBytes(params: total, bits: bits) }
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
                       lastModified: row["lastModified"] as? String)
        }
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
                    lastModified: row["lastModified"] as? String)
    }

    public static func parseConfig(_ data: Data) throws -> Config {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HubError.badJSON("config.json") }
        let q = (row["quantization"] as? [String: Any]) ?? (row["quantization_config"] as? [String: Any])
        // Multimodal configs nest the LLM: text_config.max_position_embeddings.
        let text = row["text_config"] as? [String: Any]
        return Config(modelType: row["model_type"] as? String,
                      architectures: row["architectures"] as? [String] ?? [],
                      maxPositionEmbeddings: ((row["max_position_embeddings"] ?? text?["max_position_embeddings"]) as? NSNumber)?.intValue,
                      bits: (q?["bits"] as? NSNumber)?.intValue, groupSize: (q?["group_size"] as? NSNumber)?.intValue)
    }

    /// 4-bit MLX weights ≈ params × bits/8 × 1.125 (scales + biases per group of 64). Pinned on the curated rows.
    public static func estimateMLXBytes(params: Double, bits: Int?) -> Int64 {
        Int64(params * Double(bits ?? 16) / 8 * (bits == nil ? 1 : 1.125))
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
        var notes = "From Hugging Face · \(guess.label)"
        if !guess.verified { notes += " · tool calls unverified" }
        let qwen3 = repo.id.lowercased().contains("qwen3")
        return ModelSpec(id: id, name: name.replacingOccurrences(of: "_", with: " "), repo: repo.id,
                         runtime: kind.runtime, family: guess.family, paramsB: params ?? 0, sizeBytes: bytes,
                         ctxNominal: ctx, ctxUsable8GB: ctxUsable8GB(paramsB: params, ctxNominal: ctx),
                         minRAMGB: (Double(bytes) * 1.3 / 1e9).rounded(.up), gated: repo.gated,
                         notes: notes, revision: nil, file: file?.path, temperature: nil,
                         chatTemplateKwargs: qwen3 ? ["enable_thinking": .bool(false)] : nil,
                         toolsUnverified: guess.verified ? nil : true)
    }

    // MARK: - Network

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("loopl/0.3 (iOS)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// GET with the disk cache: offline → cached or `HubError.offline`; online → network, falling back to a stale copy on failure.
    func fetch(_ url: URL, ttl: TimeInterval) async throws -> Data {
        if let cache, let hit = cache.read(url, maxAge: ttl) { return hit }
        if NetworkPolicy.isOffline {
            if let cache, let stale = cache.read(url, maxAge: .infinity) { return stale }
            throw HubError.offline
        }
        do {
            let (data, resp) = try await NetworkPolicy.session.data(for: request(url))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw HubError.gated(url.lastPathComponent) }
            guard code == 200 else { throw HubError.http(code, url.path) }
            cache?.write(url, data)
            return data
        } catch let e as HubError {
            throw e
        } catch {
            if let cache, let stale = cache.read(url, maxAge: .infinity) { return stale }
            throw error
        }
    }

    public func searchURL(_ query: String, kind: Kind, limit: Int = 30) -> URL {
        var c = URLComponents(string: "\(host)/api/models")!
        var q = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "sort", value: "downloads"),
                 URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: String(limit))]
        switch kind {
        case .mlx: q.append(URLQueryItem(name: "author", value: "mlx-community"))
        case .gguf: q.append(URLQueryItem(name: "filter", value: "gguf"))
        }
        c.queryItems = q
        return c.url!
    }

    /// Top text-generation repos for a query (by downloads). Empty query → the most downloaded.
    public func search(_ query: String, kind: Kind, limit: Int = 30) async throws -> [Hit] {
        let data = try await fetch(searchURL(query, kind: kind, limit: limit), ttl: 3600)
        return try Self.parseSearch(data, kind: kind).filter { !$0.gated }
    }

    public func repo(_ id: String) async throws -> Repo {
        let data = try await fetch(URL(string: "\(host)/api/models/\(id)?blobs=true")!, ttl: 86_400)
        return try Self.parseRepo(data)
    }

    public func config(_ repo: String) async throws -> Config? {
        let url = URL(string: "\(host)/\(repo)/resolve/main/config.json")!
        do { return try Self.parseConfig(try await fetch(url, ttl: 86_400 * 7)) }
        catch HubError.http(404, _) { return nil }   // GGUF repos usually have none
    }

    /// Search hit → downloadable spec (repo detail + config.json, two cached requests).
    public func resolve(_ repoId: String, ggufFile: File? = nil) async throws -> ModelSpec {
        let r = try await repo(repoId)
        if r.gated { throw HubError.gated(repoId) }
        let c = r.kind == .mlx || r.files.contains { $0.path == "config.json" } ? try await config(repoId) : nil
        return try Self.spec(for: r, config: c, ggufFile: ggufFile)
    }
}

/// Tiny disk cache for Hub JSON (Caches/, purgeable). Key = SHA-free: the URL made file-safe.
public struct HubCache: Sendable {
    public var directory: URL
    public init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? base.appendingPathComponent("loopl-hub", isDirectory: true)
    }
    func path(_ url: URL) -> URL {
        let key = url.absoluteString.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return directory.appendingPathComponent(String(key.suffix(180)) + ".json")
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
