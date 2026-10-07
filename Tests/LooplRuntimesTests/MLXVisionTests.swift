import XCTest
import Loopl
@testable import LooplRuntimes

/// Real MLX on macOS (Metal) with a VISION checkpoint. Runs only when LOOPL_VL_DIR points at a
/// downloaded mlx-community vision repo (e.g. `hf download mlx-community/Qwen3.5-0.8B-4bit --local-dir …`);
/// otherwise the suite is skipped so CI stays green. Proves: MLXVLM load → image + text prompt →
/// streamed description that names what is in Fixtures/vision-test.png (red circle, blue square, "LOOPL 42").
final class MLXVisionTests: XCTestCase {
    func env() throws -> (URL, ModelSpec) {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_VL_DIR"] else { throw XCTSkip("LOOPL_VL_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: dir)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else { throw XCTSkip("no config.json at \(dir)") }
        let name = url.lastPathComponent
        let spec = ModelSpec(id: "hub:mlx-community/\(name.lowercased())", name: name, repo: "mlx-community/\(name)", runtime: .mlx, family: .hermes,
                             paramsB: 0.8, sizeBytes: 650_000_000, ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2,
                             chatTemplateKwargs: name.contains("Thinking") ? nil : ["enable_thinking": .bool(false)], vision: true, thinking: name.contains("Thinking"))
        return (url, spec)
    }

    func fixture() throws -> ImageBlock {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vision-test", withExtension: "png", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(ImageBlock.detectMime(data), "image/png")
        return ImageBlock(data: data, mime: "image/png", width: 640, height: 400)
    }

    func testDescribesTheFixtureImage() async throws {
        let (dir, spec) = try env()
        let image = try fixture()
        let model = MLXModel()
        let t0 = Date()
        try await model.load(spec, from: dir) { _ in }
        let loadS = Date().timeIntervalSince(t0)
        var assembler = StreamAssembler()
        let msg = Message.user("What shapes and colours do you see, and what text is written? Answer in one sentence.", images: [image])
        for try await ev in model.stream([msg], toolSpecs: [], systemPrompt: "You are a precise, terse assistant.") { _ = assembler.feed(ev) }
        let stop = assembler.finish()
        let text = stop.message.text.lowercased()
        print("VL macOS: load \(String(format: "%.1f", loadS)) s · prompt \(stop.metrics.promptTokens) tok · \(stop.metrics.generatedTokens) tok · \(String(format: "%.1f", stop.metrics.tokensPerSecond)) tok/s · ttft \(Int(stop.metrics.ttftMs)) ms · reasoning \(stop.message.reasoning.count) chars\nTEXT: \(stop.message.text)\nREASONING: \(stop.message.reasoning.prefix(300))")
        if spec.isThinking { XCTAssertFalse(stop.message.reasoning.isEmpty, "a Thinking checkpoint must land its reasoning in the reasoning block"); XCTAssertFalse(stop.message.text.contains("</think>")) }
        XCTAssertEqual(stop.stopReason, .endTurn)
        XCTAssertGreaterThan(stop.metrics.promptTokens, 64, "image tokens must be in the prompt")
        XCTAssertTrue(text.contains("circle") || text.contains("round"), "should see the circle: \(text)")
        XCTAssertTrue(text.contains("square") || text.contains("rectangle"), "should see the square: \(text)")
        XCTAssertTrue(text.contains("loopl") || text.contains("42"), "should read the text: \(text)")
        await model.unload()
    }

    /// P8-B's P0 (2026-10-07 01:5xZ): a TEXT-ONLY turn of ≤ 512 tokens to a Qwen3-VL checkpoint died with
    /// `MLX Fatal error: SmallVector out of range` — mlx-swift-lm's Qwen3VL `prepare` feeds the ORIGINAL rank-1 ids to the
    /// short cold path (`getRopeIndex` reads dim(1)). Prompts > 512 tokens (every tool-bearing turn) took the windowed path,
    /// which is why the audits never saw it. loopl's fix: the text path hands a VLM a 2-D token array.
    func testShortTextOnlyTurnDoesNotCrash() async throws {
        let (dir, spec) = try env()
        let model = MLXModel()
        try await model.load(spec, from: dir) { _ in }
        var assembler = StreamAssembler()
        for try await ev in model.stream([.user("hi")], toolSpecs: [], systemPrompt: nil) { _ = assembler.feed(ev) }
        let stop = assembler.finish()
        print("VL short text: prompt \(stop.metrics.promptTokens) tok · \(stop.metrics.generatedTokens) tok · TEXT: \(stop.message.text.prefix(80))")
        XCTAssertLessThan(stop.metrics.promptTokens, 512, "this must exercise the short cold path")
        XCTAssertEqual(stop.stopReason, .endTurn)
        XCTAssertFalse(stop.message.text.isEmpty)
        await model.unload()
    }

    /// Image + a tool call in the same turn: the model reads the number off the picture and calls `calculator`.
    func testReadsNumberFromImageAndCallsTool() async throws {
        let (dir, spec) = try env()
        let image = try fixture()
        let model = MLXModel()
        try await model.load(spec, from: dir) { _ in }
        let tools: [ToolSpec] = [CalculatorTool().toolSpec]
        var assembler = StreamAssembler()
        let msg = Message.user("Read the number written in the image, then use the calculator tool to multiply it by 3.", images: [image])
        for try await ev in model.stream([msg], toolSpecs: tools, systemPrompt: "Use tools when asked. Be terse.") { _ = assembler.feed(ev) }
        let stop = assembler.finish()
        print("VL+tool macOS: stop \(stop.stopReason) · uses \(stop.message.toolUses.map { "\($0.name) \($0.input)" }) · text \(stop.message.text.prefix(120))")
        XCTAssertEqual(stop.stopReason, .toolUse)
        let use = try XCTUnwrap(stop.message.toolUses.first)
        XCTAssertEqual(use.name, "calculator")
        XCTAssertTrue(JSONValue.object(use.input).compact.contains("42"), "expression should contain 42: \(use.input)")
        await model.unload()
    }
}
