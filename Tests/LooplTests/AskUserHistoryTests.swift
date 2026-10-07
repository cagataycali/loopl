import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// Phase 7 `ask_user` in History: a settled card is saved as its `ask_user` tool pair with the MASKED answer, reopens as the
/// settled card, an open card is saved cancelled, and the Share-to-Hugging-Face export never carries a password.
/// Runs in the Xcode-hosted LooplTests; `swift test` compiles this file empty.
final class AskUserHistoryTests: XCTestCase {
    private func request() throws -> AskUserRequest {
        try AskUserRequest(args: ["type": "form", "text": "Wi-Fi details", "title": "Wi-Fi",
                                  "fields": [["name": "ssid", "required": true], ["name": "password", "type": "password"]]])
    }

    func testAnsweredCardRoundTripsMasked() throws {
        let r = try request()
        var t = Transcript()
        t.user("join the office wifi")
        // What the Transcript holds after `.interruptResolved` (already masked by the fold).
        t.items.append(TranscriptItem(kind: .ask(toolUseId: "a1", r, answer: .answered(["ssid": "office", "password": .string(AskUserAnswer.mask)]))))
        t.items.append(TranscriptItem(kind: .assistant("Connected to office.")))
        let saved = try XCTUnwrap(SavedConversation.from(t, id: UUID(), modelName: "m"))
        guard case .tool(let name, let args, let result, _, _, _, _) = saved.items[1] else { return XCTFail("saved as the tool pair: \(saved.items[1])") }
        XCTAssertEqual(name, "ask_user")
        XCTAssertEqual(args["type"], "form")
        XCTAssertFalse(result?.contains("hunter2") ?? true)
        XCTAssertTrue(result?.contains(AskUserAnswer.mask) == true, result ?? "")

        let back = saved.transcript()
        // History keeps no toolUseIds (every tool row gets a fresh one on reopen); a settled card is never answered again, so that is fine.
        guard let (_, req, maybe) = Self.ask(back.items[1].kind), let answer = maybe else { return XCTFail("reopened as the settled card: \(back.items[1].kind)") }
        XCTAssertEqual(req.title, "Wi-Fi")
        XCTAssertEqual(answer.summary(for: req), "Submitted")

        let thread = saved.exportThread()
        let text = thread.messages.map { $0.toolResults.map(\.content).joined() + $0.text }.joined()
        XCTAssertTrue(text.contains(AskUserAnswer.mask) && !text.contains("hunter2"), "the export carries the masked answer")
    }

    func testOpenCardIsSavedCancelledAndPasswordNeverReachesDisk() throws {
        let r = try request()
        var t = Transcript()
        t.user("join")
        t.items.append(TranscriptItem(kind: .ask(toolUseId: "a2", r, answer: nil)))
        let saved = try XCTUnwrap(SavedConversation.from(t, id: UUID(), modelName: nil))
        guard case .tool(_, _, let result, _, _, _, _) = saved.items[1] else { return XCTFail() }
        XCTAssertEqual(AskUserAnswer(toolResult: result ?? ""), .cancelled)

        // Defence in depth: even an UNMASKED answer handed to the saver is masked on the way to disk.
        var t2 = Transcript(); t2.user("join")
        t2.items.append(TranscriptItem(kind: .ask(toolUseId: "a3", r, answer: .answered(["ssid": "office", "password": "hunter2"]))))
        let saved2 = try XCTUnwrap(SavedConversation.from(t2, id: UUID(), modelName: nil))
        guard case .tool(_, _, let result2, _, _, _, _) = saved2.items[1] else { return XCTFail() }
        XCTAssertFalse(result2?.contains("hunter2") ?? true, result2 ?? "")
    }

    /// Pattern helper: `.ask` with its three values as optionals (keeps the `guard case` above readable).
    private static func ask(_ k: TranscriptItem.Kind) -> (String?, AskUserRequest, AskUserAnswer?)? {
        if case .ask(let id, let r, let a) = k { return (id, r, a) }; return nil
    }
}
#endif
