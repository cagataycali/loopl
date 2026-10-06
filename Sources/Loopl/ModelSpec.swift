import Foundation

/// One entry of the bundled `models.json` catalog. Only public (non-gated)
/// repos are listed — loopl downloads anonymously.
public struct ModelSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String                 // stable key, e.g. "qwen3-1.7b-4bit"
    public var name: String
    public var repo: String               // Hugging Face repo id ("" for Apple FM)
    public var runtime: RuntimeKind
    public var family: ToolFamily         // manual tool-prompt dialect
    public var paramsB: Double            // billions of parameters
    public var sizeBytes: Int64           // weights on disk (from the repo listing)
    public var ctxNominal: Int            // max_position_embeddings
    public var ctxUsable8GB: Int          // what we budget on an 8 GB iPhone (RAM, not the model) — `ctxRecommended8GB` in the research catalog
    public var minRAMGB: Double
    public var gated: Bool                // private/gated repo → needs the user's HF token (Settings › Hugging Face); false for every public row
    public var notes: String?
    public var revision: String? = nil
    /// GGUF: the single file to download (e.g. `Qwen3-1.7B-Q4_K_M.gguf`).
    public var file: String? = nil
    /// Sampling temperature from the model card; `nil` → family default.
    public var temperature: Float? = nil
    /// Extra kwargs for the chat template (e.g. Qwen3 `enable_thinking: false`).
    public var chatTemplateKwargs: [String: JSONValue]? = nil
    /// `true` for Hub repos whose tool-call grammar loopl has not run on-device (`HubCatalog.detectFamily`).
    /// Curated rows leave it nil; the UI shows "tool calls unverified".
    public var toolsUnverified: Bool? = nil
    /// `true` when the checkpoint has a vision tower loopl can drive (Qwen3-VL, Qwen2.5-VL, Qwen3.5, Gemma 3, SmolVLM…, MLX runtime).
    /// Gates the composer's attach button; images sent to a text model are dropped with a notice.
    public var vision: Bool? = nil
    /// A built-in identity the app puts ahead of its own system prompt (`LooplPersona`). `cagataydev/loopl-*` and
    /// `loopl`-tagged Hub repos are `.loopl`; nil for everything else.
    public var persona: Persona? = nil

    public enum Persona: String, Sendable, Codable, Hashable {
        /// loopl v1+: post-tuned on cagataydev/loopl-train with `LooplPersona.systemPrompt` as the system turn of every sample.
        case loopl
    }

    public init(id: String, name: String, repo: String, runtime: RuntimeKind, family: ToolFamily, paramsB: Double, sizeBytes: Int64,
                ctxNominal: Int, ctxUsable8GB: Int, minRAMGB: Double, gated: Bool = false, notes: String? = nil, revision: String? = nil,
                file: String? = nil, temperature: Float? = nil, chatTemplateKwargs: [String: JSONValue]? = nil, toolsUnverified: Bool? = nil,
                vision: Bool? = nil, persona: Persona? = nil) {
        self.id = id; self.name = name; self.repo = repo; self.runtime = runtime; self.family = family; self.paramsB = paramsB
        self.sizeBytes = sizeBytes; self.ctxNominal = ctxNominal; self.ctxUsable8GB = ctxUsable8GB; self.minRAMGB = minRAMGB
        self.gated = gated; self.notes = notes; self.revision = revision; self.file = file; self.temperature = temperature
        self.chatTemplateKwargs = chatTemplateKwargs; self.toolsUnverified = toolsUnverified; self.vision = vision
        self.persona = persona
    }

    /// The identity prompt this model was trained with, resolved from `persona` or the repo name (`cagataydev/loopl-*`
    /// rows from an older models.json carry no `persona` key).
    public var hasLooplPersona: Bool { persona == .loopl || LooplPersona.applies(repo: repo, tags: []) }

    /// Can this model look at pictures? (`vision` flag; only the MLX runtime has a VLM path today.)
    public var supportsVision: Bool { vision == true && runtime == .mlx }

    /// Browsed on Hugging Face at runtime (id "hub:<repo>[:<file>]") rather than shipped in the curated catalog.
    public var isFromHub: Bool { id.hasPrefix("hub:") }

    enum CodingKeys: String, CodingKey {
        case id, name, repo, runtime, family, gated, notes, revision, file, temperature, vision, persona
        case chatTemplateKwargs = "chat_template_kwargs", toolsUnverified = "tools_unverified"
        case paramsB = "params_b", sizeBytes = "size_bytes", ctxNominal = "ctx_nominal"
        case ctxUsable8GB = "ctx_usable_8gb", minRAMGB = "min_ram_gb"
    }

    /// "968.1 MB" — or "size unknown" for a repo whose blob sizes Hugging Face did not report
    /// (never "Zero KB", see ``ByteSize``). Apple Intelligence rows are not downloadable at all.
    public var sizeLabel: String { ByteSize.label(sizeBytes, zero: "size unknown") }

    /// Apple Intelligence rows have no download.
    public var isDownloadable: Bool { runtime != .appleFM }

    /// Per-family sampling defaults from the model cards (Qwen3 non-thinking
    /// 0.7/0.8/0 · Llama 3 0.6/0.9 · Gemma 1.0/0.95 · Phi 0.7 · others 0.6/0.95).
    public var defaultTemperature: Float {
        if let temperature { return temperature }
        let r = repo.lowercased()
        if r.contains("qwen3") { return 0.7 }
        if r.contains("gemma") { return 1.0 }
        if r.contains("llama") { return 0.6 }
        if r.contains("phi") { return 0.7 }
        if r.contains("deepseek") { return 0.6 }
        return 0.6
    }
    public var defaultTopP: Float {
        let r = repo.lowercased()
        if r.contains("qwen3") { return 0.8 }
        if r.contains("llama") { return 0.9 }
        return 0.95
    }

    /// "Max out all the settings": context = the 8 GB recommendation (never above
    /// the model's own limit), no new-token cap, card temperature.
    public var defaultParams: GenerationParams {
        var p = GenerationParams()
        p.contextLength = max(512, min(ctxUsable8GB, ctxNominal))
        p.maxTokens = nil
        p.temperature = defaultTemperature
        p.topP = defaultTopP
        p.minP = repo.lowercased().contains("qwen3") ? 0 : 0.05
        return p
    }
}

public struct Catalog: Sendable, Codable {
    public var version: Int
    public var updated: String
    public var models: [ModelSpec]
    public var defaultModelId: String?
    enum CodingKeys: String, CodingKey { case version, updated, models, defaultModelId = "default" }

    public init(version: Int, updated: String, models: [ModelSpec], defaultModelId: String?) {
        self.version = version; self.updated = updated; self.models = models; self.defaultModelId = defaultModelId
    }

    public static func loadBundled(_ bundle: Bundle = .main) -> Catalog {
        guard let url = bundle.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return Catalog(version: 0, updated: "", models: [], defaultModelId: nil)
        }
        return c
    }

    public var defaultModel: ModelSpec? { models.first { $0.id == defaultModelId } ?? models.first { $0.isDownloadable } }
    public subscript(id: String) -> ModelSpec? { models.first { $0.id == id } }
}
