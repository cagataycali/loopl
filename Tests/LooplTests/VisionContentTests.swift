import XCTest
@testable import Loopl

final class VisionContentTests: XCTestCase {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52])
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1])
    let webp = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)
    let heic = Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0])

    func testMimeSniffing() {
        XCTAssertEqual(ImageBlock.detectMime(png), "image/png")
        XCTAssertEqual(ImageBlock.detectMime(jpeg), "image/jpeg")
        XCTAssertEqual(ImageBlock.detectMime(webp), "image/webp")
        XCTAssertEqual(ImageBlock.detectMime(heic), "image/heic")
        XCTAssertNil(ImageBlock.detectMime(Data("hello world!".utf8)))
        XCTAssertEqual(ImageBlock(data: jpeg).format, "jpeg")
        XCTAssertEqual(ImageBlock(data: png, mime: "image/png", width: 640, height: 400).pixelCount, 256_000)
    }

    func testUserMessageWithImagesAndTemplateDictionariesStayTextOnly() {
        let img = ImageBlock(data: png, mime: "image/png", width: 640, height: 400, alt: "test")
        let m = Message.user("what is this?", images: [img])
        XCTAssertEqual(m.content.count, 2)
        XCTAssertEqual(m.text, "what is this?")
        XCTAssertEqual(m.images, [img])
        XCTAssertTrue(m.hasImage)
        // The brief's spelling.
        XCTAssertEqual(ContentBlock.image(png, mime: "image/png").image?.mime, "image/png")
        // Text models never see bytes: the template dictionaries carry the text only.
        let d = m.templateDictionaries
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0]["content"] as? String, "what is this?")
        XCTAssertNil(d[0]["images"])
        // Image-only turn is legal (the app substitutes a prompt; the SDK stays neutral).
        XCTAssertEqual(Message.user("", images: [img]).content.count, 1)
    }

    func testCodableRoundTripAndBackCompat() throws {
        let img = ImageBlock(data: jpeg, mime: "image/jpeg", width: 12, height: 8, alt: "a")
        let m = Message.user("hi", images: [img])
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"image\""))
        // A ToolResult saved before `images` existed still decodes (history files).
        let legacy = Data(#"{"toolUseId":"t1","name":"calculator","status":"success","content":"3","durationMs":1}"#.utf8)
        let r = try JSONDecoder().decode(ToolResult.self, from: legacy)
        XCTAssertEqual(r.images, [])
        // A ToolResult with a produced image round-trips and keeps `content` for the model.
        let produced = ToolResult(toolUseId: "t2", name: "generate_image", content: "a cat on a mat", images: [img])
        let back2 = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(produced))
        XCTAssertEqual(back2.images.count, 1)
        XCTAssertEqual(back2.content, "a cat on a mat")
    }

    func testTokenEstimateCountsImages() {
        let small = ImageBlock(data: png, mime: "image/png", width: 280, height: 280)   // 100 patches of 28²
        XCTAssertEqual(TokenEstimator.estimate(image: small), 100)
        let unknown = ImageBlock(data: png, mime: "image/png")
        XCTAssertEqual(TokenEstimator.estimate(image: unknown), 1280, "unknown size → the processor ceiling")
        let huge = ImageBlock(data: png, mime: "image/png", width: 4000, height: 3000)
        XCTAssertEqual(TokenEstimator.estimate(image: huge), 1280, "never above the ceiling")
        XCTAssertGreaterThan(TokenEstimator.estimate(Message.user("x", images: [small])), 100)
    }

    func testTranscriptCarriesImages() {
        var t = Transcript()
        let img = ImageBlock(data: png, mime: "image/png")
        t.user("look", images: [img])
        XCTAssertEqual(t.items.last?.images, [img])
        let use = ToolUse(toolUseId: "u1", name: "generate_image", input: ["prompt": .string("cat")])
        t.apply(.toolStarted(use))
        t.apply(.toolResult(ToolResult(toolUseId: "u1", name: "generate_image", content: "done", images: [img])))
        XCTAssertEqual(t.items.last?.images.count, 1)
    }

    func testModelSpecVisionFlag() throws {
        let vl = ModelSpec(id: "v", name: "V", repo: "mlx-community/Qwen3-VL-2B-Instruct-4bit", runtime: .mlx, family: .hermes, paramsB: 2, sizeBytes: 1,
                           ctxNominal: 4096, ctxUsable8GB: 4096, minRAMGB: 3, vision: true)
        XCTAssertTrue(vl.supportsVision)
        let text = ModelSpec(id: "t", name: "T", repo: "mlx-community/Qwen3-1.7B-4bit", runtime: .mlx, family: .hermes, paramsB: 2, sizeBytes: 1,
                             ctxNominal: 4096, ctxUsable8GB: 4096, minRAMGB: 3)
        XCTAssertFalse(text.supportsVision)
        let gguf = ModelSpec(id: "g", name: "G", repo: "x/y", runtime: .gguf, family: .hermes, paramsB: 2, sizeBytes: 1,
                             ctxNominal: 4096, ctxUsable8GB: 4096, minRAMGB: 3, vision: true)
        XCTAssertFalse(gguf.supportsVision, "GGUF has no vision path yet — MLX only")
        let json = Data(#"{"id":"a","name":"A","repo":"r","runtime":"mlx","family":"hermes","params_b":1,"size_bytes":1,"ctx_nominal":1,"ctx_usable_8gb":1,"min_ram_gb":1,"gated":false,"vision":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ModelSpec.self, from: json).vision, true)
    }

    func testHubVisionDetection() {
        XCTAssertTrue(HubCatalog.isVision(repo: "mlx-community/Qwen3-VL-4B-Instruct-4bit", pipeline: "image-text-to-text", modelType: "qwen3_vl"))
        XCTAssertTrue(HubCatalog.isVision(repo: "mlx-community/Qwen3.5-4B-4bit", pipeline: nil, modelType: "qwen3_5"), "untagged mirror → model_type")
        XCTAssertTrue(HubCatalog.isVision(repo: "someone/My-VL-Model-4bit", pipeline: nil, modelType: nil), "name heuristic")
        XCTAssertFalse(HubCatalog.isVision(repo: "mlx-community/Qwen3-1.7B-4bit", pipeline: "text-generation", modelType: "qwen3"))
        XCTAssertFalse(HubCatalog.isVision(repo: "mlx-community/Qwen3.5-2B-Text-4bit", pipeline: nil, modelType: "qwen3_5_text"), "text-only export")
        // Search rows: MLX vision passes, GGUF vision does not (no mtmd path).
        let mlx = HubCatalog.Hit(id: "mlx-community/Qwen3-VL-2B-Instruct-4bit", kind: .mlx, downloads: 1, likes: 1, gated: false, pipeline: "image-text-to-text",
                                 modelType: "qwen3_vl", bits: 4, ctx: nil, sizeBytes: nil, paramsB: 2, lastModified: nil)
        XCTAssertTrue(mlx.isVision); XCTAssertTrue(mlx.isTextGeneration)
        let gguf = HubCatalog.Hit(id: "bartowski/Qwen3-VL-2B-GGUF", kind: .gguf, downloads: 1, likes: 1, gated: false, pipeline: "image-text-to-text",
                                  modelType: "qwen3vl", bits: nil, ctx: nil, sizeBytes: nil, paramsB: 2, lastModified: nil)
        XCTAssertFalse(gguf.isTextGeneration)
        XCTAssertEqual(HubCatalog.fitBytes(weights: 1_000, vision: true), 1_150)
        XCTAssertEqual(HubCatalog.fitBytes(weights: 1_000, vision: false), 1_000)
    }

    func testHubSpecMarksVisionAndRefusesGGUFVision() throws {
        let files = [HubCatalog.File(path: "model.safetensors", size: 1_800_000_000), .init(path: "config.json", size: 1_000)]
        let repo = HubCatalog.Repo(id: "mlx-community/Qwen3-VL-2B-Instruct-4bit", sha: nil, gated: false, downloads: 1, likes: 1, pipeline: "image-text-to-text",
                                   files: files, modelType: "qwen3_vl", ggufContext: nil, paramsB: 2, lastModified: nil)
        let spec = try HubCatalog.spec(for: repo, config: .init(modelType: "qwen3_vl", maxPositionEmbeddings: 262144))
        XCTAssertEqual(spec.vision, true)
        XCTAssertTrue(spec.supportsVision)
        XCTAssertTrue(spec.notes?.contains("vision") == true)
        let g = HubCatalog.Repo(id: "x/Qwen3-VL-2B-GGUF", sha: nil, gated: false, downloads: 1, likes: 1, pipeline: "image-text-to-text",
                                files: [.init(path: "q.Q4_K_M.gguf", size: 1)], modelType: "qwen3vl", ggufContext: 4096, paramsB: 2, lastModified: nil)
        XCTAssertThrowsError(try HubCatalog.spec(for: g, config: nil)) { e in
            XCTAssertTrue((e as? HubCatalog.HubError).map { if case .visionGGUF = $0 { return true }; return false } ?? false)
        }
    }

    func testCatalogVisionRows() throws {
        // SwiftPM: Fixtures/models.json via Bundle.module; Xcode-hosted: the app bundle's models.json (same pattern as PromptBuilderTests).
        var url: URL?
        #if SWIFT_PACKAGE
        url = Bundle.module.url(forResource: "models", withExtension: "json", subdirectory: "Fixtures")
        #endif
        if url == nil { url = Bundle.allBundles.compactMap { $0.url(forResource: "models", withExtension: "json") }.first }
        let c = try JSONDecoder().decode(Catalog.self, from: try Data(contentsOf: XCTUnwrap(url)))
        let vl = c.models.filter { $0.supportsVision }
        XCTAssertGreaterThanOrEqual(vl.count, 4)
        XCTAssertTrue(vl.contains { $0.repo == "mlx-community/Qwen3.5-0.8B-4bit" })
        XCTAssertTrue(vl.allSatisfy { $0.runtime == .mlx }, "only the MLX runtime has a VLM path")
        // Public vision rows need no token; the loopl rows (mlx_vlm re-exports with the tower) are the one private family.
        XCTAssertTrue(vl.allSatisfy { !$0.gated || $0.hasLooplPersona })
        XCTAssertEqual(vl.filter(\.hasLooplPersona).count, 3, "loopl 0.8B / 2B / 4B MLX rows see")
        XCTAssertEqual(c.defaultModelId, "qwen3-0.6b-4bit", "default stays the text model until the owner's post-tuned ones land")
    }
}
