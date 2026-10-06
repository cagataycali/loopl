import Foundation

/// Supplies the user's Hugging Face token at request time, or `nil` for an anonymous call.
/// A closure (not a value) so the Keychain stays the single source of truth: paste or Remove in
/// Settings takes effect on the very next request, and a token is never copied into a long-lived struct.
public typealias HFTokenProvider = @Sendable () -> String?

/// Hugging Face repo download with resume, per-byte progress and a hard
/// offline gate. ANONYMOUS by default: `HFDownloader()` sends no credential, exactly as
/// the public catalog needs. Pass `token:` to read PRIVATE repos — the only thing the token
/// is used for is an `Authorization: Bearer` header on requests to `host`, nothing else.
/// Written by hand (not `HubApi`) so every byte that leaves the device goes through
/// `NetworkPolicy.session` and the offline rule is one `guard` per request.
public struct HFDownloader: Sendable {
    public var host = "https://huggingface.co"
    /// `nil` → anonymous. Consulted per request (see `HFTokenProvider`).
    public var token: HFTokenProvider?
    public init(token: HFTokenProvider? = nil) { self.token = token }

    public struct RemoteFile: Sendable, Hashable, Decodable {
        public var path: String
        public var size: Int64
        public var type: String
        public init(path: String, size: Int64, type: String) { self.path = path; self.size = size; self.type = type }
    }

    public enum DLError: LocalizedError, Equatable {
        case offline, http(Int, String), io(String)
        /// 401/403 with NO token: the repo is private or gated — a token would help.
        case signInRequired(String)
        /// 401/403 WITH a token: this account cannot read the repo (not yours, gated terms not accepted, or the token is read-less).
        case noAccess(String)
        /// Kept for callers that matched on it; new code sees `signInRequired` / `noAccess`.
        @available(*, deprecated, renamed: "signInRequired")
        public static func gated(_ repo: String) -> DLError { .signInRequired(repo) }
        public var errorDescription: String? {
            switch self {
            case .offline: "offline mode is on — downloads are refused"
            case .http(let c, let p): "HTTP \(c) for \(p)"
            case .signInRequired(let repo): "\(repo) is private or gated — sign in to Hugging Face in Settings to download it"
            case .noAccess(let repo): "your Hugging Face account can't read \(repo) — it is private or gated; check access on huggingface.co"
            case .io(let s): s
            }
        }
    }

    /// 401/403 → the error that tells the user what to do next.
    func denied(_ repo: String) -> DLError { Self.denied(repo, hasToken: bearer != nil) }
    public static func denied(_ repo: String, hasToken: Bool) -> DLError { hasToken ? .noAccess(repo) : .signInRequired(repo) }

    /// The token for this request, or nil (empty strings count as no token).
    var bearer: String? { token?().flatMap { $0.isEmpty ? nil : $0 } }

    /// Files an MLX model needs. Weights + tokenizer + configs; nothing else (no README, no pytorch bins).
    public static func wanted(_ f: RemoteFile) -> Bool {
        guard f.type == "file" else { return false }
        let p = f.path
        if p.contains("/") { return false }
        if p.hasSuffix(".safetensors") { return true }
        if p.hasSuffix(".gguf") { return false }   // GGUF repos are fetched one file at a time (`files(for:)`)
        let names: Set<String> = ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
                                  "tokenizer.model", "special_tokens_map.json", "model.safetensors.index.json",
                                  "chat_template.jinja", "chat_template.json", "added_tokens.json", "merges.txt", "vocab.json"]
        return names.contains(p)
    }

    /// Every request the downloader makes. The bearer is attached ONLY to URLs on `host`
    /// (never to a redirect target or a CDN — URLSession drops Authorization across hosts on its own,
    /// this guard makes the intent explicit and testable).
    public func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.setValue("loopl/0.2 (iOS)", forHTTPHeaderField: "User-Agent")
        if let t = bearer, Self.sameHost(url, host) { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    static func sameHost(_ url: URL, _ host: String) -> Bool {
        url.host?.lowercased() == URL(string: host)?.host?.lowercased()
    }

    /// What to download for a catalog entry: every MLX file, or the one GGUF file.
    public func files(for spec: ModelSpec) async throws -> [RemoteFile] {
        let all = try await listFiles(repo: spec.repo, revision: spec.revision ?? "main", filter: false)
        if spec.runtime == .gguf {
            guard let name = spec.file, let f = all.first(where: { $0.path == name }) else {
                throw DLError.io("\(spec.repo) has no file named \(spec.file ?? "<nil>")")
            }
            return [f]
        }
        return all.filter(Self.wanted)
    }

    public func listFiles(repo: String, revision: String = "main", filter: Bool = true) async throws -> [RemoteFile] {
        guard !NetworkPolicy.isOffline else { throw DLError.offline }
        let url = URL(string: "\(host)/api/models/\(repo)/tree/\(revision)?recursive=false")!
        let (data, resp) = try await NetworkPolicy.session.data(for: request(url))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw denied(repo) }
        guard code == 200 else { throw DLError.http(code, url.path) }
        let files = try JSONDecoder().decode([RemoteFile].self, from: data).filter { $0.type == "file" }
        return filter ? files.filter(Self.wanted) : files
    }

    /// Downloads one file to `dest` with `Range` resume via a `.part` sidecar.
    /// `onBytes` receives the bytes written *in this call* (delta), so the
    /// caller sums across files.
    public func download(repo: String, revision: String = "main", file: RemoteFile, to dest: URL,
                         onBytes: @Sendable @escaping (Int64) -> Void) async throws {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: dest.path), (attrs[.size] as? Int64) == file.size {
            onBytes(file.size); return   // already complete
        }
        guard !NetworkPolicy.isOffline else { throw DLError.offline }
        let part = dest.appendingPathExtension("part")
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var have: Int64 = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64 ?? 0
        if have > file.size { try? fm.removeItem(at: part); have = 0 }
        if have > 0 { onBytes(have) }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        let escaped = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        let url = URL(string: "\(host)/\(repo)/resolve/\(revision)/\(escaped)")!
        var req = request(url)
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

        // `resolve/` answers 302 to a CDN (cas-bridge / cdn-lfs) with a pre-signed URL; a Bearer riding
        // along would be a second credential (S3 answers 400) and would leak the token off huggingface.co.
        let (bytes, resp) = try await NetworkPolicy.session.bytes(for: req, delegate: bearer == nil ? nil : RedirectScrubber(host: host))
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 401 || code == 403 { throw denied(repo) }
        if code == 416 { try? fm.removeItem(at: part); throw DLError.io("range mismatch for \(file.path); retry") }
        guard code == 200 || code == 206 else { throw DLError.http(code, file.path) }
        if code == 200, have > 0 {           // server ignored Range → start over
            try fm.removeItem(at: part); fm.createFile(atPath: part.path, contents: nil)
            onBytes(-have); have = 0
        }

        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        var lastReport = Date()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer); written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.2 { onBytes(written); written = 0; lastReport = Date() }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
        if written > 0 { onBytes(written) }
        try handle.close()

        let final = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64 ?? -1
        guard final == file.size else { throw DLError.io("\(file.path): got \(final) of \(file.size) bytes") }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: part, to: dest)
    }
}

/// Drops `Authorization` when a redirect leaves `host`. Per-task delegate (iOS 15+), so the shared
/// `NetworkPolicy.session` stays untouched for every other caller.
final class RedirectScrubber: NSObject, URLSessionTaskDelegate, Sendable {
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.scrub(request, host: host))
    }
    static func scrub(_ request: URLRequest, host: String) -> URLRequest {
        guard let url = request.url, !HFDownloader.sameHost(url, host) else { return request }
        var r = request
        r.setValue(nil, forHTTPHeaderField: "Authorization")
        return r
    }
}
