import XCTest
import Network
import Loopl

/// `http` against a tiny local server (Network.framework, so it runs on the
/// simulator too). The server echoes method, path, headers and body as JSON.
final class HttpToolTests: XCTestCase {
    /// Minimal HTTP/1.1 echo server on 127.0.0.1:<port>.
    final class EchoServer: @unchecked Sendable {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        var bigBody: Int = 0
        private var connections: [NWConnection] = []
        private let lock = NSLock()

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            // Both handlers must be set BEFORE start(), or the listener never becomes ready.
            listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: .global())
            guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else { throw ToolError("listener did not start") }
            port = p
        }
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
                if let r = Self.parse(acc) { self.respond(c, r) } else if !done { self.read(c, acc) }
            }
        }
        struct Req { var method: String; var path: String; var headers: [String: String]; var body: Data }
        static func parse(_ d: Data) -> Req? {
            guard let sep = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: d[d.startIndex..<sep.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let parts = lines.removeFirst().split(separator: " ")
            guard parts.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for l in lines { if let i = l.firstIndex(of: ":") { headers[String(l[..<i]).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
            let len = Int(headers["content-length"] ?? "0") ?? 0
            let body = d[sep.upperBound...]
            guard body.count >= len else { return nil }
            return Req(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(len)))
        }
        private func respond(_ c: NWConnection, _ r: Req) {
            var status = "200 OK", type = "application/json", body: Data
            if r.path == "/big" {
                body = Data(repeating: UInt8(ascii: "x"), count: bigBody); type = "text/plain"
            } else if r.path == "/missing" {
                status = "404 Not Found"; body = Data("nope".utf8); type = "text/plain"
            } else if r.path == "/redirect" {
                status = "302 Found"; body = Data()
                let head = "HTTP/1.1 \(status)\r\nLocation: http://127.0.0.1:\(port)/landed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8), completion: .contentProcessed { _ in c.cancel() }); return
            } else {
                let echo: [String: Any] = ["method": r.method, "path": r.path, "body": String(decoding: r.body, as: UTF8.self),
                                           "contentType": r.headers["content-type"] ?? "", "auth": r.headers["authorization"] ?? "", "ua": r.headers["user-agent"] ?? ""]
                body = try! JSONSerialization.data(withJSONObject: echo)
            }
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + (r.method == "HEAD" ? Data() : body), completion: .contentProcessed { _ in c.cancel() })
        }
    }

    var server: EchoServer!
    var base: String { "http://127.0.0.1:\(server.port)" }
    override func setUpWithError() throws { server = try EchoServer(); NetworkPolicy.setOffline(false) }
    override func tearDown() { server = nil; NetworkPolicy.setOffline(false) }

    func json(_ s: String) throws -> [String: Any] {
        let body = s.split(separator: "\n", maxSplits: 1).dropFirst().joined()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any], s)
    }

    // MARK: schema + approval grading (no network)

    func testSchemaAndNames() {
        let t = HttpTool()
        XCTAssertEqual(t.name, "http")
        XCTAssertEqual(t.parameters["required"], .array(["url"]))
        XCTAssertNotNil(t.parameters["properties"]?["method"])
        XCTAssertEqual(HttpTool.methods, ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"])
    }

    func testRiskByMethodAndRedaction() throws {
        let t = HttpTool()
        let get = try XCTUnwrap(t.requiresApproval(for: ["url": "https://api.example.com/v1/items?x=1"]))
        XCTAssertEqual(get.risk, .low); XCTAssertEqual(get.method, "GET"); XCTAssertEqual(get.title, "GET api.example.com"); XCTAssertEqual(get.host, "api.example.com")
        let post = try XCTUnwrap(t.requiresApproval(for: ["url": "https://api.example.com/v1", "method": "post", "body": ["a": 1], "headers": ["Authorization": "Bearer s3cret", "Accept": "*/*"]]))
        XCTAssertEqual(post.risk, .medium); XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.headers["Authorization"], "•••"); XCTAssertEqual(post.headers["Accept"], "*/*")
        XCTAssertEqual(post.headers["Content-Type"], "application/json", "a JSON body gets its content type")
        XCTAssertEqual(post.bodyPreview, "{\"a\":1}")
        XCTAssertTrue(post.detail?.contains("POST") == true)
        let del = try XCTUnwrap(t.requiresApproval(for: ["url": "https://api.example.com/v1/1", "method": "DELETE"]))
        XCTAssertEqual(del.risk, .high)
        XCTAssertNil(t.requiresApproval(for: ["url": "ftp://x"]), "invalid input is not asked about — call() reports the error")
    }

    func testRejectsNonHttpsAndBadMethod() async {
        let t = HttpTool()
        await assertThrows(t, ["url": "http://example.com/"], contains: "https")
        await assertThrows(t, ["url": "not a url"], contains: "url")
        await assertThrows(t, ["url": "https://example.com/", "method": "TRACE"], contains: "unsupported method")
        await assertThrows(t, [:], contains: "url")
    }
    private func assertThrows(_ t: HttpTool, _ args: [String: JSONValue], contains: String) async {
        do { _ = try await t.call(args); XCTFail("expected an error for \(args)") }
        catch { XCTAssertTrue("\(error.localizedDescription)".contains(contains), error.localizedDescription) }
    }

    // MARK: against the local server

    func testGetDefaultsAndStatusLine() async throws {
        let out = try await HttpTool().call(["url": .string("\(base)/hello?q=1")])
        XCTAssertTrue(out.hasPrefix("HTTP 200 application/json\n"), out)
        let j = try json(out)
        XCTAssertEqual(j["method"] as? String, "GET"); XCTAssertEqual(j["path"] as? String, "/hello?q=1")
        XCTAssertEqual(j["ua"] as? String, "loopl/0.1 (iOS)")
    }

    func testPostJsonBodyAndHeaders() async throws {
        let out = try await HttpTool().call(["url": .string("\(base)/items"), "method": "POST", "body": ["name": "x"], "headers": ["Authorization": "Bearer t"]])
        let j = try json(out)
        XCTAssertEqual(j["method"] as? String, "POST")
        XCTAssertEqual(j["body"] as? String, "{\"name\":\"x\"}")
        XCTAssertEqual(j["contentType"] as? String, "application/json")
        XCTAssertEqual(j["auth"] as? String, "Bearer t", "the real header is sent — only the card is redacted")
    }

    func testPutPatchDeleteStringBody() async throws {
        for m in ["PUT", "PATCH", "DELETE"] {
            let j = try json(try await HttpTool().call(["url": .string("\(base)/i/1"), "method": .string(m), "body": "raw text"]))
            XCTAssertEqual(j["method"] as? String, m); XCTAssertEqual(j["body"] as? String, "raw text", m)
        }
    }

    func testHeadAndNon2xx() async throws {
        let head = try await HttpTool().call(["url": .string("\(base)/x"), "method": "HEAD"])
        XCTAssertTrue(head.hasPrefix("HTTP 200"), head); XCTAssertTrue(head.contains("(0 bytes)"), head)
        let missing = try await HttpTool().call(["url": .string("\(base)/missing")])
        XCTAssertEqual(missing, "HTTP 404 text/plain\nnope", "non-2xx is a result, not an error — the model decides")
    }

    func testSizeCapTruncates() async throws {
        server.bigBody = 50_000
        let out = try await HttpTool(maxBytes: 10_000, maxChars: 3000).call(["url": .string("\(base)/big")])
        let body = out.split(separator: "\n", maxSplits: 1).dropFirst().joined()
        XCTAssertTrue(body.hasPrefix(String(repeating: "x", count: 3000)))
        XCTAssertTrue(out.contains("[truncated: 50000 bytes total]"), out)
        XCTAssertLessThan(out.count, 3200)
    }

    func testRedirectIsFollowed() async throws {
        let out = try await HttpTool().call(["url": .string("\(base)/redirect")])
        XCTAssertEqual(try json(out)["path"] as? String, "/landed")
    }

    func testOfflineRefusesBeforeTouchingTheNetwork() async throws {
        NetworkPolicy.setOffline(true)
        do { _ = try await HttpTool().call(["url": .string("\(base)/hello")]); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("offline"), error.localizedDescription) }
    }

    func testDeprecatedHttpGetAliasStillWorks() async throws {
        // One release of compatibility for prompts/datasets that learned `http_get`.
        let out = try await HttpGetTool().call(["url": .string("\(base)/old")])
        XCTAssertEqual(try json(out)["method"] as? String, "GET")
        XCTAssertEqual(HttpGetTool().requiresApproval(for: ["url": "https://example.com/"])?.risk, .low)
    }

    // MARK: through the agent, with the policy

    func testAgentPostAsksGetDoesNot() async throws {
        let uses = [ToolUse(toolUseId: "g", name: "http", input: ["url": .string("\(base)/read")]),
                    ToolUse(toolUseId: "p", name: "http", input: ["url": .string("\(base)/write"), "method": "POST", "body": "b"])]
        let model = FakeModel(turns: [.toolUse(uses), .text("ok")])
        let agent = Agent(model: model, tools: [HttpTool()], hooks: [ApprovalPolicy(mode: .mutating)], retryStrategy: nil)
        var asked: [String] = []
        var results: [String: String] = [:]
        for try await e in agent.stream("go") {
            switch e {
            case .approvalRequested(let r): asked.append(r.id); Task { await agent.resolve(approval: r.id, .approve) }
            case .toolResult(let r): results[r.toolUseId] = r.content
            default: break
            }
        }
        XCTAssertEqual(asked, ["p"])
        XCTAssertEqual(try json(results["g"]!)["method"] as? String, "GET")
        XCTAssertEqual(try json(results["p"]!)["method"] as? String, "POST")
    }
}
