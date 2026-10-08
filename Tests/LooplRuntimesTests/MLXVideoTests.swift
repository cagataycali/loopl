import XCTest
import Loopl
@testable import LooplRuntimes

/// Live: a Qwen3-VL checkpoint answers "what happens in this video?" through loopl's MLXModel video path.
/// `LOOPL_VL_DIR=<checkpoint dir>`; `LOOPL_VIDEO=<clip>` (default: the synthetic shapes fixture);
/// `LOOPL_VIDEO_SOURCE=frames|url` picks loopl's sampler or mlx-swift-lm's; `LOOPL_VIDEO_FRAMES=N`.
/// Prints one MEASURE line per run — docs/sdk/video.md quotes them.
final class MLXVideoTests: XCTestCase {
    func env() throws -> (URL, ModelSpec) {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_VL_DIR"] else { throw XCTSkip("LOOPL_VL_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: dir)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else { throw XCTSkip("no config.json at \(dir)") }
        let name = url.lastPathComponent
        let thinking = name.lowercased().contains("thinking")
        let spec = ModelSpec(id: "hub:mlx-community/\(name.lowercased())", name: name, repo: "mlx-community/\(name)", runtime: .mlx, family: .hermes,
                             paramsB: name.contains("4B") ? 4 : 2, sizeBytes: 1_700_000_000, ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 4,
                             chatTemplateKwargs: thinking ? nil : ["enable_thinking": .bool(false)], vision: true)
        return (url, spec)
    }

    func clip() throws -> URL {
        if let p = ProcessInfo.processInfo.environment["LOOPL_VIDEO"] { return URL(fileURLWithPath: p) }
        return try XCTUnwrap(Bundle.module.url(forResource: "shapes-10s", withExtension: "mp4", subdirectory: "Fixtures"))
    }

    static func peakMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    func testWhatHappensInThisVideo() async throws {
        let (dir, spec) = try env()
        let url = try clip()
        let env = ProcessInfo.processInfo.environment
        let source = env["LOOPL_VIDEO_SOURCE"] == "url" ? VisionPrompt.VideoSource.url : .frames
        VisionPrompt.videoSource = source
        let maxFrames = Int(env["LOOPL_VIDEO_FRAMES"] ?? "") ?? 16
        let probe = try await VideoFrameSampler.probe(url)
        let plan = VideoFramePlan(maxFrames: maxFrames, fps: 1, maxEdge: 448)
        let block = VideoBlock(path: url.path, mime: "video/mp4", duration: probe.duration, width: probe.width, height: probe.height, framePlan: plan)
        let model = MLXModel()
        let t0 = Date()
        try await model.load(spec, from: dir) { _ in }
        let loadS = Date().timeIntervalSince(t0)
        let memAfterLoad = Self.peakMemoryMB()
        // Text-only baseline with the same words → the video's own token cost is prompt − baseline.
        let question = "What happens in this video? Describe the motion in two sentences."
        var baseline = 0
        if env["LOOPL_VIDEO_NOBASE"] == nil {
            var pre = StreamAssembler()
            for try await ev in model.stream([Message.user(question + " (no video attached — answer 'none')")], toolSpecs: [], systemPrompt: "You are a precise, terse assistant.") { _ = pre.feed(ev) }
            baseline = pre.finish().metrics.promptTokens - 8   // the parenthetical ≈ 8 tokens
        }
        var assembler = StreamAssembler()
        let msg = Message.user(question, images: [], videos: [block])
        let t1 = Date()
        var ttft: Double = 0
        for try await ev in model.stream([msg], toolSpecs: [], systemPrompt: "You are a precise, terse assistant.") {
            if case .metadata(let m) = ev, ttft == 0, m.ttftMs > 0 { ttft = m.ttftMs }
            _ = assembler.feed(ev)
        }
        let wall = Date().timeIntervalSince(t1)
        let stop = assembler.finish()
        let peak = Self.peakMemoryMB()
        let text = stop.message.text
        print("MEASURE video model=\(spec.name) clip=\(url.lastPathComponent) dur=\(String(format: "%.1f", probe.duration))s source=\(source) frames=\(block.frameCount) est=\(block.estimatedTokens) prompt=\(stop.metrics.promptTokens) video_tok≈\(stop.metrics.promptTokens - baseline) gen=\(stop.metrics.generatedTokens) tok/s=\(String(format: "%.1f", stop.metrics.tokensPerSecond)) ttft=\(Int(stop.metrics.ttftMs))ms wall=\(String(format: "%.1f", wall))s load=\(String(format: "%.1f", loadS))s mem_load=\(memAfterLoad)MB peak=\(peak)MB stop=\(stop.stopReason)")
        print("REASONING: \(stop.message.reasoning.prefix(400))")
        print("TEXT: \(text)")
        XCTAssertEqual(stop.stopReason, .endTurn)
        XCTAssertGreaterThan(stop.metrics.promptTokens, block.estimatedTokens / 2, "video tokens must be in the prompt")
        XCTAssertFalse(text.isEmpty)
        await model.unload()
    }
}
