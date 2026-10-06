import Foundation

/// The loopl collection on Hugging Face — the ONE place its id lives. The Models tab lists the collection's
/// runnable items (MLX 4-bit with the vision badge, GGUF under a disclosure) so whoever installs the app
/// sees and downloads the loopl models. Change the slug here and nowhere else.
public enum LooplCollection {
    /// `GET https://huggingface.co/api/collections/<slug>` — namespace/title-slug-id.
    public static let slug = "cagataydev/loopl-on-device-agents-swift-6ac51395b13a9c41d4932eaf"
    public static var url: URL { URL(string: "https://huggingface.co/collections/\(slug)")! }
}

/// A Hugging Face collection (`/api/collections/{namespace}/{slug-id}`): title, note per item, items in the
/// curator's order. Parsing is pure and pinned on a saved response (`Fixtures/hub/hf-collection-loopl.json`).
public struct HubCollection: Sendable, Hashable, Codable {
    public var slug: String
    public var title: String
    public var description: String?
    /// ISO-8601 from the Hub (`lastUpdated`).
    public var lastUpdated: String?
    public var isPrivate: Bool
    public var items: [Item]

    public struct Item: Sendable, Hashable, Codable, Identifiable {
        /// Repo id ("cagataydev/loopl-2b-4bit") — or a paper/space id for non-repo items.
        public var id: String
        /// "model" · "dataset" · "space" · "paper" · "collection".
        public var type: String
        /// The curator's one-line note (`note.text`) — the row subtitle.
        public var note: String?
        public var isPrivate: Bool
        public var gated: Bool
        public var pipeline: String?
        public var numParameters: Int64?
        public var lastModified: String?
        public var downloads: Int
        public var likes: Int

        public init(id: String, type: String = "model", note: String? = nil, isPrivate: Bool = false, gated: Bool = false, pipeline: String? = nil,
                    numParameters: Int64? = nil, lastModified: String? = nil, downloads: Int = 0, likes: Int = 0) {
            self.id = id; self.type = type; self.note = note; self.isPrivate = isPrivate; self.gated = gated; self.pipeline = pipeline
            self.numParameters = numParameters; self.lastModified = lastModified; self.downloads = downloads; self.likes = likes
        }
        public var isModel: Bool { type == "model" }
        /// Worked examples the curator keeps in the collection (models trained FROM the app: `loopl-app-*`, note "Example: …") —
        /// documentation, not something to download: the Models tab hides them.
        public var isExample: Bool { name.lowercased().hasPrefix("loopl-app-") || (note ?? "").lowercased().hasPrefix("example") }
        public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
        public var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
        /// Format guessed from the NAME alone (used when the author listing could not be fetched): `*-GGUF` →
        /// GGUF, `*-Nbit` → MLX, anything else (bf16 merges, LoRA adapters) is not runnable on the phone.
        public var guessedKind: HubCatalog.Kind? {
            let n = name.lowercased()
            if n.hasSuffix("-gguf") || n.contains("gguf") { return .gguf }
            if n.range(of: #"-\d+bit$"#, options: .regularExpression) != nil || n.contains("-mlx") { return .mlx }
            return nil
        }
    }

    public init(slug: String, title: String, description: String? = nil, lastUpdated: String? = nil, isPrivate: Bool = false, items: [Item]) {
        self.slug = slug; self.title = title; self.description = description; self.lastUpdated = lastUpdated; self.isPrivate = isPrivate; self.items = items
    }

    /// Model items only (examples excluded), in collection order.
    public var modelItems: [Item] { items.filter { $0.isModel && !$0.isExample } }
    public var datasetItems: [Item] { items.filter { $0.type == "dataset" } }
}

/// One Models-tab row of the collection: the curator's item (order, note) joined with the Hub's row
/// (format, size, files → vision badge). `hit` is what the details sheet and the download path consume.
public struct HubCollectionRow: Sendable, Hashable, Identifiable {
    public var item: HubCollection.Item
    public var hit: HubCatalog.Hit
    public var id: String { item.id }
    public init(item: HubCollection.Item, hit: HubCatalog.Hit) { self.item = item; self.hit = hit }
    public var kind: HubCatalog.Kind { hit.kind }
    public var note: String? { item.note }
}

/// The collection plus its resolved rows and where they came from — what the Models tab renders.
public struct HubCollectionListing: Sendable, Hashable {
    public enum Source: Sendable, Hashable { case network, cache, bundled }
    public var collection: HubCollection
    public var rows: [HubCollectionRow]
    public var source: Source
    /// When the rows were last confirmed against the Hub (cache file date / snapshot date / now).
    public var updated: Date?
    public init(collection: HubCollection, rows: [HubCollectionRow], source: Source, updated: Date?) {
        self.collection = collection; self.rows = rows; self.source = source; self.updated = updated
    }
    public var mlx: [HubCollectionRow] { rows.filter { $0.kind == .mlx } }
    public var gguf: [HubCollectionRow] { rows.filter { $0.kind == .gguf } }
    /// Model items the listing could not turn into a runnable row (bf16 merges, LoRA adapters) — hidden, counted for the footer.
    public var hiddenModelCount: Int { collection.modelItems.count - rows.count }
}

extension HubCatalog {
    // MARK: - Collections

    public func collectionURL(_ slug: String) -> URL { URL(string: "\(host)/api/collections/\(slug)")! }

    /// `GET /api/collections/<slug>`. Anonymous works for a PUBLIC collection; a private one needs the owner's
    /// Bearer (`token`) and otherwise surfaces as `HubError.signInRequired`. Cached 10 minutes; offline or on a
    /// network error the last copy is served (the `fetch` contract).
    public func collection(_ slug: String = LooplCollection.slug) async throws -> HubCollection {
        let data = try await fetch(collectionURL(slug), ttl: 600, repo: slug)
        return try Self.parseCollection(data)
    }

    /// Date of the cached collection answer (network or stale), nil when nothing is cached yet.
    public func collectionCachedAt(_ slug: String = LooplCollection.slug) -> Date? {
        guard let cache else { return nil }
        let url = collectionURL(slug)
        let key = bearer == nil ? url : Self.cacheKey(url)
        return (try? FileManager.default.attributesOfItem(atPath: cache.path(key).path))?[.modificationDate] as? Date
    }

    public static func parseCollection(_ data: Data) throws -> HubCollection {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], let slug = row["slug"] as? String else { throw HubError.badJSON("collection") }
        let items = (row["items"] as? [[String: Any]] ?? []).compactMap { it -> HubCollection.Item? in
            guard let id = it["id"] as? String else { return nil }
            let note = (it["note"] as? [String: Any])?["text"] as? String
            return HubCollection.Item(id: id, type: (it["type"] as? String) ?? (it["repoType"] as? String) ?? "model",
                                      note: note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? note : nil,
                                      isPrivate: (it["private"] as? Bool) ?? false, gated: gatedFlag(it["gated"]),
                                      pipeline: it["pipeline_tag"] as? String,
                                      numParameters: (it["numParameters"] as? NSNumber)?.int64Value,
                                      lastModified: it["lastModified"] as? String,
                                      downloads: (it["downloads"] as? NSNumber)?.intValue ?? 0,
                                      likes: (it["likes"] as? NSNumber)?.intValue ?? 0)
        }
        return HubCollection(slug: slug, title: (row["title"] as? String) ?? slug, description: row["description"] as? String,
                             lastUpdated: row["lastUpdated"] as? String, isPrivate: (row["private"] as? Bool) ?? false, items: items)
    }

    /// Join the collection's model items with the Hub's rows (`/api/models?author=…` — one request per author,
    /// `expand[]=siblings` gives the file list the vision badge reads, exactly as Browse/Mine do). Items the
    /// listing does not know (private + anonymous, or the listing failed) fall back to a thin row guessed from the
    /// name when the name says MLX/GGUF; bf16 merges, LoRA adapters, datasets are dropped. Order = collection order.
    public static func rows(for collection: HubCollection, listing: [Hit]) -> [HubCollectionRow] {
        let byId = Dictionary(listing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return collection.modelItems.compactMap { item in
            if let hit = byId[item.id] {
                var h = hit
                if item.isPrivate { h.isPrivate = true }
                return HubCollectionRow(item: item, hit: h)
            }
            guard let kind = item.guessedKind else { return nil }
            let bits = bitsFromName(item.id)
            let params = item.numParameters.map { Double($0) / 1e9 } ?? paramsB(fromName: item.id)
            let size: Int64? = item.numParameters.flatMap { n in kind == .mlx ? estimateMLXBytes(params: Double(n), bits: bits) : nil }
            let hit = Hit(id: item.id, kind: kind, downloads: item.downloads, likes: item.likes, gated: item.gated, pipeline: item.pipeline,
                          modelType: nil, bits: bits, ctx: nil, sizeBytes: size, paramsB: params, lastModified: item.lastModified,
                          isPrivate: item.isPrivate, files: nil)
            return HubCollectionRow(item: item, hit: hit)
        }
    }

    /// The whole listing: collection → per-author Hub rows → joined rows. The author listing is best effort
    /// (anonymous + private repos = empty, offline = cached) — the collection itself decides what is shown.
    public func collectionListing(_ slug: String = LooplCollection.slug) async throws -> HubCollectionListing {
        let c = try await collection(slug)
        var hits: [Hit] = []
        for author in Set(c.modelItems.map(\.author)).sorted() where !author.isEmpty {
            if let rows = try? await mine(author: author) { hits += rows }
        }
        let cachedAt = collectionCachedAt(slug)
        let fromNetwork = cachedAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        return HubCollectionListing(collection: c, rows: Self.rows(for: c, listing: hits), source: fromNetwork ? .network : .cache, updated: cachedAt)
    }

    /// Bundled snapshot (`App/Resources/collection.json`, written by `scripts/sync-collection.sh`):
    /// `{"saved": "<iso>", "collection": <api json>, "models": <api listing json>}` — first launch offline still lists the models.
    public static func parseCollectionSnapshot(_ data: Data) throws -> HubCollectionListing {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let coll = root["collection"] else { throw HubError.badJSON("collection snapshot") }
        let c = try parseCollection(JSONSerialization.data(withJSONObject: coll))
        let hits = try (root["models"]).map { try parseMine(JSONSerialization.data(withJSONObject: $0)) } ?? []
        let saved = (root["saved"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return HubCollectionListing(collection: c, rows: rows(for: c, listing: hits), source: .bundled, updated: saved)
    }
}
