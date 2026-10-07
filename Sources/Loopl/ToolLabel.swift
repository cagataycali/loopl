import Foundation

/// The words the app uses for a tool where a person reads them — the transcript row title, VoiceOver, notes.
/// Tool *ids* (`current_time`, `clipboard_write`) are what the model calls and stay in the expanded card, History
/// and the dataset; they never change. Unknown ids (a sub-agent's own tools, a third-party tool) read as the id with
/// underscores as spaces and a capital first letter, so nothing ever shows as `snake_case` in the chat.
public enum ToolLabel {
    public static let table: [String: String] = [
        "current_time": "Time",
        "calculator": "Calculator",
        "device_info": "Device",
        "remember": "Remember",
        "recall": "Recall",
        "http": "Web request",
        "http_get": "Web request",
        "manage_tools": "Tools",
        "manage_messages": "Tidy context",
        "use_agent": "Helper",
        "system_prompt": "Instructions",
        "render_ui": "Card",
        "ask_user": "Question",
        "clipboard_read": "Read clipboard",
        "clipboard_write": "Copy to clipboard",
        "calendar_events": "Calendar",
        "calendar_create": "Add event",
        "reminders_due": "Reminders",
        "reminders_create": "Add reminder",
        "location": "Location",
        "contacts_search": "Contacts",
        "photos_recent": "Photos",
        "music": "Music",
        "flashlight": "Flashlight",
        "vibrate": "Vibrate",
        "open_app": "Open app",
        "describe_image": "Look at picture",
        "generate_image": "Make picture",
        "generate_voice": "Speak",
        "transcribe": "Transcribe",
        "translate": "Translate",
    ]

    /// "Time" for `current_time`; "Notes" for an unknown `notes`; "Fetch weather" for an unknown `fetch_weather`.
    public static func display(_ id: String) -> String {
        if let known = table[id] { return known }
        let words = id.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init).filter { !$0.isEmpty }
        guard let first = words.first else { return id }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

}


public extension ToolResult {
    /// The result says the work is NOT finished — so the tool's own duration measures the hand-off, not the job,
    /// and a transcript row must not print it. `use_agent` hands back an envelope the moment the child starts
    /// (`{"pending": true, …}`), which made the row read "Helper · 4 ms" above a sub-agent 42 seconds into a
    /// background run: a person reads that as "the helper took 4 ms". The child's own card carries its elapsed
    /// time, so nothing is lost by staying quiet. Deliberately read off the RESULT and not off the tool's name:
    /// the same `use_agent` call that WAITED for its child did do the work in that time, and keeps its number.
    /// (IMPROVE-5 #16)
    var reportsPending: Bool {
        guard content.contains("\"pending\"") else { return false }       // cheap guard before parsing
        return JSONValue.parse(content)?["pending"]?.boolValue == true
    }
}
