import XCTest
import LooplUI

/// The one line a composer recording adds to a user message, and the way `UserTurn` reads it back.
final class AudioMarkerTests: XCTestCase {
    func testLineRoundTrips() {
        let m = AudioAttachmentMarker(path: "/Users/x/Library/Application Support/conversations/ABC.attachments/8F2A1B.m4a", duration: 5.24)
        XCTAssertEqual(m.line, "[audio attached: /Users/x/Library/Application Support/conversations/ABC.attachments/8F2A1B.m4a (5.2 s) — call transcribe with this path to hear it]")
        XCTAssertFalse(m.line.contains("\n"))
        let parts = AudioAttachmentMarker.split("What did I say?\n" + m.line)
        XCTAssertEqual(parts.text, "What did I say?")
        XCTAssertEqual(parts.clips.count, 1)
        XCTAssertEqual(parts.clips.first?.path, m.path)
        XCTAssertEqual(parts.clips.first?.duration ?? 0, 5.2, accuracy: 0.001)
    }

    func testMarkerOnlyMessageAndSeveralClips() {
        let a = AudioAttachmentMarker(path: "/tmp/a.m4a", duration: 1), b = AudioAttachmentMarker(path: "/tmp/b.m4a", duration: 61.9)
        let parts = AudioAttachmentMarker.split([a.line, b.line].joined(separator: "\n"))
        XCTAssertEqual(parts.text, "")
        XCTAssertEqual(parts.clips.map(\.path), ["/tmp/a.m4a", "/tmp/b.m4a"])
    }

    func testPlainTextIsUntouchedAndLooseBracketsAreNotMarkers() {
        let t = "[audio attached] is just words\nand so is (5.0 s)"
        let parts = AudioAttachmentMarker.split(t)
        XCTAssertEqual(parts.text, t)
        XCTAssertTrue(parts.clips.isEmpty)
    }

    func testOlderShortFormWithoutHintStillParses() {
        let parts = AudioAttachmentMarker.split("[audio attached: /tmp/x.m4a (3.0 s)]")
        XCTAssertEqual(parts.clips.first?.path, "/tmp/x.m4a")
        XCTAssertEqual(parts.clips.first?.duration ?? 0, 3, accuracy: 0.001)
    }

    func testClock() {
        XCTAssertEqual(AudioAttachmentMarker.clock(0), "0:00")
        XCTAssertEqual(AudioAttachmentMarker.clock(5.9), "0:05")
        XCTAssertEqual(AudioAttachmentMarker.clock(61), "1:01")
        XCTAssertEqual(AudioAttachmentMarker.clock(120), "2:00")
    }
}
