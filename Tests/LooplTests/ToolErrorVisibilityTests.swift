import XCTest
@testable import Loopl

/// Owner decision 2026-10-06 (loopl-train BRIEF "no RepeatBreaker"): the event loop has no
/// identical-call heuristic, so the ONLY thing that stops a small model from re-issuing a
/// failed call verbatim is seeing the failure. No chat template renders `ToolResult.status`
/// — only `content` — so every prompt path must put the marker INTO the text.
final class ToolErrorVisibilityTests: XCTestCase {
    let use = ToolUse(toolUseId: "h1", name: "http", input: ["method": "GET"])

    // MARK: the marker itself

    func testPromptContentOfAnErrorBeginsWithTheMarkerExactlyOnce() {
        let plain = ToolResult.error(use, "connection refused")
        XCTAssertEqual(plain.promptContent, "ERROR: connection refused")
        XCTAssertEqual(plain.content, "connection refused", "the stored content is untouched")

        let validation = ToolResult.error(use, "Error: missing required parameter 'url'. Call it with arguments like {\"url\": \"https://example.com\"}.")
        XCTAssertTrue(validation.promptContent.hasPrefix("ERROR: missing required parameter 'url'"), validation.promptContent)
        XCTAssertFalse(validation.promptContent.contains("ERROR: Error:"), "a leading 'Error:' is normalised, not doubled")

        let shouting = ToolResult.error(use, "ERROR: already marked")
        XCTAssertEqual(shouting.promptContent, "ERROR: already marked")

        let empty = ToolResult.error(use, "   ")
        XCTAssertEqual(empty.promptContent, "ERROR: the tool failed without a message")

        let ok = ToolResult(toolUseId: "h1", name: "http", content: "200 OK")
        XCTAssertEqual(ok.promptContent, "200 OK", "success results are passed through verbatim")
    }

    func testValidationErrorsCarryTheRetryHint() {
        let bad = ToolUse(toolUseId: "h1", name: "http", input: [:])
        let outcome = ToolValidation.validateAndPrepare(toolUses: [bad], tools: [HttpTool()])
        let r = outcome.results.first
        XCTAssertEqual(r?.status, .error)
        XCTAssertTrue(r?.content.contains("missing required parameter 'url'") == true, r?.content ?? "nil")
        XCTAssertTrue(r?.content.hasSuffix(ToolResult.retryHint) == true, r?.content ?? "nil")
        XCTAssertTrue(r?.promptContent.hasPrefix("ERROR: missing required parameter 'url'") == true, r?.promptContent ?? "nil")
        XCTAssertEqual(ToolResult.retryHint, "Fix the arguments and call the tool again, or answer the user without it.")
    }

    // MARK: path 1 — MLX native chat template (`tool` role dictionaries)

    func testTemplateDictionariesForTheToolRoleCarryTheMarker() {
        let results = Message.toolResults([
            ToolResult.error(use, "Error: missing required parameter 'url'.\n" + ToolResult.retryHint),
            ToolResult(toolUseId: "h2", name: "http", content: "200 OK"),
        ])
        let dicts = results.templateDictionaries
        XCTAssertEqual(dicts.count, 2)
        XCTAssertEqual(dicts[0]["role"] as? String, "tool")
        let content = dicts[0]["content"] as? String ?? ""
        XCTAssertTrue(content.hasPrefix("ERROR: missing required parameter 'url'."), content)
        XCTAssertTrue(content.hasSuffix(ToolResult.retryHint), content)
        XCTAssertEqual(dicts[1]["content"] as? String, "200 OK")
        // Qwen3 / Qwen3.5 / Llama templates print `message.content` only — the dictionary
        // has no `status` key the template could have read, which is why the text carries it.
        XCTAssertNil(dicts[0]["status"])
    }

    // MARK: path 2 — the <tool_response> fold (Gemma / SmolLM / FM / GGUF)

    func testFoldedToolResponseCarriesStatusAttributeAndMarker() {
        let messages: [Message] = [
            .user("fetch example.com"),
            .assistant(text: "", toolUses: [use]),
            .toolResults([ToolResult.error(use, "Error: missing required parameter 'url'.\n" + ToolResult.retryHint)]),
        ]
        let folded = PromptBuilder.foldToolMessages(messages)
        XCTAssertEqual(folded.count, 3)
        let rendered = folded[2].text
        XCTAssertTrue(rendered.hasPrefix("<tool_response name=\"http\" id=\"h1\" status=\"error\">\nERROR: missing required parameter 'url'."), rendered)
        XCTAssertTrue(rendered.contains(ToolResult.retryHint), rendered)

        let okFold = PromptBuilder.foldToolMessages([.toolResults([ToolResult(toolUseId: "h2", name: "http", content: "200 OK")])])
        XCTAssertEqual(okFold[0].text, "<tool_response name=\"http\" id=\"h2\">\n200 OK\n</tool_response>", "success keeps the old shape byte for byte")
    }

    // MARK: path 3 — ChatML text fallback (no template at all)

    func testChatMLFallbackCarriesTheMarker() {
        let messages: [Message] = [
            .user("fetch example.com"),
            .assistant(text: "", toolUses: [use]),
            .toolResults([ToolResult.error(use, "connection refused")]),
        ]
        let s = PromptBuilder.chatML(systemPrompt: nil, messages: PromptBuilder.foldToolMessages(messages))
        XCTAssertTrue(s.contains("<|im_start|>user\n<tool_response name=\"http\" id=\"h1\" status=\"error\">\nERROR: connection refused\n</tool_response><|im_end|>"), s)
    }
}
