import XCTest
@testable import loopl

final class PromptBuilderTests: XCTestCase {
    let tools: [any AgentTool] = [CalculatorTool()]

    func testHermesSystemPromptSnapshot() {
        let p = PromptBuilder.toolSystemPrompt(tools: tools, family: .hermes, base: "Be brief.")
        XCTAssertTrue(p.hasPrefix("Be brief.\n\n# Tools"))
        XCTAssertTrue(p.contains("<tools>\n{\"function\":{\"description\":\"Evaluate an arithmetic expression exactly."))
        XCTAssertTrue(p.contains("\"name\":\"calculator\""))
        XCTAssertTrue(p.contains("\"required\":[\"expression\"]"))
        XCTAssertTrue(p.hasSuffix("<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call>\nAfter the tool results arrive, answer the user in plain text."))
    }

    func testLlama3SystemPromptSnapshot() {
        let p = PromptBuilder.toolSystemPrompt(tools: tools, family: .llama3, base: nil)
        XCTAssertTrue(p.hasPrefix("Environment: ipython\n"))
        XCTAssertTrue(p.contains("{\"name\": function_name, \"parameters\": {argument: value}}"))
    }

    func testGenericSystemPromptSnapshot() {
        let p = PromptBuilder.toolSystemPrompt(tools: tools, family: .generic, base: nil)
        XCTAssertTrue(p.hasPrefix("You can use these tools:\n{\"function\""))
        XCTAssertTrue(p.contains("```json fence"))
    }

    func testNoToolsReturnsBase() {
        XCTAssertEqual(PromptBuilder.toolSystemPrompt(tools: [], family: .hermes, base: "x"), "x")
    }

    func testFoldToolMessagesKeepsAlternation() {
        let call = ToolCall(id: "c1", name: "calculator", arguments: ["expression": "1+1"])
        let msgs: [Message] = [.system("s"), .user("1+1?"), .assistant(text: "", toolCalls: [call]), .tool(result: "1+1 = 2", callId: "c1", name: "calculator")]
        let folded = PromptBuilder.foldToolMessages(msgs)
        XCTAssertEqual(folded.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertEqual(folded[2].text, "<tool_call>\n{\"name\": \"calculator\", \"arguments\": {\"expression\":\"1+1\"}}\n</tool_call>")
        XCTAssertEqual(folded[3].text, "<tool_response name=\"calculator\" id=\"c1\">\n1+1 = 2\n</tool_response>")
    }

    func testChatMLSnapshot() {
        let s = PromptBuilder.chatML([.system("sys"), .user("hi")])
        XCTAssertEqual(s, "<|im_start|>system\nsys<|im_end|>\n<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n")
    }

    func testTemplateDictionaryShape() {
        let call = ToolCall(id: "c1", name: "f", arguments: ["a": 1])
        let d = Message.assistant(text: "t", toolCalls: [call]).templateDictionary
        XCTAssertEqual(d["role"] as? String, "assistant")
        let calls = d["tool_calls"] as? [[String: any Sendable]]
        XCTAssertEqual(calls?.count, 1)
        let fn = calls?[0]["function"] as? [String: any Sendable]
        XCTAssertEqual(fn?["name"] as? String, "f")
        XCTAssertEqual((fn?["arguments"] as? [String: any Sendable])?["a"] as? Int, 1)
        let t = Message.tool(result: "r", callId: "c1", name: "f").templateDictionary
        XCTAssertEqual(t["tool_call_id"] as? String, "c1")
    }

    func testCatalogDecodes() throws {
        let url = Bundle(for: PromptBuilderTests.self).url(forResource: "models", withExtension: "json")
            ?? Bundle.main.url(forResource: "models", withExtension: "json")
        let data = try Data(contentsOf: XCTUnwrap(url))
        let c = try JSONDecoder().decode(Catalog.self, from: data)
        XCTAssertGreaterThanOrEqual(c.models.count, 6)
        XCTAssertTrue(c.models.contains { $0.repo == "mlx-community/Qwen3-1.7B-4bit" && !$0.gated })
        XCTAssertTrue(c.models.filter { $0.gated }.allSatisfy { $0.repo.contains("Llama") || $0.repo.contains("gemma") })
    }
}
