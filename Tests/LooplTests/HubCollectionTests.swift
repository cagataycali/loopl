import XCTest
import Loopl

/// The loopl collection, pinned on REAL Hub responses saved 2026-10-06 under Fixtures/hub:
///   hf-collection-loopl.json         GET /api/collections/cagataydev/loopl-on-device-agents-swift-6ac51395b13a9c41d4932eaf (Bearer — private)
///   hf-collection-loopl-models.json  GET /api/models?author=cagataydev&expand[]=… filtered to the collection's ids
final class HubCollectionTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        var url: URL?
        #if SWIFT_PACKAGE
        for sub in ["Fixtures/hub", "hub", nil] { if url == nil { url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: sub) } }
        #endif
        if url == nil {
            for sub in ["Fixtures/hub", "hub", nil] where url == nil {
                url = Bundle.allBundles.compactMap { $0.url(forResource: name, withExtension: "json", subdirectory: sub) }.first
            }
        }
        return try Data(contentsOf: XCTUnwrap(url, "fixture \(name) missing"))
    }

    func testSlugIsTheRealCollection() {
        XCTAssertEqual(LooplCollection.slug, "cagataydev/loopl-on-device-agents-swift-6ac51395b13a9c41d4932eaf")
        XCTAssertEqual(HubCatalog().collectionURL(LooplCollection.slug).absoluteString,
                       "https://huggingface.co/api/collections/cagataydev/loopl-on-device-agents-swift-6ac51395b13a9c41d4932eaf")
    }

    func testParseCollectionKeepsOrderNotesAndTypes() throws {
        let c = try HubCatalog.parseCollection(fixture("hf-collection-loopl"))
        XCTAssertEqual(c.slug, LooplCollection.slug)
        XCTAssertEqual(c.title, "loopl — on-device agents, Swift")
        XCTAssertTrue(c.isPrivate)
        XCTAssertEqual(c.items.count, 17)
        XCTAssertEqual(c.modelItems.count, 15)
        XCTAssertEqual(c.datasetItems.map(\.id), ["cagataydev/loopl-train", "cagataydev/loopl-app-conversations-test"])
        // Curator's order, not alphabetical: 4B first.
        XCTAssertEqual(c.items.first?.id, "cagataydev/loopl-4b-4bit")
        XCTAssertEqual(c.items.first?.note, "loopl 4B v1 — MLX 4-bit, vision. quiz 111 vs base 83 · tools 9/9·9/9.")
        XCTAssertTrue(c.items.allSatisfy(\.isPrivate))
        XCTAssertNotNil(c.items[0].numParameters)
    }

    func testRowsJoinListingDropBF16AndLoRAKeepOrder() throws {
        let c = try HubCatalog.parseCollection(fixture("hf-collection-loopl"))
        let listing = try HubCatalog.parseMine(fixture("hf-collection-loopl-models"))
        let rows = HubCatalog.rows(for: c, listing: listing)
        // 4 MLX (4b, 2b, 0.8b-v1.1, 0.8b) + 4 GGUF + the 2 app-trained MLX examples; bf16 merges + the LoRA adapter are not runnable.
        XCTAssertEqual(rows.map(\.id), ["cagataydev/loopl-4b-4bit", "cagataydev/loopl-2b-4bit", "cagataydev/loopl-0.8b-v1.1-4bit", "cagataydev/loopl-0.8b-4bit",
                                        "cagataydev/loopl-4b-GGUF", "cagataydev/loopl-2b-GGUF", "cagataydev/loopl-0.8b-v1.1-GGUF", "cagataydev/loopl-0.8b-GGUF",
                                        "cagataydev/loopl-app-sim-4bit", "cagataydev/loopl-app-e2e-vision-4bit"])
        let l = HubCollectionListing(collection: c, rows: rows, source: .network, updated: nil)
        XCTAssertEqual(l.mlx.count, 6)
        XCTAssertEqual(l.gguf.count, 4)
        XCTAssertEqual(l.hiddenModelCount, 5)
        // Vision badge from the FILES (preprocessor_config.json present), as #74 does — not from the architecture.
        let four = try XCTUnwrap(rows.first { $0.id == "cagataydev/loopl-4b-4bit" })
        XCTAssertTrue(four.hit.isVision)
        XCTAssertEqual(four.hit.bits, 4)
        XCTAssertTrue(four.hit.isPrivate)
        XCTAssertEqual(four.note, four.item.note)
        let gguf = try XCTUnwrap(rows.first { $0.id == "cagataydev/loopl-4b-GGUF" })
        XCTAssertEqual(gguf.kind, .gguf)
        XCTAssertFalse(gguf.hit.isVision)
    }

    func testRowsWithoutListingGuessFormatFromTheName() throws {
        // Anonymous user, private repos: the author listing is empty — the collection alone still yields runnable rows.
        let c = try HubCatalog.parseCollection(fixture("hf-collection-loopl"))
        let rows = HubCatalog.rows(for: c, listing: [])
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.filter { $0.kind == .mlx }.count, 6)
        XCTAssertEqual(rows.filter { $0.kind == .gguf }.count, 4)
        let two = try XCTUnwrap(rows.first { $0.id == "cagataydev/loopl-2b-4bit" })
        XCTAssertEqual(two.hit.bits, 4)
        XCTAssertNotNil(two.hit.sizeBytes)
        XCTAssertTrue(two.hit.isPrivate)
        XCTAssertNil(two.hit.files)
        XCTAssertFalse(rows.contains { $0.id == "cagataydev/loopl-4b-lora" || $0.id == "cagataydev/loopl-4b" })
    }

    func testGuessedKind() {
        XCTAssertEqual(HubCollection.Item(id: "a/loopl-2b-GGUF").guessedKind, .gguf)
        XCTAssertEqual(HubCollection.Item(id: "a/loopl-2b-4bit").guessedKind, .mlx)
        XCTAssertEqual(HubCollection.Item(id: "a/x-8bit").guessedKind, .mlx)
        XCTAssertNil(HubCollection.Item(id: "a/loopl-2b").guessedKind)
        XCTAssertNil(HubCollection.Item(id: "a/loopl-4b-lora").guessedKind)
    }

    func testSnapshotParsesLikeTheNetwork() throws {
        let root: [String: Any] = ["saved": "2026-10-06T16:00:00Z",
                                   "collection": try JSONSerialization.jsonObject(with: fixture("hf-collection-loopl")),
                                   "models": try JSONSerialization.jsonObject(with: fixture("hf-collection-loopl-models"))]
        let l = try HubCatalog.parseCollectionSnapshot(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(l.source, .bundled)
        XCTAssertEqual(l.updated, ISO8601DateFormatter().date(from: "2026-10-06T16:00:00Z"))
        XCTAssertEqual(l.rows.count, 10)
        XCTAssertEqual(l.collection.title, "loopl — on-device agents, Swift")
    }

    func testBundledSnapshotInTheAppIsCurrent() throws {
        // App/Resources/collection.json is what a first launch offline shows — it must parse and name the same slug.
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Resources/collection.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("App/Resources not available in this test host") }
        let l = try HubCatalog.parseCollectionSnapshot(Data(contentsOf: url))
        XCTAssertEqual(l.collection.slug, LooplCollection.slug)
        XCTAssertGreaterThanOrEqual(l.mlx.count, 3)
        XCTAssertGreaterThanOrEqual(l.gguf.count, 3)
    }
}
