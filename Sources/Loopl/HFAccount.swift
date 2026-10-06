import Foundation
#if canImport(Security)
import Security
#endif

/// The user's Hugging Face token — the ONLY credential loopl ever holds. It lives in this device's
/// Keychain (`ThisDeviceOnly`: never synced to iCloud Keychain), is read on demand through
/// `HFAccount.shared.token`, and leaves the device solely as an `Authorization: Bearer` header to
/// huggingface.co (`HFDownloader` / `HubCatalog` / the hub client). No loopl account, no analytics.
///
/// `signIn(_:)` verifies the pasted token with `GET /api/whoami-v2` BEFORE storing it, so a typo never
/// lands in the Keychain; the answer (`Identity`) is what Settings shows: name, avatar, scope badges.
public final class HFAccount: @unchecked Sendable {
    public static let shared = HFAccount()

    /// Where the token is kept. Keychain in the app; tests inject memory.
    public protocol TokenStore: Sendable {
        func read() -> String?
        func write(_ token: String?)
    }

    public var host = "https://huggingface.co"
    private let store: TokenStore
    private let lock = NSLock()
    private var cached: String??        // nil = not read yet; .some(nil) = known empty

    public init(store: TokenStore = KeychainTokenStore(), host: String = "https://huggingface.co") {
        self.store = store; self.host = host
    }

    /// Synchronous and cheap (Keychain read once, then cached) — safe to call from any request path.
    public var token: String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let t = store.read().flatMap { $0.isEmpty ? nil : $0 }
        cached = .some(t)
        return t
    }
    public var isSignedIn: Bool { token != nil }

    /// The provider `HFDownloader(token:)` / `HubCatalog(token:)` take.
    public var provider: HFTokenProvider { { [weak self] in self?.token } }

    /// Who the token belongs to, as `whoami-v2` reports it.
    public struct Identity: Sendable, Hashable, Codable {
        public var name: String                  // "cagataydev"
        public var fullname: String?
        public var avatarURL: URL?
        public var isOrg: Bool
        public var tokenName: String?            // the label the user gave the token on huggingface.co
        public var role: String?                 // "read" | "write" | "fineGrained"
        public var scopes: Set<Scope>
        public init(name: String, fullname: String? = nil, avatarURL: URL? = nil, isOrg: Bool = false, tokenName: String? = nil, role: String? = nil, scopes: Set<Scope> = []) {
            self.name = name; self.fullname = fullname; self.avatarURL = avatarURL; self.isOrg = isOrg; self.tokenName = tokenName; self.role = role; self.scopes = scopes
        }
    }

    /// What loopl needs the token for: `read` private models · `write` push conversations to a dataset ·
    /// `jobs` start a training job. Classic tokens: read → [read], write → [read, write, jobs]
    /// (a write token can run Jobs); fine-grained tokens: derived from the permission strings.
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

    public enum AccountError: LocalizedError, Equatable {
        case offline, invalidToken, http(Int), badJSON, notAToken
        public var errorDescription: String? {
            switch self {
            case .offline: "offline mode is on — turn it off to verify the token"
            case .invalidToken: "Hugging Face did not accept this token — check it on huggingface.co › Settings › Access Tokens"
            case .http(let c): "Hugging Face answered HTTP \(c)"
            case .badJSON: "unexpected answer from Hugging Face"
            case .notAToken: "that does not look like a Hugging Face token (they start with hf_)"
            }
        }
    }

    /// `GET /api/whoami-v2` with the given token. Pure network; stores nothing.
    public func whoami(_ token: String) async throws -> Identity {
        guard !NetworkPolicy.isOffline else { throw AccountError.offline }
        var r = URLRequest(url: URL(string: "\(host)/api/whoami-v2")!, timeoutInterval: 20)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("loopl/0.3 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await NetworkPolicy.session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw AccountError.invalidToken }
        guard code == 200 else { throw AccountError.http(code) }
        return try Self.parseWhoami(data)
    }

    /// Verify, then keep. The token is trimmed; whitespace from a paste never reaches the Keychain.
    @discardableResult
    public func signIn(_ raw: String) async throws -> Identity {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeToken(token) else { throw AccountError.notAToken }
        let who = try await whoami(token)
        set(token)
        return who
    }

    private func set(_ token: String?) {
        lock.withLock { store.write(token); cached = .some(token) }
    }

    /// Remove: Keychain item deleted; the next `token` read is nil, so every provider closure goes anonymous.
    public func signOut() { set(nil) }

    public static func looksLikeToken(_ s: String) -> Bool {
        s.hasPrefix("hf_") && s.count >= 20 && !s.contains(where: { $0.isWhitespace })
    }

    public static func parseWhoami(_ data: Data) throws -> Identity {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = row["name"] as? String else { throw AccountError.badJSON }
        let auth = row["auth"] as? [String: Any]
        let at = auth?["accessToken"] as? [String: Any]
        let role = at?["role"] as? String
        var scopes: Set<Scope> = []
        switch role {
        case "read": scopes = [.read]
        case "write": scopes = [.read, .write, .jobs]
        default:
            // Fine-grained: {"fineGrained":{"global":["inference.serverless.write", …],"scoped":[{"entity":{…},"permissions":["repo.content.read", …]}]}}
            var perms: [String] = []
            if let fg = at?["fineGrained"] as? [String: Any] {
                perms += fg["global"] as? [String] ?? []
                for s in fg["scoped"] as? [[String: Any]] ?? [] { perms += s["permissions"] as? [String] ?? [] }
            }
            let p = perms.map { $0.lowercased() }
            if p.contains(where: { $0.contains("read") || $0.contains("write") }) { scopes.insert(.read) }
            if p.contains(where: { $0.hasPrefix("repo") && $0.contains("write") }) { scopes.insert(.write) }
            if p.contains(where: { $0.contains("job") }) { scopes.insert(.jobs) }
        }
        return Identity(name: name, fullname: row["fullname"] as? String,
                        avatarURL: (row["avatarUrl"] as? String).flatMap { URL(string: $0.hasPrefix("/") ? "https://huggingface.co" + $0 : $0) },
                        isOrg: (row["type"] as? String) == "org",
                        tokenName: at?["displayName"] as? String, role: role, scopes: scopes)
    }
}

/// Generic-password item, this device only (no iCloud Keychain), readable after first unlock so a
/// background download can resume. One service, one account: paste replaces, Remove deletes.
public struct KeychainTokenStore: HFAccount.TokenStore {
    public var service = "dev.loopl.huggingface"
    public var account = "token"
    public init() {}
    public init(service: String, account: String = "token") { self.service = service; self.account = account }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read() -> String? {
        #if canImport(Security)
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
        #else
        return nil
        #endif
    }
    public func write(_ token: String?) {
        #if canImport(Security)
        SecItemDelete(query as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
        #endif
    }
}

/// For tests and previews.
public final class MemoryTokenStore: HFAccount.TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func read() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    public func write(_ token: String?) { lock.lock(); value = token; lock.unlock() }
}
