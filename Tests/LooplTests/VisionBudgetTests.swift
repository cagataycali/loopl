import XCTest
@testable import Loopl

final class VisionBudgetTests: XCTestCase {
    func spec(_ b: Double, bytes: Int64) -> ModelSpec {
        ModelSpec(id: "vl", name: "vl", repo: "mlx-community/Qwen3-VL-x", runtime: .mlx, family: .hermes, paramsB: b, sizeBytes: bytes,
                  ctxNominal: 262144, ctxUsable8GB: 8192, minRAMGB: 5, vision: true)
    }

    func testImageAtTheCapIsAboutAThousandTokens() {
        XCTAssertEqual(VisionBudget.imageTokens(), 1280 * 28 * 28 / 1024 + 2)   // 981
        XCTAssertEqual(VisionBudget.imageTokens(pixels: 320 * 320), 100 + 2)
        XCTAssertGreaterThan(VisionBudget.imageTokens(pixels: 1), 4)
    }

    func testVideoFramesPairUp() {
        let one = VisionBudget.videoTokens(frames: 2)
        XCTAssertEqual(one, 448 * 336 / 1024 + 2)          // 149
        XCTAssertEqual(VisionBudget.videoTokens(frames: 16), 8 * (448 * 336 / 1024) + 2)
        XCTAssertEqual(VisionBudget.videoTokens(frames: 3), VisionBudget.videoTokens(frames: 4), "an odd frame still costs a pair")
        XCTAssertEqual(VisionBudget.videoTokens(frames: 0), 0)
    }

    func testKVPerTokenFollowsTheQwen3VLGeometry() {
        XCTAssertEqual(VisionBudget.kvBytesPerToken(spec(2, bytes: 1)), 2 * 28 * 8 * 128 * 2)   // 112 KiB
        XCTAssertEqual(VisionBudget.kvBytesPerToken(spec(4, bytes: 1)), 2 * 36 * 8 * 128 * 2)   // 144 KiB
    }

    func testFourBOnAnEightGBPhoneGetsAFewFramesTwoBGetsMore() {
        let fourB = spec(4, bytes: 3_109_729_983), twoB = spec(2, bytes: 1_798_021_421)
        let budget: Int64 = 5_100 << 20                       // what iOS gives loopl on a 16 Pro (Models › Storage line)
        let f4 = VisionBudget.maxFrames(fourB, contextWindow: 8192, memoryBudget: budget)
        let f2 = VisionBudget.maxFrames(twoB, contextWindow: 12288, memoryBudget: budget)
        XCTAssertGreaterThanOrEqual(f4, 8, "\(f4)"); XCTAssertLessThanOrEqual(f4, 32)
        XCTAssertGreaterThanOrEqual(f2, f4, "2B has a bigger window and smaller KV → never fewer frames (\(f2) vs \(f4))")
        // Tight memory separates them: 4B's weights eat the budget first.
        let tight: Int64 = 4_400 << 20
        XCTAssertLessThan(VisionBudget.maxFrames(fourB, contextWindow: 8192, memoryBudget: tight), VisionBudget.maxFrames(twoB, contextWindow: 8192, memoryBudget: tight))
        XCTAssertEqual(VisionBudget.maxFrames(fourB, contextWindow: 8192, memoryBudget: 3_000 << 20), 0, "weights alone do not fit → 0, say so")
        XCTAssertEqual(VisionBudget.maxFrames(fourB, contextWindow: 2048, memoryBudget: budget), 0, "no room next to the reserve")
    }

    func testTextModelHasNoFrameBudget() {
        var s = spec(2, bytes: 1); s.vision = false
        XCTAssertEqual(VisionBudget.maxFrames(s, contextWindow: 8192, memoryBudget: .max), 0)
    }
}
