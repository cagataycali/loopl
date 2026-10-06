import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - Transport

/// One request in, one response out. The only seam `HFHubClient` has to the
/// network, so tests replay recorded responses and the app routes every byte
/// through `NetworkPolicy.session` (offline switch, one place to audit).
public protocol HFTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct HFURLSessionTransport: HFTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !NetworkPolicy.isOffline else { throw HFHubError.offline }
        let (data, resp) = try await NetworkPolicy.session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw HFHubError.http(0, request.url?.path ?? "", "no HTTP response") }
        return (data, http)
    }
}

// MARK: - Errors

public enum HFHubError: LocalizedError, Equatable, Sendable {
    case offline
    case noToken
    case unauthorized                       // 401 — token missing/invalid
    case forbidden(String)                  // 403 — token lacks a scope, repo private, …
    case notFound(String)                   // 404
    case conflict(String)                   // 409 — repo already exists
    case http(Int, String, String)          // other status: code, path, body excerpt
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .offline: "offline mode is on — Hugging Face is not reached"
        case .noToken: "no Hugging Face token — add one in Settings › Hugging Face"
        case .unauthorized: "Hugging Face rejected the token (401) — paste a fresh one in Settings"
        case .forbidden(let s): "Hugging Face refused (403): \(s)"
        case .notFound(let s): "not found on Hugging Face: \(s)"
        case .conflict(let s): "already exists on Hugging Face: \(s)"
        case .http(let c, let p, let b): "HTTP \(c) for \(p)\(b.isEmpty ? "" : " — \(b)")"
        case .decoding(let s): "unexpected Hugging Face response: \(s)"
        }
    }
}

// MARK: - Client

/// Token-aware Hugging Face Hub client: who am I, my models, private dataset
/// create/commit/tree, HF Jobs create/get/logs. Pure request builders +
/// parsers are `static` and pinned by tests on recorded responses
/// (`Tests/LooplTests/Fixtures/hub/hf-*.json`); the `async` methods only glue
/// them to a transport. Nothing here ever logs or echoes the token.
public struct HFHubClient: Sendable {
    public var host: String
    public var token: String?
    public var transport: any HFTransport
    public var userAgent = "loopl/0.2 (iOS)"

    public init(token: String? = nil, host: String = "https://huggingface.co", transport: any HFTransport = HFURLSessionTransport()) {
        self.token = token; self.host = host; self.transport = transport
    }

    public enum RepoType: String, Sendable, Codable, CaseIterable {
        case model, dataset, space
        /// Path segment used by the Hub API (`/api/models/...`, `/api/datasets/...`, `/api/spaces/...`).
        public var apiPath: String { rawValue + "s" }
        /// Web/resolve prefix (`https://huggingface.co/datasets/<repo>`; models have none).
        public var webPrefix: String { self == .model ? "" : rawValue + "s/" }
    }

    // MARK: Who am I

    public struct WhoAmI: Sendable, Hashable, Decodable {
        public var name: String
        public var fullname: String?
        public var type: String?                 // "user" | "org"
        public var role: String?                 // auth.accessToken.role: "read" | "write" | "fineGrained"
        public var tokenName: String?            // auth.accessToken.displayName
        public var fineGrainedScopes: [String]   // flattened permissions of a fine-grained token (empty for classic tokens)

        /// Classic `write` tokens may do everything; fine-grained ones need the explicit permission.
        public var canWriteRepos: Bool {
            if role == "write" { return true }
            return fineGrainedScopes.contains { $0.hasPrefix("repo.write") || $0 == "repo.content.write" || $0 == "repo.content.read.write" }
        }
        public var canRunJobs: Bool {
            if role == "write" { return true }
            return fineGrainedScopes.contains { $0.hasPrefix("jobs") || $0.contains(".jobs") }
        }
        /// Short badges for the Settings row: ["write"] / ["fine-grained", "repos", "jobs"].
        public var scopeBadges: [String] {
            if role == "fineGrained" {
                var b = ["fine-grained"]
                if canWriteRepos { b.append("repos: write") }
                if canRunJobs { b.append("jobs") }
                return b
            }
            return [role ?? "read"]
        }

        public init(name: String, fullname: String? = nil, type: String? = nil, role: String? = nil, tokenName: String? = nil, fineGrainedScopes: [String] = []) {
            self.name = name; self.fullname = fullname; self.type = type; self.role = role; self.tokenName = tokenName; self.fineGrainedScopes = fineGrainedScopes
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            name = try c.decode(String.self, forKey: AnyKey("name"))
            fullname = try c.decodeIfPresent(String.self, forKey: AnyKey("fullname"))
            type = try c.decodeIfPresent(String.self, forKey: AnyKey("type"))
            var role: String? = nil, tokenName: String? = nil, scopes: [String] = []
            if let auth = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("auth")),
               let tok = try? auth.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("accessToken")) {
                role = try? tok.decode(String.self, forKey: AnyKey("role"))
                tokenName = try? tok.decode(String.self, forKey: AnyKey("displayName"))
                // fineGrained: { "scoped": [{entity:{…}, permissions:[…]}], "global": [...] }
                if let fg = try? tok.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("fineGrained")) {
                    if let global = try? fg.decode([String].self, forKey: AnyKey("global")) { scopes += global }
                    if var scoped = try? fg.nestedUnkeyedContainer(forKey: AnyKey("scoped")) {
                        while !scoped.isAtEnd {
                            if let e = try? scoped.nestedContainer(keyedBy: AnyKey.self),
                               let p = try? e.decode([String].self, forKey: AnyKey("permissions")) { scopes += p }
                            else { _ = try? scoped.decode(AnyDecodable.self) }
                        }
                    }
                }
            }
            self.role = role; self.tokenName = tokenName
            fineGrainedScopes = Array(Set(scopes)).sorted()
        }
    }

    public static func parseWhoAmI(_ data: Data) throws -> WhoAmI { try decode(WhoAmI.self, data, what: "whoami") }

    public func whoami() async throws -> WhoAmI {
        let (data, _) = try await send(get("/api/whoami-v2"), requiresToken: true)
        return try Self.parseWhoAmI(data)
    }

    // MARK: Models by author

    public struct ModelSummary: Sendable, Hashable, Decodable, Identifiable {
        public var id: String
        public var isPrivate: Bool
        public var tags: [String]
        public var pipeline: String?
        public var lastModified: String?
        public var downloads: Int?
        public var likes: Int?

        public var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
        public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
        public var isMLX: Bool { tags.contains("mlx") }
        public var isGGUF: Bool { tags.contains("gguf") }
        /// A repo loopl can run on-device (MLX safetensors or GGUF); the full-precision training outputs are not.
        public var isRunnable: Bool { isMLX || isGGUF }
        public var isLoopl: Bool { tags.contains("loopl") || name.lowercased().hasPrefix("loopl") }
        public var isAdapter: Bool { tags.contains("peft") }   // TRL tags merged full models "lora" too; peft marks a real adapter

        enum CodingKeys: String, CodingKey { case id, isPrivate = "private", tags, pipeline = "pipeline_tag", lastModified, downloads, likes }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            pipeline = try c.decodeIfPresent(String.self, forKey: .pipeline)
            lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
            downloads = try c.decodeIfPresent(Int.self, forKey: .downloads)
            likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        }
    }

    public static func parseModels(_ data: Data) throws -> [ModelSummary] { try decode([ModelSummary].self, data, what: "models") }

    /// `GET /api/models?author=<author>&limit=&sort=lastModified` — with a token this includes the author's PRIVATE repos.
    public func models(author: String, limit: Int = 100) async throws -> [ModelSummary] {
        let (data, _) = try await send(get("/api/models", query: [("author", author), ("limit", String(limit)), ("sort", "lastModified"), ("direction", "-1")]))
        return try Self.parseModels(data)
    }

    /// `GET /api/datasets?author=<author>` — the user's dataset repos (private ones included with a token), newest first.
    public struct DatasetSummary: Sendable, Hashable, Decodable, Identifiable {
        public var id: String
        public var isPrivate: Bool
        public var tags: [String]
        public var lastModified: String?
        public var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
        public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
        /// Made by loopl's Share to Hugging Face (README tags) — the natural default target for the next push.
        public var isLoopl: Bool { tags.contains("loopl") || name.lowercased().contains("loopl") }
        enum CodingKeys: String, CodingKey { case id, isPrivate = "private", tags, lastModified }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        }
    }

    public static func parseDatasets(_ data: Data) throws -> [DatasetSummary] { try decode([DatasetSummary].self, data, what: "datasets") }

    public func datasets(author: String, limit: Int = 100) async throws -> [DatasetSummary] {
        let (data, _) = try await send(get("/api/datasets", query: [("author", author), ("limit", String(limit)), ("sort", "lastModified"), ("direction", "-1")]))
        return try Self.parseDatasets(data)
    }

    // MARK: Repos

    public struct CreatedRepo: Sendable, Hashable, Decodable {
        public var url: String
        public var name: String       // "owner/name"
        public var id: String?
    }

    public static func createRepoBody(name: String, type: RepoType, isPrivate: Bool, organization: String? = nil) -> Data {
        var o: [String: JSONValue] = ["type": .string(type.rawValue), "name": .string(name), "private": .bool(isPrivate)]
        if let organization { o["organization"] = .string(organization) }
        return Data(JSONValue.object(o).compact.utf8)
    }

    public static func parseCreatedRepo(_ data: Data) throws -> CreatedRepo { try decode(CreatedRepo.self, data, what: "repos/create") }

    /// `POST /api/repos/create`. `name` is the bare repo name; the token's user owns it unless `organization` is given.
    public func createRepo(name: String, type: RepoType = .dataset, isPrivate: Bool = true, organization: String? = nil) async throws -> CreatedRepo {
        let body = Self.createRepoBody(name: name, type: type, isPrivate: isPrivate, organization: organization)
        let (data, _) = try await send(post("/api/repos/create", body: body, contentType: "application/json"), requiresToken: true)
        return try Self.parseCreatedRepo(data)
    }

    public struct TreeEntry: Sendable, Hashable, Decodable {
        public var path: String
        public var type: String     // "file" | "directory"
        public var size: Int64?
        public var oid: String?
        public var isFile: Bool { type == "file" }
    }

    public static func parseTree(_ data: Data) throws -> [TreeEntry] { try decode([TreeEntry].self, data, what: "tree") }

    /// `GET /api/<type>s/<repo>/tree/<revision>/<path>`; an empty list when the path does not exist on that revision.
    public func tree(repo: String, type: RepoType = .dataset, revision: String = "main", path: String = "") async throws -> [TreeEntry] {
        let p = "/api/\(type.apiPath)/\(repo)/tree/\(revision)" + (path.isEmpty ? "" : "/" + path)
        do {
            let (data, _) = try await send(get(p))
            return try Self.parseTree(data)
        } catch HFHubError.notFound { return [] }
    }

    public func repoExists(_ repo: String, type: RepoType = .dataset) async throws -> Bool {
        do { _ = try await send(get("/api/\(type.apiPath)/\(repo)")); return true }
        catch HFHubError.notFound { return false }
    }

    public func fileExists(repo: String, type: RepoType = .dataset, revision: String = "main", path: String) async throws -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        return try await tree(repo: repo, type: type, revision: revision, path: dir).contains { $0.path == path && $0.isFile }
    }

    // MARK: Commit

    /// One file to add or replace in a commit. Small shards only (base64 inline, ≤ ~10 MB per op); bigger blobs need the LFS preupload dance.
    public struct FileOp: Sendable, Hashable {
        public var path: String
        public var data: Data
        public init(path: String, data: Data) { self.path = path; self.data = data }
        public init(path: String, text: String) { self.path = path; self.data = Data(text.utf8) }
    }

    public struct CommitResult: Sendable, Hashable, Decodable {
        public var commitOid: String
        public var commitUrl: String
        public var success: Bool?
    }

    /// The ndjson body of `POST /api/<type>s/<repo>/commit/<rev>`: a `header` line, one `file` line per
    /// upload (base64) and one `deletedFile` line per deletion. Byte-exact; tests pin it.
    public static func commitBody(summary: String, description: String? = nil, files: [FileOp], deletes: [String] = []) -> Data {
        var lines: [String] = []
        var header: [String: JSONValue] = ["summary": .string(summary)]
        if let description { header["description"] = .string(description) }
        lines.append(JSONValue.object(["key": .string("header"), "value": .object(header)]).compact)
        for f in files {
            lines.append(JSONValue.object(["key": .string("file"), "value": .object([
                "path": .string(f.path), "encoding": .string("base64"), "content": .string(f.data.base64EncodedString()),
            ])]).compact)
        }
        for d in deletes {
            lines.append(JSONValue.object(["key": .string("deletedFile"), "value": .object(["path": .string(d)])]).compact)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func parseCommit(_ data: Data) throws -> CommitResult { try decode(CommitResult.self, data, what: "commit") }

    public func commit(repo: String, type: RepoType = .dataset, revision: String = "main",
                       summary: String, description: String? = nil, files: [FileOp], deletes: [String] = []) async throws -> CommitResult {
        let body = Self.commitBody(summary: summary, description: description, files: files, deletes: deletes)
        let (data, _) = try await send(post("/api/\(type.apiPath)/\(repo)/commit/\(revision)", body: body, contentType: "application/x-ndjson"), requiresToken: true)
        return try Self.parseCommit(data)
    }

    /// Download one file's bytes (`/<type-prefix><repo>/resolve/<rev>/<path>`), with the token so private repos work.
    public func fileData(repo: String, type: RepoType = .dataset, revision: String = "main", path: String) async throws -> Data {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let (data, _) = try await send(get("/\(type.webPrefix)\(repo)/resolve/\(revision)/\(escaped)"))
        return data
    }

    // MARK: Jobs

    /// What `hf jobs run` sends: a docker image (or a Space), a command, a flavor, env + secrets. Secrets never come back from the API.
    public struct JobSpec: Sendable, Hashable {
        public var dockerImage: String
        public var command: [String]
        public var arguments: [String] = []
        public var environment: [String: String] = [:]
        public var secrets: [String: String] = [:]
        public var flavor: String                // "cpu-basic", "a10g-small", "a100-large", "h200", …
        public var timeoutSeconds: Int? = nil
        public init(dockerImage: String, command: [String], arguments: [String] = [], environment: [String: String] = [:],
                    secrets: [String: String] = [:], flavor: String, timeoutSeconds: Int? = nil) {
            self.dockerImage = dockerImage; self.command = command; self.arguments = arguments; self.environment = environment
            self.secrets = secrets; self.flavor = flavor; self.timeoutSeconds = timeoutSeconds
        }
        /// `hf jobs uv run <scriptURL> <args…>` on the official uv image.
        public static func uvRun(script: String, args: [String], flavor: String, secrets: [String: String] = [:], environment: [String: String] = [:],
                                 python: String = "3.12", timeoutSeconds: Int? = 4 * 3600) -> JobSpec {
            JobSpec(dockerImage: "ghcr.io/astral-sh/uv:python\(python)-bookworm", command: ["uv", "run", script] + args,
                    environment: environment, secrets: secrets, flavor: flavor, timeoutSeconds: timeoutSeconds)
        }
    }

    public struct Job: Sendable, Hashable, Decodable, Identifiable {
        public struct Status: Sendable, Hashable, Decodable {
            public var stage: String            // PENDING | RUNNING | COMPLETED | ERROR | CANCELED | DELETED
            public var message: String?
            public var failureCount: Int?
        }
        public struct Durations: Sendable, Hashable, Decodable { public var schedulingSecs: Int?; public var runningSecs: Int?; public var totalSecs: Int? }
        public var id: String
        public var createdAt: String?
        public var startedAt: String?
        public var dockerImage: String?
        public var command: [String]
        public var flavor: String?
        public var timeout: Int?
        public var status: Status
        public var durations: Durations?
        public var labels: [String: String]?

        public var stage: String { status.stage.uppercased() }
        public var isRunning: Bool { stage == "RUNNING" || stage == "PENDING" || stage == "UPDATING" }
        public var isDone: Bool { ["COMPLETED", "ERROR", "CANCELED", "DELETED", "FAILED"].contains(stage) }
        public var succeeded: Bool { stage == "COMPLETED" }

        enum CodingKeys: String, CodingKey { case id, createdAt, startedAt, dockerImage, command, flavor, timeout, status, durations, labels }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
            dockerImage = try c.decodeIfPresent(String.self, forKey: .dockerImage)
            command = try c.decodeIfPresent([String].self, forKey: .command) ?? []
            flavor = try c.decodeIfPresent(String.self, forKey: .flavor)
            timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
            status = try c.decode(Status.self, forKey: .status)
            durations = try c.decodeIfPresent(Durations.self, forKey: .durations)
            labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
        }
    }

    public static func createJobBody(_ spec: JobSpec) -> Data {
        var o: [String: JSONValue] = [
            "dockerImage": .string(spec.dockerImage),
            "command": .array(spec.command.map(JSONValue.string)),
            "arguments": .array(spec.arguments.map(JSONValue.string)),
            "environment": .object(spec.environment.mapValues(JSONValue.string)),
            "secrets": .object(spec.secrets.mapValues(JSONValue.string)),
            "flavor": .string(spec.flavor),
        ]
        if let t = spec.timeoutSeconds { o["timeout"] = .number(Double(t)) }
        return Data(JSONValue.object(o).compact.utf8)
    }

    public static func parseJob(_ data: Data) throws -> Job { try decode(Job.self, data, what: "job") }
    public static func parseJobs(_ data: Data) throws -> [Job] { try decode([Job].self, data, what: "jobs") }

    /// `POST /api/jobs/<namespace>` — bills the NAMESPACE's account. Callers show the cost and get approval first.
    public func createJob(namespace: String, _ spec: JobSpec) async throws -> Job {
        let (data, _) = try await send(post("/api/jobs/\(namespace)", body: Self.createJobBody(spec), contentType: "application/json"), requiresToken: true)
        return try Self.parseJob(data)
    }

    public func job(namespace: String, id: String) async throws -> Job {
        let (data, _) = try await send(get("/api/jobs/\(namespace)/\(id)"), requiresToken: true)
        return try Self.parseJob(data)
    }

    public func jobs(namespace: String) async throws -> [Job] {
        let (data, _) = try await send(get("/api/jobs/\(namespace)"), requiresToken: true)
        return try Self.parseJobs(data)
    }

    public func cancelJob(namespace: String, id: String) async throws {
        _ = try await send(post("/api/jobs/\(namespace)/\(id)/cancel", body: Data(), contentType: "application/json"), requiresToken: true)
    }

    public struct LogLine: Sendable, Hashable { public var text: String; public var timestamp: String? }

    /// The logs endpoint streams server-sent events: `data: {"data": "...", "timestamp": "..."}` per line.
    public static func parseLogs(_ text: String) -> [LogLine] {
        var out: [LogLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(raw)
            if line.hasPrefix("data:") { line = line.dropFirst(5).drop(while: { $0 == " " }) }
            guard let v = JSONValue.parse(String(line)) else { continue }
            guard let s = v["data"]?.stringValue else { continue }
            out.append(LogLine(text: s, timestamp: v["timestamp"]?.stringValue))
        }
        return out
    }

    /// Fetches what the log stream has so far (the endpoint returns the buffered SSE body, then keeps the connection
    /// open for a live job — a bounded timeout makes it a snapshot).
    public func jobLogs(namespace: String, id: String, timeout: TimeInterval = 10) async throws -> [LogLine] {
        var req = get("/api/jobs/\(namespace)/\(id)/logs")
        req.timeoutInterval = timeout
        do {
            let (data, _) = try await send(req, requiresToken: true)
            return Self.parseLogs(String(decoding: data, as: UTF8.self))
        } catch let e as URLError where e.code == .timedOut { return [] }
    }

    // MARK: Request plumbing

    func get(_ path: String, query: [(String, String)] = []) -> URLRequest {
        var comps = URLComponents(string: host + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return request(comps.url!, method: "GET")
    }

    func post(_ path: String, body: Data, contentType: String) -> URLRequest {
        var r = request(URL(string: host + path)!, method: "POST")
        r.httpBody = body
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return r
    }

    func request(_ url: URL, method: String) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = method
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    @discardableResult
    func send(_ req: URLRequest, requiresToken: Bool = false) async throws -> (Data, HTTPURLResponse) {
        if requiresToken, (token ?? "").isEmpty { throw HFHubError.noToken }
        let (data, http) = try await transport.send(req)
        try Self.check(http.statusCode, path: req.url?.path ?? "", body: data)
        return (data, http)
    }

    /// Hub error bodies are `{"error": "..."}`; surface that text, never the token.
    public static func check(_ code: Int, path: String, body: Data) throws {
        guard !(200..<300).contains(code) else { return }
        let msg = JSONValue.parse(String(decoding: body, as: UTF8.self))?["error"]?.stringValue ?? String(decoding: body.prefix(200), as: UTF8.self)
        switch code {
        case 401: throw HFHubError.unauthorized
        case 403: throw HFHubError.forbidden(msg.isEmpty ? path : msg)
        case 404: throw HFHubError.notFound(msg.isEmpty ? path : msg)
        case 409: throw HFHubError.conflict(msg.isEmpty ? path : msg)
        default: throw HFHubError.http(code, path, msg)
        }
    }

    static func decode<T: Decodable>(_ t: T.Type, _ data: Data, what: String) throws -> T {
        do { return try JSONDecoder().decode(t, from: data) }
        catch { throw HFHubError.decoding("\(what): \(error)") }
    }
}

// MARK: - Account (Keychain-backed token)

/// Where the token lives. The Keychain on device; an in-memory store in tests.
public protocol HFTokenStore: Sendable {
    func read() -> String?
    func write(_ token: String?) throws
}

public final class HFMemoryTokenStore: HFTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ initial: String? = nil) { value = initial }
    public func read() -> String? { lock.withLock { value } }
    public func write(_ token: String?) throws { lock.withLock { value = token } }
}

#if canImport(Security)
/// `kSecClassGenericPassword`, service "technology.tiny.loopl.hf", account "token". This-device-only
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never synced to iCloud Keychain.
public struct HFKeychainTokenStore: HFTokenStore {
    public var service = "technology.tiny.loopl.hf"
    public var account = "token"
    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func write(_ token: String?) throws {
        SecItemDelete(query as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw HFHubError.http(Int(st), "keychain", "could not store the token") }
    }
}
#endif

/// The user's Hugging Face identity on this device. ONE token, in the Keychain, used for private downloads,
/// dataset pushes and HF Jobs. `HFAccount.shared` is what the app and every lane read;
/// `HFAccount(store:)` with a memory store is what tests use.
public final class HFAccount: @unchecked Sendable {
    public static let shared = HFAccount()

    private let lock = NSLock()
    private let store: any HFTokenStore
    private var cachedToken: String?
    private var cachedWhoAmI: HFHubClient.WhoAmI?
    public var host = "https://huggingface.co"

    public init(store: (any HFTokenStore)? = nil) {
        #if canImport(Security)
        self.store = store ?? HFKeychainTokenStore()
        #else
        self.store = store ?? HFMemoryTokenStore()
        #endif
        // Dev/test override: inject a token through the environment (simulator runs) without touching the Keychain.
        if let env = ProcessInfo.processInfo.environment["LOOPL_HF_TOKEN"], !env.isEmpty { cachedToken = env }
        else { cachedToken = self.store.read() }
    }

    /// The raw token, or nil. Never log it.
    public var token: String? { lock.withLock { cachedToken } }
    public var hasToken: Bool { !(token ?? "").isEmpty }

    /// Last successful whoami (memory only; refreshed by `verify()`).
    public var whoami: HFHubClient.WhoAmI? { lock.withLock { cachedWhoAmI } }
    public var username: String? { whoami?.name }

    /// Store (or clear with nil/empty) the token. Trims whitespace/newlines from a paste.
    public func setToken(_ raw: String?) throws {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.write((t ?? "").isEmpty ? nil : t)
        lock.withLock { cachedToken = (t ?? "").isEmpty ? nil : t; cachedWhoAmI = nil }
    }

    public func clear() throws { try setToken(nil) }

    /// A client bound to the current token (nil token → anonymous client; token-requiring calls throw `.noToken`).
    public func client(transport: any HFTransport = HFURLSessionTransport()) -> HFHubClient {
        HFHubClient(token: token, host: host, transport: transport)
    }

    /// Calls whoami with the stored token and caches the identity. Throws `.unauthorized` for a dead token.
    @discardableResult
    public func verify(transport: any HFTransport = HFURLSessionTransport()) async throws -> HFHubClient.WhoAmI {
        let who = try await client(transport: transport).whoami()
        lock.withLock { cachedWhoAmI = who }
        return who
    }

    /// `hf_` + 30+ chars is what every Hub token looks like today; a cheap paste sanity check, not a verification.
    public static func looksLikeToken(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("hf_") && t.count >= 20 && !t.contains(" ")
    }
}

// MARK: - Decoding helpers

struct AnyKey: CodingKey {
    var stringValue: String; var intValue: Int?
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
}

/// Swallows one arbitrary JSON value while walking an unkeyed container.
struct AnyDecodable: Decodable { init(from decoder: any Decoder) throws { _ = try JSONValue(from: decoder) } }
