import XCTest
import Loopl

/// `HFHubClient` + `HFAccount` pinned on REAL Hub responses recorded 2026-10-06 with the owner's token
/// (Fixtures/hub/hf-*.json; secrets/avatars scrubbed, throwaway repo deleted afterwards):
///   hf-whoami.json            GET  /api/whoami-v2
///   hf-models-author.json     GET  /api/models?author=cagataydev&limit=50&sort=lastModified
///   hf-datasets-author.json   GET  /api/datasets?author=cagataydev&limit=50&sort=lastModified
///   hf-repo-create.json       POST /api/repos/create {type:dataset,name:loopl-hub-client-fixture,private:true}
///   hf-commit.json            POST /api/datasets/cagataydev/loopl-hub-client-fixture/commit/main (ndjson, 1 base64 file)
///   hf-tree-after-commit.json GET  /api/datasets/cagataydev/loopl-hub-client-fixture/tree/main/data
///   hf-dataset-tree.json      GET  /api/datasets/cagataydev/loopl-train/tree/main
///   hf-jobs-list.json         GET  /api/jobs/cagataydev (first 3)
///   hf-job-get.json           GET  /api/jobs/cagataydev/6ac4691e404719ba3765b92f
///   hf-job-logs.txt           GET  /api/jobs/cagataydev/6ac4691e404719ba3765b92f/logs (SSE excerpt)
/// No network: every test goes through `ReplayTransport`.
final class HFHubClientTests: XCTestCase {
    func fixture(_ name: String, ext: String = "json") throws -> Data {
        var url: URL?
        #if SWIFT_PACKAGE
        for sub in ["Fixtures/hub", "hub", nil] { if url == nil { url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: sub) } }
        #endif
        if url == nil {
            for sub in ["Fixtures/hub", "hub", nil] where url == nil {
                url = Bundle.allBundles.compactMap { $0.url(forResource: name, withExtension: ext, subdirectory: sub) }.first
            }
        }
        return try Data(contentsOf: XCTUnwrap(url, "fixture \(name) missing"))
    }

    /// Replays canned (status, body) per "METHOD path" and records every request so tests can assert headers/bodies.
    final class ReplayTransport: HFTransport, @unchecked Sendable {
        struct Canned { var status: Int; var body: Data }
        var routes: [String: Canned] = [:]
        private(set) var requests: [URLRequest] = []
        private let lock = NSLock()
        func on(_ method: String, _ path: String, status: Int = 200, _ body: Data) { routes["\(method) \(path)"] = Canned(status: status, body: body) }
        func on(_ method: String, _ path: String, status: Int = 200, text: String) { on(method, path, status: status, Data(text.utf8)) }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { requests.append(request) }
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            guard let c = routes[key] else { throw HFHubError.http(599, key, "no canned route") }
            return (c.body, HTTPURLResponse(url: request.url!, statusCode: c.status, httpVersion: nil, headerFields: nil)!)
        }
        var last: URLRequest { lock.withLock { requests.last! } }
    }

    func client(_ t: ReplayTransport, token: String? = "hf_test_token_000000000000000000") -> HFHubClient {
        HFHubClient(token: token, transport: t)
    }

    // MARK: whoami

    func testWhoAmIParsesClassicWriteToken() throws {
        let who = try HFHubClient.parseWhoAmI(fixture("hf-whoami"))
        XCTAssertEqual(who.name, "cagataydev")
        XCTAssertEqual(who.type, "user")
        XCTAssertEqual(who.role, "write")
        XCTAssertEqual(who.tokenName, "mac-mini")
        XCTAssertTrue(who.canWriteRepos)
        XCTAssertTrue(who.canRunJobs)
        XCTAssertEqual(who.scopeBadges, ["write"])
    }

    func testWhoAmIFlattensFineGrainedScopes() throws {
        let json = """
        {"type":"user","id":"x","name":"someone","fullname":"Some One",
         "auth":{"type":"access_token","accessToken":{"displayName":"phone","role":"fineGrained",
           "fineGrained":{"canReadGatedRepos":true,"global":["inference.endpoints.infer.write","jobs.write"],
                          "scoped":[{"entity":{"type":"user","name":"someone"},"permissions":["repo.content.read","repo.write"]}]}}}}
        """
        let who = try HFHubClient.parseWhoAmI(Data(json.utf8))
        XCTAssertEqual(who.role, "fineGrained")
        XCTAssertEqual(who.fineGrainedScopes, ["inference.endpoints.infer.write", "jobs.write", "repo.content.read", "repo.write"])
        XCTAssertTrue(who.canWriteRepos); XCTAssertTrue(who.canRunJobs)
        XCTAssertEqual(who.scopeBadges, ["fine-grained", "repos: write", "jobs"])

        let readOnly = try HFHubClient.parseWhoAmI(Data("""
        {"type":"user","name":"ro","auth":{"accessToken":{"role":"read","displayName":"r"}}}
        """.utf8))
        XCTAssertFalse(readOnly.canWriteRepos); XCTAssertFalse(readOnly.canRunJobs); XCTAssertEqual(readOnly.scopeBadges, ["read"])
    }

    func testWhoAmISendsBearerAndRequiresToken() async throws {
        let t = ReplayTransport(); t.on("GET", "/api/whoami-v2", try fixture("hf-whoami"))
        let who = try await client(t).whoami()
        XCTAssertEqual(who.name, "cagataydev")
        XCTAssertEqual(t.last.value(forHTTPHeaderField: "Authorization"), "Bearer hf_test_token_000000000000000000")
        XCTAssertEqual(t.last.value(forHTTPHeaderField: "User-Agent"), "loopl/0.2 (iOS)")

        do { _ = try await client(t, token: nil).whoami(); XCTFail("anonymous whoami must not hit the network") }
        catch let e as HFHubError { XCTAssertEqual(e, .noToken) }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testStatusCodesMapToErrors() async throws {
        let t = ReplayTransport()
        t.on("GET", "/api/whoami-v2", status: 401, text: #"{"error":"Invalid credentials in Authorization header"}"#)
        do { _ = try await client(t).whoami(); XCTFail() } catch let e as HFHubError { XCTAssertEqual(e, .unauthorized) }
        t.on("POST", "/api/repos/create", status: 409, text: #"{"error":"You already created this dataset repo"}"#)
        do { _ = try await client(t).createRepo(name: "x"); XCTFail() } catch let e as HFHubError { XCTAssertEqual(e, .conflict("You already created this dataset repo")) }
        t.on("POST", "/api/jobs/cagataydev", status: 403, text: #"{"error":"This token does not have the jobs scope"}"#)
        do { _ = try await client(t).createJob(namespace: "cagataydev", .uvRun(script: "s", args: [], flavor: "cpu-basic")); XCTFail() }
        catch let e as HFHubError { XCTAssertEqual(e, .forbidden("This token does not have the jobs scope")) }
        t.on("GET", "/api/datasets/a/b", status: 404, text: #"{"error":"Repository not found"}"#)
        let exists = try await client(t).repoExists("a/b")
        XCTAssertFalse(exists)
        t.on("GET", "/api/datasets/a/b/tree/main/data", status: 404, text: #"{"error":"data does not exist on \"main\""}"#)
        let tree = try await client(t).tree(repo: "a/b", path: "data")
        XCTAssertEqual(tree, [])
    }

    // MARK: models

    func testModelsByAuthorIncludePrivateAndRunnableFlags() throws {
        let models = try HFHubClient.parseModels(fixture("hf-models-author"))
        XCTAssertEqual(models.count, 50)
        let mlx = try XCTUnwrap(models.first { $0.id == "cagataydev/loopl-0.8b-mid-4bit" })
        XCTAssertTrue(mlx.isPrivate); XCTAssertTrue(mlx.isMLX); XCTAssertTrue(mlx.isRunnable); XCTAssertTrue(mlx.isLoopl); XCTAssertFalse(mlx.isAdapter)
        XCTAssertEqual(mlx.author, "cagataydev"); XCTAssertEqual(mlx.name, "loopl-0.8b-mid-4bit")
        let gguf = try XCTUnwrap(models.first { $0.id == "cagataydev/loopl-0.8b-mid-GGUF" })
        XCTAssertTrue(gguf.isGGUF && gguf.isRunnable)
        let full = try XCTUnwrap(models.first { $0.id == "cagataydev/loopl-0.8b-mid" })
        XCTAssertFalse(full.isRunnable, "full-precision training output is not something the phone runs")
        let lora = try XCTUnwrap(models.first { $0.id == "cagataydev/loopl-0.8b-smoke-lora" })
        XCTAssertTrue(lora.isAdapter)
        XCTAssertGreaterThan(models.filter(\.isRunnable).count, 5)
    }

    func testModelsRequestCarriesAuthorQuery() async throws {
        let t = ReplayTransport(); t.on("GET", "/api/models", try fixture("hf-models-author"))
        _ = try await client(t).models(author: "cagataydev", limit: 50)
        let q = URLComponents(url: t.last.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "author" }?.value, "cagataydev")
        XCTAssertEqual(q.first { $0.name == "limit" }?.value, "50")
        XCTAssertEqual(q.first { $0.name == "sort" }?.value, "lastModified")
    }

    func testDatasetsByAuthorFlagLooplRepos() async throws {
        let t = ReplayTransport(); t.on("GET", "/api/datasets", try fixture("hf-datasets-author"))
        let ds = try await client(t).datasets(author: "cagataydev")
        XCTAssertGreaterThanOrEqual(ds.count, 2)
        let test = try XCTUnwrap(ds.first { $0.id == "cagataydev/loopl-app-conversations-test" })
        XCTAssertTrue(test.isPrivate); XCTAssertTrue(test.isLoopl); XCTAssertEqual(test.name, "loopl-app-conversations-test")
        // The curated training set is tagged `loopl` as well — it must NOT look like a share target.
        let train = try XCTUnwrap(ds.first { $0.id == "cagataydev/loopl-train" })
        XCTAssertTrue(train.isPrivate); XCTAssertTrue(train.isLoopl); XCTAssertFalse(train.isLooplShare)
        XCTAssertFalse(ds.contains(where: \.isLooplShare), "fixture predates the loopl-conversations tag")
    }

    // MARK: repos + commits

    func testCreateRepoBodyAndResponse() async throws {
        let body = HFHubClient.createRepoBody(name: "loopl-hub-client-fixture", type: .dataset, isPrivate: true)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"name":"loopl-hub-client-fixture","private":true,"type":"dataset"}"#)
        let t = ReplayTransport(); t.on("POST", "/api/repos/create", try fixture("hf-repo-create"))
        let created = try await client(t).createRepo(name: "loopl-hub-client-fixture")
        XCTAssertEqual(created.name, "cagataydev/loopl-hub-client-fixture")
        XCTAssertEqual(created.url, "https://huggingface.co/datasets/cagataydev/loopl-hub-client-fixture")
        XCTAssertEqual(t.last.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(t.last.httpBody, body)
    }

    func testCommitBodyIsNDJSONWithBase64Files() throws {
        let body = HFHubClient.commitBody(summary: "loopl fixture commit", description: "recorded for HFHubClient tests",
                                          files: [.init(path: "data/train-fixture.jsonl", text: "{\"messages\":[]}\n")], deletes: ["old.jsonl"])
        let lines = String(decoding: body, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], #"{"key":"header","value":{"description":"recorded for HFHubClient tests","summary":"loopl fixture commit"}}"#)
        XCTAssertEqual(lines[1], #"{"key":"file","value":{"content":"eyJtZXNzYWdlcyI6W119Cg==","encoding":"base64","path":"data/train-fixture.jsonl"}}"#)
        XCTAssertEqual(lines[2], #"{"key":"deletedFile","value":{"path":"old.jsonl"}}"#)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasSuffix("\n"))
    }

    func testCommitRoundTripAndTree() async throws {
        let t = ReplayTransport()
        t.on("POST", "/api/datasets/cagataydev/loopl-hub-client-fixture/commit/main", try fixture("hf-commit"))
        t.on("GET", "/api/datasets/cagataydev/loopl-hub-client-fixture/tree/main/data", try fixture("hf-tree-after-commit"))
        let c = client(t)
        let r = try await c.commit(repo: "cagataydev/loopl-hub-client-fixture", summary: "loopl fixture commit",
                                   files: [.init(path: "data/train-fixture.jsonl", text: "{\"messages\":[]}\n")])
        XCTAssertEqual(r.commitOid, "df561c3ef56458a63e3c44517c787ccb6e7a9994")
        XCTAssertEqual(r.commitUrl, "https://huggingface.co/datasets/cagataydev/loopl-hub-client-fixture/commit/df561c3ef56458a63e3c44517c787ccb6e7a9994")
        XCTAssertEqual(t.last.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
        let tree = try await c.tree(repo: "cagataydev/loopl-hub-client-fixture", path: "data")
        XCTAssertEqual(tree.map(\.path), ["data/train-fixture.jsonl"]); XCTAssertEqual(tree.first?.size, 16)
        let exists = try await c.fileExists(repo: "cagataydev/loopl-hub-client-fixture", path: "data/train-fixture.jsonl")
        XCTAssertTrue(exists)
        let missing = try await c.fileExists(repo: "cagataydev/loopl-hub-client-fixture", path: "data/nope.jsonl")
        XCTAssertFalse(missing)
    }

    func testDatasetRootTreeListsDirectoriesAndFiles() throws {
        let tree = try HFHubClient.parseTree(fixture("hf-dataset-tree"))
        XCTAssertEqual(tree.filter { !$0.isFile }.map(\.path), ["eval", "images", "stats", "system", "tools"])
        XCTAssertTrue(tree.contains { $0.path == "train.jsonl" && $0.isFile })
        XCTAssertTrue(tree.contains { $0.path == "README.md" && $0.isFile })
    }

    // MARK: jobs

    func testJobSpecBodyMatchesHubShape() throws {
        let spec = HFHubClient.JobSpec.uvRun(script: "https://huggingface.co/datasets/u/d/resolve/main/train/loopl_sft.py",
                                             args: ["--dataset", "u/d", "--base", "Qwen/Qwen3.5-0.8B"], flavor: "a10g-small",
                                             secrets: ["HF_TOKEN": "hf_secret"], environment: ["LOOPL": "1"], timeoutSeconds: 7200)
        let body = try XCTUnwrap(JSONValue.parse(String(decoding: HFHubClient.createJobBody(spec), as: UTF8.self)))
        XCTAssertEqual(body["dockerImage"]?.stringValue, "ghcr.io/astral-sh/uv:python3.12-bookworm")
        XCTAssertEqual(body["command"]?.arrayValue?.compactMap(\.stringValue),
                       ["uv", "run", "https://huggingface.co/datasets/u/d/resolve/main/train/loopl_sft.py", "--dataset", "u/d", "--base", "Qwen/Qwen3.5-0.8B"])
        XCTAssertEqual(body["flavor"]?.stringValue, "a10g-small")
        XCTAssertEqual(body["secrets"]?["HF_TOKEN"]?.stringValue, "hf_secret")
        XCTAssertEqual(body["environment"]?["LOOPL"]?.stringValue, "1")
        XCTAssertEqual(body["timeoutSeconds"]?.doubleValue, 7200, "the API key is timeoutSeconds — `timeout` is ignored and the job runs uncapped")
        XCTAssertNil(body["timeout"])
        XCTAssertEqual(body["arguments"]?.arrayValue?.count, 0)
    }

    func testJobGetParsesStatusFlavorAndDurations() throws {
        let job = try HFHubClient.parseJob(fixture("hf-job-get"))
        XCTAssertEqual(job.id, "6ac4691e404719ba3765b92f")
        XCTAssertEqual(job.stage, "RUNNING"); XCTAssertTrue(job.isRunning); XCTAssertFalse(job.isDone); XCTAssertFalse(job.succeeded)
        XCTAssertEqual(job.flavor, "a100-large")
        XCTAssertEqual(job.dockerImage, "ghcr.io/astral-sh/uv:python3.12-bookworm")
        XCTAssertEqual(job.command.prefix(3), ["uv", "run", "/data/sft.py"])
        XCTAssertEqual(job.timeout, 43200)
        XCTAssertEqual(job.durations?.runningSecs, 1432)
        XCTAssertEqual(job.labels?["name"], "loopl-full-0-8b-20261006T0320")
    }

    func testJobsListAndCreateRoundTrip() async throws {
        let t = ReplayTransport()
        t.on("GET", "/api/jobs/cagataydev", try fixture("hf-jobs-list"))
        t.on("POST", "/api/jobs/cagataydev", try fixture("hf-job-get"))
        t.on("GET", "/api/jobs/cagataydev/6ac4691e404719ba3765b92f", try fixture("hf-job-get"))
        let c = client(t)
        let list = try await c.jobs(namespace: "cagataydev")
        XCTAssertEqual(list.count, 3)
        XCTAssertTrue(list.allSatisfy { !$0.id.isEmpty && !$0.status.stage.isEmpty })
        let created = try await c.createJob(namespace: "cagataydev", .uvRun(script: "s.py", args: [], flavor: "cpu-basic"))
        XCTAssertEqual(created.id, "6ac4691e404719ba3765b92f")
        XCTAssertEqual(t.last.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let again = try await c.job(namespace: "cagataydev", id: created.id)
        XCTAssertEqual(again.stage, "RUNNING")
    }

    func testJobLogsParseServerSentEvents() throws {
        let text = String(decoding: try fixture("hf-job-logs", ext: "txt"), as: UTF8.self)
        let lines = HFHubClient.parseLogs(text)
        XCTAssertGreaterThanOrEqual(lines.count, 4)
        XCTAssertEqual(lines.first?.text, "===== Job started at 2026-10-06 03:21:03 =====")
        XCTAssertEqual(lines.first?.timestamp, "2026-10-06T03:21:03Z")
        XCTAssertEqual(lines[1].text, "Downloading tokenizers (3.2MiB)")
        // Truncated trailing event (the recorder cut the stream mid-line) is skipped, not crashed on.
        XCTAssertFalse(lines.contains { $0.text.hasPrefix("Downloading hf-xet") && !$0.text.hasSuffix(")") && $0.timestamp == nil })
    }

    // MARK: account

    func testAccountStoresTrimsAndClearsToken() throws {
        let store = HFMemoryTokenStore()
        let acct = HFAccount(store: store)
        XCTAssertFalse(acct.hasToken)
        try acct.setToken("  hf_abcdefghijklmnopqrstuvwxyz0123\n")
        XCTAssertEqual(acct.token, "hf_abcdefghijklmnopqrstuvwxyz0123")
        XCTAssertEqual(store.read(), "hf_abcdefghijklmnopqrstuvwxyz0123")
        XCTAssertTrue(acct.hasToken)
        try acct.clear()
        XCTAssertNil(acct.token); XCTAssertNil(store.read())
        XCTAssertTrue(HFAccount.looksLikeToken("hf_abcdefghijklmnopqrstuvwxyz0123"))
        XCTAssertFalse(HFAccount.looksLikeToken("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        XCTAssertFalse(HFAccount.looksLikeToken("hf_short"))
    }

    func testAccountVerifyCachesWhoAmIAndClientUsesToken() async throws {
        let acct = HFAccount(store: HFMemoryTokenStore("hf_abcdefghijklmnopqrstuvwxyz0123"))
        let t = ReplayTransport(); t.on("GET", "/api/whoami-v2", try fixture("hf-whoami"))
        XCTAssertNil(acct.whoami)
        let who = try await acct.verify(transport: t)
        XCTAssertEqual(who.name, "cagataydev")
        XCTAssertEqual(acct.username, "cagataydev")
        XCTAssertEqual(t.last.value(forHTTPHeaderField: "Authorization"), "Bearer hf_abcdefghijklmnopqrstuvwxyz0123")
        try acct.setToken("hf_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
        XCTAssertNil(acct.whoami, "changing the token forgets the old identity")
        XCTAssertEqual(acct.client(transport: t).token, "hf_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
    }
}
