import XCTest
import Loopl

/// HubCatalog pinned on REAL Hugging Face Hub responses saved 2026-10-05 under Fixtures/hub:
///   search-mlx-qwen3.json   GET /api/models?search=qwen3&author=mlx-community&sort=downloads&limit=30
///   search-gguf-qwen3.json  GET /api/models?search=qwen3&filter=gguf&sort=downloads&limit=30
///   repo-mlx-qwen2.5-1.5b.json      GET /api/models/mlx-community/Qwen2.5-1.5B-Instruct-4bit?blobs=true
///   repo-gguf-bartowski-qwen3-1.7b.json GET /api/models/bartowski/Qwen_Qwen3-1.7B-GGUF?blobs=true
///   config-mlx-qwen2.5-1.5b.json    GET /mlx-community/Qwen2.5-1.5B-Instruct-4bit/resolve/main/config.json
final class HubCatalogTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        // SwiftPM keeps Fixtures/hub/<name>.json; Xcode-hosted runs (CI simulator job) flatten copied folders → try every shape.
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

    // MARK: search

    func testMLXSearchParsesRowsAndEstimatesSize() throws {
        let hits = try HubCatalog.parseSearch(fixture("search-mlx-qwen3"), kind: .mlx)
        XCTAssertEqual(hits.count, 30)
        let q06 = try XCTUnwrap(hits.first { $0.id == "mlx-community/Qwen3-0.6B-4bit" })
        XCTAssertEqual(q06.kind, .mlx)
        XCTAssertEqual(q06.author, "mlx-community")
        XCTAssertEqual(q06.name, "Qwen3-0.6B-4bit")
        XCTAssertEqual(q06.bits, 4)
        XCTAssertEqual(q06.modelType, "qwen3")
        XCTAssertEqual(q06.downloads, 36878)
        XCTAssertFalse(q06.gated)
        XCTAssertTrue(q06.isTextGeneration)
        // 596,049,920 params × 4 bits / 8 × 1.125 ≈ 335 MB — the curated row's real size is 335,450,584.
        let est = try XCTUnwrap(q06.sizeBytes)
        XCTAssertEqual(Double(est), 335_450_584, accuracy: 335_450_584 * 0.02)
        XCTAssertEqual(try XCTUnwrap(q06.paramsB), 0.596, accuracy: 0.001)
    }

    func testMLXSearchHidesNonChatCheckpoints() throws {
        let hits = try HubCatalog.parseSearch(fixture("search-mlx-qwen3"), kind: .mlx)
        let chat = hits.filter(\.isTextGeneration).map(\.id)
        XCTAssertFalse(chat.contains("mlx-community/Qwen3-ASR-0.6B-8bit"))
        XCTAssertFalse(chat.contains("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"))
        // Vision checkpoints are chat models loopl can run (MLXVLM) — they stay, flagged as vision.
        XCTAssertTrue(chat.contains("mlx-community/Qwen3-VL-4B-Instruct-4bit"))
        XCTAssertTrue(hits.first { $0.id == "mlx-community/Qwen3-VL-4B-Instruct-4bit" }?.isVision == true)
        XCTAssertFalse(chat.contains("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"))
        XCTAssertTrue(chat.contains("mlx-community/Qwen3-1.7B-4bit"))
        XCTAssertTrue(chat.contains("mlx-community/Qwen3-4B-Instruct-2507-4bit"))
        XCTAssertGreaterThan(chat.count, 15)
    }

    func testGGUFSearchCarriesContextAndTotalSize() throws {
        let hits = try HubCatalog.parseSearch(fixture("search-gguf-qwen3"), kind: .gguf)
        XCTAssertEqual(hits.count, 30)
        let u = try XCTUnwrap(hits.first { $0.id == "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF" })
        XCTAssertEqual(u.kind, .gguf)
        XCTAssertEqual(u.ctx, 262_144)
        XCTAssertEqual(u.sizeBytes, 30_532_122_624)
        XCTAssertEqual(u.modelType, "qwen3moe")
        XCTAssertEqual(u.downloads, 7_361_953)
        XCTAssertEqual(u.paramsB, 30, "params fall back to the name when the Hub gives no safetensors count")
    }

    // MARK: repo + config

    func testMLXRepoDetailListsWeightsAndSizes() throws {
        let r = try HubCatalog.parseRepo(fixture("repo-mlx-qwen2.5-1.5b"))
        XCTAssertEqual(r.id, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertEqual(r.kind, .mlx)
        XCTAssertEqual(r.files.count, 11)
        XCTAssertEqual(r.files.first { $0.path == "model.safetensors" }?.size, 868_628_559)
        XCTAssertEqual(r.mlxFiles.map(\.path).sorted(), ["added_tokens.json", "config.json", "merges.txt", "model.safetensors", "model.safetensors.index.json", "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.json"], "README/.gitattributes are not downloaded")
        XCTAssertEqual(r.mlxBytes, 868_628_559 + 605 + 784 + 1_671_853 + 51_569 + 613 + 7_031_673 + 7_308 + 2_776_833)
        XCTAssertEqual(try XCTUnwrap(r.paramsB), 1.5437, accuracy: 0.001)
        XCTAssertEqual(r.modelType, "qwen2")
        XCTAssertNil(r.preferredGGUF)
    }

    func testConfigReadsContextAndQuantization() throws {
        let c = try HubCatalog.parseConfig(fixture("config-mlx-qwen2.5-1.5b"))
        XCTAssertEqual(c.modelType, "qwen2")
        XCTAssertEqual(c.architectures, ["Qwen2ForCausalLM"])
        XCTAssertEqual(c.maxPositionEmbeddings, 32768)
        XCTAssertEqual(c.bits, 4)
        XCTAssertEqual(c.groupSize, 64)
    }

    func testGGUFRepoPicksQ4KMAndParsesQuantNames() throws {
        let r = try HubCatalog.parseRepo(fixture("repo-gguf-bartowski-qwen3-1.7b"))
        XCTAssertEqual(r.kind, .gguf)
        XCTAssertEqual(r.ggufContext, 32768, "bartowski's GGUF header says 32768 (Qwen3-1.7B's native window; 40960 is with YaRN)")
        XCTAssertEqual(r.modelType, "qwen3")
        XCTAssertGreaterThan(r.ggufFiles.count, 10)
        let pref = try XCTUnwrap(r.preferredGGUF)
        XCTAssertEqual(pref.path, "Qwen_Qwen3-1.7B-Q4_K_M.gguf")
        XCTAssertEqual(pref.quant, "Q4_K_M")
        XCTAssertEqual(HubCatalog.File(path: "Qwen_Qwen3-1.7B-IQ3_XXS.gguf", size: 1).quant, "IQ3_XXS")
        XCTAssertEqual(HubCatalog.File(path: "x-Q8_0.gguf", size: 1).quant, "Q8_0")
        XCTAssertEqual(HubCatalog.File(path: "x-bf16.gguf", size: 1).quant, "BF16")
        XCTAssertNil(HubCatalog.File(path: "README.md", size: 1).quant)
        // imatrix calibration files are never the default pick
        XCTAssertFalse(pref.path.lowercased().contains("imatrix"))
        XCTAssertEqual(r.ggufFiles, r.ggufFiles.sorted { $0.size < $1.size }, "quants listed smallest first")
    }

    // MARK: spec

    func testMLXSpecFromRepoAndConfig() throws {
        let r = try HubCatalog.parseRepo(fixture("repo-mlx-qwen2.5-1.5b"))
        let c = try HubCatalog.parseConfig(fixture("config-mlx-qwen2.5-1.5b"))
        let s = try HubCatalog.spec(for: r, config: c)
        XCTAssertEqual(s.id, "hub:mlx-community/qwen2.5-1.5b-instruct-4bit")
        XCTAssertTrue(s.isFromHub)
        XCTAssertEqual(s.runtime, .mlx)
        XCTAssertEqual(s.family, .hermes)
        XCTAssertNil(s.toolsUnverified, "Qwen's grammar is verified")
        XCTAssertEqual(s.repo, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertEqual(s.sizeBytes, r.mlxBytes)
        XCTAssertEqual(s.ctxNominal, 32768)
        XCTAssertEqual(s.ctxUsable8GB, 8192)
        XCTAssertEqual(s.paramsB, 1.5437, accuracy: 0.001)
        XCTAssertEqual(s.minRAMGB, 2)
        XCTAssertNil(s.file)
        XCTAssertNil(s.chatTemplateKwargs)
        XCTAssertFalse(s.gated)
        // Same shape as the curated row for the same repo (size matches the catalog's real number).
        XCTAssertEqual(s.sizeBytes, 868_628_559 + 605 + 784 + 1_671_853 + 51_569 + 613 + 7_031_673 + 7_308 + 2_776_833)
        // Round-trips through the on-disk "my models" store.
        let back = try JSONDecoder().decode(ModelSpec.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testGGUFSpecUsesTheChosenQuant() throws {
        let r = try HubCatalog.parseRepo(fixture("repo-gguf-bartowski-qwen3-1.7b"))
        let s = try HubCatalog.spec(for: r, config: nil)
        XCTAssertEqual(s.id, "hub:bartowski/qwen_qwen3-1.7b-gguf:qwen_qwen3-1.7b-q4_k_m.gguf")
        XCTAssertEqual(s.runtime, .gguf)
        XCTAssertEqual(s.file, "Qwen_Qwen3-1.7B-Q4_K_M.gguf")
        XCTAssertEqual(s.sizeBytes, r.preferredGGUF?.size)
        XCTAssertEqual(s.ctxNominal, 32768, "from gguf.context_length when there is no config.json")
        XCTAssertEqual(s.ctxUsable8GB, 8192)
        XCTAssertEqual(s.paramsB, 1.7)
        XCTAssertEqual(s.family, .hermes)
        XCTAssertEqual(s.chatTemplateKwargs?["enable_thinking"], .bool(false))
        let q8 = try XCTUnwrap(r.ggufFiles.first { $0.quant == "Q8_0" })
        let s8 = try HubCatalog.spec(for: r, config: nil, ggufFile: q8)
        XCTAssertEqual(s8.file, q8.path)
        XCTAssertEqual(s8.sizeBytes, q8.size)
        XCTAssertNotEqual(s8.id, s.id)
    }

    func testSpecRefusesReposWithoutRunnableWeights() throws {
        let r = HubCatalog.Repo(id: "x/y", sha: nil, gated: false, downloads: 0, likes: 0, pipeline: nil,
                                files: [.init(path: "README.md", size: 1), .init(path: "pytorch_model.bin", size: 9)],
                                modelType: "llama", ggufContext: nil, paramsB: nil, lastModified: nil)
        XCTAssertThrowsError(try HubCatalog.spec(for: r, config: nil))
    }

    // MARK: fit + family + names

    func testFitVerdictBands() {
        let gb: Int64 = 1 << 30
        XCTAssertEqual(HubCatalog.Fit.verdict(bytes: gb, available: 4 * gb), .green)      // 1.3 GB of 4 GB = 33 %
        XCTAssertEqual(HubCatalog.Fit.verdict(bytes: 2 * gb, available: 4 * gb), .amber)  // 2.6 GB = 65 %
        XCTAssertEqual(HubCatalog.Fit.verdict(bytes: 3 * gb, available: 4 * gb), .red)    // 3.9 GB = 98 %
        XCTAssertEqual(HubCatalog.Fit.verdict(bytes: gb, available: 0), .amber, "unknown budget → warn, never block")
    }

    func testFamilyDetection() {
        XCTAssertEqual(HubCatalog.detectFamily(repo: "mlx-community/Qwen3-1.7B-4bit", modelType: "qwen3").family, .hermes)
        XCTAssertEqual(HubCatalog.detectFamily(repo: "bartowski/Llama-3.2-3B-Instruct-GGUF", modelType: nil).family, .llama3)
        XCTAssertEqual(HubCatalog.detectFamily(repo: "mlx-community/gemma-3-1b-it-4bit", modelType: "gemma3_text").family, .generic)
        XCTAssertTrue(HubCatalog.detectFamily(repo: "mlx-community/gemma-3-1b-it-4bit", modelType: "gemma3_text").verified)
        XCTAssertEqual(HubCatalog.detectFamily(repo: "mlx-community/Phi-4-mini-instruct-4bit", modelType: "phi3").family, .hermes)
        XCTAssertEqual(HubCatalog.detectFamily(repo: "mlx-community/SmolLM3-3B-4bit", modelType: "smollm3").family, .hermes)
        XCTAssertEqual(HubCatalog.detectFamily(repo: "mlx-community/SmolLM2-1.7B-Instruct-4bit", modelType: "llama").family, .generic, "SmolLM2 wins over its llama architecture")
        let m = HubCatalog.detectFamily(repo: "mlx-community/Mistral-7B-Instruct-v0.3-4bit", modelType: "mistral")
        XCTAssertFalse(m.verified)
        let unknown = HubCatalog.detectFamily(repo: "someone/weird-model", modelType: nil)
        XCTAssertEqual(unknown.family, .generic)
        XCTAssertFalse(unknown.verified)
    }

    func testBitsFromNames() {
        XCTAssertEqual(HubCatalog.bitsFromName("mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"), 4)
        XCTAssertEqual(HubCatalog.bitsFromName("mlx-community/Qwen3-0.6B-8bit"), 8)
        XCTAssertEqual(HubCatalog.bitsFromName("mlx-community/Qwen3.5-2B-6bit"), 6)
        XCTAssertEqual(HubCatalog.bitsFromName("mlx-community/Qwen3.8-27B-bf16"), 16)
        XCTAssertEqual(HubCatalog.bitsFromName("mlx-community/gpt-oss-20b-MXFP4-Q8"), 4)
        XCTAssertNil(HubCatalog.bitsFromName("mlx-community/Kimi-K2.5"))
        XCTAssertNil(HubCatalog.bitsFromName("bartowski/Qwen_Qwen3-1.7B-GGUF"))
    }

    func testMLXSizeEstimateFallsBackToTheName() throws {
        // Older mlx-community conversions have no quantization_config; the "-4bit" suffix is the only hint.
        let json = """
        [{"id":"mlx-community/Qwen2.5-0.5B-Instruct-4bit","gated":false,"likes":1,"downloads":54000,"config":{"model_type":"qwen2"},
          "safetensors":{"parameters":{"U32":494032768},"total":494032768},"pipeline_tag":"text-generation"}]
        """
        let hit = try XCTUnwrap(HubCatalog.parseSearch(Data(json.utf8), kind: .mlx).first)
        XCTAssertEqual(hit.bits, 4)
        XCTAssertEqual(Double(try XCTUnwrap(hit.sizeBytes)), 494_032_768 * 0.5 * 1.125, accuracy: 1)
    }

    func testParamsFromNames() {
        XCTAssertEqual(HubCatalog.paramsB(fromName: "Qwen3-1.7B-4bit"), 1.7)
        XCTAssertEqual(HubCatalog.paramsB(fromName: "Llama-3.2-3B-Instruct-Q4_K_M"), 3)
        XCTAssertEqual(HubCatalog.paramsB(fromName: "SmolLM2-360M-Instruct"), 0.36)
        XCTAssertEqual(HubCatalog.paramsB(fromName: "Qwen3-Coder-30B-A3B-Instruct-GGUF"), 30)
        XCTAssertNil(HubCatalog.paramsB(fromName: "weird-model"))
        XCTAssertNil(HubCatalog.paramsB(fromName: "Qwen3-4bit"), "the quant suffix is not a size")
    }

    func testContextBudget() {
        XCTAssertEqual(HubCatalog.ctxUsable8GB(paramsB: 0.6, ctxNominal: 40960), 16384)
        XCTAssertEqual(HubCatalog.ctxUsable8GB(paramsB: 1.7, ctxNominal: 40960), 8192)
        XCTAssertEqual(HubCatalog.ctxUsable8GB(paramsB: 4, ctxNominal: 40960), 8192)
        XCTAssertEqual(HubCatalog.ctxUsable8GB(paramsB: 8, ctxNominal: 131072), 4096)
        XCTAssertEqual(HubCatalog.ctxUsable8GB(paramsB: 30, ctxNominal: 262144), 2048)
        XCTAssertEqual(HubCatalog.ctxUsable8GB(paramsB: 1.7, ctxNominal: 2048), 2048, "never above the model's own limit")
    }

    func testSearchURLs() {
        let h = HubCatalog()
        let expand = "&expand%5B%5D=config&expand%5B%5D=safetensors&expand%5B%5D=gguf&expand%5B%5D=gated&expand%5B%5D=pipeline_tag&expand%5B%5D=lastModified&expand%5B%5D=likes&expand%5B%5D=downloads"
        XCTAssertEqual(h.searchURL("qwen3", kind: .mlx).absoluteString,
                       "https://huggingface.co/api/models?search=qwen3&sort=downloads&direction=-1&limit=30&author=mlx-community" + expand)
        XCTAssertEqual(h.searchURL("qwen3", kind: .gguf).absoluteString,
                       "https://huggingface.co/api/models?search=qwen3&sort=downloads&direction=-1&limit=30&filter=gguf" + expand)
        XCTAssertEqual(h.searchURL("", kind: .mlx).absoluteString,
                       "https://huggingface.co/api/models?sort=downloads&direction=-1&limit=30&author=mlx-community" + expand, "empty query = most downloaded")
    }

    func testCacheRoundTripAndAge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hubcache-\(UUID().uuidString)")
        let c = HubCache(directory: dir)
        let url = URL(string: "https://huggingface.co/api/models?search=a&b=c")!
        XCTAssertNil(c.read(url, maxAge: 60))
        c.write(url, Data("[1]".utf8))
        XCTAssertEqual(c.read(url, maxAge: 60), Data("[1]".utf8))
        XCTAssertNil(c.read(url, maxAge: -1), "expired")
        XCTAssertEqual(c.read(url, maxAge: .infinity), Data("[1]".utf8), "stale copies still serve offline")
        c.clear()
        XCTAssertNil(c.read(url, maxAge: .infinity))
    }

    func testCacheKeysDoNotCollideOnLongURLs() {
        let c = HubCache(directory: FileManager.default.temporaryDirectory)
        let h = HubCatalog()
        let a = c.path(h.searchURL("qwen3", kind: .mlx)), b = c.path(h.searchURL("qwen2.5 1.5b", kind: .mlx)), d = c.path(h.searchURL("", kind: .mlx))
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(a, d); XCTAssertNotEqual(b, d)
        XCTAssertEqual(c.path(h.searchURL("qwen3", kind: .mlx)), a, "deterministic")
        XCTAssertLessThan(a.lastPathComponent.count, 100)
    }
}
