import XCTest
import Loopl

/// `AgentCheckpoint` round trips, versioning, the file store, and a snapshot
/// taken while a tool call is suspended for approval.
final class CheckpointTests: XCTestCase {
    func use(_ name: String, _ args: [String: JSONValue] = [:], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }
    func roundTrip(_ c: AgentCheckpoint) throws -> AgentCheckpoint { try AgentCheckpoint(jsonData: c.jsonData()) }

    /// A tool that always asks (so a run can be snapshotted mid-interrupt).
    final class Guarded: Tool, @unchecked Sendable {
        let name = "guarded"
        let description = "asks first"
        let parameters: JSONValue = ToolSchema.object(["value": ToolSchema.string("v")])
        func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
            ApprovalRequest(toolName: name, title: "guarded", risk: .high, input: input)
        }
        func call(_ args: [String: JSONValue]) async throws -> String { "ran" }
    }

    // MARK: round trip

    func testRoundTripWithToolTurns() async throws {
        let model = FakeModel(turns: [.toolUse(text: "let me compute", [use("calculator", ["expression": "23*47"], id: "t1")]), .text("1081")])
        let agent = Agent(model: model, tools: [CalculatorTool()], systemPrompt: "be brief", retryStrategy: nil)
        _ = try await agent("23*47?")

        let snapshot = await agent.checkpoint(id: "chat-1", label: "after the sum", userInfo: ["title": "maths"])
        XCTAssertEqual(snapshot.version, AgentCheckpoint.currentVersion)
        XCTAssertEqual(snapshot.messages.count, 4)
        XCTAssertEqual(snapshot.systemPrompt, "be brief")
        XCTAssertEqual(snapshot.runtime, "mlx")
        XCTAssertEqual(snapshot.metrics.cycleCount, 2)
        XCTAssertEqual(snapshot.metrics.toolCallCount, 1)
        XCTAssertFalse(snapshot.isSuspended)

        let decoded = try roundTrip(snapshot)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.messages[1].toolUses.map(\.name), ["calculator"])
        XCTAssertEqual(decoded.messages[2].toolResults.map(\.content), ["23*47 = 1081"])
        XCTAssertEqual(decoded.userInfo["title"]?.stringValue, "maths")
    }

    func testRestoreIntoAFreshAgent() async throws {
        let model = FakeModel(turns: [.text("first answer")])
        let agent = Agent(model: model, systemPrompt: "be brief", retryStrategy: nil)
        _ = try await agent("hello?")
        let snapshot = await agent.checkpoint()

        let resumed = Agent(model: FakeModel(turns: [.text("second answer")]), retryStrategy: nil)
        await resumed.restore(snapshot)
        let messages = await resumed.messages
        XCTAssertEqual(messages.map(\.text), ["hello?", "first answer"])
        let prompt = await resumed.systemPrompt
        XCTAssertEqual(prompt, "be brief")
        let metrics = await resumed.eventLoopMetrics
        XCTAssertEqual(metrics.cycleCount, snapshot.metrics.cycleCount)

        // and the conversation continues on top of the restored history
        let result = try await resumed("and again?")
        XCTAssertEqual(result.text, "second answer")
        let after = await resumed.messages.map(\.text)
        XCTAssertEqual(after, ["hello?", "first answer", "and again?", "second answer"])
    }

    // MARK: mid-interrupt

    func testSnapshotWhileAToolCallIsSuspended() async throws {
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "write"], id: "g1")]), .text("done")])
        let agent = Agent(model: model, tools: [Guarded()], retryStrategy: nil)

        // run in the background and wait for the approval to be asked
        let asked = expectation(description: "approval asked")
        let finished = expectation(description: "run finished")
        let task = Task {
            for try await event in agent.stream("go") {
                if case .approvalRequested = event { asked.fulfill() }
            }
            finished.fulfill()
        }
        await fulfillment(of: [asked], timeout: 5)

        let suspended = await agent.checkpoint(id: "mid", label: "waiting for a human")
        XCTAssertTrue(suspended.isSuspended)
        XCTAssertEqual(suspended.pendingApprovals.map(\.toolName), ["guarded"])
        XCTAssertEqual(suspended.pendingApprovals.map(\.id), ["g1"])
        XCTAssertEqual(suspended.interrupt?.kind, "approval")
        XCTAssertEqual(suspended.interrupt?.toolUseId, "g1")
        XCTAssertEqual(suspended.interrupt?.payload["toolNames"], .array(["guarded"]))
        // the model's tool-use turn is already in history, so a restored run re-asks
        XCTAssertEqual(suspended.messages.last?.toolUses.map(\.toolUseId), ["g1"])

        let decoded = try roundTrip(suspended)
        XCTAssertEqual(decoded, suspended)
        XCTAssertEqual(decoded.pendingApprovals.first?.risk, .high)

        _ = await agent.resolve(approval: "g1", .approve)
        await fulfillment(of: [finished], timeout: 5)
        _ = await task.result

        let after = await agent.checkpoint()
        XCTAssertFalse(after.isSuspended)
        XCTAssertNil(after.interrupt)
    }

    // MARK: versioning

    func testNewerVersionIsRefused() throws {
        let json = #"{"version": 99, "id": "x", "createdAt": "2026-10-06T00:00:00.000Z", "messages": []}"#
        do {
            _ = try AgentCheckpoint(jsonData: Data(json.utf8))
            XCTFail("expected unsupportedVersion")
        } catch let error as CheckpointError {
            XCTAssertEqual(error, .unsupportedVersion(found: 99, supported: AgentCheckpoint.currentVersion))
        }
    }

    func testUnknownFieldsAndMissingFieldsAreTolerated() throws {
        // start from a real file, then add a field this build has never heard of
        let original = AgentCheckpoint(id: "x", messages: [.user("hi")])
        var object = JSONValue.parse(String(data: try original.jsonData(), encoding: .utf8)!)!.objectValue!
        object["somethingFromTheFuture"] = .object(["a": 1])
        object["metrics"] = nil
        object["pendingApprovals"] = nil
        let decoded = try AgentCheckpoint(jsonData: Data(JSONValue.object(object).compact.utf8))
        XCTAssertEqual(decoded.id, "x")
        XCTAssertEqual(decoded.messages.map(\.text), ["hi"])
        XCTAssertEqual(decoded.metrics.cycleCount, 0)
        XCTAssertTrue(decoded.pendingApprovals.isEmpty)
    }

    // MARK: file store

    func testFileStoreSaveLoadListDelete() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("loopl-checkpoints-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileCheckpointStore(directory: dir)

        var a = AgentCheckpoint(id: "chat/one", label: "a", messages: [.user("hi")])
        a.createdAt = Date(timeIntervalSince1970: 100)
        var b = AgentCheckpoint(id: "chat-two", label: "b", messages: [.user("yo"), .assistant("hey")])
        b.createdAt = Date(timeIntervalSince1970: 200)
        try store.save(a)
        try store.save(b)

        let loaded = try store.load("chat/one")
        XCTAssertEqual(loaded.label, "a")
        XCTAssertEqual(loaded.messages.map(\.text), ["hi"])

        let list = try store.list()
        XCTAssertEqual(list.map(\.id), ["chat-two", "chat/one"])      // newest first
        XCTAssertEqual(list.first?.messageCount, 2)

        try store.delete("chat-two")
        XCTAssertEqual(try store.list().map(\.id), ["chat/one"])
        XCTAssertThrowsError(try store.load("chat-two")) { error in
            XCTAssertEqual(error as? CheckpointError, .notFound("chat-two"))
        }
    }

    func testFileStoreRejectsCorruptFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("loopl-checkpoints-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let store = FileCheckpointStore(directory: dir)
        XCTAssertThrowsError(try store.load("broken")) { error in
            guard case .corrupt(let id, _)? = error as? CheckpointError else { return XCTFail("\(error)") }
            XCTAssertEqual(id, "broken")
        }
        XCTAssertTrue(try store.list().isEmpty, "a broken file is skipped, not fatal")
    }
}
