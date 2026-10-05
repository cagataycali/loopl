import Foundation

/// One entry of the bundled `models.json` catalog.
public struct ModelSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String                 // stable key, e.g. "qwen3-1.7b-4bit"
    public var name: String
    public var repo: String               // Hugging Face repo id
    public var runtime: RuntimeKind
    public var family: ToolFamily         // manual tool-prompt dialect
    public var paramsB: Double            // billions of parameters
    public var sizeBytes: Int64           // 4-bit weights on disk (approx, from the repo)
    public var ctxNominal: Int            // max_position_embeddings
    public var ctxUsable8GB: Int          // what we budget on an 8 GB iPhone (RAM, not the model)
    public var minRAMGB: Double
    public var gated: Bool                // needs an accepted licence + HF token
    public var notes: String?
    public var revision: String? = nil
    /// Extra kwargs for the chat template (e.g. Qwen3 `enable_thinking: false`).
    public var chatTemplateKwargs: [String: JSONValue]? = nil

    public init(id: String, name: String, repo: String, runtime: RuntimeKind, family: ToolFamily, paramsB: Double, sizeBytes: Int64,
                ctxNominal: Int, ctxUsable8GB: Int, minRAMGB: Double, gated: Bool, notes: String? = nil, revision: String? = nil,
                chatTemplateKwargs: [String: JSONValue]? = nil) {
        self.id = id; self.name = name; self.repo = repo; self.runtime = runtime; self.family = family; self.paramsB = paramsB
        self.sizeBytes = sizeBytes; self.ctxNominal = ctxNominal; self.ctxUsable8GB = ctxUsable8GB; self.minRAMGB = minRAMGB
        self.gated = gated; self.notes = notes; self.revision = revision; self.chatTemplateKwargs = chatTemplateKwargs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, repo, runtime, family, gated, notes, revision
        case chatTemplateKwargs = "chat_template_kwargs"
        case paramsB = "params_b", sizeBytes = "size_bytes", ctxNominal = "ctx_nominal"
        case ctxUsable8GB = "ctx_usable_8gb", minRAMGB = "min_ram_gb"
    }

    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }

    /// Apple Intelligence rows have no download.
    public var isDownloadable: Bool { runtime != .appleFM }
}

public struct Catalog: Sendable, Codable {
    public var version: Int
    public var updated: String
    public var models: [ModelSpec]
    enum CodingKeys: String, CodingKey { case version, updated, models, defaultModelId = "default" }

    public var defaultModelId: String?

    public static func loadBundled(_ bundle: Bundle = .main) -> Catalog {
        guard let url = bundle.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return Catalog(version: 0, updated: "", models: [], defaultModelId: nil)
        }
        return c
    }
}
