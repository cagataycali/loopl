import Foundation
import Loopl
#if canImport(EventKit)
import EventKit
#endif

// Calendar + Reminders as loopl tools (2026-10-06). Four small tools, not two with an
// `action` — the clipboard measurement showed a 0.8B hears the verb in the request and picks the wrong
// enum value when read and write share one tool. Reads are plain; creates are HITL (approval card with
// the title, time and calendar) because they change the user's calendar. All four are OFF by default
// (`AppleTool.defaultOn == false`): fewer tools help small models, and most conversations never need them.
//
// Permission is asked just in time by EventKit (`requestFullAccessToEvents` / `requestFullAccessToReminders`,
// iOS 17+) with the strings in App/project.yml. `EventSource` is the seam: the real `EKEventStore` on a
// device, `FixtureEventSource` for the harness, the Simulator fixtures and the unit tests.

/// One calendar event or reminder as the tools report it.
public struct AgendaItem: Sendable, Hashable, Codable {
    public var title: String
    public var start: Date?
    public var end: Date?
    public var allDay: Bool
    public var calendar: String
    public var location: String?
    public var notes: String?
    /// Reminders only.
    public var completed: Bool
    public init(title: String, start: Date? = nil, end: Date? = nil, allDay: Bool = false, calendar: String = "", location: String? = nil, notes: String? = nil, completed: Bool = false) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.calendar = calendar; self.location = location; self.notes = notes; self.completed = completed
    }
}

/// What the tools need from a calendar store — implemented by EventKit and by fixtures.
public protocol EventSource: Sendable {
    func events(from: Date, to: Date) async throws -> [AgendaItem]
    func createEvent(_ item: AgendaItem) async throws -> AgendaItem
    func reminders(dueBefore: Date, includeCompleted: Bool) async throws -> [AgendaItem]
    func createReminder(_ item: AgendaItem) async throws -> AgendaItem
    var calendarNames: [String] { get async }
}

/// A canned store for tests, the harness and `--design-fixture`. Creates land in `created`.
public final class FixtureEventSource: EventSource, @unchecked Sendable {
    let lock = NSLock()
    public var items: [AgendaItem]
    public var todos: [AgendaItem]
    public private(set) var created: [AgendaItem] = []
    public init(events: [AgendaItem] = [], reminders: [AgendaItem] = []) { items = events; todos = reminders }
    public func events(from: Date, to: Date) async throws -> [AgendaItem] {
        lock.withLock { items.filter { ($0.start ?? .distantPast) < to && ($0.end ?? $0.start ?? .distantFuture) >= from }.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) } }
    }
    public func createEvent(_ item: AgendaItem) async throws -> AgendaItem { lock.withLock { items.append(item); created.append(item) }; return item }
    public func reminders(dueBefore: Date, includeCompleted: Bool) async throws -> [AgendaItem] {
        lock.withLock { todos.filter { (includeCompleted || !$0.completed) && ($0.start.map { $0 < dueBefore } ?? true) }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) } }
    }
    public func createReminder(_ item: AgendaItem) async throws -> AgendaItem { lock.withLock { todos.append(item); created.append(item) }; return item }
    public var calendarNames: [String] { ["Home", "Work"] }
}

/// Where the tools get their store. The app leaves it on EventKit; tests and fixtures swap in a `FixtureEventSource`.
public enum AgendaStore {
    nonisolated(unsafe) private static var override: (any EventSource)?
    private static let lock = NSLock()
    public static func use(_ source: (any EventSource)?) { lock.lock(); override = source; lock.unlock() }
    public static var isFixture: Bool { lock.lock(); defer { lock.unlock() }; return override != nil }
    static var current: any EventSource {
        lock.lock(); defer { lock.unlock() }
        if let o = override { return o }
        #if canImport(EventKit)
        return EventKitSource.shared
        #else
        return FixtureEventSource()
        #endif
    }

    /// Availability for all four tools: EventKit present (fixtures always count).
    static func availability() -> ToolAvailability {
        if isFixture { return .ok }
        #if canImport(EventKit) && (os(iOS) || os(macOS))
        return .ok
        #else
        return .no("Needs Calendar and Reminders (iOS or macOS)")
        #endif
    }

    // MARK: formatting shared by the four tools

    static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f }()
    static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static let stampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
    /// The date as a person says it on an approval card: "today at 9:00", "tomorrow at 9:00", "Thu 9 Oct at 15:00"
    /// (within 7 days), "Fri 7 Nov 2026 at 15:00" beyond; all-day drops the clock. Never an ISO stamp.
    static func spoken(_ d: Date, allDay: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: d)).day ?? 99
        func fmt(_ pattern: String?, time: Bool = false) -> String {
            let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
            if let pattern { f.dateFormat = pattern } else { f.timeStyle = .short; f.dateStyle = .none }
            return f.string(from: d)
        }
        let day: String
        switch days {
        case 0: day = "today"
        case 1: day = "tomorrow"
        case -1: day = "yesterday"
        case 2..<7: day = fmt("EEE d MMM")
        default: day = fmt("EEE d MMM yyyy")
        }
        return allDay ? day + " (all day)" : day + " at " + fmt(nil)
    }
    /// "Today is 2026-10-06 (Monday)." — appended to the tool descriptions, because the app prompt carries no date and a
    /// small model cannot turn "tomorrow at 12:30" into yyyy-MM-dd without it. Specs are rebuilt every turn.
    static var todayHint: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd (EEEE)"
        return " Today is \(f.string(from: Date()))."
    }

    static func line(_ e: AgendaItem, now: Date = Date()) -> String {
        var s = "- "
        if let st = e.start {
            s += dayFormatter.string(from: st)
            if !e.allDay { s += " " + timeFormatter.string(from: st); if let en = e.end, en > st { s += "–" + timeFormatter.string(from: en) } }
            else { s += " all day" }
            s += ": "
        }
        s += e.title
        if let l = e.location, !l.isEmpty { s += " @ " + l }
        if e.completed { s += " (done)" }
        if !e.calendar.isEmpty { s += " [\(e.calendar)]" }
        return s
    }

    /// Parses the model's time: ISO-8601 (with or without seconds / offset), `yyyy-MM-dd HH:mm`, `yyyy-MM-dd` (→ all day).
    static func parseDate(_ raw: String) -> (Date, allDay: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return (d, false) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return (d, false) }
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
            if let d = f.date(from: s) { return (d, false) }
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: s) { return (d, true) }
        return nil
    }
}

#if canImport(EventKit)
/// The real store. Access is requested on first use (the system sheet); a denial is a tool error the model can relay.
final class EventKitSource: EventSource, @unchecked Sendable {
    static let shared = EventKitSource()
    let store = EKEventStore()

    func ensureAccess(_ entity: EKEntityType) async throws {
        let status = EKEventStore.authorizationStatus(for: entity)
        switch status {
        case .fullAccess, .authorized: return
        case .writeOnly where entity == .event: return
        case .notDetermined:
            let ok = entity == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
            if !ok { throw ToolError("the user did not allow access to \(entity == .event ? "Calendar" : "Reminders")") }
        default:
            throw ToolError("access to \(entity == .event ? "Calendar" : "Reminders") is off — the user can allow it in Settings › Privacy › \(entity == .event ? "Calendars" : "Reminders") › loopl")
        }
    }

    func events(from: Date, to: Date) async throws -> [AgendaItem] {
        try await ensureAccess(.event)
        let p = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: p).map { Self.item($0) }
    }
    func createEvent(_ item: AgendaItem) async throws -> AgendaItem {
        try await ensureAccess(.event)
        let e = EKEvent(eventStore: store)
        e.title = item.title; e.startDate = item.start; e.endDate = item.end ?? item.start?.addingTimeInterval(3600)
        e.isAllDay = item.allDay; e.location = item.location; e.notes = item.notes
        e.calendar = store.calendars(for: .event).first { $0.title.caseInsensitiveCompare(item.calendar) == .orderedSame } ?? store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true)
        return Self.item(e)
    }
    func reminders(dueBefore: Date, includeCompleted: Bool) async throws -> [AgendaItem] {
        try await ensureAccess(.reminder)
        let p = includeCompleted ? store.predicateForReminders(in: nil) : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: nil)
        // Map to Sendable items inside the callback: EKReminder is not Sendable.
        let items: [AgendaItem] = await withCheckedContinuation { c in _ = store.fetchReminders(matching: p) { c.resume(returning: ($0 ?? []).map { Self.item($0) }) } }
        return items.filter { $0.start.map { $0 < dueBefore } ?? true }
    }
    func createReminder(_ item: AgendaItem) async throws -> AgendaItem {
        try await ensureAccess(.reminder)
        let r = EKReminder(eventStore: store)
        r.title = item.title; r.notes = item.notes
        if let d = item.start { r.dueDateComponents = Calendar.current.dateComponents(item.allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: d) }
        r.calendar = store.calendars(for: .reminder).first { $0.title.caseInsensitiveCompare(item.calendar) == .orderedSame } ?? store.defaultCalendarForNewReminders()
        try store.save(r, commit: true)
        return Self.item(r)
    }
    var calendarNames: [String] { store.calendars(for: .event).map(\.title) }

    static func item(_ e: EKEvent) -> AgendaItem {
        AgendaItem(title: e.title ?? "(untitled)", start: e.startDate, end: e.endDate, allDay: e.isAllDay, calendar: e.calendar?.title ?? "", location: e.location, notes: e.notes)
    }
    static func item(_ r: EKReminder) -> AgendaItem {
        let due = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        return AgendaItem(title: r.title ?? "(untitled)", start: due, allDay: r.dueDateComponents?.hour == nil, calendar: r.calendar?.title ?? "", notes: r.notes, completed: r.isCompleted)
    }
}
#endif

// MARK: - calendar_events

public struct CalendarEventsTool: AppleTool {
    public init() {}
    public let name = "calendar_events"
    public var description: String { "List the user's calendar events for the coming days (default: today and tomorrow). Use when the user asks what is on their calendar, their schedule, agenda, or whether they are free." + AgendaStore.todayHint }
    public let parameters: JSONValue = ToolSchema.object([
        "days": ToolSchema.number("How many days from today to include (default 2, max 31)"),
        "from": ToolSchema.string("First day yyyy-MM-dd. Leave it out for today."),
    ])
    public static let onDeviceCopy = "Reads your calendar when the model asks. Asks for Calendar access the first time."
    public static var defaultOn: Bool { false }
    public static func availability() -> ToolAvailability { AgendaStore.availability() }
    public static let maxDays = 31

    public struct Request: Sendable, Hashable { public var from: Date; public var to: Date; public var days: Int }
    public static func parse(_ args: [String: JSONValue], now: Date = Date()) throws -> Request {
        let days = max(1, min(maxDays, args.int("days") ?? 2))
        var start = Calendar.current.startOfDay(for: now)
        if let f = args.string("from"), !f.isEmpty {
            guard let (d, _) = AgendaStore.parseDate(f) else { throw ToolError("from must be a date like 2026-10-07") }
            start = Calendar.current.startOfDay(for: d)
        }
        return Request(from: start, to: Calendar.current.date(byAdding: .day, value: days, to: start)!, days: days)
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let r = try Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("calendar_events is not available here: \(a.reason)") }
        let items = try await AgendaStore.current.events(from: r.from, to: r.to)
        let span = "\(AgendaStore.dayFormatter.string(from: r.from)) – \(AgendaStore.dayFormatter.string(from: r.to.addingTimeInterval(-1)))"
        if items.isEmpty { return "calendar: no events \(span)" }
        return "calendar: \(items.count) event\(items.count == 1 ? "" : "s") \(span)\n" + items.map { AgendaStore.line($0) }.joined(separator: "\n")
    }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput { ToolOutput(text: try await call(args)) }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}

// MARK: - calendar_create (HITL)

public struct CalendarCreateTool: AppleTool {
    public init() {}
    public let name = "calendar_create"
    public var description: String { "Add an event to the user's calendar. Needs a title and a start time (yyyy-MM-dd HH:mm, or yyyy-MM-dd for all day); end defaults to one hour later. Use only when the user asks to add, schedule or book something." + AgendaStore.todayHint }
    public let parameters: JSONValue = ToolSchema.object([
        "title": ToolSchema.string("What the event is called"),
        "start": ToolSchema.string("Start, e.g. 2026-10-07 15:00 — or 2026-10-07 for an all-day event"),
        "end": ToolSchema.string("End, same format (default: start + 1 hour)"),
        "location": ToolSchema.string("Where (optional)"),
        "notes": ToolSchema.string("Notes (optional)"),
    ], required: ["title", "start"])
    public static let onDeviceCopy = "Adds events to your calendar after you approve each one."
    public static var defaultOn: Bool { false }
    public static func availability() -> ToolAvailability { AgendaStore.availability() }

    public static func parse(_ args: [String: JSONValue]) throws -> AgendaItem {
        guard let title = args.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { throw ToolError("need a title") }
        guard let raw = args.string("start") ?? args.string("date") ?? args.string("when"), let (start, allDay) = AgendaStore.parseDate(raw) else {
            throw ToolError("start must be a date and time like 2026-10-07 15:00 (or 2026-10-07 for all day)")
        }
        var end: Date? = nil
        if let e = args.string("end"), !e.isEmpty {
            guard let (d, _) = AgendaStore.parseDate(e) else { throw ToolError("end must look like 2026-10-07 16:00") }
            // Measured: Qwen3.5-0.8B fills `end` with the start time 2 of 3 times — an hour is the honest default, not an error.
            if d > start { end = d }
        }
        if end == nil { end = allDay ? start : start.addingTimeInterval(3600) }
        return AgendaItem(title: title, start: start, end: end, allDay: allDay, calendar: args.string("calendar") ?? "", location: args.string("location"), notes: args.string("notes"))
    }

    public func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
        guard let item = try? Self.parse(input) else { return nil }
        let when = AgendaStore.spoken(item.start!, allDay: item.allDay)
        var detail = "Adds to your calendar — \(when)"
        if let l = item.location, !l.isEmpty { detail += " at \(l)" }
        return ApprovalRequest(toolName: name, title: "Add event · \(item.title)", method: "ADD", url: nil, bodyPreview: AgendaStore.line(item), detail: detail, risk: .medium, input: input)
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let item = try Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("calendar_create is not available here: \(a.reason)") }
        let saved = try await AgendaStore.current.createEvent(item)
        return "calendar: added\n" + AgendaStore.line(saved)
    }
    /// "Open in Calendar" on the day of the event (`calshow:` takes seconds since 2001).
    public static func control(_ item: AgendaItem) -> ToolControl {
        let t = item.start.map { Int($0.timeIntervalSinceReferenceDate) }
        return .link(label: "Open in Calendar", url: t.map { "calshow:\($0)" } ?? "calshow:")
    }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let item = try Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("calendar_create is not available here: \(a.reason)") }
        let saved = try await AgendaStore.current.createEvent(item)
        return ToolOutput(text: "calendar: added\n" + AgendaStore.line(saved), control: Self.control(saved))
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}

// MARK: - reminders_due

public struct RemindersDueTool: AppleTool {
    public init() {}
    public let name = "reminders_due"
    public var description: String { "List the user's open reminders (to-dos) due today, or within the next days. Use when the user asks what they have to do, their tasks or reminders." + AgendaStore.todayHint }
    public let parameters: JSONValue = ToolSchema.object([
        "days": ToolSchema.number("Due within this many days from today (default 1 = today, max 31)"),
        "include_completed": ToolSchema.boolean("Also list completed reminders (default false)"),
    ])
    public static let onDeviceCopy = "Reads your reminders when the model asks. Asks for Reminders access the first time."
    public static var defaultOn: Bool { false }
    public static func availability() -> ToolAvailability { AgendaStore.availability() }

    public static func parse(_ args: [String: JSONValue], now: Date = Date()) -> (until: Date, completed: Bool) {
        let days = max(1, min(31, args.int("days") ?? 1))
        let until = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: now))!
        return (until, args.bool("include_completed") ?? false)
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let (until, completed) = Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("reminders_due is not available here: \(a.reason)") }
        let items = try await AgendaStore.current.reminders(dueBefore: until, includeCompleted: completed)
        if items.isEmpty { return "reminders: nothing due before \(AgendaStore.dayFormatter.string(from: until))" }
        return "reminders: \(items.count) due before \(AgendaStore.dayFormatter.string(from: until))\n" + items.map { AgendaStore.line($0) }.joined(separator: "\n")
    }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput { ToolOutput(text: try await call(args)) }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}

// MARK: - reminders_create (HITL)

public struct RemindersCreateTool: AppleTool {
    public init() {}
    public let name = "reminders_create"
    public var description: String { "Add a reminder (to-do) for the user, optionally due at a date and time (yyyy-MM-dd HH:mm or yyyy-MM-dd). Use only when the user asks to be reminded or to add a task." + AgendaStore.todayHint }
    public let parameters: JSONValue = ToolSchema.object([
        "title": ToolSchema.string("What to remind them of"),
        "due": ToolSchema.string("When, e.g. 2026-10-07 09:00 or 2026-10-07 (optional)"),
        "notes": ToolSchema.string("Notes (optional)"),
    ], required: ["title"])
    public static let onDeviceCopy = "Adds reminders after you approve each one."
    public static var defaultOn: Bool { false }
    public static func availability() -> ToolAvailability { AgendaStore.availability() }

    public static func parse(_ args: [String: JSONValue]) throws -> AgendaItem {
        guard let title = (args.string("title") ?? args.string("text") ?? args.string("reminder"))?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { throw ToolError("need a title — what to remind the user of") }
        var due: Date? = nil, allDay = false
        if let raw = args.string("due") ?? args.string("when") ?? args.string("date"), !raw.isEmpty {
            guard let (d, ad) = AgendaStore.parseDate(raw) else { throw ToolError("due must look like 2026-10-07 09:00 or 2026-10-07") }
            due = d; allDay = ad
        }
        return AgendaItem(title: title, start: due, allDay: allDay, calendar: args.string("list") ?? "", notes: args.string("notes"))
    }
    public func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
        guard let item = try? Self.parse(input) else { return nil }
        let when = item.start.map { AgendaStore.spoken($0, allDay: item.allDay) } ?? "no due date"
        return ApprovalRequest(toolName: name, title: "Add reminder · \(item.title)", method: "ADD", url: nil, bodyPreview: AgendaStore.line(item), detail: "Adds to Reminders — \(when)", risk: .medium, input: input)
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let item = try Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("reminders_create is not available here: \(a.reason)") }
        let saved = try await AgendaStore.current.createReminder(item)
        return "reminders: added\n" + AgendaStore.line(saved)
    }
    /// "Open in Reminders" (the app's URL scheme; no per-item deep link is public).
    public static func control(_ item: AgendaItem) -> ToolControl {
        .link(label: "Open in Reminders", url: "x-apple-reminderkit://")
    }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let item = try Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("reminders_create is not available here: \(a.reason)") }
        let saved = try await AgendaStore.current.createReminder(item)
        return ToolOutput(text: "reminders: added\n" + AgendaStore.line(saved), control: Self.control(saved))
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}
