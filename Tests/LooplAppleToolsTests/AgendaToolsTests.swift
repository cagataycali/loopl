import XCTest
import Loopl
@testable import LooplAppleTools

/// calendar_events / calendar_create / reminders_due / reminders_create against the fixture store:
/// parsing (the flat shapes small models emit), the approval cards, the listing format, defaults OFF.
final class AgendaToolsTests: XCTestCase {
    var src: FixtureEventSource!
    let cal = Calendar.current
    var today: Date { cal.startOfDay(for: Date()) }
    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: cal.date(byAdding: .day, value: day, to: today)!)! }

    override func setUp() {
        src = FixtureEventSource(events: [
            AgendaItem(title: "Standup", start: at(0, 9, 30), end: at(0, 9, 45), calendar: "Work"),
            AgendaItem(title: "Dentist", start: at(1, 15), end: at(1, 16), calendar: "Home", location: "Hoboken"),
            AgendaItem(title: "Trip", start: at(5, 0), end: at(6, 0), allDay: true, calendar: "Home"),
        ], reminders: [
            AgendaItem(title: "Buy edamame", start: at(0, 18), calendar: "Reminders"),
            AgendaItem(title: "Call mum", start: at(0, 12), calendar: "Reminders", completed: true),
            AgendaItem(title: "Renew passport", start: at(10, 9), calendar: "Reminders"),
        ])
        AgendaStore.use(src)
    }
    override func tearDown() { AgendaStore.use(nil) }

    func testEventsDefaultTwoDays() async throws {
        let out = try await CalendarEventsTool().call([:])
        XCTAssertTrue(out.hasPrefix("calendar: 2 events"), out)
        XCTAssertTrue(out.contains("09:30–09:45: Standup [Work]"), out)
        XCTAssertTrue(out.contains("15:00–16:00: Dentist @ Hoboken [Home]"), out)
        XCTAssertFalse(out.contains("Trip"))
    }

    func testEventsDaysAndFromAndAllDay() async throws {
        let out = try await CalendarEventsTool().call(["days": .number(7)])
        XCTAssertTrue(out.contains("all day: Trip"), out)
        XCTAssertTrue(out.hasPrefix("calendar: 3 events"))
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let later = try await CalendarEventsTool().call(["from": .string(f.string(from: at(30, 0))), "days": .string("2")])
        XCTAssertTrue(later.hasPrefix("calendar: no events"), later)
        XCTAssertEqual(try CalendarEventsTool.parse(["days": .number(999)]).days, CalendarEventsTool.maxDays)
        XCTAssertThrowsError(try CalendarEventsTool.parse(["from": .string("tomorrow")]))
    }

    func testCreateEventParsesAndAsks() throws {
        let t = CalendarCreateTool()
        let item = try CalendarCreateTool.parse(["title": .string("Lunch"), "start": .string("2026-10-07 12:30")])
        XCTAssertEqual(item.end, item.start?.addingTimeInterval(3600), "end defaults to +1 h")
        XCTAssertFalse(item.allDay)
        let allDay = try CalendarCreateTool.parse(["title": .string("Trip"), "start": .string("2026-10-12")])
        XCTAssertTrue(allDay.allDay)
        XCTAssertNotNil(try CalendarCreateTool.parse(["title": .string("x"), "start": .string("2026-10-07T12:30:00Z")]).start)
        XCTAssertThrowsError(try CalendarCreateTool.parse(["title": .string("x")]))
        XCTAssertThrowsError(try CalendarCreateTool.parse(["start": .string("2026-10-07 12:30")]))
        let sameEnd = try CalendarCreateTool.parse(["title": .string("x"), "start": .string("2026-10-07 12:30"), "end": .string("2026-10-07 12:30")])
        XCTAssertEqual(sameEnd.end, sameEnd.start?.addingTimeInterval(3600), "end ≤ start → one hour, not an error (measured 0.8B habit)")
        let req = t.requiresApproval(for: ["title": .string("Lunch"), "start": .string("2026-10-07 12:30"), "location": .string("Pier 13")])
        XCTAssertEqual(req?.method, "ADD"); XCTAssertEqual(req?.risk, .medium)
        XCTAssertEqual(req?.title, "Add event · Lunch")
        XCTAssertTrue(req?.detail?.hasPrefix("Adds to your calendar — ") == true, req?.detail ?? "")
        XCTAssertTrue(req?.detail?.hasSuffix(" at Pier 13") == true, req?.detail ?? "")
        XCTAssertFalse(req?.detail?.contains("2026-10-07") == true, "no ISO stamp on the card: \(req?.detail ?? "")")
        XCTAssertNil(t.requiresApproval(for: ["title": .string("Lunch")]), "invalid input fails in call, no card")
    }

    func testCreateEventWritesToTheStore() async throws {
        let out = try await CalendarCreateTool().call(["title": .string("Lunch"), "start": .string("2026-10-07 12:30"), "end": .string("2026-10-07 13:15")])
        XCTAssertTrue(out.hasPrefix("calendar: added\n- "), out)
        XCTAssertTrue(out.contains("12:30–13:15: Lunch"), out)
        XCTAssertEqual(src.created.map(\.title), ["Lunch"])
    }

    func testRemindersDueTodayHidesCompletedAndLater() async throws {
        let out = try await RemindersDueTool().call([:])
        XCTAssertTrue(out.hasPrefix("reminders: 1 due"), out)
        XCTAssertTrue(out.contains("Buy edamame"))
        XCTAssertFalse(out.contains("Call mum")); XCTAssertFalse(out.contains("Renew passport"))
        let all = try await RemindersDueTool().call(["days": .number(14), "include_completed": .bool(true)])
        XCTAssertTrue(all.contains("Call mum (done)"), all); XCTAssertTrue(all.contains("Renew passport"))
    }

    func testCreateReminderAliasesAndCard() async throws {
        let item = try RemindersCreateTool.parse(["text": .string("Water the plants"), "when": .string("2026-10-08")])
        XCTAssertEqual(item.title, "Water the plants"); XCTAssertTrue(item.allDay)
        XCTAssertNil(try RemindersCreateTool.parse(["title": .string("x")]).start, "due is optional")
        XCTAssertThrowsError(try RemindersCreateTool.parse(["due": .string("2026-10-08")]))
        let req = RemindersCreateTool().requiresApproval(for: ["title": .string("Water the plants")])
        XCTAssertEqual(req?.title, "Add reminder · Water the plants"); XCTAssertEqual(req?.detail, "Adds to Reminders — no due date"); XCTAssertEqual(req?.risk, .medium)
        let out = try await RemindersCreateTool().call(["title": .string("Water the plants"), "due": .string("2026-10-08 09:00")])
        XCTAssertTrue(out.hasPrefix("reminders: added"), out); XCTAssertTrue(out.contains("09:00: Water the plants"), out)
        XCTAssertEqual(src.created.last?.title, "Water the plants")
    }

    func testReadsNeedNoApprovalCreatesDo() {
        XCTAssertNil(CalendarEventsTool().requiresApproval(for: [:]))
        XCTAssertNil(RemindersDueTool().requiresApproval(for: [:]))
        XCTAssertNotNil(CalendarCreateTool().requiresApproval(for: ["title": .string("a"), "start": .string("2026-10-07 10:00")]))
        XCTAssertNotNil(RemindersCreateTool().requiresApproval(for: ["title": .string("a")]))
    }

    func testRegisteredAndOffByDefault() {
        for n in ["calendar_events", "calendar_create", "reminders_due", "reminders_create"] {
            XCTAssertTrue(AppleTools.names.contains(n), n)
            XCTAssertFalse(AppleTools.isDefaultOn(n), "\(n) must be off by default — fewer tools help small models")
            XCTAssertTrue(AppleTools.availability(of: n).available, "fixture store counts as available")
        }
        XCTAssertEqual(Set(AppleTools.defaultOnNames), Set(["generate_image", "generate_voice", "describe_image", "translate", "transcribe", "flashlight", "vibrate", "open_app", "clipboard_read", "clipboard_write", "music"]))
    }

    func testParseDateShapes() {
        XCTAssertNotNil(AgendaStore.parseDate("2026-10-07T15:00:00+02:00"))
        XCTAssertNotNil(AgendaStore.parseDate("2026-10-07T15:00"))
        XCTAssertEqual(AgendaStore.parseDate("2026-10-07")?.allDay, true)
        XCTAssertEqual(AgendaStore.parseDate("2026-10-07 15:00")?.allDay, false)
        XCTAssertNil(AgendaStore.parseDate("next tuesday"))
    }

    // MARK: spoken dates (AUDIT improve-3 #1: the card said "Adds to Reminders: 2026-10-07 09:00")
    func testSpokenDatesReadLikeAPerson() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 22, minute: 0))!
        func at(_ day: Int, _ month: Int = 10, _ h: Int = 9) -> Date { cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: 0))! }
        let cf = DateFormatter(); cf.calendar = cal; cf.timeZone = cal.timeZone; cf.timeStyle = .short; cf.dateStyle = .none
        let clock = cf.string(from: at(7))   // locale-dependent "9:00 AM" / "09:00"
        XCTAssertEqual(AgendaStore.spoken(at(6), now: now, calendar: cal), "today at \(clock)")
        XCTAssertEqual(AgendaStore.spoken(at(7), now: now, calendar: cal), "tomorrow at \(clock)")
        XCTAssertEqual(AgendaStore.spoken(at(7), allDay: true, now: now, calendar: cal), "tomorrow (all day)")
        XCTAssertEqual(AgendaStore.spoken(at(9), now: now, calendar: cal), "Fri 9 Oct at \(clock)")           // within a week: weekday
        XCTAssertEqual(AgendaStore.spoken(at(7, 11), now: now, calendar: cal), "Sat 7 Nov 2026 at \(clock)") // beyond: with the year
        XCTAssertFalse(AgendaStore.spoken(at(7), now: now, calendar: cal).contains("2026-10-07"))
    }
}
