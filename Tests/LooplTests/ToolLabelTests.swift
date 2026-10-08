import XCTest
@testable import Loopl

/// an audit #5/#9/#10: nothing in the chat reads as `snake_case` or as an envelope.
final class ToolLabelTests: XCTestCase {
    func testKnownToolsReadAsPlainWords() {
        XCTAssertEqual(ToolLabel.display("current_time"), "Time")
        XCTAssertEqual(ToolLabel.display("clipboard_write"), "Copy to clipboard")
        XCTAssertEqual(ToolLabel.display("manage_messages"), "Tidy context")
        XCTAssertEqual(ToolLabel.display("use_agent"), "Helper")
        XCTAssertEqual(ToolLabel.display("render_ui"), "Card")
    }
    func testUnknownToolsNeverShowUnderscores() {
        XCTAssertEqual(ToolLabel.display("notes"), "Notes")
        XCTAssertEqual(ToolLabel.display("fetch_weather"), "Fetch weather")
        XCTAssertEqual(ToolLabel.display("x"), "X")
        XCTAssertEqual(ToolLabel.display(""), "")
        for (id, label) in ToolLabel.table { XCTAssertFalse(label.contains("_"), id) }
    }
    func testEveryShippedToolHasALabel() {
        // Every id in the SDK's own tool list and the Apple set has a hand-written label, so a new tool
        // either lands here or is caught by this test (the fallback is for sub-agents' tools and third parties).
        let shipped = ["current_time", "calculator", "device_info", "remember", "recall", "http", "manage_tools", "manage_messages",
                       "use_agent", "system_prompt", "render_ui", "ask_user", "clipboard_read", "clipboard_write", "calendar_events",
                       "calendar_create", "reminders_due", "reminders_create", "location", "contacts_search", "photos_recent", "music",
                       "flashlight", "vibrate", "open_app", "describe_image", "generate_image", "generate_voice", "transcribe", "translate"]
        for id in shipped { XCTAssertNotNil(ToolLabel.table[id], id) }
    }
    func testWakeLineIsPlainAndThePromptKeepsTheEnvelope() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let info = SubAgentInfo(id: "agent_i", parentToolUseId: "t1", name: "issues", systemPrompt: "x", input: "task", tools: ["http"], background: true, startedAt: t0)
        let env = SubAgentEnvelope(info: info, status: .done, result: "three issues", endedAt: t0.addingTimeInterval(73))
        XCTAssertEqual(SubAgentWake.line(for: env), "Helper issues finished · 1 min 13 s")
        XCTAssertTrue(SubAgentWake.line(for: env).hasPrefix(SubAgentWake.prefix))
        XCTAssertFalse(SubAgentWake.line(for: env).contains("["))
        XCTAssertTrue(SubAgentWake.prompt(for: env).hasPrefix("[use_agent agent_i finished]"), "the model still gets the envelope")
        XCTAssertEqual(SubAgentWake.spokenElapsed(8), "8 s"); XCTAssertEqual(SubAgentWake.spokenElapsed(120), "2 min")
    }
}
