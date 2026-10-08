import XCTest
import Loopl
@testable import LooplRuntimes

#if canImport(MLXLLM) && canImport(MLXLMCommon) && !targetEnvironment(simulator)
import Jinja

/// What the chat template is handed for tools. swift-jinja sorts the keys of a plain dictionary, which
/// renders `{"function": {"description": …, "name": …}}` — measured on Qwen3.5-0.8B-4bit (mlx_lm, 8 samples
/// × 3 asks): canonical order picked the right tool 24/24, sorted order 11/24 (drifting to remember/recall).
/// `PromptEncoder.orderedValue` keeps the order the models were trained on.
final class PromptEncoderTests: XCTestCase {
    func testToolSpecIsRenderedInCanonicalKeyOrder() throws {
        let spec = HttpTool().toolSpec
        let value = PromptEncoder.orderedValue(spec.openAIFunction)
        // Render through Jinja's own `tojson` — the filter every HF chat template uses (insertion order kept).
        let json = try Template("{{ tool | tojson }}").render(["tool": value])
        XCTAssertFalse(json.hasPrefix("{\"function\""), "sorted order = the bug: \(json.prefix(80))")
        // top level: type before function; function: name, description, parameters; parameters: type, properties, required
        let typeIdx = try XCTUnwrap(json.range(of: "\"type\": \"function\"")).lowerBound
        let fnIdx = try XCTUnwrap(json.range(of: "\"function\": {")).lowerBound
        XCTAssertLessThan(typeIdx, fnIdx, json)
        let nameIdx = try XCTUnwrap(json.range(of: "\"name\": \"http\"")).lowerBound
        let descIdx = try XCTUnwrap(json.range(of: "\"description\": \"Make an HTTPS")).lowerBound
        let paramsIdx = try XCTUnwrap(json.range(of: "\"parameters\": {")).lowerBound
        XCTAssertLessThan(fnIdx, nameIdx); XCTAssertLessThan(nameIdx, descIdx); XCTAssertLessThan(descIdx, paramsIdx)
        let propsIdx = try XCTUnwrap(json.range(of: "\"properties\": {")).lowerBound
        let reqIdx = try XCTUnwrap(json.range(of: "\"required\": [\"url\"]")).lowerBound
        XCTAssertLessThan(paramsIdx, propsIdx); XCTAssertLessThan(propsIdx, reqIdx)
        // inside a property: type before description before enum/examples; unlisted keys alphabetical after
        let urlIdx = try XCTUnwrap(json.range(of: "\"url\": {\"type\": \"string\", \"description\": \"full https URL, required\", \"examples\": [\"https://example.com\"]}")).lowerBound
        XCTAssertLessThan(propsIdx, urlIdx)
    }

    func testToolsContextCarriesKwargsAndOrderedTools() {
        let ctx = PromptEncoder.toolsContext([CurrentTimeTool().toolSpec], kwargs: ["enable_thinking": false])
        XCTAssertEqual(ctx["enable_thinking"] as? Bool, false)
        guard case .array(let tools)? = ctx["tools"] as? Jinja.Value, tools.count == 1, case .object(let tool) = tools[0] else { return XCTFail("tools missing") }
        XCTAssertEqual(Array(tool.keys), ["type", "function"])
    }

    func testNumbersStayIntegersWhenTheyAre() {
        guard case .object(let o) = PromptEncoder.orderedValue(.object(["a": .number(3), "b": .number(2.5)])) else { return XCTFail() }
        XCTAssertEqual(o["a"], .int(3)); XCTAssertEqual(o["b"], .double(2.5))
    }

}
#endif
