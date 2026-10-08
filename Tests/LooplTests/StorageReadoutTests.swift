import XCTest
@testable import Loopl

/// Models › Storage wording (the audit): free space is always there to read.
final class StorageReadoutTests: XCTestCase {
    func testUsedAndFree() {
        let s = StorageReadout.spaceLine(used: 2_130_000_000, free: 54_000_000_000)
        XCTAssertTrue(s.contains("used"), s)
        XCTAssertTrue(s.contains("free"), s)
        XCTAssertTrue(s.contains(" · "), s)
    }

    func testNothingDownloadedStillSaysFree() {
        let s = StorageReadout.spaceLine(used: 0, free: 54_000_000_000)
        XCTAssertTrue(s.hasPrefix("Nothing downloaded"), s)
        XCTAssertTrue(s.contains("free"), s)
        XCTAssertFalse(s.contains("used"), s)
    }

    func testVolumeStates() {
        XCTAssertEqual(StorageReadout.volumeLine(connected: false, usable: false, used: 1, free: 1), "Not connected")
        XCTAssertTrue(StorageReadout.volumeLine(connected: true, usable: false, used: 1, free: 1).contains("Settings › Storage"))
        XCTAssertTrue(StorageReadout.volumeLine(connected: true, usable: true, used: 1_000_000, free: 2_000_000).contains("free"))
    }
}
