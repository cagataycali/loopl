import XCTest
import Loopl
@testable import LooplRuntimes

/// Call-order probe on one loaded VL container: `LOOPL_SEQ=text,image,video,videourl` (comma list, run in order).
/// Found while measuring: text-only then video on the same container died inside MLX (SmallVector out of range).
final class MLXVideoSequenceTests: XCTestCase {
    func testSequence() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["LOOPL_VL_DIR"], let seq = env["LOOPL_SEQ"] else { throw XCTSkip("LOOPL_VL_DIR / LOOPL_SEQ not set") }
        let url = URL(fileURLWithPath: dir)
        let name = url.lastPathComponent
        let spec = ModelSpec(id: "hub:x/\(name)", name: name, repo: "mlx-community/\(name)", runtime: .mlx, family: .hermes,
                             paramsB: 2, sizeBytes: 1_700_000_000, ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 4,
                             chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: true)
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "shapes-10s", withExtension: "mp4", subdirectory: "Fixtures"))
        let png = try XCTUnwrap(Bundle.module.url(forResource: "vision-test", withExtension: "png", subdirectory: "Fixtures"))
        let image = ImageBlock(data: try Data(contentsOf: png), mime: "image/png", width: 640, height: 400)
        let probe = try await VideoFrameSampler.probe(clip)
        let video = VideoBlock(path: clip.path, mime: "video/mp4", duration: probe.duration, width: probe.width, height: probe.height,
                               framePlan: VideoFramePlan(maxFrames: 4, fps: 1, maxEdge: 448))
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        for step in seq.split(separator: ",") {
            let msg: Message
            switch step {
            case "text": msg = .user("Say one word: hello.")
            case "image": msg = .user("What is in the picture? One sentence.", images: [image])
            case "video": VisionPrompt.videoSource = .frames; msg = .user("What happens in the video? One sentence.", images: [], videos: [video])
            case "videourl": VisionPrompt.videoSource = .url; msg = .user("What happens in the video? One sentence.", images: [], videos: [video])
            default: XCTFail("unknown step \(step)"); return
            }
            var a = StreamAssembler()
            for try await ev in model.stream([msg], toolSpecs: [], systemPrompt: "You are a precise, terse assistant.") { _ = a.feed(ev) }
            let stop = a.finish()
            print("SEQ step=\(step) prompt=\(stop.metrics.promptTokens) gen=\(stop.metrics.generatedTokens) text=\(stop.message.text.prefix(80))")
        }
        await model.unload()
    }
}
