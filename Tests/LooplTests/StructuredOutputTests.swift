import XCTest
import Loopl

/// Schema derivation (`JSONSchema.derive`) + structured output forcing, driven by `FakeModel`.
final class StructuredOutputTests: XCTestCase {

    // MARK: types under test

    struct Weather: Codable, Sendable, Equatable {
        let city: String
        let celsius: Int
        let note: String?
    }
    enum Condition: String, Codable, SchemaEnum, Sendable { case sunny, cloudy, rain }
    struct Place: Codable, Sendable, Equatable { let name: String; let lat: Double }
    struct Forecast: Codable, Sendable, Equatable {
        let place: Place
        let days: [Int]
        let condition: Condition
        let updated: Date
        let source: URL?
    }
    /// Validating initialiser — derivation cannot probe it, so it declares its schema.
    struct Rating: Codable, Sendable, Equatable {
        let stars: Int
        init(from decoder: any Decoder) throws {
            stars = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .stars)
            guard (1...5).contains(stars) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "stars must be 1…5"))
            }
        }
        enum CodingKeys: String, CodingKey { case stars }
    }

    func use(_ name: String, _ args: [String: JSONValue], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }
    func props(_ schema: JSONValue) -> [String: JSONValue] { schema["properties"]?.objectValue ?? [:] }
    func required(_ schema: JSONValue) -> [String] { (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue) }

    // MARK: derivation

    func testDeriveFlatStruct() throws {
        let schema = try JSONSchema.derive(Weather.self, describe: ["city": "City name"])
        XCTAssertEqual(schema["type"]?.stringValue, "object")
        XCTAssertEqual(props(schema)["city"], ["type": "string", "description": "City name"])
        XCTAssertEqual(props(schema)["celsius"]?["type"]?.stringValue, "integer")
        XCTAssertEqual(props(schema)["note"]?["type"]?.stringValue, "string")
        // the optional is NOT required
        XCTAssertEqual(required(schema).sorted(), ["celsius", "city"])
    }

    func testDeriveNestedArrayEnumDateURL() throws {
        let schema = try JSONSchema.derive(Forecast.self, describe: ["place.name": "Place name"])
        let p = props(schema)
        XCTAssertEqual(p["place"]?["type"]?.stringValue, "object")
        XCTAssertEqual(p["place"]?["properties"]?["name"], ["type": "string", "description": "Place name"])
        XCTAssertEqual(p["place"]?["properties"]?["lat"]?["type"]?.stringValue, "number")
        XCTAssertEqual(p["days"], ["type": "array", "items": ["type": "integer"]])
        XCTAssertEqual(p["condition"]?["enum"], .array(["sunny", "cloudy", "rain"]))
        XCTAssertEqual(p["condition"]?["type"]?.stringValue, "string")
        XCTAssertEqual(p["updated"]?["format"]?.stringValue, "date-time")
        XCTAssertEqual(p["source"]?["format"]?.stringValue, "uri")
        XCTAssertEqual(required(schema).sorted(), ["condition", "days", "place", "updated"])
    }

    func testDeriveScalarAndDescription() throws {
        XCTAssertEqual(try JSONSchema.derive(String.self), ["type": "string"])
        let described = try JSONSchema.derive(Weather.self, description: "a weather reading")
        XCTAssertEqual(described["description"]?.stringValue, "a weather reading")
    }

    func testValidatingInitialiserThrowsActionableError() {
        do {
            _ = try JSONSchema.derive(Rating.self)
            XCTFail("expected derivation to fail")
        } catch let error as SchemaDerivationError {
            XCTAssertTrue(error.type.contains("Rating"))
            XCTAssertTrue((error.errorDescription ?? "").contains("JSONSchemaProviding"), error.errorDescription ?? "")
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testDeclaredSchemaWins() throws {
        let schema = try JSONSchema.derive(Declared.self)
        XCTAssertEqual(schema, ToolSchema.object(["stars": ToolSchema.number("1…5")], required: ["stars"]))
    }
    struct Declared: Codable, Sendable, JSONSchemaProviding {
        let stars: Int
        static var jsonSchema: JSONValue { ToolSchema.object(["stars": ToolSchema.number("1…5")], required: ["stars"]) }
    }

    // MARK: the tool

    func testToolDecodesWrappedAndStringifiedInput() throws {
        typealias T = StructuredOutputTool<Weather>
        let direct = try T.decode(["city": "Istanbul", "celsius": 21], dateStrategy: .iso8601)
        XCTAssertEqual(direct, Weather(city: "Istanbul", celsius: 21, note: nil))
        let wrapped = try T.decode(["output": ["city": "Istanbul", "celsius": 21]], dateStrategy: .iso8601)
        XCTAssertEqual(wrapped, direct)
        let stringified = try T.decode(["output": .string("{\"city\":\"Istanbul\",\"celsius\":21}")], dateStrategy: .iso8601)
        XCTAssertEqual(stringified, direct)
        XCTAssertThrowsError(try T.decode(["celsius": 21], dateStrategy: .iso8601))
    }

    // MARK: forcing

    func agent(_ turns: [FakeModel.Turn], tools: [any Tool] = []) -> Agent {
        Agent(model: FakeModel(turns: turns), tools: tools, systemPrompt: "s", retryStrategy: nil)
    }

    /// The model calls the tool → the value comes back and no second generation is spent.
    func testCallsToolImmediately() async throws {
        let model = FakeModel(turns: [
            .toolUse(text: "", [use("structured_output", ["city": "Istanbul", "celsius": 21], id: "s1")]),
            .text("(should never run)"),
        ])
        let agent = Agent(model: model, tools: [CalculatorTool()], systemPrompt: "s", retryStrategy: nil)
        let run = try await agent.structuredRun(As: Weather.self, prompt: "weather in Istanbul")
        XCTAssertEqual(run.value, Weather(city: "Istanbul", celsius: 21, note: nil))
        XCTAssertFalse(run.forced)
        XCTAssertEqual(run.repairs, 0)
        XCTAssertEqual(run.result.stopReason, .endTurn)
        // only ONE model call happened: the loop was ended before the summarising cycle
        let seen = await model.seenPrompts.count
        XCTAssertEqual(seen, 1, "the second cycle never reached the model at all")
        let remaining = await model.turns.count
        XCTAssertEqual(remaining, 1, "the second scripted turn was never consumed")
        // the agent's own tools are back and the structured tool is gone
        let names = await agent.tools.map(\.name)
        XCTAssertEqual(names, ["calculator"])
    }

    /// The first pass offers the agent's tools too, so the model can look things up first.
    func testToolUseThenStructured() async throws {
        let model = FakeModel(turns: [
            .toolUse(text: "", [use("calculator", ["expression": "20+1"], id: "c1")]),
            .toolUse(text: "", [use("structured_output", ["city": "Istanbul", "celsius": 21], id: "s1")]),
        ])
        let agent = Agent(model: model, tools: [CalculatorTool()], systemPrompt: "s", retryStrategy: nil)
        let run = try await agent.structuredRun(As: Weather.self, prompt: "weather in Istanbul")
        XCTAssertEqual(run.value.celsius, 21)
        let firstSpecs = await model.seenToolSpecs.first?.map(\.name).sorted()
        XCTAssertEqual(firstSpecs, ["calculator", "structured_output"])
    }

    /// Prose instead of a call → the forced pass offers ONLY the structured tool.
    func testIgnoredThenForced() async throws {
        let model = FakeModel(turns: [
            .text("It is about 21 degrees in Istanbul."),
            .toolUse(text: "", [use("structured_output", ["city": "Istanbul", "celsius": 21], id: "s1")]),
        ])
        let agent = Agent(model: model, tools: [CalculatorTool()], systemPrompt: "s", retryStrategy: nil)
        let run = try await agent.structuredRun(As: Weather.self, prompt: "weather in Istanbul")
        XCTAssertEqual(run.value, Weather(city: "Istanbul", celsius: 21, note: nil))
        XCTAssertTrue(run.forced)
        let specs = await model.seenToolSpecs.map { $0.map(\.name).sorted() }
        XCTAssertEqual(specs.prefix(2).map { $0 }, [["calculator", "structured_output"], ["structured_output"]])
        let prompts = await model.seenPrompts
        XCTAssertTrue(prompts[1].last?.text.contains("structured_output tool now") == true, "the forcing prompt is in the second pass")
    }

    /// Prose twice → thrown, with the model's last answer in the message.
    func testNeverCalledThrows() async throws {
        let agent = agent([.text("twenty-one degrees"), .text("I said twenty-one degrees")])
        do {
            _ = try await agent.structured(As: Weather.self, prompt: "weather in Istanbul")
            XCTFail("expected notCalled")
        } catch let error as StructuredOutputError {
            guard case .notCalled(let type, let attempts, let last) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(type.contains("Weather"))
            XCTAssertEqual(attempts, 2)
            XCTAssertTrue(last.contains("twenty-one"))
        }
    }

    /// Malformed input is handed back to the model as an error result, and the retry decodes.
    func testInvalidInputIsRepaired() async throws {
        let model = FakeModel(turns: [
            .toolUse(text: "", [use("structured_output", ["city": "Istanbul"], id: "s1")]),            // celsius missing
            .toolUse(text: "", [use("structured_output", ["city": "Istanbul", "celsius": 21], id: "s2")]),
        ])
        let agent = Agent(model: model, tools: [], systemPrompt: "s", retryStrategy: nil)
        let run = try await agent.structuredRun(As: Weather.self, prompt: "weather in Istanbul")
        XCTAssertEqual(run.value.celsius, 21)
        XCTAssertEqual(run.repairs, 1)
        // the model was told what was wrong
        let prompts = await model.seenPrompts
        let errorResult = prompts[1].flatMap(\.toolResults).first { $0.isError }
        XCTAssertTrue(errorResult?.content.contains("missing required field \"celsius\"") == true, errorResult?.content ?? "nil")
    }

    /// Malformed beyond the repair budget → thrown, with the decoder's complaint.
    func testInvalidInputBeyondBudgetThrows() async throws {
        let model = FakeModel(turns: [
            .toolUse(text: "", [use("structured_output", ["city": "Istanbul"], id: "s1")]),
            .toolUse(text: "", [use("structured_output", ["city": "Istanbul"], id: "s2")]),
            .toolUse(text: "", [use("structured_output", ["city": "Istanbul"], id: "s3")]),
        ])
        let agent = Agent(model: model, tools: [], systemPrompt: "s", retryStrategy: nil)
        do {
            _ = try await agent.structured(As: Weather.self, prompt: "weather in Istanbul")
            XCTFail("expected decodingFailed")
        } catch let error as StructuredOutputError {
            guard case .decodingFailed(_, let reason, let repairs) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("celsius"), reason)
            XCTAssertGreaterThanOrEqual(repairs, 2)
        }
    }

    /// `discardHistory` leaves the conversation exactly as it was.
    func testDiscardHistory() async throws {
        let model = FakeModel(turns: [.toolUse(text: "", [use("structured_output", ["city": "Izmir", "celsius": 25], id: "s1")])])
        let agent = Agent(model: model, tools: [], systemPrompt: "s", messages: [.user("hi"), .assistant("hello")], retryStrategy: nil)
        var options = StructuredOutputOptions()
        options.discardHistory = true
        _ = try await agent.structured(As: Weather.self, prompt: "weather in Izmir", options: options)
        let messages = await agent.messages
        XCTAssertEqual(messages.map(\.text), ["hi", "hello"])
    }

    /// A second structured call on the same agent still works (the coordinator is reused, not re-registered).
    func testTwoStructuredCallsOnOneAgent() async throws {
        let model = FakeModel(turns: [
            .toolUse(text: "", [use("structured_output", ["city": "A", "celsius": 1], id: "s1")]),
            .toolUse(text: "", [use("structured_output", ["city": "B", "celsius": 2], id: "s2")]),
        ])
        let agent = Agent(model: model, tools: [], systemPrompt: "s", retryStrategy: nil)
        let first = try await agent.structured(As: Weather.self, prompt: "a")
        let second = try await agent.structured(As: Weather.self, prompt: "b")
        XCTAssertEqual([first.city, second.city], ["A", "B"])
    }

    /// A normal `agent(…)` after a structured call is unaffected: no stale cancel, no stray tool.
    func testPlainCallAfterStructuredCall() async throws {
        let model = FakeModel(turns: [
            .toolUse(text: "", [use("structured_output", ["city": "A", "celsius": 1], id: "s1")]),
            .text("plain answer"),
        ])
        let agent = Agent(model: model, tools: [], systemPrompt: "s", retryStrategy: nil)
        _ = try await agent.structured(As: Weather.self, prompt: "a")
        let result = try await agent("and now in words?")
        XCTAssertEqual(result.text, "plain answer")
        XCTAssertEqual(result.stopReason, .endTurn)
    }

    /// The markup path (what MLX/GGUF actually emit) reaches the same place.
    func testHermesMarkupCallsStructuredTool() async throws {
        let json = "{\"name\": \"structured_output\", \"arguments\": {\"city\": \"Ankara\", \"celsius\": 18}}"
        let agent = agent([.markup("<tool_call>\(json)</tool_call>")])
        let value = try await agent.structured(As: Weather.self, prompt: "weather in Ankara")
        XCTAssertEqual(value, Weather(city: "Ankara", celsius: 18, note: nil))
    }
}
