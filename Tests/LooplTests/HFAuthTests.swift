import XCTest
@testable import Loopl

/// The Hugging Face token path: `HFDownloader` / `HubCatalog` stay anonymous unless a token provider is
/// injected; with one, `Authorization: Bearer` rides ONLY on requests to huggingface.co, 401/403 split into
/// "sign in" vs "no access", and `mine(author:)` lists the user's own MLX/GGUF repos incl. private ones.
/// `mine-cagataydev.json` = 9 rows of a REAL `GET /api/models?author=cagataydev&expand[]=…` answer
/// (owner's token, 2026-10-06; tags trimmed, no secrets) — 4 private, 5 public, 4 runnable.
final class HFAuthTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        var url: URL?
        #if SWIFT_PACKAGE
        for sub in ["Fixtures/hub", "hub", nil] { if url == nil { url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: sub) } }
        #endif
        if url == nil {
            for sub in ["Fixtures/hub", "hub", nil] where url == nil {
                url = Bundle.allBundles.compactMap { $0.url(forResource: name, withExtension: "json", subdirectory: sub) }.first
            }
        }
        return try Data(contentsOf: XCTUnwrap(url, "fixture \(name) missing"))
    }

    let hub = URL(string: "https://huggingface.co/api/models/cagataydev/loopl-0.8b-mid-4bit/tree/main")!

    // MARK: header presence / absence

    func testDownloaderIsAnonymousByDefault() {
        let r = HFDownloader().request(hub)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), "loopl/0.2 (iOS)")
    }

    func testDownloaderSendsBearerWhenProvided() {
        let r = HFDownloader(token: { "hf_test_123" }).request(hub)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer hf_test_123")
    }

    func testEmptyOrNilTokenMeansAnonymous() {
        XCTAssertNil(HFDownloader(token: { "" }).request(hub).value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(HFDownloader(token: { nil }).request(hub).value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(HubCatalog(token: { "" }).request(hub).value(forHTTPHeaderField: "Authorization"))
    }

    func testProviderIsConsultedPerRequest() {
        // Remove in Settings must take effect on the next request without rebuilding the downloader.
        final class Box: @unchecked Sendable { var token: String? = "hf_a" }
        let box = Box()
        let dl = HFDownloader(token: { box.token })
        XCTAssertEqual(dl.request(hub).value(forHTTPHeaderField: "Authorization"), "Bearer hf_a")
        box.token = nil
        XCTAssertNil(dl.request(hub).value(forHTTPHeaderField: "Authorization"))
    }

    func testBearerNeverLeavesHuggingFace() {
        let dl = HFDownloader(token: { "hf_x" })
        let cdn = URL(string: "https://cas-bridge.xethub.hf.co/xet-bridge-us/abc?X-Amz-Signature=1")!
        XCTAssertNil(dl.request(cdn).value(forHTTPHeaderField: "Authorization"), "no bearer to a CDN host")
        XCTAssertNil(HubCatalog(token: { "hf_x" }).request(cdn).value(forHTTPHeaderField: "Authorization"))
        var custom = HFDownloader(token: { "hf_x" }); custom.host = "https://hf-mirror.example.com"
        XCTAssertNil(custom.request(hub).value(forHTTPHeaderField: "Authorization"), "host is whatever `host` says, not hard-coded")
        XCTAssertEqual(custom.request(URL(string: "https://hf-mirror.example.com/a/b")!).value(forHTTPHeaderField: "Authorization"), "Bearer hf_x")
    }

    func testRedirectToCDNDropsAuthorization() {
        var toCDN = URLRequest(url: URL(string: "https://cdn-lfs.hf.co/repos/ab/cd/model.safetensors?X-Amz-Signature=sig")!)
        toCDN.setValue("Bearer hf_x", forHTTPHeaderField: "Authorization")
        toCDN.setValue("bytes=10-", forHTTPHeaderField: "Range")
        let scrubbed = RedirectScrubber.scrub(toCDN, host: "https://huggingface.co")
        XCTAssertNil(scrubbed.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(scrubbed.value(forHTTPHeaderField: "Range"), "bytes=10-", "resume survives the redirect")

        var sameHost = URLRequest(url: URL(string: "https://huggingface.co/cagataydev/x/resolve/main/config.json")!)
        sameHost.setValue("Bearer hf_x", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(RedirectScrubber.scrub(sameHost, host: "https://huggingface.co").value(forHTTPHeaderField: "Authorization"), "Bearer hf_x")
    }

    func testCatalogSendsBearerAndAcceptsJSON() {
        let r = HubCatalog(token: { "hf_t" }).request(hub)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer hf_t")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(HubCatalog().request(hub).value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: 401 / 403

    func testDeniedSplitsIntoSignInAndNoAccess() {
        XCTAssertEqual(HFDownloader.denied("a/b", hasToken: false), .signInRequired("a/b"))
        XCTAssertEqual(HFDownloader.denied("a/b", hasToken: true), .noAccess("a/b"))
        XCTAssertEqual(HFDownloader().denied("a/b"), .signInRequired("a/b"))
        XCTAssertEqual(HFDownloader(token: { "hf_x" }).denied("a/b"), .noAccess("a/b"))
        XCTAssertEqual(HubCatalog().denied("a/b"), .signInRequired("a/b"))
        XCTAssertEqual(HubCatalog(token: { "hf_x" }).denied("a/b"), .noAccess("a/b"))
        // The copy tells the user where to go.
        XCTAssertTrue(HFDownloader.DLError.signInRequired("cagataydev/loopl-0.8b-mid-4bit").localizedDescription.contains("sign in to Hugging Face in Settings"))
        XCTAssertTrue(HubCatalog.HubError.signInRequired("x/y").localizedDescription.contains("Settings"))
        XCTAssertTrue(HFDownloader.DLError.noAccess("x/y").localizedDescription.contains("huggingface.co"))
        XCTAssertFalse(HFDownloader.DLError.signInRequired("x/y").localizedDescription.contains("public models only"), "the old anonymous-only wording is gone")
    }

    // MARK: mine(author:)

    func testMineURL() {
        let u = HubCatalog().mineURL(author: "cagataydev", limit: 500).absoluteString
        XCTAssertTrue(u.hasPrefix("https://huggingface.co/api/models?author=cagataydev&sort=lastModified&direction=-1&limit=500"), u)
        for f in ["private", "library_name", "tags", "gguf", "safetensors", "config", "gated", "pipeline_tag"] { XCTAssertTrue(u.contains("expand%5B%5D=\(f)"), f) }
    }

    func testParseMineKeepsOnlyRunnableReposAndMarksPrivate() throws {
        let hits = try HubCatalog.parseMine(fixture("mine-cagataydev"))
        let ids = hits.map(\.id)
        // Runnable: MLX (tag/library mlx) + GGUF (gguf metadata / tag).
        XCTAssertEqual(Set(ids), ["cagataydev/loopl-0.8b-mid-4bit", "cagataydev/loopl-0.8b-mid-GGUF", "cagataydev/doer", "cagataydev/Qwen3.5-4B-cagatay-4bit"])
        // Dropped: full-precision transformers checkpoint, LoRA adapter (peft), robot policies, a VL transformers repo.
        for gone in ["cagataydev/loopl-0.8b-mid", "cagataydev/loopl-0.8b-smoke-lora", "cagataydev/gr00t-wave", "cagataydev/sac-unitree-go2-mujoco", "cagataydev/strands-qwen3-vl-2b"] {
            XCTAssertFalse(ids.contains(gone), gone)
        }
        let mid = try XCTUnwrap(hits.first { $0.id == "cagataydev/loopl-0.8b-mid-4bit" })
        XCTAssertTrue(mid.isPrivate)
        XCTAssertEqual(mid.kind, .mlx)
        XCTAssertEqual(mid.modelType, "qwen3_5")
        XCTAssertEqual(mid.bits, 4)
        XCTAssertEqual(mid.paramsB.map { ($0 * 100).rounded() / 100 }, 0.75)
        XCTAssertTrue(mid.isTextGeneration)
        let gguf = try XCTUnwrap(hits.first { $0.id == "cagataydev/loopl-0.8b-mid-GGUF" })
        XCTAssertTrue(gguf.isPrivate)
        XCTAssertEqual(gguf.kind, .gguf)
        XCTAssertEqual(gguf.sizeBytes, 752_393_024)
        let doer = try XCTUnwrap(hits.first { $0.id == "cagataydev/doer" })
        XCTAssertFalse(doer.isPrivate)
        XCTAssertEqual(doer.kind, .mlx)
        XCTAssertTrue(hits.allSatisfy(\.isTextGeneration), "the fixture rows survive the chat filter mine() applies")
    }

    func testPublicSearchRowsAreNotPrivate() throws {
        // The anonymous search fixture has no `private` field → false, never nil-crashes.
        let hits = try HubCatalog.parseSearch(fixture("search-mlx-qwen3"), kind: .mlx)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { !$0.isPrivate })
    }

    func testRepoDetailCarriesPrivateFlag() throws {
        let data = Data(#"{"id":"cagataydev/loopl-0.8b-mid-4bit","private":true,"gated":false,"siblings":[{"rfilename":"config.json","size":2830},{"rfilename":"model.safetensors","size":424026224}],"config":{"model_type":"qwen3_5"}}"#.utf8)
        let repo = try HubCatalog.parseRepo(data)
        XCTAssertTrue(repo.isPrivate)
        XCTAssertEqual(repo.kind, .mlx)
        XCTAssertFalse(try HubCatalog.parseRepo(fixture("repo-mlx-qwen2.5-1.5b")).isPrivate)
    }

    // MARK: cache isolation

    func testAuthenticatedResponsesCacheUnderTheirOwnKey() {
        let url = URL(string: "https://huggingface.co/api/models?author=cagataydev")!
        let key = HubCatalog.cacheKey(url)
        XCTAssertNotEqual(key, url)
        XCTAssertEqual(key.fragment, "auth")
        let c = HubCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hubcache-auth-\(UUID().uuidString)"))
        c.write(key, Data("[\"private\"]".utf8))
        XCTAssertNil(c.read(url, maxAge: .infinity), "a private listing never serves the anonymous path")
        XCTAssertEqual(c.read(key, maxAge: .infinity), Data("[\"private\"]".utf8))
        c.clear()
    }
}

/// LIVE proof against huggingface.co with the developer's own token (`~/.cache/huggingface/token`, the
/// file `hf auth login` writes — never committed). Skips unless `LOOPL_HF_LIVE=1`; CI never runs it.
final class HFAuthLiveTests: XCTestCase {
    static var token: String? {
        guard ProcessInfo.processInfo.environment["LOOPL_HF_LIVE"] == "1" else { return nil }
        let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/token")
        return (try? String(contentsOf: p, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testPrivateRepoIsSignInRequiredAnonymouslyAndListsWithToken() async throws {
        guard let token = Self.token else { throw XCTSkip("set LOOPL_HF_LIVE=1 with a token in ~/.cache/huggingface/token") }
        let repo = "cagataydev/loopl-0.8b-mid-4bit"
        var anon = HFDownloader(); anon.host = "https://huggingface.co"
        do { _ = try await anon.listFiles(repo: repo); XCTFail("anonymous must not see a private repo") }
        catch let e as HFDownloader.DLError { XCTAssertEqual(e, .signInRequired(repo)) }

        let files = try await HFDownloader(token: { token }).listFiles(repo: repo)
        XCTAssertTrue(files.contains { $0.path == "model.safetensors" }, files.map(\.path).joined(separator: ","))
        XCTAssertTrue(files.contains { $0.path == "config.json" })

        var hub = HubCatalog(token: { token }); hub.cache = nil
        let mine = try await hub.mine(author: "cagataydev")
        let mid = try XCTUnwrap(mine.first { $0.id == repo }, mine.map(\.id).joined(separator: ","))
        XCTAssertTrue(mid.isPrivate)
        XCTAssertEqual(mid.kind, .mlx)
        let spec = try await hub.resolve(repo)
        XCTAssertEqual(spec.repo, repo)
        XCTAssertEqual(spec.runtime, .mlx)
        XCTAssertGreaterThan(spec.sizeBytes, 400_000_000)
        print("LIVE mine=\(mine.count) rows; \(repo) private=\(mid.isPrivate) size=\(spec.sizeBytes) ctx=\(spec.ctxNominal) vision=\(spec.vision ?? false)")

        var anonHub = HubCatalog(); anonHub.cache = nil
        do { _ = try await anonHub.repo(repo); XCTFail("anonymous resolve must fail") }
        catch let e as HubCatalog.HubError { XCTAssertEqual(e, .signInRequired(repo)) }
    }
}

final class HFAccountTests: XCTestCase {
    func testTokenStoreRoundTripAndProvider() throws {
        let acct = HFAccount(store: HFMemoryTokenStore())
        XCTAssertNil(acct.token); XCTAssertFalse(acct.isSignedIn)
        XCTAssertNil(HFDownloader(token: acct.provider).request(URL(string: "https://huggingface.co/api/models/a/b")!).value(forHTTPHeaderField: "Authorization"))
        // A token already in the store (previous launch) is picked up.
        let acct2 = HFAccount(store: HFMemoryTokenStore("hf_abcdefghijklmnopqrstuvwxyz"))
        XCTAssertEqual(acct2.token, "hf_abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(HubCatalog(token: acct2.provider).request(URL(string: "https://huggingface.co/api/models?author=x")!).value(forHTTPHeaderField: "Authorization"), "Bearer hf_abcdefghijklmnopqrstuvwxyz")
        acct2.signOut()
        XCTAssertNil(acct2.token)
        XCTAssertNil(HubCatalog(token: acct2.provider).request(URL(string: "https://huggingface.co/x")!).value(forHTTPHeaderField: "Authorization"), "Remove goes anonymous on the next request")
    }

    func testSignInRejectsNonTokensBeforeAnyNetwork() async {
        let acct = HFAccount(store: HFMemoryTokenStore())
        for bad in ["", "hello", "hf_short", "hf_ with space in it long enough"] {
            do { try await acct.signIn(bad, transport: FailingTransport()); XCTFail(bad) }
            catch let e as HFAccount.SignInError { XCTAssertEqual(e, .notAToken, bad) }
            catch { XCTFail("\(error)") }
        }
        XCTAssertNil(acct.token)
        XCTAssertTrue(HFAccount.looksLikeToken("hf_abcdefghijklmnopqrstuvwxyz"))
    }

    /// A token the Hub rejects never stays in the store; one it accepts does, with whoami cached on the account.
    func testSignInKeepsOnlyVerifiedTokens() async throws {
        let acct = HFAccount(store: HFMemoryTokenStore())
        do { try await acct.signIn("hf_abcdefghijklmnopqrstuvwxyz", transport: StatusTransport(401)); XCTFail() }
        catch let e as HFHubError { XCTAssertEqual(e, .unauthorized) }
        XCTAssertNil(acct.token, "rejected token is not kept")
        let body = Data(#"{"type":"user","name":"cagataydev","fullname":"Cagatay Cali","avatarUrl":"/avatars/abc.svg","auth":{"accessToken":{"displayName":"mac-mini","role":"write"}}}"#.utf8)
        let who = try await acct.signIn("  hf_abcdefghijklmnopqrstuvwxyz\n", transport: StatusTransport(200, body))
        XCTAssertEqual(acct.token, "hf_abcdefghijklmnopqrstuvwxyz", "trimmed before storing")
        XCTAssertEqual(acct.whoami, who); XCTAssertEqual(acct.username, "cagataydev")
        XCTAssertEqual(who.scopes, [.read, .write, .jobs])
        // a later bad paste keeps the good token
        do { try await acct.signIn("hf_zzzzzzzzzzzzzzzzzzzzzzzzzzzz", transport: StatusTransport(403)); XCTFail() } catch {}
        XCTAssertEqual(acct.token, "hf_abcdefghijklmnopqrstuvwxyz")
    }

    func testWhoamiClassicWriteToken() throws {
        let data = Data(#"{"type":"user","id":"6498ef778fadf0ae7639b982","name":"cagataydev","fullname":"Cagatay Cali","avatarUrl":"https://cdn-avatars.huggingface.co/v1/production/uploads/x/y.jpeg","auth":{"type":"access_token","accessToken":{"displayName":"mac-mini","role":"write","createdAt":"2026-03-02T02:23:02.604Z"}}}"#.utf8)
        let who = try HFHubClient.parseWhoAmI(data)
        XCTAssertEqual(who.name, "cagataydev")
        XCTAssertEqual(who.fullname, "Cagatay Cali")
        XCTAssertEqual(who.avatarURL?.host, "cdn-avatars.huggingface.co")
        XCTAssertFalse(who.isOrg)
        XCTAssertEqual(who.tokenName, "mac-mini")
        XCTAssertEqual(who.role, "write")
        XCTAssertEqual(who.scopes, [.read, .write, .jobs])
    }

    func testWhoamiReadTokenAndFineGrained() throws {
        let read = try HFHubClient.parseWhoAmI(Data(#"{"type":"user","name":"u","auth":{"accessToken":{"displayName":"phone","role":"read"}}}"#.utf8))
        XCTAssertEqual(read.scopes, [.read])
        let fg = try HFHubClient.parseWhoAmI(Data(#"{"type":"user","name":"u","avatarUrl":"/avatars/abc.svg","auth":{"accessToken":{"displayName":"fg","role":"fineGrained","fineGrained":{"global":["inference.serverless.write","jobs.write"],"scoped":[{"entity":{"type":"user","name":"u"},"permissions":["repo.content.read","repo.write"]}]}}}}"#.utf8))
        XCTAssertEqual(fg.scopes, [.read, .write, .jobs])
        XCTAssertEqual(fg.avatarURL?.absoluteString, "https://huggingface.co/avatars/abc.svg", "relative avatar paths are made absolute")
        let fgRead = try HFHubClient.parseWhoAmI(Data(#"{"type":"user","name":"u","auth":{"accessToken":{"role":"fineGrained","fineGrained":{"global":[],"scoped":[{"permissions":["repo.content.read"]}]}}}}"#.utf8))
        XCTAssertEqual(fgRead.scopes, [.read])
        XCTAssertEqual(Array(fg.scopes).sorted(), [.read, .write, .jobs])
    }

    func testWhoamiBadJSON() {
        XCTAssertThrowsError(try HFHubClient.parseWhoAmI(Data("{}".utf8)))
        XCTAssertThrowsError(try HFHubClient.parseWhoAmI(Data("nope".utf8)))
    }
}

/// Replays one status (+ body) for every request; `FailingTransport` asserts no request is made at all.
private struct StatusTransport: HFTransport {
    let code: Int; let body: Data
    init(_ code: Int, _ body: Data = Data("{}".utf8)) { self.code = code; self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
private struct FailingTransport: HFTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { XCTFail("network must not be touched for \(request.url!)"); throw HFHubError.offline }
}

extension HFAuthLiveTests {
    func testLiveWhoami() async throws {
        guard let token = HFAuthLiveTests.token else { throw XCTSkip("LOOPL_HF_LIVE=1") }
        let acct = HFAccount(store: HFMemoryTokenStore())
        let who = try await acct.signIn(token)
        XCTAssertFalse(who.name.isEmpty)
        XCTAssertTrue(who.scopes.contains(.read))
        XCTAssertEqual(acct.token, token)
        print("LIVE whoami name=\(who.name) role=\(who.role ?? "-") scopes=\(who.scopes.sorted().map(\.rawValue)) token=\(who.tokenName ?? "-")")
        do { _ = try await HFHubClient(token: "hf_definitelynotavalidtoken000000").whoami(); XCTFail() }
        catch let e as HFHubError { XCTAssertEqual(e, .unauthorized) }
    }
}
