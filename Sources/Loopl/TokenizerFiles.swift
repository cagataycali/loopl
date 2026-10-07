import Foundation
import CryptoKit

/// The small files next to the weights that decide whether a downloaded model can be *tokenized* at all —
/// and how loopl repairs them without touching the weights.
///
/// Why this exists (2026-10-06): `cagataydev/loopl-{0.8b,2b,4b}-4bit` were exported with transformers 5, which writes
/// `tokenizer_class: "Qwen3_5Tokenizer"` into tokenizer_config.json. swift-transformers knows `Qwen2Tokenizer` and
/// `PreTrainedTokenizer` but has no entry for that name, so the phone said "Qwen3_5Tokenizer is not supported" — after
/// a 2.4 GB download. The Hub repos were fixed by hand; the files already on the owner's phone were not. Hence:
/// 1. the MLX runtime loads unknown tokenizer classes with `strict: false` (BPE fallback), and
/// 2. when a load still fails on the tokenizer, `HFDownloader.repairSmallFiles` re-fetches ONLY the small files whose
///    git blob hash differs from the Hub's — weights are never downloaded twice.
public enum TokenizerFiles {
    /// Everything that is not a weight shard: tokenizer, templates, configs. Each is well under 20 MB.
    public static let names: Set<String> = ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
                                            "tokenizer.model", "special_tokens_map.json", "chat_template.jinja", "chat_template.json",
                                            "added_tokens.json", "merges.txt", "vocab.json"]

    /// tokenizer_class names swift-transformers 1.3.x knows (`TokenizerModel.knownTokenizers`). A `Fast` suffix is ignored upstream.
    public static let knownClasses: Set<String> = ["BertTokenizer", "CodeGenTokenizer", "CodeLlamaTokenizer", "CohereTokenizer",
                                                   "DistilbertTokenizer", "DistilBertTokenizer", "FalconTokenizer", "GemmaTokenizer",
                                                   "GPT2Tokenizer", "LlamaTokenizer", "RobertaTokenizer", "T5Tokenizer", "TokenizersBackend",
                                                   "PreTrainedTokenizer", "Qwen2Tokenizer", "WhisperTokenizer", "XLMRobertaTokenizer",
                                                   "Xlm-RobertaTokenizer"]

    /// What a local model directory's tokenizer files look like to swift-transformers, before loading them.
    public struct Audit: Sendable, Equatable {
        public var tokenizerClass: String?
        public var hasTokenizerJSON: Bool
        public var hasChatTemplate: Bool
        /// `tokenizer_class` is set but swift-transformers has no entry for it → would throw `unsupportedTokenizer` under strict loading.
        public var unknownClass: Bool { tokenizerClass.map { !TokenizerFiles.knownClasses.contains($0.replacingOccurrences(of: "Fast", with: "")) } ?? false }
        /// Loadable with the non-strict (BPE fallback) loader: a tokenizer.json and a chat template are there.
        public var isLoadableNonStrict: Bool { hasTokenizerJSON && hasChatTemplate }
    }

    public static func audit(_ directory: URL) -> Audit {
        let fm = FileManager.default
        var cls: String?
        var templateInConfig = false
        if let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cls = obj["tokenizer_class"] as? String
            if let t = obj["chat_template"] as? String, !t.isEmpty { templateInConfig = true }
            if let list = obj["chat_template"] as? [[String: Any]], !list.isEmpty { templateInConfig = true }
        }
        let hasTemplate = templateInConfig || fm.fileExists(atPath: directory.appendingPathComponent("chat_template.jinja").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("chat_template.json").path)
        return Audit(tokenizerClass: cls, hasTokenizerJSON: fm.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path),
                     hasChatTemplate: hasTemplate)
    }

    /// Does this load error come from the tokenizer files (as opposed to weights, memory, a missing drive…)?
    /// Matched on swift-transformers' and mlx-swift-lm's own messages, which are the only signal the runtime gives.
    public static func isTokenizerError(_ error: Error) -> Bool { isTokenizerError(String(describing: error) + " " + error.localizedDescription) }

    public static func isTokenizerError(_ description: String) -> Bool {
        let d = description.lowercased()
        if d.contains("tokenizer") { return true }                       // "Qwen3_5Tokenizer is not supported", unsupportedTokenizer, tokenizer_config…
        if d.contains("chat template") || d.contains("chattemplate") { return true }   // missingChatTemplate
        if d.contains("missingconfig") || d.contains("tokenizerdata") { return true }
        return false
    }

    // The copy shown when a load fails on the tokenizer: what is wrong, and an action that is really there.
    //
    // **There is no Repair button in loopl, and there never was.** The repair is automatic: `Engine.load`
    // catches a tokenizer error, shows `.repairing`, and calls `ModelStore.repairFiles` itself. The only
    // control the reader is offered in the failed state is **Try again** (`ChatView`'s readiness row).
    //
    // IMPROVE-9: the old single `repairMessage` said "tap Repair to refresh them from Hugging Face" at all
    // three failure sites, so the one piece of guidance a stuck reader gets named a control that does not
    // exist — and at the fetch-failed site it read "tap Repair ... Repair failed: ...", telling them to do
    // the thing it had just said failed. One message for three different states is why; each state now has
    // its own, and each names only an action that is really there.

    /// Offline: loopl *can* fix this, but not without the network.
    public static func needsInternetMessage(for modelName: String) -> String {
        "\(modelName) can't start: some of its small setup files are out of date. loopl can fetch fresh ones — a few kilobytes, and the model itself stays on your device — but it needs the internet. Connect and tap Try again."
    }

    /// loopl tried to fetch those files and the fetch itself failed. Retrying is worth it.
    public static func fetchFailedMessage(for modelName: String) -> String {
        "\(modelName) can't start: some of its small setup files are out of date, and loopl could not fetch fresh ones just now. Tap Try again."
    }

    /// The files already match Hugging Face, or have just been refreshed, and the model still will not load.
    /// Nothing on this device changes that, so say so and give the reader the move that is theirs.
    public static func cannotBeFixedMessage(for modelName: String) -> String {
        "\(modelName) can't start, and nothing here will fix it: its files already match Hugging Face, so the problem is in how the model was published rather than on your device. Try another model — you can delete this one under Models to get the space back."
    }

    /// Git's blob hash — `sha1("blob <size>\0" + bytes)` — which is the `oid` the Hub tree API reports for every
    /// non-LFS file. Lets the app compare a local small file with the Hub's current version without downloading it.
    public static func gitBlobSHA1(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\u{0}".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func gitBlobSHA1(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return gitBlobSHA1(data)
    }

    /// SHA-256 of a file's content — what the Hub reports as `lfs.oid` for LFS-stored files (tokenizer.json is one once it
    /// passes ~10 MB; its tree `oid` is then the hash of the pointer, not of the content).
    public static func sha256(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension HFDownloader {
    /// Refresh the small files of an already-downloaded model from the Hub: every file in `TokenizerFiles.names` whose
    /// content hash differs from the Hub's (`oid` git blob SHA-1, or `lfs.oid` SHA-256 for LFS-stored ones like a big
    /// tokenizer.json) or is missing locally is downloaded again; weights (`*.safetensors`, `*.gguf`) are never touched. Returns the names that changed. Offline → `DLError.offline` before any request.
    @discardableResult
    public func repairSmallFiles(repo: String, revision: String = "main", in directory: URL) async throws -> [String] {
        let remote = try await listFiles(repo: repo, revision: revision, filter: false)
            .filter { TokenizerFiles.names.contains($0.path) }
        var changed: [String] = []
        let fm = FileManager.default
        for file in remote {
            let dest = directory.appendingPathComponent(file.path)
            if file.matches(dest) { continue }
            try? fm.removeItem(at: dest)
            try? fm.removeItem(at: dest.appendingPathExtension("part"))
            try await download(repo: repo, revision: revision, file: file, to: dest) { _ in }
            changed.append(file.path)
        }
        return changed
    }
}
