import XCTest
import Loopl
@testable import LooplAppleTools

/// `clipboard` — parsing (lenient aliases small models emit), the HITL card for writes, a real
/// round trip on the host pasteboard (restored afterwards), and the default-on registry.
final class ClipboardToolTests: XCTestCase {
    func testParseActionsAndAliases() throws {
        XCTAssertEqual(try ClipboardTool.parse(["action": .string("read")]).action, "read")
        XCTAssertEqual(try ClipboardTool.parse(["action": .string("WRITE"), "text": .string("x")]).action, "write")
        XCTAssertEqual(try ClipboardTool.parse([:]).action, "read", "no action, no text → read")
        XCTAssertEqual(try ClipboardTool.parse(["text": .string("hi")]).action, "write", "text alone → write")
        XCTAssertEqual(try ClipboardTool.parse(["action": .string("copy"), "value": .string("hi")]).text, "hi")
        XCTAssertEqual(try ClipboardTool.parse(["action": .string("paste")]).action, "read")
        XCTAssertThrowsError(try ClipboardTool.parse(["action": .string("write")]))
        XCTAssertThrowsError(try ClipboardTool.parse(["action": .string("clear")]))
    }

    func testSchemaEnumMatchesActions() throws {
        guard case .object(let s) = ClipboardTool().parameters, case .object(let props)? = s["properties"],
              case .object(let a)? = props["action"], case .array(let e)? = a["enum"] else { return XCTFail("schema") }
        XCTAssertEqual(e.compactMap(\.stringValue), Clipboard.actions)
    }

    func testWriteNeedsApprovalReadDoesNot() {
        let t = ClipboardTool()
        XCTAssertNil(t.requiresApproval(for: ["action": .string("read")]))
        let req = t.requiresApproval(for: ["action": .string("write"), "text": .string("hello from loopl")])
        XCTAssertEqual(req?.toolName, "clipboard")
        XCTAssertEqual(req?.method, "COPY")
        XCTAssertEqual(req?.bodyPreview, "hello from loopl")
        XCTAssertEqual(req?.risk, .medium, "the default ApprovalPolicy(.mutating) auto-approves .low — a clipboard write must reach the card")
        XCTAssertTrue(req?.title.contains("hello from loopl") == true)
        XCTAssertNil(t.requiresApproval(for: ["action": .string("write"), "text": .string("")]), "empty text fails in call, no card")
        XCTAssertNotNil(ClipboardWriteTool().requiresApproval(for: ["text": .string("x")]))
        XCTAssertEqual(ClipboardWriteTool().requiresApproval(for: ["text": .string("x")])?.toolName, "clipboard_write")
    }

    func testApprovalTitleTruncatesLongText() {
        let long = String(repeating: "a", count: 300)
        let req = Clipboard.approval(toolName: "clipboard", text: long, input: [:])
        XCTAssertLessThan(req.title.count, 110)
        XCTAssertEqual(req.bodyPreview, long, "the card body keeps the full text")
    }

    func testRoundTripOnHostPasteboard() async throws {
        guard Clipboard.isAvailable else { throw XCTSkip("no pasteboard") }
        let before = Clipboard.readText()
        defer { if let b = before { Clipboard.write(b) } }
        let t = ClipboardTool()
        let w = try await t.call(["action": .string("write"), "text": .string("loopl clipboard test")])
        XCTAssertTrue(w.contains("replaced with 20 characters"), w)
        let r = try await t.callOutput(["action": .string("read")])
        XCTAssertTrue(r.text.hasPrefix("clipboard: text (20 characters)\n"), r.text)
        XCTAssertTrue(r.text.hasSuffix("loopl clipboard test"))
        XCTAssertTrue(r.images.isEmpty)
        // shape B reads the same bytes
        let r2 = try await ClipboardReadTool().call([:])
        XCTAssertTrue(r2.hasSuffix("loopl clipboard test"))
    }

    func testLongTextIsTruncatedAndSaysSo() async throws {
        guard Clipboard.isAvailable else { throw XCTSkip("no pasteboard") }
        let before = Clipboard.readText()
        defer { if let b = before { Clipboard.write(b) } }
        Clipboard.write(String(repeating: "x", count: Clipboard.maxTextChars + 500))
        let r = Clipboard.performRead()
        XCTAssertTrue(r.text.hasPrefix("clipboard: text (\(Clipboard.maxTextChars + 500) characters, first \(Clipboard.maxTextChars) shown)"), r.text)
        XCTAssertEqual(r.text.split(separator: "\n").last?.count, Clipboard.maxTextChars)
    }

    func testEmptyWriteIsAnError() async {
        do { _ = try await ClipboardTool().call(["action": .string("write"), "text": .string("")]); XCTFail("should throw") }
        catch { XCTAssertTrue("\(error)".contains("text must not be empty"), "\(error)") }
    }

    func testRegistryAndDefaults() {
        XCTAssertEqual(AppleTools.names.filter { $0.hasPrefix("clipboard") }, ["clipboard_read", "clipboard_write"], "shape B — measured, see ClipboardTool.swift header")
        XCTAssertTrue(AppleTools.isDefaultOn("clipboard_read")); XCTAssertTrue(AppleTools.isDefaultOn("clipboard_write"))
        XCTAssertTrue(AppleTools.isDefaultOn("flashlight"), "existing tools keep today's default")
        XCTAssertFalse(AppleTools.defaultOnNames.isEmpty)
        XCTAssertFalse(AppleTools.names.contains("clipboard"), "shape A lost the measurement on the 0.8B; it stays in the SDK only")
    }
}
