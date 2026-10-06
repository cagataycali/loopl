import XCTest
import Loopl

/// Vision truth from the FILES, not the architecture name — pinned on real Hub responses saved 2026-10-06
/// (owner's token for the private loopl repo; tags trimmed of base_model, no secrets):
///   repo-mlx-loopl-4b-4bit.json        GET /api/models/cagataydev/loopl-4b-4bit?blobs=true  (qwen3_5, text-generation, NO processor files)
///   config-mlx-loopl-4b-4bit.json      its config.json — model_type qwen3_5, Qwen3_5ForConditionalGeneration, NO vision_config
///   config-mlx-qwen3.5-0.8b-4bit.json  mlx-community/Qwen3.5-0.8B-4bit config.json — vision_config present
///   search-mlx-qwen3.5-siblings.json   GET /api/models?search=Qwen3.5-0.8B&author=mlx-community&…&expand[]=siblings
/// The owner's report: Models › Mine badged loopl-4b "vision" (model_type ⇒ vision) while 0/924 tensors are visual.
final class VisionTruthTests: XCTestCase {
    func fixture(_ name: String) throws -> Data { try HubCatalogTests().fixture(name) }

    // MARK: config.json is the truth

    func testConfigHasVisionConfigDecidesTheTower() throws {
        let base = try HubCatalog.parseConfig(fixture("config-mlx-qwen3.5-0.8b-4bit"))
        XCTAssertEqual(base.modelType, "qwen3_5")
        XCTAssertEqual(base.hasVisionConfig, true)
        let loopl = try HubCatalog.parseConfig(fixture("config-mlx-loopl-4b-4bit"))
        XCTAssertEqual(loopl.modelType, "qwen3_5", "same architecture name…")
        XCTAssertEqual(loopl.architectures, ["Qwen3_5ForConditionalGeneration"])
        XCTAssertEqual(loopl.hasVisionConfig, false, "…but the merge dropped the tower: no vision_config")
        XCTAssertEqual(loopl.maxPositionEmbeddings, 262_144, "text_config.max_position_embeddings still read")
        // Older fixture (text model, no vision keys) → false, not nil: the file was read.
        XCTAssertEqual(try HubCatalog.parseConfig(fixture("config-mlx-qwen2.5-1.5b")).hasVisionConfig, false)
    }

    func testHasVisionConfigAcceptsEveryVisionKeyShape() {
        XCTAssertTrue(HubCatalog.hasVisionConfig(["vision_config": ["depth": 24]]))
        XCTAssertTrue(HubCatalog.hasVisionConfig(["visual": ["depth": 32]]))          // older Qwen-VL exports
        XCTAssertTrue(HubCatalog.hasVisionConfig(["vision_tower": [:]]))
        XCTAssertFalse(HubCatalog.hasVisionConfig(["vision_config": NSNull()]))      // explicit null = none
        XCTAssertFalse(HubCatalog.hasVisionConfig(["model_type": "qwen3_5", "image_token_id": 248056]), "token ids alone are not a tower")
    }

    // MARK: the Hub listing (no config.json yet) — file list beats model_type

    func testLooplRepoIsNotVisionWhenTheFilesSaySo() throws {
        let repo = try HubCatalog.parseRepo(fixture("repo-mlx-loopl-4b-4bit"))
        XCTAssertEqual(repo.modelType, "qwen3_5")
        XCTAssertEqual(repo.pipeline, "text-generation")
        XCTAssertTrue(repo.isPrivate)
        XCTAssertFalse(repo.files.contains { $0.path == "preprocessor_config.json" })
        XCTAssertFalse(repo.isVision, "qwen3_5 with no processor files and a text-generation tag = text-only export")
        XCTAssertEqual(repo.tags?.contains("loopl"), true)
        // Without config.json the spec already says text-only; with it, the same.
        let spec = try HubCatalog.spec(for: repo, config: nil)
        XCTAssertNil(spec.vision); XCTAssertFalse(spec.supportsVision)
        XCTAssertEqual(spec.repo, "cagataydev/loopl-4b-4bit")
        let withConfig = try HubCatalog.spec(for: repo, config: HubCatalog.parseConfig(fixture("config-mlx-loopl-4b-4bit")))
        XCTAssertFalse(withConfig.supportsVision)
        XCTAssertFalse(withConfig.notes?.contains("vision") ?? false)
        XCTAssertEqual(withConfig.ctxNominal, 262_144)
    }

    func testConfigOverridesTheListingWhenTheyDisagree() throws {
        // A repo the Hub still tags image-text-to-text whose config.json has no tower (an export in flight) → text-only;
        // and the reverse: an un-tagged mirror whose config.json has vision_config → vision.
        let repo = HubCatalog.Repo(id: "someone/Mirror-4bit", sha: nil, gated: false, downloads: 0, likes: 0, pipeline: "image-text-to-text",
                                   files: [.init(path: "config.json", size: 1), .init(path: "model.safetensors", size: 10)],
                                   modelType: "qwen3_5", ggufContext: nil, paramsB: 0.8, lastModified: nil)
        XCTAssertTrue(repo.isVision)
        XCTAssertFalse(try HubCatalog.spec(for: repo, config: .init(modelType: "qwen3_5", hasVisionConfig: false)).supportsVision)
        var plain = repo; plain.pipeline = nil; plain.modelType = "mystery"
        XCTAssertFalse(plain.isVision)
        XCTAssertTrue(try HubCatalog.spec(for: plain, config: .init(modelType: "mystery", hasVisionConfig: true)).supportsVision)
    }

    func testSearchHitsReadSiblingsForTheBadge() throws {
        let hits = try HubCatalog.parseSearch(fixture("search-mlx-qwen3.5-siblings"), kind: .mlx)
        let base = try XCTUnwrap(hits.first { $0.id == "mlx-community/Qwen3.5-0.8B-4bit" })
        XCTAssertEqual(base.files?.contains("preprocessor_config.json"), true)
        XCTAssertTrue(base.isVision)
        // An mlx-community row with NO pipeline_tag but the processor files → still vision (files decide).
        let untagged = try XCTUnwrap(hits.first { $0.pipeline == nil })
        XCTAssertEqual(untagged.files?.contains("preprocessor_config.json"), true)
        XCTAssertTrue(untagged.isVision)
        // The same architecture listed WITHOUT processor files and tagged text-generation (what /api/models?author= returns for loopl-*-4bit).
        let row: [String: Any] = ["id": "cagataydev/loopl-4b-4bit", "pipeline_tag": "text-generation", "config": ["model_type": "qwen3_5"],
                                  "tags": ["mlx", "loopl"], "private": true,
                                  "siblings": ["config.json", "model.safetensors", "tokenizer.json", "chat_template.jinja"].map { ["rfilename": $0] }]
        let mine = try HubCatalog.parseMine(JSONSerialization.data(withJSONObject: [row]))
        XCTAssertEqual(mine.count, 1)
        XCTAssertFalse(mine[0].isVision, "Mine badge: qwen3_5 without an image processor is text-only")
        XCTAssertTrue(mine[0].isTextGeneration)
        // Older cached rows without siblings keep the architecture heuristic (no regression for Qwen3-VL mirrors).
        XCTAssertTrue(HubCatalog.isVision(repo: "mlx-community/Qwen3-VL-4B-Instruct-4bit", pipeline: nil, modelType: "qwen3_vl", files: nil))
        XCTAssertTrue(HubCatalog.isVision(repo: "x/y", pipeline: nil, modelType: "qwen3_5", files: []))
        XCTAssertFalse(HubCatalog.isVision(repo: "x/Qwen3.5-0.8B-Text-4bit", pipeline: "image-text-to-text", modelType: "qwen3_5", files: ["preprocessor_config.json"]))
    }

    func testSearchAndMineURLsExpandSiblings() {
        let hub = HubCatalog()
        XCTAssertTrue(hub.searchURL("qwen", kind: .mlx).absoluteString.contains("expand%5B%5D=siblings"))
        XCTAssertTrue(hub.mineURL(author: "me").absoluteString.contains("expand%5B%5D=siblings"))
    }

    // MARK: what a vision download must fetch

    func testDownloaderWantsTheImageProcessorConfigs() {
        for name in ["preprocessor_config.json", "processor_config.json", "video_preprocessor_config.json", "config.json", "model.safetensors"] {
            XCTAssertTrue(HFDownloader.wanted(.init(path: name, size: 1, type: "file")), name)
        }
        for name in ["README.md", "scorecard.json", "train_summary.json", "images/preprocessor_config.json"] {
            XCTAssertFalse(HFDownloader.wanted(.init(path: name, size: 1, type: "file")), name)
        }
    }

    // MARK: the files on the phone

    func testLocalConfigDecidesAfterDownload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-truth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(LocalModelFiles.hasVisionTower(in: dir), "no config.json → unknown, not false")
        try fixture("config-mlx-loopl-4b-4bit").write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(LocalModelFiles.hasVisionTower(in: dir), false)
        try fixture("config-mlx-qwen3.5-0.8b-4bit").write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(LocalModelFiles.hasVisionTower(in: dir), true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertNil(LocalModelFiles.hasVisionTower(in: dir))
    }

    // MARK: ModelSpec round trip

    func testRowsWithTheOldPersonaKeyStillDecode() throws {
        // models.json shipped `"persona": "loopl"` for one build (0.1.0 (8)); the key is gone with the built-in identity
        // (the owner's 15:2xZ decision: identity lives in the weights, the system prompt is the user's). Old rows must still load.
        let json = """
        {"id":"loopl-4b-4bit","name":"loopl 4B","repo":"cagataydev/loopl-4b-4bit","runtime":"mlx","family":"hermes","params_b":4,"size_bytes":1,
         "ctx_nominal":262144,"ctx_usable_8gb":8192,"min_ram_gb":6,"gated":true,"vision":false,"persona":"loopl"}
        """
        let old = try JSONDecoder().decode(ModelSpec.self, from: Data(json.utf8))
        XCTAssertEqual(old.repo, "cagataydev/loopl-4b-4bit"); XCTAssertFalse(old.supportsVision)
        let back = try JSONDecoder().decode(ModelSpec.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(back.id, old.id)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("persona"), "nothing re-encodes the dropped key")
    }

    func testBundledLooplRowsAreGatedWithVisionPerRuntime() throws {
        // SwiftPM: Fixtures/models.json via Bundle.module; Xcode-hosted: the app bundle's models.json.
        var url: URL?
        #if SWIFT_PACKAGE
        url = Bundle.module.url(forResource: "models", withExtension: "json", subdirectory: "Fixtures")
        #endif
        if url == nil { url = Bundle.allBundles.compactMap { $0.url(forResource: "models", withExtension: "json") }.first }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: XCTUnwrap(url)))
        let loopl = catalog.models.filter { $0.repo.hasPrefix("cagataydev/loopl-") }
        XCTAssertEqual(loopl.count, 6)
        for row in loopl {
            XCTAssertTrue(row.gated, row.id)
            // VISION-EXPORT READY (2026-10-06 13:3xZ): the -4bit repos are mlx_vlm exports WITH the tower (vision_tower.* + processor
            // configs, revs de32efa9 / 8c2afdb4 / 413f2c66); GGUF stays text-only (the GGUF runtime has no image path).
            XCTAssertEqual(row.vision, row.runtime == .mlx, "\(row.id)")
            XCTAssertEqual(row.supportsVision, row.runtime == .mlx, row.id)
        }
    }
}
