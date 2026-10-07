import XCTest
@testable import Loopl
import LooplUI

/// IMPROVE-4: words small models copy and words people wait on.
final class PlainWordsTests: XCTestCase {
    /// Measured on Qwen3 0.6B: "what time is it right now?" → `current_time(timezone: "Europe/Istanbul")` — the example city in
    /// the description went straight into the call. No city example in the description; the device default is the loud part.
    func testCurrentTimeDescriptionCarriesNoExampleCity() {
        let d = CurrentTimeTool().description
        XCTAssertFalse(d.contains("Istanbul"), d)
        XCTAssertFalse(d.contains("Los_Angeles"), d)
        XCTAssertTrue(d.lowercased().contains("no arguments"), "the default call is spelled out: \(d)")
        XCTAssertTrue(d.lowercased().contains("another place"), "when to pass a zone is spelled out: \(d)")
    }

    /// With no timezone the tool answers in the device zone (the default the description promises).
    func testCurrentTimeDefaultsToDeviceZone() async throws {
        let out = try await CurrentTimeTool().call([:])
        XCTAssertTrue(out.contains(TimeZone.current.identifier) || out.contains(TimeZone.current.abbreviation() ?? "§"), out)
    }

    /// The pending row says what is happening once the wait is long (IMPROVE-4 #12).
    func testPendingRowCaptionGrowsWithTheWait() {
        XCTAssertEqual(PendingRow.caption(after: 0), "…")
        XCTAssertEqual(PendingRow.caption(after: 3.9), "…")
        XCTAssertEqual(PendingRow.caption(after: 4), "Reading your message and the tools…")
        XCTAssertEqual(PendingRow.caption(after: 20), "Still reading — a big prompt takes longer on this device.")
    }
}
