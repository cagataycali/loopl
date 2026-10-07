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
        /// Phase 6: mounted in the CURRENT conversation (the agent may have changed it with `manage_tools`); `nil` when the
        /// host has no conversation state — then the toggle is the truth.
        public var mountedHere: Bool?
        /// Always on and not switchable (`manage_tools` itself).
        public var pinned: Bool
        public init(name: String, copy: String, defaultOn: Bool, available: Bool = true, reason: String = "", enabled: Bool, asksFirst: String? = nil,
                    mountedHere: Bool? = nil, pinned: Bool = false) {
            self.name = name; self.copy = copy; self.defaultOn = defaultOn; self.available = available; self.reason = reason; self.enabled = enabled
            self.asksFirst = asksFirst ?? ToolListing.approvalNotes[name]
            self.mountedHere = mountedHere; self.pinned = pinned
        }
        /// "mounted for this conversation" / "unmounted for this conversation" when the agent changed this tool's state
        /// away from the toggle; `nil` when they agree.
        public var conversationTag: String? {
            guard let mountedHere, available, mountedHere != enabled else { return nil }
            return mountedHere ? "mounted for this conversation" : "unmounted for this conversation"
        }
        /// The model is offered this tool this turn.
        public var offered: Bool { enabled && available }
        /// "on by default" / "off by default" / "always on".
        public var defaultTag: String { pinned ? "always on" : defaultOn ? "on by default" : "off by default" }
    }

    public var on: [Row]
    public var off: [Row]

    /// Keeps the caller's (Settings) order inside each group. Unavailable tools go under Off whatever their toggle says.
    public init(_ rows: [Row]) {
        on = rows.filter(\.offered)
        off = rows.filter { !$0.offered }
    }

    public var all: [Row] { on + off }

    /// One sentence for the section footer when the agent's mounted set differs from the switches, else `nil`:
    /// "In this conversation the agent also mounted http · unmounted calculator."
    public var conversationNote: String? {
        let added = all.filter { $0.conversationTag != nil && $0.mountedHere == true }.map(\.name)
        let removed = all.filter { $0.conversationTag != nil && $0.mountedHere == false }.map(\.name)
        guard !added.isEmpty || !removed.isEmpty else { return nil }
        var parts: [String] = []
        if !added.isEmpty { parts.append("also mounted \(added.joined(separator: ", "))") }
        if !removed.isEmpty { parts.append("unmounted \(removed.joined(separator: ", "))") }
        return "In this conversation the agent " + parts.joined(separator: " · ") + ". A new conversation starts from the switches."
    }
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
        "system_prompt": "Asks before changing the system prompt — the card shows old → new; reads go through.",
    ]

    /// One-line copy for the portable tools (their `description` is written for the model, not for Settings).
    public static let coreCopy: [String: String] = [
        "current_time": "The date and time right now, in your time zone.",
        "calculator": "Arithmetic the model should not do in its head.",
        "device_info": "Battery, storage, memory and the model of this device.",
        "remember": "Keeps a note between conversations — on this device only.",
        "recall": "Reads those notes back.",
        "http": "Fetches a URL for the model. Refused while offline mode is on.",
        "manage_tools": "Lets the model add or remove its own tools mid-conversation — a mount works on its very next step.",
        "manage_messages": "Lets the model tidy its own context in a long chat — old tool results go, your messages stay. The chat on screen never changes.",
        "system_prompt": "Lets the model read or change its own system prompt when you ask for a standing rule — the Settings field, for every conversation. Revert any time in Settings › System prompt.",
    ]
}
