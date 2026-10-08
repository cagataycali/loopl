import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// History grouped by when a thread was last touched, and a search over titles + what was said.
@MainActor
final class HistoryGroupsTests: XCTestCase {
    private func thread(_ title: String, ago: TimeInterval, now: Date, items: [SavedConversation.Item]? = nil) -> SavedConversation {
        SavedConversation(id: UUID(), title: title, updated: now.addingTimeInterval(-ago), modelName: "m", items: items ?? [.user(title), .assistant("ok")])
    }

    func testGroupsByRecency() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        // 20 October, 15:00 local.
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!
        let h: TimeInterval = 3600, d = 24 * h
        let threads = [thread("a", ago: h, now: now),            // 14:00 today
                       thread("b", ago: 20 * h, now: now),       // 19:00 yesterday
                       thread("c", ago: 3 * d, now: now), thread("d", ago: 5 * d, now: now),   // within the last 6 days
                       thread("e", ago: 10 * d, now: now),       // 10 Oct → this month
                       thread("f", ago: 40 * d, now: now)]       // 10 Sep
        let g = HistoryGroups.group(threads, now: now, calendar: cal)
        XCTAssertEqual(g.map(\.label), ["Today", "Yesterday", "This week", "This month", "September 2026"], "\(g.map(\.label))")
        XCTAssertEqual(g[0].conversations.map(\.title), ["a"])
        XCTAssertEqual(g[1].conversations.map(\.title), ["b"])
        XCTAssertEqual(g[2].conversations.map(\.title), ["c", "d"])
        XCTAssertEqual(g[3].conversations.map(\.title), ["e"])
        XCTAssertEqual(g[4].conversations.map(\.title), ["f"])
    }

    func testGroupsKeepOrderAndSurviveEmptyInput() {
        XCTAssertTrue(HistoryGroups.group([]).isEmpty)
        let now = Date()
        let g = HistoryGroups.group([thread("x", ago: 10, now: now), thread("y", ago: 20, now: now)], now: now)
        XCTAssertEqual(g.count, 1); XCTAssertEqual(g[0].label, "Today"); XCTAssertEqual(g[0].conversations.map(\.title), ["x", "y"])
    }

    func testSearchMatchesTitleAndWhatWasSaid() {
        let now = Date()
        let c = thread("Weather in İstanbul", ago: 1, now: now, items: [.user("Bana hava durumunu söyle"), .assistant("Bugün yağmur var."), .tool(name: "weather", args: [:], result: "secret-payload", isError: false, ms: 1, images: nil)])
        XCTAssertTrue(HistoryGroups.matches(c, "istanbul"), "diacritic-insensitive title match")
        XCTAssertTrue(HistoryGroups.matches(c, "yağmur"), "the model's answer")
        XCTAssertTrue(HistoryGroups.matches(c, "HAVA"), "the person's message, case-insensitive")
        XCTAssertFalse(HistoryGroups.matches(c, "secret"), "tool payloads are not searched")
        XCTAssertTrue(HistoryGroups.matches(c, "   "), "blank query matches everything")
        XCTAssertFalse(HistoryGroups.matches(c, "dentist"))
    }
}
#endif
