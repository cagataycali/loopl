import XCTest
import Loopl
@testable import LooplRuntimes

/// The sampler on the synthetic fixture clip (shapes-10s.mp4: 640×360, 30 fps, 10 s, a 440 Hz sine audio track).
final class VideoFrameSamplerTests: XCTestCase {
    func fixture() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "shapes-10s", withExtension: "mp4", subdirectory: "Fixtures"))
    }

    func testProbeReadsDurationSizeAndAudio() async throws {
        let p = try await VideoFrameSampler.probe(try fixture())
        XCTAssertEqual(p.duration, 10, accuracy: 0.2)
        XCTAssertEqual(p.width, 640); XCTAssertEqual(p.height, 360)
        XCTAssertTrue(p.hasAudio)
    }

    func testSampleTimesSpreadOverTheClip() {
        let times = VideoFrameSampler.sampleTimes(duration: 10, plan: VideoFramePlan(maxFrames: 16, fps: 1, maxEdge: 448))
        XCTAssertEqual(times.count, 10)
        XCTAssertEqual(times.first?.seconds, 0)
        XCTAssertLessThan(times.last!.seconds, 10); XCTAssertGreaterThan(times.last!.seconds, 9)
        XCTAssertEqual(VideoFrameSampler.sampleTimes(duration: 0.2, plan: .default), [.zero])
    }

    func testFramesHonourCountAndEdge() async throws {
        let url = try fixture()
        let plan = VideoFramePlan(maxFrames: 8, fps: 2, maxEdge: 448)
        let t0 = Date()
        let frames = try await VideoFrameSampler.frames(of: url, plan: plan)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        XCTAssertEqual(frames.count, 8)
        for f in frames {
            XCTAssertLessThanOrEqual(max(f.image.extent.width, f.image.extent.height), 448)
            XCTAssertEqual(f.image.extent.width / f.image.extent.height, 640.0 / 360.0, accuracy: 0.02)
        }
        // Frames are in time order and distinct instants.
        let secs = frames.map(\.time.seconds)
        XCTAssertEqual(secs, secs.sorted()); XCTAssertEqual(Set(secs.map { Int($0 * 10) }).count, 8)
        print("VideoFrameSampler: 8 frames @≤448 from a 10 s 640×360 clip in \(ms) ms")
    }

    func testThumbnailIsASmallJPEG() async throws {
        let maybe = await VideoFrameSampler.thumbnail(of: try fixture())
        let thumb = try XCTUnwrap(maybe)
        XCTAssertEqual(thumb.mime, "image/jpeg")
        XCTAssertLessThanOrEqual(max(thumb.width ?? 0, thumb.height ?? 0), 256)
        XCTAssertLessThan(thumb.byteCount, 60_000)
    }
}
