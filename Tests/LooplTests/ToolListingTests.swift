import XCTest
@testable import Loopl

final class ToolListingTests: XCTestCase {
    func testGroupsByWhatTheModelGets() {
        let l = ToolListing([
            .init(name: "calculator", copy: "", defaultOn: true, enabled: true),
            .init(name: "http", copy: "", defaultOn: true, enabled: false),
            .init(name: "generate_image", copy: "", defaultOn: true, available: false, reason: "Needs Apple Intelligence", enabled: true),
            .init(name: "location", copy: "", defaultOn: false, enabled: false),
            .init(name: "music", copy: "", defaultOn: true, enabled: true),
        ])
        XCTAssertEqual(l.on.map(\.name), ["calculator", "music"], "settings order kept")
        XCTAssertEqual(l.off.map(\.name), ["http", "generate_image", "location"], "switched off OR unavailable, in order")
        XCTAssertEqual(l.summary, "2 of 4", "the unavailable one is not offerable")
        XCTAssertEqual(ToolListing([.init(name: "http", copy: "", defaultOn: true, enabled: false)]).summary, "off")
    }

    func testTagsAndApprovalNotes() {
        let w = ToolListing.Row(name: "clipboard_write", copy: "", defaultOn: true, enabled: true)
        XCTAssertEqual(w.asksFirst, "Asks before replacing what is on your clipboard.")
        XCTAssertEqual(w.defaultTag, "on by default")
        let r = ToolListing.Row(name: "clipboard_read", copy: "", defaultOn: true, enabled: true)
        XCTAssertNil(r.asksFirst, "reads carry no note")
        XCTAssertEqual(ToolListing.Row(name: "location", copy: "", defaultOn: false, enabled: false).defaultTag, "off by default")
        XCTAssertNil(ToolListing.Row(name: "music", copy: "", defaultOn: true, enabled: true).asksFirst, "music never stops at a card")
        for n in ["current_time", "calculator", "device_info", "remember", "recall", "http"] { XCTAssertNotNil(ToolListing.coreCopy[n], n) }
    }

    func testSummaryMatchesToolCountSummary() {
        let rows: [ToolListing.Row] = [
            .init(name: "a", copy: "", defaultOn: true, enabled: true), .init(name: "b", copy: "", defaultOn: true, enabled: true),
            .init(name: "c", copy: "", defaultOn: true, available: false, enabled: true), .init(name: "d", copy: "", defaultOn: false, enabled: false),
        ]
        XCTAssertEqual(ToolListing(rows).summary, ToolCountSummary.label(core: 2, coreEnabled: 2, apple: [(true, false), (false, true)]))
    }
}
