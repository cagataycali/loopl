import Foundation
import XCTest
@testable import Loopl

/// The launcher behind the Train screen, driven through a replay transport — no network, no money.
@MainActor
final class TrainingSessionTests: XCTestCase {
    final class Replay: HFTransport, @unchecked Sendable {
        var routes: [String: (Int, Data)] = [:]
        private(set) var requests: [URLRequest] = []
        private let lock = NSLock()
        func on(_ method: String, _ path: String, status: Int = 200, _ text: String) { routes["\(method) \(path)"] = (status, Data(text.utf8)) }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { requests.append(request) }
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            guard let c = routes[key] else { throw HFHubError.http(599, key, "no canned route") }
            return (c.1, HTTPURLResponse(url: request.url!, statusCode: c.0, httpVersion: nil, headerFields: nil)!)
        }
        func paths(_ method: String) -> [String] { lock.withLock { requests.filter { $0.httpMethod == method }.map { $0.url!.path } } }
    }

    static let script = Data("# /// script\nSCRIPT_VERSION = \"1.0.2\"\nprint('hi')\n".utf8)
    static let jobJSON = #"{"type":"job","id":"6ac4711f404719ba3765bbc4","createdAt":"2026-10-06T03:55:00Z","dockerImage":"ghcr.io/astral-sh/uv:python3.12-bookworm","command":["bash","-lc","x"],"flavor":"a10g-small","status":{"stage":"RUNNING","message":null},"labels":{}}"#
    static let doneJSON = jobJSON.replacingOccurrences(of: "RUNNING", with: "COMPLETED")
    static func sse(_ lines: [String]) -> String {
        lines.map { "data: " + (try! String(decoding: JSONEncoder().encode(["data": $0, "timestamp": "2026-10-06T04:00:00Z"]), as: UTF8.self)) }.joined(separator: "\n\n")
    }

    func makeSession(_ t: Replay, token: String? = "hf_test_token_000000000000000000") -> TrainingSession {
        let plan = TrainingPlan(dataset: "cagataydev/loopl-app-smoke-data", conversations: 191, base: .b0_8, outputName: "loopl-app-smoke", hoursCap: 1)
        return TrainingSession(plan: plan, user: "cagataydev", client: HFHubClient(token: token, transport: t), script: Self.script, pollInterval: .milliseconds(10))
    }

    func testLaunchUploadsScriptThenCreatesJobAndPollsToCompletion() async throws {
        let t = Replay()
        t.on("GET", "/datasets/cagataydev/loopl-app-smoke-data/resolve/main/train/loopl_sft.py", status: 404, "{}")
        t.on("POST", "/api/datasets/cagataydev/loopl-app-smoke-data/commit/main", #"{"commitOid":"abc","commitUrl":"u","success":true}"#)
        t.on("POST", "/api/jobs/cagataydev", Self.jobJSON)
        t.on("GET", "/api/jobs/cagataydev/6ac4711f404719ba3765bbc4", Self.doneJSON)
        t.on("GET", "/api/jobs/cagataydev/6ac4711f404719ba3765bbc4/logs", Self.sse(TrainingTests.smokeJobLog))
        let s = makeSession(t)
        XCTAssertEqual(s.scriptVersion, "1.0.2")
        let id = try await s.launch(now: Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(id, "6ac4711f404719ba3765bbc4")
        XCTAssertEqual(t.paths("POST"), ["/api/datasets/cagataydev/loopl-app-smoke-data/commit/main", "/api/jobs/cagataydev"], "script first, then the job")
        // the job body is the launch contract and names the private resolve URL
        let jobReq = t.requests.first { $0.url!.path == "/api/jobs/cagataydev" }!
        let body = String(decoding: jobReq.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("\"flavor\":\"a10g-small\""), body)
        XCTAssertTrue(body.contains("resolve/main/train/loopl_sft.py"), body)
        XCTAssertTrue(body.contains("\"HF_TOKEN\":\"hf_test_token"), body)
        XCTAssertTrue(body.contains("\"timeoutSeconds\":3600"), body)
        // polling runs on its own; wait for the terminal phase
        for _ in 0..<200 { if !s.phase.isActive { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard case .finished(_, let out) = s.phase else { return XCTFail("phase \(s.phase)") }
        XCTAssertEqual(out.mlx, "cagataydev/loopl-app-smoke-4bit")
        XCTAssertEqual(s.progress.stages.count, 9)
        XCTAssertEqual(s.jobURL?.absoluteString, "https://huggingface.co/jobs/cagataydev/6ac4711f404719ba3765bbc4")
    }

    func testLaunchSkipsUploadWhenTheSameScriptVersionIsThere() async throws {
        let t = Replay()
        t.on("GET", "/datasets/cagataydev/loopl-app-smoke-data/resolve/main/train/loopl_sft.py", String(decoding: Self.script, as: UTF8.self))
        t.on("POST", "/api/jobs/cagataydev", Self.jobJSON)
        t.on("GET", "/api/jobs/cagataydev/6ac4711f404719ba3765bbc4", Self.jobJSON)
        t.on("GET", "/api/jobs/cagataydev/6ac4711f404719ba3765bbc4/logs", Self.sse(Array(TrainingTests.smokeJobLog.prefix(3))))
        let s = makeSession(t)
        _ = try await s.launch()
        XCTAssertEqual(t.paths("POST"), ["/api/jobs/cagataydev"])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(s.phase.isActive)
        XCTAssertEqual(s.progress.current?.name, "train")
        t.on("POST", "/api/jobs/cagataydev/6ac4711f404719ba3765bbc4/cancel", "{}")
        await s.cancel()
        XCTAssertEqual(s.phase, .cancelled(jobId: "6ac4711f404719ba3765bbc4"))
    }

    func testNoTokenFailsBeforeAnyRequest() async {
        let t = Replay()
        let s = makeSession(t, token: nil)
        do { _ = try await s.launch(); XCTFail("expected noToken") } catch { XCTAssertEqual(error as? HFHubError, .noToken) }
        XCTAssertTrue(t.requests.isEmpty)
        if case .failed(nil, let why) = s.phase { XCTAssertTrue(why.contains("Settings › Hugging Face"), why) } else { XCTFail("\(s.phase)") }
    }

    func testJobErrorWithoutDoneLineIsAFailure() async throws {
        let t = Replay()
        t.on("GET", "/datasets/cagataydev/loopl-app-smoke-data/resolve/main/train/loopl_sft.py", String(decoding: Self.script, as: UTF8.self))
        t.on("POST", "/api/jobs/cagataydev", Self.jobJSON)
        t.on("GET", "/api/jobs/cagataydev/6ac4711f404719ba3765bbc4", Self.jobJSON.replacingOccurrences(of: "\"RUNNING\",\"message\":null", with: "\"ERROR\",\"message\":\"exit code 1\""))
        t.on("GET", "/api/jobs/cagataydev/6ac4711f404719ba3765bbc4/logs", Self.sse(Array(TrainingTests.smokeJobLog.prefix(3)) + ["torch.OutOfMemoryError: CUDA out of memory."]))
        let s = makeSession(t)
        _ = try await s.launch()
        for _ in 0..<200 { if !s.phase.isActive { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed(let id, let why) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(id, "6ac4711f404719ba3765bbc4")
        XCTAssertEqual(why, "torch.OutOfMemoryError: CUDA out of memory.")
        XCTAssertEqual(s.progress.current?.name, "error")
    }

    func testDatasetsListingParsesPrivateRepos() throws {
        let json = #"[{"id":"cagataydev/loopl-app-conversations","private":true,"tags":["loopl","loopl-conversations"],"lastModified":"2026-10-06T04:00:00Z"},{"id":"cagataydev/loopl-train","private":true,"tags":["loopl"]}]"#
        let ds = try HFHubClient.parseDatasets(Data(json.utf8))
        XCTAssertEqual(ds.count, 2)
        XCTAssertTrue(ds[0].isPrivate && ds[0].isLoopl && ds[0].isLooplShare); XCTAssertEqual(ds[0].name, "loopl-app-conversations")
        XCTAssertTrue(ds[1].isLoopl); XCTAssertFalse(ds[1].isLooplShare, "a curated training set is never the default target")
        let fixture = HFHubClient.DatasetSummary(id: "u/x", tags: ["loopl-conversations"])
        XCTAssertTrue(fixture.isLooplShare)
    }
}
