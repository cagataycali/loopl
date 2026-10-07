import XCTest
import Network
import CryptoKit
@testable import Loopl

/// The small-file story behind "Qwen3_5Tokenizer is not supported" (2026-10-06): what the audit sees, how a load
/// error is classified, and how a model's small files are repaired from the Hub without re-downloading weights.
final class TokenizerFilesTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tokenizer")

    func testAuditFlagsTheTransformers5Export() {
        // tokenizer_config.json exactly as transformers 5 wrote it into cagataydev/loopl-0.8b-4bit (rev 3a5efee7), no template file.
        let a = TokenizerFiles.audit(Self.fixtures.appendingPathComponent("transformers5"))
        XCTAssertEqual(a.tokenizerClass, "Qwen3_5Tokenizer")
        XCTAssertTrue(a.unknownClass)
        XCTAssertTrue(a.hasTokenizerJSON)
        XCTAssertFalse(a.hasChatTemplate)
        XCTAssertFalse(a.isLoadableNonStrict, "no chat template → even the BPE fallback cannot serve a chat")
    }

    func testAuditAcceptsTheNormalisedExport() {
        let a = TokenizerFiles.audit(Self.fixtures.appendingPathComponent("normalised"))
        XCTAssertEqual(a.tokenizerClass, "Qwen2Tokenizer")
        XCTAssertFalse(a.unknownClass)
        XCTAssertTrue(a.hasChatTemplate, "chat_template.jinja counts")
        XCTAssertTrue(a.isLoadableNonStrict)
    }

    func testAuditOfAMissingDirectory() {
        let a = TokenizerFiles.audit(URL(fileURLWithPath: "/nonexistent/loopl"))
        XCTAssertNil(a.tokenizerClass)
        XCTAssertFalse(a.unknownClass)
        XCTAssertFalse(a.isLoadableNonStrict)
    }

    func testKnownClassesIgnoreTheFastSuffix() {
        XCTAssertFalse(TokenizerFiles.Audit(tokenizerClass: "Qwen2TokenizerFast", hasTokenizerJSON: true, hasChatTemplate: true).unknownClass)
        XCTAssertFalse(TokenizerFiles.Audit(tokenizerClass: "PreTrainedTokenizer", hasTokenizerJSON: true, hasChatTemplate: true).unknownClass)
        XCTAssertFalse(TokenizerFiles.Audit(tokenizerClass: "TokenizersBackend", hasTokenizerJSON: true, hasChatTemplate: true).unknownClass)
        XCTAssertTrue(TokenizerFiles.Audit(tokenizerClass: "Qwen3_5Tokenizer", hasTokenizerJSON: true, hasChatTemplate: true).unknownClass)
    }

    func testTokenizerErrorsAreRecognisedAndOthersAreNot() {
        // swift-transformers' message, verbatim from the owner's phone.
        XCTAssertTrue(TokenizerFiles.isTokenizerError("Qwen3_5Tokenizer is not supported"))
        XCTAssertTrue(TokenizerFiles.isTokenizerError("unsupportedTokenizer(\"Qwen3_5Tokenizer\")"))
        XCTAssertTrue(TokenizerFiles.isTokenizerError("missingChatTemplate"))
        XCTAssertTrue(TokenizerFiles.isTokenizerError("No chat template was specified"))
        XCTAssertTrue(TokenizerFiles.isTokenizerError(ModelError("tokenizer_config.json could not be read")))
        XCTAssertFalse(TokenizerFiles.isTokenizerError("The file “config.json.part” doesn’t exist."))
        XCTAssertFalse(TokenizerFiles.isTokenizerError("SanDisk was disconnected while loading loopl 4B."))
        XCTAssertFalse(TokenizerFiles.isTokenizerError(ModelError("out of memory")))
    }

    func testGitBlobSHA1MatchesGit() {
        // `printf 'hello\n' | git hash-object --stdin` → ce013625030ba8dba906f756967f9e9ca394464a
        XCTAssertEqual(TokenizerFiles.gitBlobSHA1(Data("hello\n".utf8)), "ce013625030ba8dba906f756967f9e9ca394464a")
        // empty blob
        XCTAssertEqual(TokenizerFiles.gitBlobSHA1(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        XCTAssertNil(TokenizerFiles.gitBlobSHA1(contentsOf: URL(fileURLWithPath: "/nonexistent")))
    }

    func testRemoteFileDecodesTheTreeOidAndLFS() throws {
        let json = #"[{"type":"file","oid":"c6c5184301c694c20fa3b3b4a08a8516f419aade","size":6771,"path":"tokenizer_config.json"},{"type":"file","oid":"abc","size":444000000,"path":"model.safetensors","lfs":{"oid":"deadbeef","size":444000000}}]"#
        let files = try JSONDecoder().decode([HFDownloader.RemoteFile].self, from: Data(json.utf8))
        XCTAssertEqual(files[0].oid, "c6c5184301c694c20fa3b3b4a08a8516f419aade")
        XCTAssertNil(files[0].lfs)
        XCTAssertEqual(files[1].lfs?.oid, "deadbeef")
        XCTAssertEqual(files[1].path, "model.safetensors")
        // matches(): git blob hash for plain files, SHA-256 for LFS, size when the API gave no hash
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rf-\(UUID().uuidString)")
        try Data("hello\n".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertTrue(HFDownloader.RemoteFile(path: "x", size: 6, type: "file", oid: "ce013625030ba8dba906f756967f9e9ca394464a").matches(tmp))
        XCTAssertFalse(HFDownloader.RemoteFile(path: "x", size: 6, type: "file", oid: "0000").matches(tmp))
        XCTAssertTrue(HFDownloader.RemoteFile(path: "x", size: 6, type: "file", oid: "pointer", lfs: .init(oid: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")).matches(tmp))
        XCTAssertTrue(HFDownloader.RemoteFile(path: "x", size: 6, type: "file").matches(tmp))
        XCTAssertFalse(HFDownloader.RemoteFile(path: "x", size: 7, type: "file").matches(tmp))
        XCTAssertTrue(TokenizerFiles.names.contains(files[0].path))
        XCTAssertFalse(TokenizerFiles.names.contains(files[1].path), "weights are never part of a repair")
    }

    /// IMPROVE-9: this test used to read
    /// ```
    /// XCTAssertTrue(m.contains("Repair"))
    /// XCTAssertTrue(m.contains("weights stay"))
    /// ```
    /// — and so it **held the bug in place**. loopl has never had a Repair button (the repair is automatic in
    /// `Engine.load`; the only control in the failed state is Try again), and "weights" is the packager's word,
    /// not the reader's. A test asserting the presence of a defect is why nobody questioned it. What actually
    /// matters is that each message names the model and an action that exists.
    func testLoadFailureMessagesNameTheModelAndARealAction() {
        for m in [TokenizerFiles.needsInternetMessage(for: "loopl 4B"),
                  TokenizerFiles.fetchFailedMessage(for: "loopl 4B"),
                  TokenizerFiles.cannotBeFixedMessage(for: "loopl 4B")] {
            XCTAssertTrue(m.contains("loopl 4B"), m)
            XCTAssertFalse(m.lowercased().contains("repair"), "no such button: \(m)")
            XCTAssertFalse(m.contains("weights"), "the packager's word: \(m)")
        }
        // Only the two recoverable states point at the retry; the dead end must not dangle one.
        XCTAssertTrue(TokenizerFiles.needsInternetMessage(for: "m").contains("Try again"))
        XCTAssertTrue(TokenizerFiles.fetchFailedMessage(for: "m").contains("Try again"))
        XCTAssertFalse(TokenizerFiles.cannotBeFixedMessage(for: "m").contains("Try again"))
    }
}

/// `HFDownloader.repairSmallFiles` against a local HTTP server standing in for huggingface.co: only the files whose git
/// blob hash differs are fetched, weights are never requested, a second pass is a no-op.
final class RepairSmallFilesTests: XCTestCase {
    override func setUp() { NetworkPolicy.setOffline(false) }
    override func tearDown() { NetworkPolicy.setOffline(false) }

    func testRepairsOnlyChangedSmallFiles() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokfix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let oldConfig = Data(#"{"tokenizer_class": "Qwen3_5Tokenizer", "backend": "tokenizers"}"#.utf8)
        let newConfig = Data(#"{"tokenizer_class": "Qwen2Tokenizer"}"#.utf8)
        let tokenizer = Data(#"{"model": {"type": "BPE"}}"#.utf8)
        let template = Data("{{ tools }}".utf8)
        let weights = Data(repeating: 7, count: 4096)
        try oldConfig.write(to: tmp.appendingPathComponent("tokenizer_config.json"))
        try tokenizer.write(to: tmp.appendingPathComponent("tokenizer.json"))
        try weights.write(to: tmp.appendingPathComponent("model.safetensors"))

        let remote: [String: Data] = ["tokenizer_config.json": newConfig, "tokenizer.json": tokenizer, "chat_template.jinja": template,
                                      "model.safetensors": weights, "README.md": Data("x".utf8)]
        // tokenizer.json is LFS-stored on the real Hub (≥10 MB): its tree `oid` is the POINTER's blob hash, the content hash lives in `lfs.oid`.
        let tree = try JSONSerialization.data(withJSONObject: remote.map { name, data -> [String: Any] in
            if name == "tokenizer.json" || name == "model.safetensors" {
                let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return ["type": "file", "path": name, "size": data.count, "oid": "pointer-blob-sha1-not-the-content", "lfs": ["oid": sha256, "size": data.count]]
            }
            return ["type": "file", "path": name, "size": data.count, "oid": TokenizerFiles.gitBlobSHA1(data)]
        })
        let requested = Requested()
        let server = try LocalHTTP { path in
            requested.add(path)
            if path.hasPrefix("/api/models/acme/m/tree/main") { return (200, tree) }
            if let r = path.range(of: "/resolve/main/") { return remote[String(path[r.upperBound...])].map { (200, $0) } ?? (404, Data()) }
            return (404, Data())
        }
        defer { server.stop() }
        var dl = HFDownloader()
        dl.host = "http://127.0.0.1:\(server.port)"

        let changed = try await dl.repairSmallFiles(repo: "acme/m", in: tmp)
        XCTAssertEqual(Set(changed), ["tokenizer_config.json", "chat_template.jinja"], "identical tokenizer.json is kept; README is not a model file")
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("tokenizer_config.json")), newConfig)
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("chat_template.jinja")), template)
        XCTAssertEqual(TokenizerFiles.audit(tmp).tokenizerClass, "Qwen2Tokenizer")
        let paths = requested.all
        XCTAssertFalse(paths.contains { $0.contains("model.safetensors") }, "weights must never be re-downloaded: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("tokenizer.json") }, "an unchanged file is not fetched: \(paths)")

        let again = try await dl.repairSmallFiles(repo: "acme/m", in: tmp)
        XCTAssertEqual(again, [], "second pass: everything matches the Hub")
    }

    func testOfflineRefusesBeforeAnyRequest() async throws {
        NetworkPolicy.setOffline(true)
        defer { NetworkPolicy.setOffline(false) }
        var dl = HFDownloader(); dl.host = "http://127.0.0.1:1"
        do { try await dl.repairSmallFiles(repo: "acme/m", in: FileManager.default.temporaryDirectory); XCTFail("must throw offline") }
        catch let e as HFDownloader.DLError { XCTAssertEqual(e, .offline) }
    }
}

final class Requested: @unchecked Sendable {
    private var paths: [String] = []
    private let lock = NSLock()
    func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

/// Minimal HTTP/1.1 server on 127.0.0.1 answering GET <path> with whatever `handler` returns (status, body).
final class LocalHTTP: @unchecked Sendable {
    let listener: NWListener
    private(set) var port: UInt16 = 0
    private let handler: @Sendable (String) throws -> (Int, Data)
    private var connections: [NWConnection] = []
    private let lock = NSLock()

    init(_ handler: @escaping @Sendable (String) throws -> (Int, Data)) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else { throw ToolError("listener did not start") }
        port = p
    }
    func stop() { listener.cancel() }
    deinit { listener.cancel() }

    private func serve(_ c: NWConnection) {
        lock.withLock { connections.append(c) }
        c.start(queue: .global())
        read(c, Data())
    }
    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var acc = acc; if let data { acc.append(data) }
            if let sep = acc.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: acc[acc.startIndex..<sep.lowerBound], as: UTF8.self)
                let parts = head.components(separatedBy: "\r\n")[0].split(separator: " ")
                let path = parts.count >= 2 ? String(parts[1]) : "/"
                let (status, body) = (try? self.handler(path)) ?? (500, Data())
                let text = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
                let h = "HTTP/1.1 \(status) \(text)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            } else if !done { self.read(c, acc) }
        }
    }
}
