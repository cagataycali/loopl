import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// #20 Share a conversation as Markdown / image. Runs in the Xcode-hosted LooplTests; `swift test` compiles this file empty.
/// `LOOPL_SHARE_OUT=<dir>` (simctl launchctl setenv) also writes the rendered files there for screenshots.
@MainActor final class ConversationShareTests: XCTestCase {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP4z8DAwMDAxMDAwMDAAAANHQEDasKb6QAAAABJRU5ErkJggg==")!

    private func convo() -> SavedConversation {
        SavedConversation(id: UUID(), title: "What's the time in Tokyo?", updated: Date(timeIntervalSince1970: 1_790_000_000), modelName: "Qwen3.5 0.8B (4-bit)", items: [
            .user("What's the time in Tokyo? And what is 17 × 23?", images: [ImageBlock(data: Self.png, mime: "image/png", width: 2, height: 2)]),
            .tool(name: "current_time", args: ["timezone": .string("Asia/Tokyo")], result: "2026-10-06 23:14 JST", isError: false, ms: 4),
            .tool(name: "calculator", args: ["expression": .string("17*23")], result: "391", isError: false, ms: 2),
            .assistant("It's **23:14** in Tokyo, and 17 × 23 = **391**.\n\n| city | time |\n|---|---|\n| Tokyo | 23:14 |"),
            .note("Switched to Qwen3.5 0.8B (4-bit)"),
        ])
    }

    func testMarkdownHasEveryTurnInOrder() {
        let md = ConversationShare.markdown(convo())
        XCTAssertTrue(md.hasPrefix("# What's the time in Tokyo?\n"))
        XCTAssertTrue(md.contains("Qwen3.5 0.8B (4-bit) · "))
        XCTAssertTrue(md.contains("**You** _(1 image)_"))
        XCTAssertTrue(md.contains(#"> ✓ **current_time** `{"timezone":"Asia/Tokyo"}`"#))
        XCTAssertTrue(md.contains("> 391"))
        XCTAssertTrue(md.contains("| Tokyo | 23:14 |"), "assistant Markdown passes through verbatim")
        XCTAssertTrue(md.contains("_Switched to Qwen3.5 0.8B (4-bit)_"))
        let order = ["**You**", "current_time", "calculator", "**loopl**", "_Switched"].map { md.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted())
        XCTAssertFalse(md.contains("base64"), "pictures are counted, never inlined")
    }

    func testAudioMarkerBecomesACountNotAPath() {
        var c = convo()
        c.items = [.user("hello\n[audio attached: /var/mobile/x.m4a (3.2 s) — call transcribe with this path to hear it]", images: nil)]
        let md = ConversationShare.markdown(c)
        XCTAssertTrue(md.contains("_(1 recording)_"))
        XCTAssertFalse(md.contains("/var/mobile"), "a device path never leaves in a share")
    }

    func testFileNameIsSafe() {
        XCTAssertEqual(ConversationShare.fileName(convo(), ext: "md"), "Whats the time in Tokyo.md")
        var c = convo(); c.title = "a/b:c?"
        XCTAssertEqual(ConversationShare.fileName(c, ext: "png"), "abc.png")
        c.title = "???"
        XCTAssertEqual(ConversationShare.fileName(c, ext: "md"), "loopl conversation.md")
    }

    func testImageRendersAtPhoneWidth() throws {
        for dark in [false, true] {
            let data = try XCTUnwrap(ConversationShare.image(convo(), dark: dark))
            let img = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(img.size.width * img.scale, ShareCard.width * 3, accuracy: 1)
            XCTAssertGreaterThan(img.size.height, 300, "the whole column is drawn (ScrollView would render empty)")
            if let out = ProcessInfo.processInfo.environment["LOOPL_SHARE_OUT"] {
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("share-\(dark ? "dark" : "light").png"))
                try Data(ConversationShare.markdown(convo()).utf8).write(to: URL(fileURLWithPath: out).appendingPathComponent("share.md"))
            }
        }
    }
}
#endif
