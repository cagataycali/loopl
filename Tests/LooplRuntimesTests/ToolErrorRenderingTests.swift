import XCTest
@testable import Loopl
@testable import LooplRuntimes

/// The two runtime prompt paths that do not go through `Message.templateDictionaries`:
/// GGUF (`llama_chat_apply_template` over the folded chat) and Apple FM (plain transcript).
/// Both must show the model an unmistakable `ERROR:` for a failed tool call.
final class ToolErrorRenderingTests: XCTestCase {
    let use = ToolUse(toolUseId: "h1", name: "http", input: ["method": "GET"])
    var failed: [Message] {
        [.user("fetch example.com"),
         .assistant(text: "", toolUses: [use]),
         .toolResults([ToolResult.error(use, "Error: missing required parameter 'url'. Call it with arguments like {\"url\": \"https://example.com\"}.\n" + ToolResult.retryHint)])]
    }

    func testGGUFRenderedPromptCarriesTheMarker() throws {
        guard GGUFModel.availability().available else { throw XCTSkip(GGUFModel.availability().reason) }
        // A ChatML template of the shape Qwen3 GGUFs ship (tool turns arrive folded as user text).
        let tmpl = "{% for message in messages %}{{'<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>' + '\\n'}}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% endif %}"
        let out = GGUFModel.renderPrompt(template: tmpl, systemPrompt: nil, messages: failed, toolSpecs: [HttpTool().toolSpec], family: .hermes)
        XCTAssertTrue(out.contains("<tool_response name=\"http\" id=\"h1\" status=\"error\">\nERROR: missing required parameter 'url'."), out)
        XCTAssertTrue(out.contains(ToolResult.retryHint), out)
        // And the no-template fallback.
        let fallback = GGUFModel.renderPrompt(template: nil, systemPrompt: nil, messages: failed, toolSpecs: [HttpTool().toolSpec], family: .hermes)
        XCTAssertTrue(fallback.contains("status=\"error\">\nERROR: missing required parameter 'url'."), fallback)
    }

    func testAppleFMPromptAfterAFailedCallStaysInCallModeAndShowsTheError() {
        let built = AppleFMPrompt.build(messages: failed, toolSpecs: [HttpTool().toolSpec], systemPrompt: nil)
        XCTAssertEqual(built.mode, .call, "an errored result must leave the model free to call again with fixed arguments")
        XCTAssertTrue(built.prompt.contains("Tool result: http -> ERROR: missing required parameter 'url'."), built.prompt)
        XCTAssertTrue(built.prompt.contains(ToolResult.retryHint), built.prompt)
        XCTAssertFalse(built.prompt.contains("Tools have already been run for you"), "that is the answer-mode sentence; it forbids a retry")
    }

    func testAppleFMPromptAfterASuccessfulCallIsAnswerMode() {
        let ok: [Message] = [.user("fetch example.com"), .assistant(text: "", toolUses: [use]),
                             .toolResults([ToolResult(toolUseId: "h1", name: "http", content: "200 OK")])]
        let built = AppleFMPrompt.build(messages: ok, toolSpecs: [HttpTool().toolSpec], systemPrompt: nil)
        XCTAssertEqual(built.mode, .answer)
        XCTAssertTrue(built.prompt.contains("http -> 200 OK"), built.prompt)
    }

    func testAppleFMMixedResultsStayInCallMode() {
        let other = ToolUse(toolUseId: "c1", name: "calculator", input: ["expression": "1+1"])
        let mixed: [Message] = [.user("x"), .assistant(text: "", toolUses: [use, other]),
                                .toolResults([ToolResult.error(use, "timeout"), ToolResult(toolUseId: "c1", name: "calculator", content: "2")])]
        let built = AppleFMPrompt.build(messages: mixed, toolSpecs: [HttpTool().toolSpec, CalculatorTool().toolSpec], systemPrompt: nil)
        XCTAssertEqual(built.mode, .call)
        XCTAssertTrue(built.prompt.contains("http -> ERROR: timeout"), built.prompt)
    }
}
