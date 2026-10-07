import XCTest
@testable import Loopl

/// `VideoBlock` / `VideoFramePlan`: the pure half of video input — what travels in a message, what a text
/// model reads, and how many tokens a plan costs before anything is decoded.
final class VideoBlockTests: XCTestCase {
    func clip(_ duration: TimeInterval = 10, transcript: String? = nil, plan: VideoFramePlan = .default) -> VideoBlock {
        VideoBlock(path: "/tmp/t.attachments/AB12.mov", mime: "video/quicktime", duration: duration, width: 1920, height: 1080,
                   framePlan: plan, transcript: transcript)
    }

    func testPlanFrameCountFollowsFpsThenCap() {
        let plan = VideoFramePlan(maxFrames: 16, fps: 1, maxEdge: 448)
        XCTAssertEqual(plan.frameCount(duration: 10), 10)
        XCTAssertEqual(plan.frameCount(duration: 60), 16, "capped by maxFrames")
        XCTAssertEqual(plan.frameCount(duration: 0.3), 1, "never zero")
        XCTAssertEqual(VideoFramePlan(maxFrames: 32, fps: 2, maxEdge: 448).frameCount(duration: 10), 20)
    }

    func testPlanTokenEstimateUsesTemporalPairsAndFittedEdge() {
        // 1920×1080 → 448×252 → 16 × 9 patches = 144 per frame pair; 10 frames = 5 pairs → 720 tokens.
        let plan = VideoFramePlan(maxFrames: 16, fps: 1, maxEdge: 448)
        XCTAssertTrue(VideoFramePlan.fitted(width: 1920, height: 1080, maxEdge: 448) == (448, 252))
        XCTAssertEqual(plan.estimatedTokens(duration: 10, width: 1920, height: 1080), 720)
        // Odd frame count rounds up to a whole pair (the processor pads the last temporal patch).
        XCTAssertEqual(plan.estimatedTokens(duration: 9, width: 1920, height: 1080), 720)
        XCTAssertEqual(plan.estimatedTokens(duration: 8, width: 1920, height: 1080), 576)
        // Small sources are never upscaled.
        XCTAssertTrue(VideoFramePlan.fitted(width: 320, height: 240, maxEdge: 448) == (320, 240))
    }

    func testFittingShrinksFramesBeforeEdge() {
        let fit = VideoFramePlan.fitting(tokenBudget: 400, duration: 60, width: 1920, height: 1080)
        XCTAssertEqual(fit?.maxFrames, 4, "16 → 8 → 4 frames (2 pairs × 144 = 288 ≤ 400)")
        XCTAssertEqual(fit?.maxEdge, 448)
        let tiny = VideoFramePlan.fitting(tokenBudget: 100, duration: 60, width: 1920, height: 1080)
        XCTAssertEqual(tiny?.maxFrames, 2); XCTAssertEqual(tiny?.maxEdge, 336, "1 pair at 336×189 = 12×7 = 84 tokens")
        XCTAssertNil(VideoFramePlan.fitting(tokenBudget: 10, duration: 60, width: 1920, height: 1080), "honest nil when nothing fits")
    }

    func testTextModelReadsHonestFallbackAndTranscript() {
        let m = Message.user("what happens here?", images: [], videos: [clip(65, transcript: "hello from the harbour")])
        XCTAssertTrue(m.hasVideo); XCTAssertTrue(m.hasVisualMedia); XCTAssertFalse(m.hasImage)
        let text = m.textWithVideoFallback
        XCTAssertTrue(text.hasPrefix("what happens here?\n[video attached: AB12.mov (1:05) — the frames need a vision model"), text)
        XCTAssertTrue(text.hasSuffix("[audio transcript: hello from the harbour]"), text)
        // The chat-template path (text models) sees the same fallback; `text` itself stays the typed words.
        XCTAssertEqual(m.text, "what happens here?")
        XCTAssertEqual(m.templateDictionaries.first?["content"] as? String, text)
        XCTAssertNil(clip().transcriptLine)
        XCTAssertEqual(clip(transcript: "x").transcriptLine, "[audio transcript: x]")
    }

    func testCodableRoundTripKeepsPlanAndThumbnail() throws {
        let thumb = ImageBlock(data: Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 12)), width: 256, height: 144)
        var v = clip(12.5, transcript: "t", plan: VideoFramePlan(maxFrames: 8, fps: 0.5, maxEdge: 336))
        v.thumbnail = thumb
        let m = Message.user("q", images: [], videos: [v])
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.videos.first?.framePlan.maxEdge, 336)
        XCTAssertEqual(back.videos.first?.thumbnail?.width, 256)
        XCTAssertEqual(back.videos.first?.frameCount, 6)
    }

    func testEstimatorCountsFramesNotFileBytes() {
        let m = Message.user("q", images: [], videos: [clip(10, transcript: "four words right here")])
        let n = TokenEstimator.estimate(m)
        // 4 (role) + 1 (q) + 720 frames + transcript (~22 bytes → 6) + 8
        XCTAssertGreaterThanOrEqual(n, 720); XCTAssertLessThan(n, 800, "\(n)")
    }

    func testHistoryEditorNamesTheBlock() {
        let m = Message.user("q", images: [], videos: [clip()])
        XCTAssertTrue(HistoryEditor.summarize(m.content).contains("[video]"))
    }
}
