import XCTest
import Loopl

/// `Tracer`: spans built from hooks only, OTel-shaped, no dependency.
final class TracingTests: XCTestCase {
    func use(_ name: String, _ args: [String: JSONValue] = [:], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }
    func attr(_ span: Span?, _ key: String) -> JSONValue? { span?.attributes[key] }
    func span(_ tracer: Tracer, _ name: String) -> Span? { tracer.spans.first { $0.name == name } }

    func testSpanTreeForAToolCall() async throws {
        let tracer = Tracer(agentName: "chat")
        let model = FakeModel(turns: [.toolUse(text: "computing", [use("calculator", ["expression": "23*47"], id: "t1")]), .text("1081")])
        let agent = Agent(model: model, tools: [CalculatorTool()], systemPrompt: "s", hooks: [tracer], retryStrategy: nil)
        _ = try await agent("23*47?")

        let spans = tracer.spans
        XCTAssertEqual(spans.map(\.name), ["chat", "execute_tool calculator", "chat", "invoke_agent chat"])
        let root = spans.last!
        XCTAssertNil(root.parentId)
        XCTAssertTrue(spans.dropLast().allSatisfy { $0.parentId == root.id })
        XCTAssertTrue(spans.allSatisfy { $0.traceId == root.traceId })
        XCTAssertEqual(root.traceId.count, 32)
        XCTAssertEqual(root.id.count, 16)
        XCTAssertTrue(spans.allSatisfy { $0.endTime != nil && $0.status == .ok })
        XCTAssertTrue(spans.allSatisfy { ($0.durationMs ?? -1) >= 0 })

        // OTel operation names
        XCTAssertEqual(attr(root, SpanAttribute.operation)?.stringValue, "invoke_agent")
        XCTAssertEqual(attr(spans.first, SpanAttribute.operation)?.stringValue, "chat")
        XCTAssertEqual(attr(span(tracer, "execute_tool calculator"), SpanAttribute.operation)?.stringValue, "execute_tool")
        XCTAssertEqual(attr(span(tracer, "execute_tool calculator"), SpanAttribute.toolCallId)?.stringValue, "t1")
        XCTAssertEqual(attr(root, SpanAttribute.finishReason), .array(["end_turn"]))
        XCTAssertEqual(attr(root, "loopl.event_loop.cycles")?.doubleValue, 2)
        XCTAssertEqual(attr(root, "loopl.tool_calls")?.doubleValue, 1)
        XCTAssertEqual(attr(spans[0], SpanAttribute.cycle)?.doubleValue, 1)
        XCTAssertEqual(attr(spans[2], SpanAttribute.cycle)?.doubleValue, 2)

        // every message appended shows up as a span event on the root
        XCTAssertEqual(root.events.map(\.name),
                       ["gen_ai.user.message", "gen_ai.assistant.message", "gen_ai.tool.message", "gen_ai.assistant.message"])
    }

    func testContentIsNotRecordedByDefault() async throws {
        let quiet = Tracer()
        let loud = Tracer(options: .init(recordContent: true))
        for tracer in [quiet, loud] {
            let model = FakeModel(turns: [.text("the answer")])
            let agent = Agent(model: model, systemPrompt: "secret system prompt", hooks: [tracer], retryStrategy: nil)
            _ = try await agent("a private question")
        }
        let quietRoot = quiet.spans.last
        XCTAssertNil(attr(quietRoot, SpanAttribute.inputMessages))
        XCTAssertNil(attr(quiet.spans.first, "gen_ai.system_instructions"))
        XCTAssertTrue(quietRoot?.events.allSatisfy { $0.attributes["content"] == nil } == true)

        let loudRoot = loud.spans.last
        XCTAssertEqual(attr(loudRoot, SpanAttribute.inputMessages)?.arrayValue?.first?["content"]?.stringValue, "a private question")
        XCTAssertEqual(attr(loud.spans.first, "gen_ai.system_instructions")?.stringValue, "secret system prompt")
        XCTAssertEqual(attr(loudRoot, SpanAttribute.outputMessages)?.arrayValue?.first?["content"]?.stringValue, "the answer")
    }

    func testFailureMarksSpansAndRoot() async throws {
        let tracer = Tracer()
        let model = FakeModel(turns: [.failure(ModelError("metal is busy"))])
        let agent = Agent(model: model, hooks: [tracer], retryStrategy: nil)
        do { _ = try await agent("hi") } catch {}
        let spans = tracer.spans
        XCTAssertEqual(spans.map(\.name), ["chat", "invoke_agent agent"])
        XCTAssertTrue(spans.allSatisfy { $0.status == .error })
        XCTAssertEqual(spans[0].statusMessage, "metal is busy")
        XCTAssertEqual(spans[1].statusMessage, "metal is busy")
    }

    func testToolErrorIsASpanError() async throws {
        let tracer = Tracer()
        let model = FakeModel(turns: [.toolUse([use("nope", [:], id: "x1")]), .text("ok")])
        let agent = Agent(model: model, hooks: [tracer], retryStrategy: nil)
        _ = try await agent("call a tool that is not there")
        let tool = span(tracer, "execute_tool nope")
        XCTAssertEqual(tool?.status, .error)
        XCTAssertEqual(attr(tool, "loopl.tool.unknown")?.boolValue, true)
        XCTAssertTrue(tool?.statusMessage?.contains("Unknown tool") == true)
        XCTAssertEqual(tracer.spans.last?.status, .ok, "the loop recovered, so the invocation is ok")
    }

    func testConcurrentToolsGetTheirOwnSpans() async throws {
        let tracer = Tracer()
        let model = FakeModel(turns: [
            .toolUse([use("calculator", ["expression": "1+1"], id: "a"), use("calculator", ["expression": "2+2"], id: "b")]),
            .text("done"),
        ])
        let agent = Agent(model: model, tools: [CalculatorTool()], hooks: [tracer], retryStrategy: nil)
        _ = try await agent("two sums")
        let toolSpans = tracer.spans.filter { $0.name == "execute_tool calculator" }
        XCTAssertEqual(toolSpans.count, 2)
        XCTAssertEqual(Set(toolSpans.compactMap { attr($0, SpanAttribute.toolCallId)?.stringValue }), ["a", "b"])
        XCTAssertEqual(Set(toolSpans.map(\.id)).count, 2)
    }

    func testRecordMetricsLandsOnTheOpenChatSpan() async throws {
        let tracer = Tracer()
        let model = FakeModel(turns: [.text("hello there")])
        let agent = Agent(model: model, hooks: [tracer], retryStrategy: nil)
        for try await event in agent.stream("hi") {
            if case .metrics(let m) = event { tracer.record(m, runtime: .mlx, modelId: "qwen3-1.7b-4bit") }
        }
        let chat = span(tracer, "chat")
        XCTAssertEqual(attr(chat, SpanAttribute.requestModel)?.stringValue, "qwen3-1.7b-4bit")
        XCTAssertEqual(attr(chat, SpanAttribute.runtime)?.stringValue, "mlx")
        XCTAssertEqual(attr(chat, SpanAttribute.outputTokens)?.doubleValue, 2)
        XCTAssertEqual(attr(chat, "loopl.tokens_estimated")?.boolValue, true)
    }

    func testOnSpanEndCallbackAndKeepZero() async throws {
        final class Sink: @unchecked Sendable {
            private let lock = NSLock(); private var names: [String] = []
            var all: [String] { lock.withLock { names } }
            func add(_ n: String) { lock.withLock { names.append(n) } }
        }
        let sink = Sink()
        let tracer = Tracer(options: .init(keep: 0)) { span in sink.add(span.name) }
        let model = FakeModel(turns: [.text("x")])
        let agent = Agent(model: model, hooks: [tracer], retryStrategy: nil)
        _ = try await agent("hi")
        XCTAssertEqual(sink.all, ["chat", "invoke_agent agent"])
        XCTAssertTrue(tracer.spans.isEmpty, "keep: 0 streams spans out without holding them")
    }

    func testOTLPJSONShape() async throws {
        let tracer = Tracer(agentName: "chat")
        let model = FakeModel(turns: [.toolUse([use("calculator", ["expression": "1+1"], id: "t1")]), .text("2")])
        let agent = Agent(model: model, tools: [CalculatorTool()], hooks: [tracer], retryStrategy: nil)
        _ = try await agent("1+1?")

        let otlp = tracer.otlpJSON(serviceName: "loopl-tests")
        let resource = otlp["resourceSpans"]?.arrayValue?.first
        XCTAssertEqual(resource?["resource"]?["attributes"]?.arrayValue?.first?["value"]?["stringValue"]?.stringValue, "loopl-tests")
        let spans = resource?["scopeSpans"]?.arrayValue?.first?["spans"]?.arrayValue ?? []
        XCTAssertEqual(spans.count, tracer.spans.count)
        let root = spans.last
        XCTAssertEqual(root?["name"]?.stringValue, "invoke_agent chat")
        XCTAssertEqual(root?["traceId"]?.stringValue?.count, 32)
        XCTAssertEqual(root?["spanId"]?.stringValue?.count, 16)
        XCTAssertNil(root?["parentSpanId"])
        XCTAssertEqual(root?["status"]?["code"]?.doubleValue, 1)
        XCTAssertNotNil(root?["endTimeUnixNano"]?.stringValue.flatMap { UInt64($0) })
        // attributes are OTel key/value pairs, ints as strings
        let attributes = root?["attributes"]?.arrayValue ?? []
        let cycles = attributes.first { $0["key"]?.stringValue == "loopl.event_loop.cycles" }
        XCTAssertEqual(cycles?["value"]?["intValue"]?.stringValue, "2")
        let system = attributes.first { $0["key"]?.stringValue == SpanAttribute.system }
        XCTAssertEqual(system?["value"]?["stringValue"]?.stringValue, "loopl")
        // the child points at the root
        let child = spans.first
        XCTAssertEqual(child?["parentSpanId"]?.stringValue, root?["spanId"]?.stringValue)
        XCTAssertEqual(child?["kind"]?.doubleValue, 3)      // SPAN_KIND_CLIENT for a model call
        // and it is valid JSON
        XCTAssertNotNil(JSONValue.parse(otlp.compact))
    }

    func testSpansAreCodable() async throws {
        let tracer = Tracer()
        let agent = Agent(model: FakeModel(turns: [.text("x")]), hooks: [tracer], retryStrategy: nil)
        _ = try await agent("hi")
        let data = try JSONEncoder().encode(tracer.spans)
        let decoded = try JSONDecoder().decode([Span].self, from: data)
        XCTAssertEqual(decoded.map(\.name), tracer.spans.map(\.name))
    }
}
