import Foundation

/// The rows of Settings › Tools — ONE list for every tool the app can offer (portable + on-device), grouped by what
/// the model actually gets: **On** (switched on and runnable here) and **Off** (switched off, or something this device
/// cannot run). Owner, 2026-10-06: "the tools in Settings need to be under the Tools dropdown instead of half here and
/// half somewhere else." Pure data so the grouping, the tags and the approval notes are unit-tested; the view only draws.
public struct ToolListing: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        /// One line: what it does, in the user's words.
        public var copy: String
        /// Whether a fresh install switches it on.
        public var defaultOn: Bool
        /// Runnable on this device right now; `reason` says why not.
        public var available: Bool
        public var reason: String
        public var enabled: Bool
        /// "Asks before …" when the tool stops at an approval card; `nil` for reads.
        public var asksFirst: String?
        public init(name: String, copy: String, defaultOn: Bool, available: Bool = true, reason: String = "", enabled: Bool, asksFirst: String? = nil) {
            self.name = name; self.copy = copy; self.defaultOn = defaultOn; self.available = available; self.reason = reason; self.enabled = enabled
            self.asksFirst = asksFirst ?? ToolListing.approvalNotes[name]
        }
        /// The model is offered this tool this turn.
        public var offered: Bool { enabled && available }
        /// "on by default" / "off by default".
        public var defaultTag: String { defaultOn ? "on by default" : "off by default" }
    }

    public var on: [Row]
    public var off: [Row]

    /// Keeps the caller's (Settings) order inside each group. Unavailable tools go under Off whatever their toggle says.
    public init(_ rows: [Row]) {
        on = rows.filter(\.offered)
        off = rows.filter { !$0.offered }
    }

    public var all: [Row] { on + off }
    /// "9 of 15" or "off" — the label next to the disclosure, same arithmetic as `ToolCountSummary`.
    public var summary: String {
        let offerable = all.filter(\.available).count
        return on.isEmpty ? "off" : "\(on.count) of \(offerable)"
    }

    /// Which tools stop at an approval card, and for what. Reads have no entry.
    public static let approvalNotes: [String: String] = [
        "http": "Asks before POST, PUT, PATCH or DELETE — reads go through.",
        "open_app": "Asks before leaving loopl, unless the app's scheme is on your allowlist.",
        "clipboard_write": "Asks before replacing what is on your clipboard.",
        "calendar_create": "Asks before adding an event.",
        "reminders_create": "Asks before adding a reminder.",
    ]

    /// One-line copy for the portable tools (their `description` is written for the model, not for Settings).
    public static let coreCopy: [String: String] = [
        "current_time": "The date and time right now, in your time zone.",
        "calculator": "Arithmetic the model should not do in its head.",
        "device_info": "Battery, storage, memory and the model of this device.",
        "remember": "Keeps a note between conversations — on this device only.",
        "recall": "Reads those notes back.",
        "http": "Fetches a URL for the model. Refused while offline mode is on.",
    ]
}
