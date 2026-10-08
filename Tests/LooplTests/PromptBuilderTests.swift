import XCTest
import Loopl

final class PromptBuilderTests: XCTestCase {
    let tools: [any Tool] = [CalculatorTool()]

    func testHermesSystemPromptSnapshot() {
        let p = PromptBuilder.toolSystemPrompt(tools: tools, family: .hermes, base: "Be brief.")
        XCTAssertTrue(p.hasPrefix("Be brief.\n\n# Tools\n"))
        XCTAssertTrue(p.contains("<tools>\n{\"function\":{\"description\":"))
        XCTAssertTrue(p.contains("\"name\":\"calculator\""))
        XCTAssertTrue(p.contains("<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call>"))
    }

    func testLlama3SystemPrompt() {
        let p = PromptBuilder.toolSystemPrompt(tools: tools, family: .llama3, base: nil)
        XCTAssertTrue(p.hasPrefix("Environment: ipython\n"))
        XCTAssertTrue(p.contains("\"parameters\""))
    }

    func testGenericSystemPrompt() {
        let p = PromptBuilder.toolSystemPrompt(tools: tools, family: .generic, base: nil)
        XCTAssertTrue(p.contains("```json fence"))
    }

    func testNoToolsReturnsBase() {
        XCTAssertEqual(PromptBuilder.toolSystemPrompt(tools: [], family: .hermes, base: "x"), "x")
    }

    func testFoldToolMessagesKeepsAlternation() {
        let use = ToolUse(toolUseId: "c1", name: "calculator", input: ["expression": "1+1"])
        let msgs: [Message] = [.user("1+1?"), .assistant(text: "", toolUses: [use]),
                               .toolResults([ToolResult(toolUseId: "c1", name: "calculator", content: "1+1 = 2")])]
        let folded = PromptBuilder.foldToolMessages(msgs)
        XCTAssertEqual(folded.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(folded[1].text, "<tool_call>\n{\"name\": \"calculator\", \"arguments\": {\"expression\":\"1+1\"}}\n</tool_call>")
        XCTAssertEqual(folded[2].text, "<tool_response name=\"calculator\" id=\"c1\">\n1+1 = 2\n</tool_response>")
    }

    func testChatMLSnapshot() {
        let s = PromptBuilder.chatML(systemPrompt: "sys", messages: [.user("hi")])
        XCTAssertEqual(s, "<|im_start|>system\nsys<|im_end|>\n<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n")
    }

    func testTemplateDictionaryShape() {
        let use = ToolUse(toolUseId: "c1", name: "f", input: ["a": 1])
        let d = Message.assistant(text: "t", toolUses: [use]).templateDictionaries[0]
        XCTAssertEqual(d["role"] as? String, "assistant")
        let calls = d["tool_calls"] as? [[String: any Sendable]]
        XCTAssertEqual(calls?.count, 1)
        let fn = calls?[0]["function"] as? [String: any Sendable]
        XCTAssertEqual(fn?["name"] as? String, "f")
        XCTAssertEqual((fn?["arguments"] as? [String: any Sendable])?["a"] as? Int, 1)
        let t = Message.toolResults([ToolResult(toolUseId: "c1", name: "f", content: "r")]).templateDictionaries
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0]["role"] as? String, "tool")
        XCTAssertEqual(t[0]["tool_call_id"] as? String, "c1")
        let all = Message.templateDictionaries(systemPrompt: "s", messages: [.user("u")])
        XCTAssertEqual(all.map { $0["role"] as? String }, ["system", "user"])
    }

    func testCatalogDecodesAndIsPublicOnly() throws {
        // SwiftPM: Fixtures/models.json via Bundle.module; Xcode-hosted: the app bundle's models.json.
        var url: URL?
        #if SWIFT_PACKAGE
        url = Bundle.module.url(forResource: "models", withExtension: "json", subdirectory: "Fixtures") ?? Bundle.module.url(forResource: "models", withExtension: "json")
        #endif
        if url == nil { url = Bundle.allBundles.compactMap { $0.url(forResource: "models", withExtension: "json") }.first }
        let data = try Data(contentsOf: XCTUnwrap(url))
        let c = try JSONDecoder().decode(Catalog.self, from: data)
        XCTAssertGreaterThanOrEqual(c.models.count, 12)
        // the catalog may carry the owner's PRIVATE loopl models (gated → "sign in to Hugging Face", Bearer download);
        // everything else, and always the default, stays public so a signed-out user is never blocked.
        let gated = c.models.filter(\.gated)
        XCTAssertTrue(gated.allSatisfy { $0.id.hasPrefix("loopl-") && $0.repo.hasPrefix("cagataydev/loopl-") },
                      "only the loopl GGUF rows (private repos) may be gated: \(gated.map(\.id))")
        XCTAssertFalse(try XCTUnwrap(c.defaultModel).gated, "default model must be public")
        XCTAssertEqual(c.defaultModelId, "qwen3-0.6b-4bit")
        XCTAssertEqual(c.models.first?.id, "qwen3-0.6b-4bit")
        XCTAssertEqual(c.defaultModel?.repo, "mlx-community/Qwen3-0.6B-4bit")
        let ggufs = c.models.filter { $0.runtime == .gguf }
        XCTAssertGreaterThanOrEqual(ggufs.count, 5)
        XCTAssertTrue(ggufs.allSatisfy { $0.file?.hasSuffix(".gguf") == true })
        XCTAssertEqual(c["qwen3-1.7b-4bit"]?.chatTemplateKwargs?["enable_thinking"], .bool(false))
    }

    func testDefaultParamsAreMaxedOut() throws {
        let spec = ModelSpec(id: "q", name: "Q", repo: "unsloth/Qwen3-1.7B-GGUF", runtime: .gguf, family: .hermes, paramsB: 1.7, sizeBytes: 1,
                             ctxNominal: 40960, ctxUsable8GB: 8192, minRAMGB: 6)
        let p = spec.defaultParams
        XCTAssertNil(p.maxTokens, "no new-token cap by default")
        XCTAssertEqual(p.contextLength, 8192)
        XCTAssertEqual(p.temperature, 0.7)
        let small = ModelSpec(id: "s", name: "S", repo: "x/SmolLM2", runtime: .gguf, family: .generic, paramsB: 1, sizeBytes: 1, ctxNominal: 2048, ctxUsable8GB: 8192, minRAMGB: 1)
        XCTAssertEqual(small.defaultParams.contextLength, 2048, "never above the model's own window")
    }
}
