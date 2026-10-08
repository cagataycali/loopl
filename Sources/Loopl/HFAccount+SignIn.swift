import Foundation

// Lane HF-ACCOUNT's additions on top of `HFAccount` / `HFHubClient` (HFHub.swift is the one token source).
// Everything here is an extension: the token lives in `HFAccount.shared`, whoami is `HFHubClient.whoami()`.

extension HFAccount {
    /// What loopl needs the token for: `read` private models · `write` push conversations to a dataset ·
    /// `jobs` start a training job. Derived from `WhoAmI` (classic write → all three; fine-grained → permissions).
    public enum Scope: String, Sendable, Codable, CaseIterable, Comparable {
        case read, write, jobs
        public static func < (a: Scope, b: Scope) -> Bool { a.order < b.order }
        var order: Int { switch self { case .read: 0; case .write: 1; case .jobs: 2 } }
        public var label: String { rawValue }
        /// One line for the Settings footer per missing scope.
        public var needed: String {
            switch self {
            case .read: "download your private models"
            case .write: "push conversations to your datasets"
            case .jobs: "start training jobs"
            }
        }
    }

    /// Why a pasted token was rejected before any network call.
    public enum SignInError: LocalizedError, Equatable {
        case notAToken
        public var errorDescription: String? { "that does not look like a Hugging Face token (they start with hf_)" }
    }

    /// `HFDownloader(token:)` / `HubCatalog(token:)` consult this per request, so Remove goes anonymous immediately.
    public var provider: HFTokenProvider { { [weak self] in self?.token } }
    public var isSignedIn: Bool { hasToken }

    /// Paste → whoami → keep. The token is trimmed and sanity-checked before any network; a token the Hub
    /// rejects (401/403/offline/HTTP error) is NOT kept, so `token` is always one that verified at least once.
    @discardableResult
    public func signIn(_ raw: String, transport: any HFTransport = HFURLSessionTransport()) async throws -> HFHubClient.WhoAmI {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeToken(t) else { throw SignInError.notAToken }
        let previous = token
        try setToken(t)
        do { return try await verify(transport: transport) }
        catch { try? setToken(previous); throw error }
    }

    /// Remove: Keychain item deleted; the next `token` read is nil, so every provider closure goes anonymous.
    public func signOut() { try? clear() }
}

extension HFHubClient.WhoAmI {
    public var isOrg: Bool { type == "org" }

    /// Classic read → [read]; classic write → [read, write, jobs] (a write token can run Jobs);
    /// fine-grained → from the permission strings (`repo.*read*` → read, `repo.*write*` → write, `*jobs*` → jobs).
    public var scopes: Set<HFAccount.Scope> {
        switch role {
        case "read": return [.read]
        case "write": return [.read, .write, .jobs]
        default:
            var s: Set<HFAccount.Scope> = []
            let p = fineGrainedScopes.map { $0.lowercased() }
            if p.contains(where: { $0.contains("read") || $0.contains("write") }) { s.insert(.read) }
            if canWriteRepos { s.insert(.write) }
            if canRunJobs { s.insert(.jobs) }
            return s
        }
    }
}
