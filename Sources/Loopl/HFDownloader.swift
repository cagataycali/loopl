import Foundation

/// Hugging Face repo download with resume, per-byte progress, token auth
/// and a hard offline gate. Written by hand (not `HubApi`) so every byte
/// that leaves the device goes through `NetworkPolicy.session` and the
/// offline rule is one `guard` at the top of each request.
public struct HFDownloader: Sendable {
    public var token: String?
    public var host = "https://huggingface.co"
    public init(token: String?) { self.token = token }

    public struct RemoteFile: Sendable, Hashable, Decodable {
        public var path: String
        public var size: Int64
        public var type: String
        public init(path: String, size: Int64, type: String) { self.path = path; self.size = size; self.type = type }
    }

    public enum DLError: LocalizedError {
        case offline, http(Int, String), gated(String), io(String)
        public var errorDescription: String? {
            switch self {
            case .offline: "offline mode is on — downloads are refused"
            case .http(let c, let p): "HTTP \(c) for \(p)"
            case .gated(let repo): "\(repo) is gated — accept the licence on huggingface.co and add your token in Settings"
            case .io(let s): s
            }
        }
    }

    /// Files an MLX model needs. Weights + tokenizer + configs; nothing else (no README, no pytorch bins).
    public static func wanted(_ f: RemoteFile) -> Bool {
        guard f.type == "file" else { return false }
        let p = f.path
        if p.contains("/") { return false }
        if p.hasSuffix(".safetensors") { return true }
        let names: Set<String> = ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
                                  "tokenizer.model", "special_tokens_map.json", "model.safetensors.index.json",
                                  "chat_template.jinja", "chat_template.json", "added_tokens.json", "merges.txt", "vocab.json"]
        return names.contains(p)
    }

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.setValue("loopl/0.1 (iOS; mlx)", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public func listFiles(repo: String, revision: String = "main") async throws -> [RemoteFile] {
        guard !NetworkPolicy.isOffline else { throw DLError.offline }
        let url = URL(string: "\(host)/api/models/\(repo)/tree/\(revision)?recursive=false")!
        let (data, resp) = try await NetworkPolicy.session.data(for: request(url))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw DLError.gated(repo) }
        guard code == 200 else { throw DLError.http(code, url.path) }
        return try JSONDecoder().decode([RemoteFile].self, from: data).filter(Self.wanted)
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

        let (bytes, resp) = try await NetworkPolicy.session.bytes(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 401 || code == 403 { throw DLError.gated(repo) }
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
