import XCTest
import Loopl
@testable import LooplRuntimes

/// Real llama.cpp on macOS (the vendored xcframework has a macOS slice).
/// Runs only when LOOPL_GGUF_DIR points at a directory holding the catalog's
/// Qwen3-0.6B-Q4_K_M.gguf — otherwise the suite is skipped, so CI without
/// Vendor/ stays green.
final class GGUFModelTests: XCTestCase {
    func env() throws -> (URL, ModelSpec) {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_GGUF_DIR"] else { throw XCTSkip("LOOPL_GGUF_DIR not set") }
        guard GGUFModel.availability().available else { throw XCTSkip(GGUFModel.availability().reason) }
        let spec = ModelSpec(id: "qwen3-0.6b-q4_k_m", name: "Qwen3 0.6B Q4_K_M", repo: "unsloth/Qwen3-0.6B-GGUF", runtime: .gguf, family: .hermes,
                             paramsB: 0.6, sizeBytes: 396705472, ctxNominal: 40960, ctxUsable8GB: 4096, minRAMGB: 3, file: "Qwen3-0.6B-Q4_K_M.gguf",
                             chatTemplateKwargs: ["enable_thinking": .bool(false)])
        let url = URL(fileURLWithPath: dir)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(spec.file!).path) else { throw XCTSkip("no gguf at \(dir)") }
        return (url, spec)
    }

    func testLoadsAndStreamsWithStopReason() async throws {
        let (dir, spec) = try env()
        let model = GGUFModel()
        try await model.load(spec, from: dir) { _ in }
        let loaded = await model.loadedModelId; XCTAssertEqual(loaded, spec.id)
        let p = await model.params; XCTAssertNil(p.maxTokens)
        var assembler = StreamAssembler()
        var chunks = 0
        for try await ev in model.stream([.user("Reply with exactly: pong")], toolSpecs: [], systemPrompt: "You are terse. /no_think") {
            chunks += 1
            _ = assembler.feed(ev)
        }
        let stop = assembler.finish()
        XCTAssertEqual(stop.stopReason, .endTurn)
        XCTAssertFalse(stop.message.text.isEmpty)
        XCTAssertGreaterThan(stop.metrics.generatedTokens, 0)
        XCTAssertGreaterThan(stop.metrics.tokensPerSecond, 0)
        print("GGUF macOS: \(stop.metrics.generatedTokens) tok · \(String(format: "%.1f", stop.metrics.tokensPerSecond)) tok/s · ttft \(Int(stop.metrics.ttftMs)) ms · text=\(stop.message.text.prefix(80))")
        await model.unload()
    }

    func testAgentLoopWithToolOnRealModel() async throws {
        let (dir, spec) = try env()
        let model = GGUFModel()
        try await model.load(spec, from: dir) { _ in }
        let agent = Agent(model: model, tools: [CalculatorTool()], systemPrompt: "Use the calculator tool for arithmetic. Answer briefly. /no_think", retryStrategy: nil)
        let r = try await agent("What is 23*47? Use the tool.")
        print("GGUF agent: cycles=\(r.metrics.cycleCount) tools=\(r.metrics.toolCallCount) text=\(r.text.prefix(120))")
        XCTAssertEqual(r.stopReason, .endTurn)
        XCTAssertGreaterThanOrEqual(r.metrics.toolCallCount, 1, "a 0.6B Qwen3 reliably calls the calculator with the hermes template")
        XCTAssertTrue(r.text.contains("1081"), "answer should carry the tool result: \(r.text)")
        await model.unload()
    }

    func testContextOverflowIsReported() async throws {
        let (dir, spec) = try env()
        var small = spec; small.ctxUsable8GB = 512
        let model = GGUFModel()
        try await model.load(small, from: dir) { _ in }
        let huge = String(repeating: "lorem ipsum dolor ", count: 400)
        do {
            for try await _ in model.stream([.user(huge)], toolSpecs: [], systemPrompt: nil) {}
            XCTFail("expected ContextWindowOverflowError")
        } catch is ContextWindowOverflowError {}
        await model.unload()
    }

    func testTemplateRenderingUsesModelTemplate() {
        let tmpl = "{% for message in messages %}{{'<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>' + '\\n'}}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% endif %}"
        let out = GGUFModel.renderPrompt(template: tmpl, systemPrompt: "sys", messages: [.user("hi")], toolSpecs: [], family: .hermes)
        XCTAssertEqual(out, "<|im_start|>system\nsys<|im_end|>\n<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n")
        let fallback = GGUFModel.renderPrompt(template: "not a template {{", systemPrompt: "sys", messages: [.user("hi")], toolSpecs: [], family: .hermes)
        XCTAssertTrue(fallback.hasPrefix("<|im_start|>system\nsys<|im_end|>"), "unknown template → ChatML fallback")
    }

    func testEnableThinkingFalseOpensAnEmptyThinkBlock() {
        let tmpl = "{% for message in messages %}{{'<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>' + '\\n'}}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% endif %}"
        let off = GGUFModel.renderPrompt(template: tmpl, systemPrompt: nil, messages: [.user("hi")], toolSpecs: [], family: .hermes, kwargs: ["enable_thinking": .bool(false)])
        XCTAssertTrue(off.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"), "Qwen3 non-thinking = empty think block, as its Jinja template renders it")
        let on = GGUFModel.renderPrompt(template: tmpl, systemPrompt: nil, messages: [.user("hi")], toolSpecs: [], family: .hermes, kwargs: ["enable_thinking": .bool(true)])
        XCTAssertTrue(on.hasSuffix("<|im_start|>assistant\n"))
        let none = GGUFModel.renderPrompt(template: tmpl, systemPrompt: nil, messages: [.user("hi")], toolSpecs: [], family: .hermes)
        XCTAssertEqual(none, on)
        XCTAssertEqual(GGUFModel.applyKwargs("x<think>\n\n</think>\n\n", kwargs: ["enable_thinking": .bool(false)]), "x<think>\n\n</think>\n\n", "never doubled")
    }

    func testUTF8AccumulatorSplitsScalars() {
        var acc = UTF8Accumulator()
        let euro = Array("€".utf8)   // E2 82 AC
        XCTAssertEqual(acc.append([euro[0]]), "")
        XCTAssertEqual(acc.append([euro[1]]), "")
        XCTAssertEqual(acc.append([euro[2], 0x41]), "€A")
        XCTAssertNil(acc.flush())
    }
}
