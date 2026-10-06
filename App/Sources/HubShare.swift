import Foundation
import Observation
import Loopl

/// "Share to Hugging Face": selected conversations → one loopl-train shard → the person's PRIVATE dataset repo.
/// Owns the review state (redaction, preview, counts), the account step (token → whoami), the repo choice
/// (existing dataset or a new private one) and the push (create → README → commit), with one honest state
/// machine the sheet renders. Nothing leaves the device until `push()`.
@MainActor @Observable
final class HubShare {
    enum Stage: Equatable {
        case review                     // choose redaction, look at the preview
        case account                    // no token yet (paste) or verifying
        case repo                       // pick/create the dataset repo
        case pushing(String)            // progress label
        case done(URL, rows: Int, images: Int)
        case failed(String)
    }

    let conversations: [SavedConversation]
    var redaction = ConversationExport.Redaction()
    var stage: Stage = .review
    var whoami: HFHubClient.WhoAmI?
    var tokenDraft = ""
    var datasets: [HFHubClient.DatasetSummary] = []
    var repoName = "loopl-conversations"          // bare name for a new repo…
    var chosenRepo: String?                        // …or an existing "owner/name"
    var error: String?

    private let account: HFAccount
    private let transport: any HFTransport
    let appVersion: String
    let platform: String

    init(conversations: [SavedConversation], account: HFAccount = .shared, transport: any HFTransport = HFURLSessionTransport(),
         appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2", platform: String = "iOS") {
        self.conversations = conversations; self.account = account; self.transport = transport
        self.appVersion = appVersion; self.platform = platform
        self.whoami = account.whoami
    }

    // MARK: Review

    var options: ConversationExport.Options { .init(redaction: redaction, appVersion: appVersion, platform: platform) }
    var shard: ConversationExport.Shard { ConversationExport.shard(conversations.map { $0.exportThread() }, options: options) }

    struct Row: Identifiable, Hashable {
        var id: UUID; var title: String; var turns: Int; var toolCalls: Int; var images: Int; var skipped: String?
    }
    /// One line per selected conversation, with why it would be skipped (so the person can deselect it).
    var rows: [Row] {
        conversations.map { c in
            do {
                let r = try ConversationExport.record(c.exportThread(), options: options)
                return Row(id: c.id, title: c.title, turns: r.turns, toolCalls: r.toolCalls, images: r.images.count, skipped: nil)
            } catch {
                return Row(id: c.id, title: c.title, turns: 0, toolCalls: 0, images: 0, skipped: error.localizedDescription)
            }
        }
    }
    var hasTools: Bool { conversations.contains { !($0.tools ?? []).isEmpty } }
    /// First record, pretty-printed and clipped — what the jsonl actually says.
    var preview: String {
        guard let first = shard.records.first else { return "" }
        let data = (try? JSONSerialization.data(withJSONObject: first.json.anyValue, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var s = String(decoding: data, as: UTF8.self)
        // The system turn is long and identical for every row — fold it so the preview shows the conversation.
        if let r = s.range(of: ConversationExport.systemPrompt) { s.replaceSubrange(r, with: "<loopl system prompt v\(ConversationExport.systemVersion), \(ConversationExport.systemPrompt.count) chars>") }
        return s.count > 6000 ? String(s.prefix(6000)) + "\n…" : s
    }

    /// Where "Continue" goes from the review: straight to the repo step when the account is already verified.
    func proceed() async {
        if account.hasToken, whoami == nil { await verify(account.token) ; return }
        stage = account.hasToken && whoami != nil ? .repo : .account
        if case .repo = stage { await loadDatasets() }
    }

    // MARK: Account

    func verify(_ token: String?) async {
        let t = (token ?? tokenDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard HFAccount.looksLikeToken(t) else { error = "that does not look like a Hugging Face token (hf_…)"; return }
        stage = .pushing("Checking the token…")
        do {
            try account.setToken(t)
            let who = try await account.verify(transport: transport)
            whoami = who; error = nil; tokenDraft = ""
            guard who.canWriteRepos else {
                error = "this token is read-only — sharing needs a token with write access to repositories"
                stage = .account; return
            }
            stage = .repo
            await loadDatasets()
        } catch {
            try? account.clear()
            self.error = error.localizedDescription
            stage = .account
        }
    }

    func signOut() { try? account.clear(); whoami = nil; datasets = []; stage = .account }

    // MARK: Repo

    func loadDatasets() async {
        guard let who = whoami else { return }
        do {
            datasets = try await account.client(transport: transport).datasets(author: who.name).filter { $0.isPrivate }
            if chosenRepo == nil, let mine = datasets.first(where: \.isLooplShare) { chosenRepo = mine.id }
        } catch { datasets = [] }
    }

    var targetRepo: String? {
        if let chosenRepo { return chosenRepo }
        guard let who = whoami else { return nil }
        let name = Self.slug(repoName)
        return name.isEmpty ? nil : "\(who.name)/\(name)"
    }
    var createsNewRepo: Bool { chosenRepo == nil }

    /// Hub repo names: letters, digits, `-`, `_`, `.`; no leading/trailing `-`/`.`; ≤ 96 chars.
    static func slug(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
            .reduce(into: "") { acc, ch in if !(ch == "-" && acc.last == "-") { acc.append(ch) } }
        while let f = out.first, f == "-" || f == "." { out.removeFirst() }
        while let l = out.last, l == "-" || l == "." { out.removeLast() }
        return String(out.prefix(96))
    }

    // MARK: Push

    func push() async {
        guard let repo = targetRepo else { error = "pick a dataset name"; return }
        let shard = self.shard
        guard !shard.records.isEmpty else { error = "nothing to share — every selected conversation was skipped"; return }
        error = nil
        let hub = account.client(transport: transport)
        do {
            if createsNewRepo {
                stage = .pushing("Creating private dataset \(repo)…")
                do { _ = try await hub.createRepo(name: Self.slug(repoName), type: .dataset, isPrivate: true) }
                catch HFHubError.conflict { /* already there — fine, we append */ }
            }
            stage = .pushing("Preparing \(shard.records.count) conversation\(shard.records.count == 1 ? "" : "s")…")
            var files: [HFHubClient.FileOp] = [.init(path: shard.path, text: shard.jsonl)]
            files += shard.images.map { .init(path: $0.path, data: $0.data) }
            // README: create the card the first time; afterwards append the shard to its list so the viewer config stays.
            if let existing = try? await hub.fileData(repo: repo, type: .dataset, path: "README.md"), !existing.isEmpty {
                var text = String(decoding: existing, as: UTF8.self)
                if !text.contains(shard.path) { text += (text.hasSuffix("\n") ? "" : "\n") + "- `\(shard.path)` (\(shard.records.count) rows)\n" }
                files.append(.init(path: "README.md", text: text))
            } else {
                files.append(.init(path: "README.md", text: ConversationExport.readme(repo: repo, shards: [shard.path], rows: shard.records.count, appVersion: appVersion)))
            }
            #if DEBUG
            // Proof hook (simulator runs): keep the exact bytes that go up, so the lane can diff them against the Hub.
            if let dir = ProcessInfo.processInfo.environment["LOOPL_EXPORT_DIR"], !dir.isEmpty {
                let root = URL(fileURLWithPath: dir)
                for f in files {
                    let url = root.appendingPathComponent(f.path)
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? f.data.write(to: url)
                }
            }
            #endif
            stage = .pushing("Uploading \(ByteSize.label(Int64(shard.byteCount)))…")
            let result = try await hub.commit(repo: repo, type: .dataset, summary: "loopl \(appVersion): share \(shard.records.count) conversation\(shard.records.count == 1 ? "" : "s")",
                                              description: "Pushed from the loopl app (Share to Hugging Face). Redaction: images \(redaction.stripImages ? "stripped" : "kept"), tool results \(redaction.stripToolResults ? "stripped" : "kept"), URLs \(redaction.anonymiseURLs ? "anonymised" : "kept").",
                                              files: files)
            let url = URL(string: result.commitUrl.replacingOccurrences(of: #"/commit/[0-9a-f]+$"#, with: "/tree/main/data", options: .regularExpression)) ?? URL(string: "https://huggingface.co/datasets/\(repo)")!
            stage = .done(url, rows: shard.records.count, images: shard.images.count)
        } catch HFHubError.unauthorized {
            try? account.clear(); whoami = nil
            error = "Hugging Face rejected the token — paste a fresh one"; stage = .account
        } catch {
            self.error = error.localizedDescription
            stage = .failed(error.localizedDescription)
        }
    }

    func retry() { stage = .repo; error = nil }
}
