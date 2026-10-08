import XCTest
import Loopl

/// `ConversationExport` must write EXACTLY loopl-train's row shape. The contract is
/// `Fixtures/hub/conversation.schema.json` — a verbatim copy of cagataycali/loopl-train `schema/conversation.schema.json`
/// (PR #2). These tests read the enums/patterns back out of that file and hold the exporter to them, and
/// `ConversationExport.validate` to the same rules; `ConversationExportFixtures.write` dumps the three fixture threads
/// (the ones the audit pushes to the Hub as proof) so the Python `jsonschema` check can run on the identical bytes.
final class ConversationExportTests: XCTestCase {
    func fixture(_ name: String, ext: String) throws -> Data {
        var url: URL?
        #if SWIFT_PACKAGE
        for sub in ["Fixtures/hub", "hub", nil] { if url == nil { url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: sub) } }
        #endif
        if url == nil {
            for sub in ["Fixtures/hub", "hub", nil] where url == nil {
                url = Bundle.allBundles.compactMap { $0.url(forResource: name, withExtension: ext, subdirectory: sub) }.first
            }
        }
        return try Data(contentsOf: XCTUnwrap(url, "fixture \(name).\(ext) missing"))
    }

    var schema: JSONValue { get throws { try XCTUnwrap(JSONValue.parse(String(decoding: try fixture("conversation", ext: "schema.json"), as: UTF8.self))) } }
    let fixed = Date(timeIntervalSince1970: 1_791_000_000)   // 2026-10-03T04:00:00Z, stable output
    var options: ConversationExport.Options { .init(appVersion: "0.2-test", platform: "iOS-sim", now: fixed) }

    // MARK: fixture threads (shared with the proof push)

    static let calculator = ToolSpec(name: "calculator", description: "Evaluate arithmetic.",
                                     inputSchema: .object(["type": "object", "properties": .object(["expression": .object(["type": "string"])]), "required": .array(["expression"])]))
    static let currentTime = ToolSpec(name: "current_time", description: "Current date and time.",
                                      inputSchema: .object(["type": "object", "properties": .object(["timezone": .object(["type": "string"])]), "required": .array([])]))
    static let http = ToolSpec(name: "http", description: "HTTP request (approval needed for writes).",
                               inputSchema: .object(["type": "object", "properties": .object(["url": .object(["type": "string"]), "method": .object(["type": "string"])]), "required": .array(["url"])]))

    static func threads(png: Data) -> [ConversationExport.Thread] {
        let u1 = ToolUse(toolUseId: "tooluse_a1", name: "calculator", input: ["expression": "23*47"])
        let u2 = ToolUse(toolUseId: "tooluse_a2", name: "current_time", input: ["timezone": "Europe/Istanbul"])
        let t1 = ConversationExport.Thread(id: "11111111-1111-1111-1111-111111111111", title: "math + time",
            messages: [.user("what is 23*47 and what time is it in Istanbul?"),
                       .assistant(text: "", toolUses: [u1, u2]),
                       .toolResults([ToolResult(toolUseId: "tooluse_a1", name: "calculator", content: "1081"),
                                     ToolResult(toolUseId: "tooluse_a2", name: "current_time", content: "Tuesday 6 October 2026 07:05 (Europe/Istanbul, UTC+0300)")]),
                       .assistant("23 × 47 = **1081**, and it is 07:05 on Tuesday in Istanbul.")],
            tools: [calculator, currentTime], modelId: "mlx-community/Qwen3.5-0.8B-4bit", updated: Date(timeIntervalSince1970: 1_790_999_000))
        let u3 = ToolUse(toolUseId: "tooluse_b1", name: "http", input: ["url": "https://api.github.com/repos/cagataycali/loopl", "method": "GET"])
        let t2 = ConversationExport.Thread(id: "22222222-2222-2222-2222-222222222222", title: "repo stars",
            messages: [.user("how many stars does https://github.com/cagataycali/loopl have?"),
                       Message(role: .assistant, content: [.reasoning("I should fetch the repo JSON."), .toolUse(u3)]),
                       .toolResults([ToolResult(toolUseId: "tooluse_b1", name: "http", status: .error, content: "HTTP 404 for https://api.github.com/repos/cagataycali/loopl — the repository is private")]),
                       .assistant("I can't read that repository: GitHub answers 404 — it is private, so the API hides it. Check it on https://github.com/cagataycali/loopl while signed in."),
                       .user("ok thanks"),
                       .assistant("Any time.")],
            tools: [http, calculator], modelId: "qwen3.5-0.8b-4bit", updated: Date(timeIntervalSince1970: 1_790_999_500))
        let t3 = ConversationExport.Thread(id: "33333333-3333-3333-3333-333333333333", title: "picture",
            messages: [.user("what colour is this square?", images: [ImageBlock(data: png, mime: "image/png", width: 2, height: 2)]),
                       .assistant("It is a solid red square.")],
            tools: [], modelId: "mlx-community/Qwen3.5-0.8B-4bit", updated: Date(timeIntervalSince1970: 1_790_999_900))
        return [t1, t2, t3]
    }

    // MARK: shape

    func testTrajectoryBecomesHFChatRowWithObjectArgumentsAndToolTurns() throws {
        let t = Self.threads(png: try fixture("fixture-red", ext: "png"))[0]
        let r = try ConversationExport.record(t, options: options)
        XCTAssertEqual(ConversationExport.validate(r.json), [])
        XCTAssertEqual(r.json["family"]?.stringValue, "u")
        XCTAssertEqual(r.json["split"]?.stringValue, "train")
        XCTAssertEqual(r.id, "u-" + String(r.id.dropFirst(2)))
        XCTAssertEqual(r.id.count, 12)
        let msgs = try XCTUnwrap(r.json["messages"]?.arrayValue)
        XCTAssertEqual(msgs.map { $0["role"]?.stringValue }, ["system", "user", "assistant", "tool", "tool", "assistant"])
        XCTAssertEqual(msgs[0]["content"]?.stringValue, ConversationExport.systemPrompt)
        XCTAssertTrue(ConversationExport.systemPrompt.hasPrefix("You are loopl, an on-device agent runtime built by Cagatay Cali"))
        XCTAssertEqual(msgs[2]["content"]?.stringValue, "")
        let calls = try XCTUnwrap(msgs[2]["tool_calls"]?.arrayValue)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0]["type"]?.stringValue, "function")
        XCTAssertEqual(calls[0]["function"]?["name"]?.stringValue, "calculator")
        XCTAssertEqual(calls[0]["function"]?["arguments"], .object(["expression": "23*47"]), "arguments is an OBJECT, never a string")
        XCTAssertEqual(msgs[3]["tool_call_id"]?.stringValue, "tooluse_a1"); XCTAssertEqual(msgs[3]["content"]?.stringValue, "1081")
        XCTAssertEqual(msgs[4]["tool_call_id"]?.stringValue, "tooluse_a2")
        XCTAssertNil(msgs[5]["tool_calls"])
        XCTAssertEqual(r.json["tools"]?.arrayValue?.count, 2)
        XCTAssertEqual(r.json["tools"]?.arrayValue?.first?["function"]?["name"]?.stringValue, "calculator")
        XCTAssertEqual(r.json["source"], .array([]))
        XCTAssertNil(r.json["critic"]); XCTAssertNil(r.json["images"])
        XCTAssertEqual(r.json["gen"]?["generator"]?.stringValue, "loopl-app/0.2-test")
        XCTAssertEqual(r.json["gen"]?["model"]?.stringValue, "mlx-community/Qwen3.5-0.8B-4bit")
        XCTAssertEqual(r.json["gen"]?["system_version"]?.stringValue, ConversationExport.systemVersion)
        XCTAssertEqual(r.json["gen"]?["ts"]?.stringValue, "2026-10-03T04:00:00Z")
        XCTAssertEqual(r.json["gen"]?["platform"]?.stringValue, "iOS-sim")
        XCTAssertEqual(r.turns, 3); XCTAssertEqual(r.toolCalls, 2)
        XCTAssertFalse(r.line.contains("\n"), "one line per record")
    }

    func testReasoningDroppedErroredResultKeptAndIdStable() throws {
        let t = Self.threads(png: try fixture("fixture-red", ext: "png"))[1]
        let r = try ConversationExport.record(t, options: options)
        XCTAssertEqual(ConversationExport.validate(r.json), [])
        let msgs = try XCTUnwrap(r.json["messages"]?.arrayValue)
        XCTAssertEqual(msgs.map { $0["role"]?.stringValue }, ["system", "user", "assistant", "tool", "assistant", "user", "assistant"])
        XCTAssertFalse(r.line.contains("I should fetch"), "reasoning never leaves the device")
        XCTAssertTrue(msgs[3]["content"]?.stringValue?.contains("404") == true, "errored tool results are facts the model must learn from")
        XCTAssertEqual(r.id, try ConversationExport.record(t, options: options).id, "id derives from the thread id")
        XCTAssertNotEqual(r.id, try ConversationExport.record(Self.threads(png: Data())[0], options: options).id)
    }

    func testVisionThreadWritesPartsAndImageFiles() throws {
        let png = try fixture("fixture-red", ext: "png")
        let r = try ConversationExport.record(Self.threads(png: png)[2], options: options)
        XCTAssertEqual(ConversationExport.validate(r.json), [])
        let user = try XCTUnwrap(r.json["messages"]?.arrayValue?[1])
        XCTAssertEqual(user["content"]?.arrayValue, [.object(["type": "image"]), .object(["type": "text", "text": "what colour is this square?"])])
        XCTAssertEqual(r.images.count, 1)
        let path = try XCTUnwrap(r.images.first?.path)
        XCTAssertTrue(path.hasPrefix("images/") && path.hasSuffix(".png")); XCTAssertEqual(path.count, "images/".count + 12 + 4)
        XCTAssertEqual(r.json["images"]?.arrayValue?.compactMap(\.stringValue), [path])
        XCTAssertEqual(r.images.first?.data, png)
    }

    // MARK: redaction

    func testRedactionToggles() throws {
        let png = try fixture("fixture-red", ext: "png")
        let all = ConversationExport.Redaction(stripImages: true, stripToolResults: true, anonymiseURLs: true)
        let o = ConversationExport.Options(redaction: all, appVersion: "0.2-test", now: fixed)
        let vision = try ConversationExport.record(Self.threads(png: png)[2], options: o)
        XCTAssertEqual(ConversationExport.validate(vision.json), [])
        XCTAssertNil(vision.json["images"]); XCTAssertEqual(vision.images, [])
        XCTAssertEqual(vision.json["messages"]?.arrayValue?[1]["content"]?.stringValue, "what colour is this square?", "text stays, picture goes")

        let web = try ConversationExport.record(Self.threads(png: png)[1], options: o)
        XCTAssertEqual(ConversationExport.validate(web.json), [])
        let line = web.line
        XCTAssertFalse(line.contains("github.com"), "no real host leaves the device: \(line.prefix(300))")
        XCTAssertFalse(line.contains("api.github.com"))
        XCTAssertTrue(line.contains("https://example.com/u1"))
        let msgs = web.json["messages"]!.arrayValue!
        XCTAssertEqual(msgs[2]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"]?["url"]?.stringValue, "https://example.com/u2", "tool arguments are scrubbed too, with a stable per-record mapping")
        XCTAssertEqual(msgs[3]["content"]?.stringValue, "[tool result removed before sharing]")
        XCTAssertEqual(web.json["gen"]?["redaction"], .object(["strip_images": true, "strip_tool_results": true, "anonymise_urls": true]))
        XCTAssertEqual(web.json["messages"]?.arrayValue?.count, 7, "structure untouched by redaction")
    }

    // MARK: trimming + refusals

    func testTrailingToolCallAndEmptyThreadsAreHandled() throws {
        let u = ToolUse(toolUseId: "tooluse_z", name: "calculator", input: ["expression": "1+1"])
        let dangling = ConversationExport.Thread(id: "d", messages: [.user("1+1?"), .assistant("Let me compute."), .assistant(text: "", toolUses: [u])], tools: [Self.calculator])
        let r = try ConversationExport.record(dangling, options: options)
        XCTAssertEqual(ConversationExport.validate(r.json), [])
        XCTAssertEqual(r.json["messages"]?.arrayValue?.map { $0["role"]?.stringValue }, ["system", "user", "assistant"], "unanswered call + its turn trimmed")

        XCTAssertThrowsError(try ConversationExport.record(.init(id: "e", messages: [.user("hello?")]), options: options)) {
            XCTAssertEqual($0 as? ConversationExport.ExportError, .noAssistantAnswer("hello?"))
        }
        XCTAssertThrowsError(try ConversationExport.record(.init(id: "f", title: "T", messages: [.assistant("hi")]), options: options)) {
            XCTAssertEqual($0 as? ConversationExport.ExportError, .noUserTurn("T"))
        }
        XCTAssertThrowsError(try ConversationExport.record(.init(id: "g", messages: []), options: options))
    }

    func testShardCollectsRecordsSkipsAndImages() throws {
        let png = try fixture("fixture-red", ext: "png")
        var threads = Self.threads(png: png)
        threads.append(.init(id: "broken", title: "broken", messages: [.user("?")]))
        let shard = ConversationExport.shard(threads, options: options)
        XCTAssertEqual(shard.records.count, 3)
        XCTAssertEqual(shard.skipped, ["broken: no finished assistant answer to learn from"])
        XCTAssertEqual(shard.path, "data/train-20261003T040000Z.jsonl")
        XCTAssertEqual(shard.jsonl.split(separator: "\n").count, 3); XCTAssertTrue(shard.jsonl.hasSuffix("\n"))
        XCTAssertEqual(shard.images.count, 1); XCTAssertEqual(shard.toolCalls, 3)
        XCTAssertGreaterThan(shard.byteCount, shard.jsonl.utf8.count)
        for line in shard.jsonl.split(separator: "\n") {
            XCTAssertEqual(ConversationExport.validate(try XCTUnwrap(JSONValue.parse(String(line)))), [])
        }
        let readme = ConversationExport.readme(repo: "cagataydev/loopl-app-conversations-test", shards: [shard.path], rows: 3)
        XCTAssertTrue(readme.hasPrefix("---\n")); XCTAssertTrue(readme.contains("path: data/*.jsonl")); XCTAssertTrue(readme.contains(shard.path))
    }

    // MARK: against the shared JSON Schema

    func testOutputSatisfiesTheVendoredSchemaPatterns() throws {
        let s = try schema
        XCTAssertEqual(s["$schema"]?.stringValue, "https://json-schema.org/draft/2020-12/schema")
        let families = try XCTUnwrap(s["properties"]?["family"]?["enum"]?.arrayValue?.compactMap(\.stringValue))
        XCTAssertTrue(families.contains("u"), "loopl-train schema must know family u")
        let idPattern = try XCTUnwrap(s["properties"]?["id"]?["pattern"]?.stringValue)
        let imgPattern = try XCTUnwrap(s["properties"]?["images"]?["items"]?["pattern"]?.stringValue)
        let namePattern = try XCTUnwrap(s["$defs"]?["message"]?["properties"]?["tool_calls"]?["items"]?["properties"]?["function"]?["properties"]?["name"]?["pattern"]?.stringValue)
        let roles = try XCTUnwrap(s["$defs"]?["message"]?["properties"]?["role"]?["enum"]?.arrayValue?.compactMap(\.stringValue))
        let required = try XCTUnwrap(s["required"]?.arrayValue?.compactMap(\.stringValue))
        let minItems = try XCTUnwrap(s["properties"]?["messages"]?["minItems"]?.doubleValue)

        let png = try fixture("fixture-red", ext: "png")
        for r in ConversationExport.shard(Self.threads(png: png), options: options).records {
            let o = try XCTUnwrap(r.json.objectValue)
            for k in required { XCTAssertNotNil(o[k], "required key \(k)") }
            XCTAssertTrue(families.contains(o["family"]!.stringValue!))
            XCTAssertNotNil(r.id.range(of: idPattern, options: .regularExpression), "\(r.id) !~ \(idPattern)")
            let msgs = o["messages"]!.arrayValue!
            XCTAssertGreaterThanOrEqual(Double(msgs.count), minItems)
            for m in msgs {
                XCTAssertTrue(roles.contains(m["role"]!.stringValue!))
                for c in m["tool_calls"]?.arrayValue ?? [] {
                    let n = c["function"]!["name"]!.stringValue!
                    XCTAssertNotNil(n.range(of: namePattern, options: .regularExpression))
                    XCTAssertNotNil(c["function"]!["arguments"]!.objectValue)
                }
                if m["role"]?.stringValue == "tool" { XCTAssertNotNil(m["tool_call_id"]?.stringValue); XCTAssertNotNil(m["content"]?.stringValue) }
            }
            for ref in o["images"]?.arrayValue ?? [] {
                XCTAssertNotNil(ref.stringValue!.range(of: imgPattern, options: .regularExpression), "\(ref) !~ \(imgPattern)")
            }
        }
    }

    func testValidateMirrorsTheSchemaRules() throws {
        let png = try fixture("fixture-red", ext: "png")
        let good = try ConversationExport.record(Self.threads(png: png)[0], options: options).json
        XCTAssertEqual(ConversationExport.validate(good), [])
        func mutated(_ f: (inout [String: JSONValue]) -> Void) -> [String] { var o = good.objectValue!; f(&o); return ConversationExport.validate(.object(o)) }
        XCTAssertFalse(mutated { $0["id"] = "zz" }.isEmpty)
        XCTAssertFalse(mutated { $0["family"] = "q" }.isEmpty)
        XCTAssertFalse(mutated { $0["images"] = .array(["pictures/x.png"]) }.isEmpty)
        XCTAssertFalse(mutated { var m = $0["messages"]!.arrayValue!; m.removeLast(); $0["messages"] = .array(m) }.isEmpty, "must end with a plain assistant answer")
        XCTAssertFalse(mutated { var m = $0["messages"]!.arrayValue!; m.remove(at: 3); $0["messages"] = .array(m) }.isEmpty, "tool call without result")
        XCTAssertFalse(mutated { var m = $0["messages"]!.arrayValue!; var a = m[2].objectValue!; a["tool_calls"] = .array([.object(["id": "x", "type": "function", "function": .object(["name": "calculator", "arguments": "{}"])])]); m[2] = .object(a); $0["messages"] = .array(m) }.isEmpty, "string arguments refused")
        XCTAssertTrue(mutated { $0["tools"] = nil }.isEmpty, "tools may be absent (families a–h)")
        XCTAssertFalse(mutated { $0["tools"] = .array([Self.currentTime.openAIFunction]) }.isEmpty, "a call to a tool the row does not offer is refused")
    }

    // MARK: proof artefacts

    /// Writes the 3 fixture threads as a shard to `$LOOPL_EXPORT_DIR` (if set) so the audit can validate the SAME bytes with
    /// Python `jsonschema` and push them to the Hub. A no-op in CI.
    func testWriteFixtureShardForProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_EXPORT_DIR"] else { throw XCTSkip("LOOPL_EXPORT_DIR not set") }
        let png = try fixture("fixture-red", ext: "png")
        let shard = ConversationExport.shard(Self.threads(png: png), options: .init(appVersion: "0.2", platform: "iOS-sim"))
        let root = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data(shard.jsonl.utf8).write(to: root.appendingPathComponent(shard.path))
        for img in shard.images { try img.data.write(to: root.appendingPathComponent(img.path)) }
        try Data(ConversationExport.readme(repo: "cagataydev/loopl-app-conversations-test", shards: [shard.path], rows: shard.records.count).utf8).write(to: root.appendingPathComponent("README.md"))
        print("wrote \(shard.path) (\(shard.records.count) rows, \(shard.images.count) images) to \(dir)")
    }
}
