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

    func testConversationTagsAndNote() {
        // the agent mounted http (switch off) and unmounted calculator (switch on); manage_tools is pinned.
        let rows: [ToolListing.Row] = [
            .init(name: "calculator", copy: "", defaultOn: true, enabled: true, mountedHere: false),
            .init(name: "http", copy: "", defaultOn: true, enabled: false, mountedHere: true),
            .init(name: "current_time", copy: "", defaultOn: true, enabled: true, mountedHere: true),
            .init(name: "manage_tools", copy: "", defaultOn: true, enabled: true, mountedHere: true, pinned: true),
            .init(name: "flashlight", copy: "", defaultOn: true, available: false, reason: "No torch", enabled: true, mountedHere: false),
        ]
        XCTAssertEqual(rows[0].conversationTag, "unmounted for this conversation")
        XCTAssertEqual(rows[1].conversationTag, "mounted for this conversation")
        XCTAssertNil(rows[2].conversationTag, "switch and conversation agree → no tag")
        XCTAssertEqual(rows[3].defaultTag, "always on")
        XCTAssertNil(rows[4].conversationTag, "an unavailable tool is never tagged")
        XCTAssertEqual(ToolListing(rows).conversationNote, "In this conversation the agent also mounted http · unmounted calculator. A new conversation starts from the switches.")
        XCTAssertNil(ToolListing([rows[2], rows[3]]).conversationNote)
        XCTAssertNil(ToolListing.Row(name: "x", copy: "", defaultOn: true, enabled: true).conversationTag, "no conversation state → the toggle is the truth")
        XCTAssertNotNil(ToolListing.coreCopy["manage_tools"])
    }

    /// Every portable tool needs a hand-written line in `coreCopy`, because `ToolsSection` falls back to the tool's own
    /// `description` — written FOR THE MODEL. `use_agent` had no entry and Settings printed its 694-character prompt,
    /// `{pending:true, id}` and all, as a 324 pt row (356 pt on an SE). The old check listed six names by hand, so a new
    /// tool was invisible to it; this one asks the tools themselves.
    func testEveryPortableToolHasHumanCopy() {
        // The simple tools answer for themselves; the three that need a host are named by their own `toolName`
        // constant, so renaming a tool breaks the build here instead of silently dropping it from this check.
        let simple: [any Tool] = [CurrentTimeTool(), CalculatorTool(), RememberTool(), RecallTool(), HttpTool(), ManageMessagesTool()]
        let names = simple.map(\.name) + [UseAgentTool.toolName, RenderUITool.toolName, AskUserTool.toolName,
                                          SystemPromptTool.toolName, ManageToolsTool.toolName]
        let longest = ToolListing.coreCopy.values.map(\.count).max() ?? 0
        for name in names {
            guard let copy = ToolListing.coreCopy[name] else {
                return XCTFail("\(name) has no Settings copy — the row would print its model prompt instead")
            }
            XCTAssertLessThanOrEqual(copy.count, 180, "\(name): \(copy.count) characters is a paragraph, not a row (longest today \(longest))")
            XCTAssertFalse(copy.contains("{") || copy.contains("}"), "\(name): braces are JSON, not words")
            XCTAssertNil(copy.range(of: "[a-z_]+:(true|false|[a-z])", options: .regularExpression),
                         "\(name): `key:value` is the model's argument syntax")
            XCTAssertNil(copy.range(of: "\\b[A-Z]{4,}\\b", options: .regularExpression), "\(name): SHOUTING is prompt voice")
        }
        for (name, copy) in ToolListing.coreCopy {
            XCTAssertTrue(copy.hasSuffix(".") || copy.hasSuffix("›"), "\(name): a row is a sentence")
        }
    }

    func testSummaryMatchesToolCountSummary() {
        let rows: [ToolListing.Row] = [
            .init(name: "a", copy: "", defaultOn: true, enabled: true), .init(name: "b", copy: "", defaultOn: true, enabled: true),
            .init(name: "c", copy: "", defaultOn: true, available: false, enabled: true), .init(name: "d", copy: "", defaultOn: false, enabled: false),
        ]
        XCTAssertEqual(ToolListing(rows).summary, ToolCountSummary.label(core: 2, coreEnabled: 2, apple: [(true, false), (false, true)]))
    }
}
