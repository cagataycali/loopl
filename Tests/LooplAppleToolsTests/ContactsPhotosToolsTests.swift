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

    /// The fixture's photos must be "today" at EVERY hour, not at most hours.
    ///
    /// `testPhotosRecentAttachesImages` asks for today's photos and requires one, and the fixture used to take
    /// them "an hour ago" — so between 00:00 and 00:59 all three were yesterday and that test failed. It is a
    /// clock, not a flake, which is the worst kind: it passes 23 hours a day, so it reads as noise and gets
    /// re-run until it goes away. (It failed twice in a row at 00:00:57Z and 00:08:38Z on 8 October, on two
    /// branches whose diffs could not touch it.)
    ///
    /// Asserting "the photos are today" here would reproduce the same bug in the guard — true at 14:00 either
    /// way. So pin the ANCHOR instead: every fixture photo sits a fixed distance from the START OF TODAY, which
    /// is a statement about the fixture rather than about when the suite happens to run.
    func testFixturePhotosAreAnchoredToTodayAtAnyHour() {
        let start = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(photos.items.count, 3)
        for item in photos.items {
            guard let taken = item.taken else { return XCTFail("a fixture photo must carry a date") }
            XCTAssertTrue(Calendar.current.isDate(taken, inSameDayAs: Date()), "fixture photo \(taken) is not today")
            // Pin it to NOON, within minutes. A looser band ("more than an hour into the day, less than 23")
            // is NOT a guard: I wrote that first and it passed against the broken fixture at 20:22, because
            // `Date() - 1h` is 19.4 h into the day and sits comfortably inside the band. Only the exact anchor
            // distinguishes "midday today" from "an hour before whenever the suite ran".
            let hoursIn = taken.timeIntervalSince(start) / 3600
            XCTAssertEqual(hoursIn, 12, accuracy: 0.1,
                           "a fixture photo must be anchored to midday today, not to the time the suite ran: \(hoursIn) h in")
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
