import XCTest
import Loopl

/// Strands `validate_and_prepare_tools`: a toolUse the model broke never reaches a
/// tool — it gets an error result in its place, so the toolUse and toolResult lists
/// stay 1:1 and the model can read what it did wrong.
final class ToolValidationTests: XCTestCase {

    let echo = ClosureTool(name: "echo", description: "echo a string",
                           parameters: ToolSchema.object(["text": ToolSchema.string("what to echo")], required: ["text"])) { args in
        args["text"]?.stringValue ?? ""
    }
    let adder = ClosureTool(name: "add", description: "add two numbers",
                            parameters: ToolSchema.object(["a": ToolSchema.number("a"), "b": ToolSchema.number("b")],
                                                          required: ["a", "b"])) { args in
        String((args["a"]?.doubleValue ?? 0) + (args["b"]?.doubleValue ?? 0))
    }
    let flagger = ClosureTool(name: "flag", description: "set a flag",
                              parameters: ToolSchema.object(["on": ToolSchema.boolean("on")], required: ["on"])) { args in
        "\(args["on"]?.boolValue ?? false)"
    }

    var tools: [any Tool] { [echo, adder, flagger] }

    func validate(_ uses: [ToolUse]) -> ToolValidation.Outcome {
        ToolValidation.validateAndPrepare(toolUses: uses, tools: tools)
    }

    // MARK: Strands' own rule — the tool-use name

    func testEmptyNameIsRejectedNotExecuted() {
        let out = validate([ToolUse(toolUseId: "t1", name: "", input: [:])])
        XCTAssertTrue(out.valid.isEmpty)
        XCTAssertEqual(out.results.count, 1)
        XCTAssertEqual(out.results[0].toolUseId, "t1")
        XCTAssertEqual(out.results[0].status, .error)
        XCTAssertTrue(out.results[0].content.contains("tool name missing"), out.results[0].content)
    }

    func testNamePatternAndLength() {
        let bad = validate([ToolUse(toolUseId: "t1", name: "echo tool!", input: ["text": "hi"])])
        XCTAssertTrue(bad.valid.isEmpty)
        XCTAssertTrue(bad.results[0].content.contains("invalid tool name pattern"), bad.results[0].content)

        let long = String(repeating: "a", count: ToolValidation.maxNameLength + 1)
        let tooLong = validate([ToolUse(toolUseId: "t2", name: long, input: [:])])
        XCTAssertTrue(tooLong.results[0].content.contains("invalid tool name length"), tooLong.results[0].content)

        XCTAssertNil(ToolValidation.nameProblem("http"))
        XCTAssertNil(ToolValidation.nameProblem("current_time"))
        XCTAssertNil(ToolValidation.nameProblem("tool-2"))
    }

    /// An unknown tool is NOT a validation failure: the agent answers with
    /// "Unknown tool: … Available tools: …", which is what models recover from.
    func testUnknownToolIsLeftToTheAgent() {
        let out = validate([ToolUse(toolUseId: "t1", name: "nope", input: [:])])
        XCTAssertEqual(out.valid.map(\.name), ["nope"])
        XCTAssertTrue(out.results.isEmpty)
    }

    // MARK: what small models actually emit

    func testDuplicateToolUseIdFirstWinsSecondGetsAnError() {
        let out = validate([ToolUse(toolUseId: "dup", name: "echo", input: ["text": "a"]),
                            ToolUse(toolUseId: "dup", name: "echo", input: ["text": "b"])])
        XCTAssertEqual(out.valid.count, 1)
        XCTAssertEqual(out.valid[0].input["text"], .string("a"))
        XCTAssertEqual(out.results.count, 1)
        XCTAssertTrue(out.results[0].content.contains("duplicate toolUseId"), out.results[0].content)
    }

    func testMissingRequiredFieldNamesItAndShowsTheShape() {
        let out = validate([ToolUse(toolUseId: "t1", name: "add", input: ["a": 1])])
        XCTAssertTrue(out.valid.isEmpty)
        let text = out.results[0].content
        XCTAssertTrue(text.contains("missing required parameter 'b'"), text)
        XCTAssertTrue(text.contains("\"a\": <number>"), text)
    }

    func testWrongTypeIsRefusedWithExpectedAndActual() {
        let out = validate([ToolUse(toolUseId: "t1", name: "add", input: ["a": ["nested": 1], "b": 2])])
        XCTAssertTrue(out.valid.isEmpty)
        let text = out.results[0].content
        XCTAssertTrue(text.contains("parameter 'a'"), text)
        XCTAssertTrue(text.contains("expected number, got object"), text)
    }

    /// Small models quote everything. `"3"` for a number is a coercion, not a failure.
    func testQuotedNumbersAndBooleansAreCoerced() {
        let out = validate([ToolUse(toolUseId: "t1", name: "add", input: ["a": "3", "b": " 4 "]),
                            ToolUse(toolUseId: "t2", name: "flag", input: ["on": "yes"])])
        XCTAssertTrue(out.results.isEmpty, out.results.map(\.content).joined())
        XCTAssertEqual(out.valid[0].input["a"], .number(3))
        XCTAssertEqual(out.valid[0].input["b"], .number(4))
        XCTAssertEqual(out.valid[1].input["on"], .bool(true))
    }

    /// `"arguments": "12*12"` (Apple FM does this) → lifted into the single required property.
    func testBareStringArgumentIsLiftedIntoTheOnlyRequiredProperty() {
        let out = validate([ToolUse(toolUseId: "t1", name: "echo", input: ["_": .string("hello there")])])
        XCTAssertTrue(out.results.isEmpty, out.results.map(\.content).joined())
        XCTAssertEqual(out.valid.count, 1)
        XCTAssertEqual(out.valid[0].input, ["text": .string("hello there")])
    }

    /// With two required properties there is nothing to lift it into — say so instead of guessing.
    func testBareStringWithTwoRequiredPropertiesIsAnError() {
        let out = validate([ToolUse(toolUseId: "t1", name: "add", input: ["_": .string("1 and 2")])])
        XCTAssertTrue(out.valid.isEmpty)
        XCTAssertTrue(out.results[0].content.contains("missing required parameter"), out.results[0].content)
    }

    func testEnumIsEnforced() {
        let spec: JSONValue = ["type": "string", "enum": .array([.string("a"), .string("b")])]
        guard case .problem(let complaint) = ToolValidation.coerce(.string("c"), to: spec) else {
            return XCTFail("expected the enum to be enforced")
        }
        XCTAssertTrue(complaint.contains("expected one of"), complaint)
        guard case .value(let ok) = ToolValidation.coerce(.string("b"), to: spec) else {
            return XCTFail("b is in the enum")
        }
        XCTAssertEqual(ok, .string("b"))
    }

    func testIntegerRejectsAFraction() {
        let spec: JSONValue = ["type": "integer"]
        guard case .problem = ToolValidation.coerce(.number(1.5), to: spec) else {
            return XCTFail("1.5 is not an integer")
        }
        guard case .value(let coerced) = ToolValidation.coerce(.string("7"), to: spec) else {
            return XCTFail("\"7\" is an integer")
        }
        XCTAssertEqual(coerced, .number(7))
    }

    func testPropertiesNotInTheSchemaArePassedThrough() {
        let out = validate([ToolUse(toolUseId: "t1", name: "echo", input: ["text": "hi", "extra": 1])])
        XCTAssertEqual(out.valid[0].input["extra"], .number(1))
    }

    // MARK: through the agent (Strands' repair: the result list stays paired)

    /// Note: a toolUse with an EMPTY name never reaches the agent — `StreamAssembler`
    /// drops a content block that has no tool name, so that case is covered by the unit
    /// tests above rather than end to end.
    func testAgentPairsEveryBrokenToolUseWithAnErrorResult() async throws {
        let uses = [ToolUse(toolUseId: "ok", name: "echo", input: ["text": "fine"]),
                    ToolUse(toolUseId: "broken", name: "add", input: ["a": 1]),
                    ToolUse(toolUseId: "wrongtype", name: "flag", input: ["on": .array([.bool(true)])])]
        let model = FakeModel(turns: [.toolUse(uses), .text("done")])
        let agent = Agent(model: model, tools: tools, retryStrategy: nil)
        var results: [ToolResult] = []
        for try await e in agent.stream("go") { if case .toolResult(let r) = e { results.append(r) } }

        XCTAssertEqual(Set(results.map(\.toolUseId)), ["ok", "broken", "wrongtype"],
                       "every toolUse needs a result or the next prompt does not render")
        XCTAssertEqual(results.first { $0.toolUseId == "ok" }?.status, .success)
        XCTAssertEqual(results.first { $0.toolUseId == "broken" }?.status, .error)
        XCTAssertEqual(results.first { $0.toolUseId == "wrongtype" }?.status, .error)

        // The toolResult message the model sees carries all three, in one user turn.
        let history = await agent.messages
        let toolResultMessage = history.first { $0.role == .user && $0.content.contains { $0.isToolResult } }
        XCTAssertEqual(toolResultMessage?.content.compactMap { $0.toolResult?.toolUseId }.count, 3)
    }

    func testABrokenCallDoesNotRunTheTool() async throws {
        let ran = Counter()
        let strict = ClosureTool(name: "strict", description: "needs a number",
                                 parameters: ToolSchema.object(["n": ToolSchema.number("n")], required: ["n"])) { _ in
            await ran.bump(); return "ran"
        }
        let model = FakeModel(turns: [.toolUse([ToolUse(toolUseId: "t1", name: "strict", input: ["n": .string("not a number")])]),
                                      .text("done")])
        let agent = Agent(model: model, tools: [strict], retryStrategy: nil)
        for try await _ in agent.stream("go") {}
        let calls = await ran.value
        XCTAssertEqual(calls, 0, "a tool must not see input its schema refuses")
    }

    /// A tool that validates its own input (`StructuredOutputTool`) is NOT pre-checked:
    /// its decoder's complaint is the repair signal the model must read.
    func testSelfValidatingToolsSkipTheSchemaPreCheck() throws {
        struct Reading: Decodable, Sendable { var city: String; var celsius: Int }
        let structured = try StructuredOutputTool<Reading>(Reading.self)
        XCTAssertTrue(structured.validatesOwnInput)
        let use = ToolUse(toolUseId: "s1", name: structured.name, input: ["city": .string("Istanbul")]) // celsius missing
        let outcome = ToolValidation.validateAndPrepare(toolUses: [use], tools: [structured])
        XCTAssertEqual(outcome.valid.map { $0.toolUseId }, ["s1"], "the call must reach the tool untouched")
        XCTAssertTrue(outcome.results.isEmpty)
        // …while an ordinary tool with the same schema is still refused before it runs.
        let plain = ClosureTool(name: "plain", description: "", parameters: structured.parameters) { _ in "ran" }
        XCTAssertFalse(plain.validatesOwnInput)
        let refused = ToolValidation.validateAndPrepare(toolUses: [ToolUse(toolUseId: "p1", name: "plain", input: ["city": .string("Istanbul")])], tools: [plain])
        XCTAssertTrue(refused.valid.isEmpty)
        XCTAssertEqual(refused.results.count, 1)
    }
}

/// Minimal async-safe counter for the tests above.
actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
