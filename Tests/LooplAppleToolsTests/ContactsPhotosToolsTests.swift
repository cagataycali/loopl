import XCTest
import Loopl
@testable import LooplAppleTools

/// contacts_search / photos_recent against the fixture sources: parsing, rendering, images on the result, off by default.
final class ContactsPhotosToolsTests: XCTestCase {
    var contacts: FixtureContactsSource!; var photos: FixturePhotosSource!
    override func setUp() { contacts = FixtureContactsSource(); ContactsStore.use(contacts); photos = FixturePhotosSource(); PhotosStore.use(photos) }
    override func tearDown() { ContactsStore.use(nil); PhotosStore.use(nil) }

    func testContactsSearchFindsDiacriticInsensitive() async throws {
        let out = try await ContactsSearchTool().call(["name": .string("ali")])
        XCTAssertTrue(out.hasPrefix("contacts: 2 matches for \"ali\"\n"), out)
        XCTAssertTrue(out.contains("- Ali Yılmaz (Acme) · phone +90 532 000 11 22 · email ali@example.com"), out)
        XCTAssertTrue(out.contains("- Alice Park · phone +1 (201) 555-0142 · email alice.park@example.org"), out)
        let one = try await ContactsSearchTool().call(["query": .string("yıl"), "limit": .number(1)])
        XCTAssertTrue(one.hasPrefix("contacts: 1 match for"), one)
        let zed = try await ContactsSearchTool().call(["name": .string("Zed")])
        XCTAssertEqual(zed, "contacts: no one named \"Zed\"")
        XCTAssertEqual(contacts.queries, ["ali", "yıl", "Zed"])
    }

    func testContactsParse() throws {
        XCTAssertEqual(try ContactsSearchTool.parse(["name": .string(" Mum ")]), .init(name: "Mum", limit: 5))
        XCTAssertEqual(try ContactsSearchTool.parse(["q": .string("a"), "limit": .number(99)]).limit, ContactsSearchTool.maxLimit)
        XCTAssertThrowsError(try ContactsSearchTool.parse([:]))
        XCTAssertThrowsError(try ContactsSearchTool.parse(["name": .string("  ")]))
    }

    func testPhotosRecentAttachesImages() async throws {
        let out = try await PhotosRecentTool().callOutput([:])
        XCTAssertEqual(out.images.count, 1)
        XCTAssertTrue(out.text.hasPrefix("photos: 1, attached to this result (newest first)"), out.text)
        XCTAssertTrue(out.text.contains("- photo 1: "), out.text)
        let three = try await PhotosRecentTool().callOutput(["count": .number(9)])
        XCTAssertEqual(three.images.count, 3, "capped at the fixture's 3 (max 4)")
        XCTAssertEqual(photos.requests.map(\.0), [1, PhotosRecentTool.maxCount])
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = try await PhotosRecentTool().callOutput(["date": .string(f.string(from: Date())), "count": .number(4)])
        XCTAssertFalse(today.images.isEmpty); XCTAssertTrue(today.text.contains(" from "), today.text)
        let none = try await PhotosRecentTool().callOutput(["date": .string("2001-01-01")])
        XCTAssertTrue(none.images.isEmpty); XCTAssertTrue(none.text.hasPrefix("photos: none from"), none.text)
        XCTAssertThrowsError(try PhotosRecentTool.parse(["date": .string("yesterday")]))
    }

    /// The CI red that held #206: `testPhotosRecentAttachesImages` asks the tool for photos dated
    /// TODAY, while the fixture made its three photos at `now - 1h/2h/3h`. Run before 01:00 and all
    /// three land on YESTERDAY, so the day truthfully has no photos and the assertion fails — a
    /// one-hour window in every twenty-four, on a UTC runner. It failed at 00:00:57Z.
    /// Pins the PROMISE, not an hour: a fixture's photos lie inside its own anchor's local day, and
    /// none of them is in the future.
    func testFixturePhotosAlwaysLieInsideTheirOwnDayIncludingAtMidnight() async throws {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        for anchor in [midnight, midnight.addingTimeInterval(57), midnight.addingTimeInterval(12 * 3600)] {
            let src = FixturePhotosSource(now: anchor)
            XCTAssertEqual(src.items.count, 3, "anchor \(anchor)")
            for p in src.items {
                let taken = try XCTUnwrap(p.taken)
                XCTAssertTrue(cal.isDate(taken, inSameDayAs: anchor), "photo taken \(taken) is outside the day of \(anchor)")
                XCTAssertLessThanOrEqual(taken, anchor, "a fixture photo must not have been taken in the future")
            }
            let takens = src.items.compactMap(\.taken)
            XCTAssertEqual(takens, takens.sorted(by: >), "newest first")
            let onItsOwnDay = try await src.recent(count: 4, on: anchor)
            XCTAssertFalse(onItsOwnDay.isEmpty, "asking the fixture for its own day must return photos (anchor \(anchor))")
        }
    }

    func testPhotosCallThroughAnyToolKeepsImages() async throws {
        // The dispatch bug TOOLS-E2E found: through `any Tool`, images must still arrive.
        let t: any Tool = PhotosRecentTool()
        let out = try await t.call([:], images: [])
        XCTAssertEqual(out.images.count, 1)
    }

    func testReadOnlyOffByDefaultRegistered() {
        XCTAssertNil(ContactsSearchTool().requiresApproval(for: ["name": .string("a")]))
        XCTAssertNil(PhotosRecentTool().requiresApproval(for: [:]))
        for n in ["contacts_search", "photos_recent"] {
            XCTAssertTrue(AppleTools.names.contains(n)); XCTAssertFalse(AppleTools.isDefaultOn(n), n)
            XCTAssertTrue(AppleTools.availability(of: n).available)
        }
        XCTAssertEqual(AppleTools.names.count, 18)
        XCTAssertEqual(AppleTools.defaultOnNames.count, 12, "the everyday set: 8 + the two clipboard tools + music + location (on since 2026-10-07)")
    }
}
