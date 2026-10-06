import XCTest
import Tokenizers
import Loopl
@testable import LooplRuntimes

/// LIVE proof for "Qwen3_5Tokenizer is not supported" (owner, neon_net, 2026-10-06) against the REAL private repo
/// `cagataydev/loopl-0.8b-4bit` with the developer's token (`~/.cache/huggingface/token` or `LOOPL_HF_TOKEN`), on the
/// macOS test host. Skips unless `LOOPL_HF_LIVE=1`; CI never runs it. Set `LOOPL_TOKFIX_DIR` to keep the 444 MB
/// download between runs (default: a temp dir).
///
///   1. the files transformers 5 wrote (repo revision 3a5efee7) make swift-transformers' STRICT loader throw —
///      the bug exactly as the phone saw it;
///   2. loopl's non-strict loader tokenizes them anyway ("hello" round-trips, the chat template renders a tool);
///   3. `repairSmallFiles` swaps in the Hub's current small files (tokenizer_class Qwen2Tokenizer) — weights untouched;
///   4. `MLXModel` loads the repaired directory and answers.
final class TokenizerFixLiveTests: XCTestCase {
    static let repo = "cagataydev/loopl-0.8b-4bit"
    static let brokenRevision = "3a5efee7a0230b03c1b89686519b649ad8800229"   // the transformers-5 export, before tiny's fix

    static var token: String? {
        guard ProcessInfo.processInfo.environment["LOOPL_HF_LIVE"] == "1" else { return nil }
        if let t = ProcessInfo.processInfo.environment["LOOPL_HF_TOKEN"], !t.isEmpty { return t }
        let p = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/token")
        return (try? String(contentsOf: p, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testBrokenFilesFallBackThenRepairThenLoad() async throws {
        guard let token = Self.token else { throw XCTSkip("set LOOPL_HF_LIVE=1 with a token in ~/.cache/huggingface/token") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let dirPath = ProcessInfo.processInfo.environment["LOOPL_TOKFIX_DIR"] ?? NSTemporaryDirectory() + "loopl-tokfix/" + Self.repo.replacingOccurrences(of: "/", with: "--")
        let dir = URL(fileURLWithPath: (dirPath as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dl = HFDownloader(token: { token })
        let spec = ModelSpec(id: "loopl-0.8b-4bit", name: "loopl 0.8B", repo: Self.repo, runtime: .mlx, family: .hermes, paramsB: 0.8,
                             sizeBytes: 444_091_186, ctxNominal: 262_144, ctxUsable8GB: 16384, minRAMGB: 2, gated: true,
                             chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: false)

        // Weights + current small files (resume-aware: a kept LOOPL_TOKFIX_DIR costs nothing the second time).
        let t0 = Date()
        let files = try await dl.files(for: spec)
        for f in files { try await dl.download(repo: Self.repo, file: f, to: dir.appendingPathComponent(f.path)) { _ in } }
        print("LIVE download/verify \(files.count) files in \(Int(Date().timeIntervalSince(t0))) s")

        // 1. Put the transformers-5 small files back (what the owner's phone still has) — weights are identical across revisions.
        let broken = try await dl.listFiles(repo: Self.repo, revision: Self.brokenRevision, filter: false).filter { TokenizerFiles.names.contains($0.path) }
        for name in TokenizerFiles.names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        for f in broken { try await dl.download(repo: Self.repo, revision: Self.brokenRevision, file: f, to: dir.appendingPathComponent(f.path)) { _ in } }
        let before = TokenizerFiles.audit(dir)
        XCTAssertEqual(before.tokenizerClass, "Qwen3_5Tokenizer")
        XCTAssertTrue(before.unknownClass)
        do {
            _ = try await AutoTokenizer.from(modelFolder: dir)   // strict, what MLXModel did before this change
            XCTFail("strict load must reproduce the phone's error")
        } catch {
            print("LIVE strict loader: \(error)")
            XCTAssertTrue(TokenizerFiles.isTokenizerError(error), "classified as a tokenizer error: \(error)")
            XCTAssertTrue(String(describing: error).contains("Qwen3_5Tokenizer"))
        }

        // 2. loopl's loader (strict: false) tokenizes the same files.
        let fallback = try await TransformersTokenizerLoader().load(from: dir)
        let ids = fallback.encode(text: "hello loopl", addSpecialTokens: false)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(fallback.decode(tokenIds: ids, skipSpecialTokens: false), "hello loopl")
        let params: [String: any Sendable] = ["type": "object", "properties": ["url": ["type": "string"] as [String: any Sendable]] as [String: any Sendable], "required": ["url"]]
        let fn: [String: any Sendable] = ["name": "http", "description": "fetch a URL", "parameters": params]
        let tool: [String: any Sendable] = ["type": "function", "function": fn]
        let rendered = try fallback.applyChatTemplate(messages: [["role": "user", "content": "hi"]], tools: [tool], additionalContext: nil)
        let prompt = fallback.decode(tokenIds: rendered, skipSpecialTokens: false)
        XCTAssertTrue(prompt.contains("http"), "tool spec rendered: \(prompt.prefix(400))")
        XCTAssertTrue(prompt.contains("<|im_start|>user"), prompt.prefix(400).description)

        // 3. Repair from the Hub: only the small files that differ; the weights' mtime does not move.
        let weightsBefore = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("model.safetensors").path)[.modificationDate] as? Date
        let changed = try await dl.repairSmallFiles(repo: Self.repo, in: dir)
        print("LIVE repaired: \(changed)")
        XCTAssertTrue(changed.contains("tokenizer_config.json"), "\(changed)")
        let after = TokenizerFiles.audit(dir)
        XCTAssertEqual(after.tokenizerClass, "Qwen2Tokenizer")
        XCTAssertFalse(after.unknownClass)
        XCTAssertTrue(after.hasChatTemplate)
        let weightsAfter = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("model.safetensors").path)[.modificationDate] as? Date
        XCTAssertEqual(weightsBefore, weightsAfter, "weights untouched")
        let again = try await dl.repairSmallFiles(repo: Self.repo, in: dir)
        XCTAssertEqual(again, [], "second pass is a no-op: local git blob hashes equal the Hub's oids")
        _ = try await AutoTokenizer.from(modelFolder: dir)   // strict now succeeds too

        // 4. The real thing: MLXModel loads the repaired directory and generates.
        let model = MLXModel()
        let t1 = Date()
        try await model.load(spec, from: dir) { _ in }
        var assembler = StreamAssembler()
        for try await ev in model.stream([.user("Who built you? One sentence.")], toolSpecs: [], systemPrompt: nil) { _ = assembler.feed(ev) }
        let stop = assembler.finish()
        print("LIVE MLXModel: load \(String(format: "%.1f", Date().timeIntervalSince(t1))) s · \(stop.metrics.generatedTokens) tok · \(String(format: "%.1f", stop.metrics.tokensPerSecond)) tok/s\nTEXT: \(stop.message.text)")
        XCTAssertEqual(stop.stopReason, .endTurn)
        XCTAssertFalse(stop.message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        await model.unload()
    }
}
