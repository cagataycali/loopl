import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// History rows read well at scale — titles from messy first messages, orphan attachment folders
/// swept on reload, model names without their build suffix. Runs in the Xcode-hosted LooplTests.
@MainActor
final class HistoryTitleTests: XCTestCase {
    func testTitleCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(ConversationTitle.make("\n\nhey   can you\nsummarise this"), "hey can you summarise this")
        XCTAssertEqual(ConversationTitle.make("   "), "Conversation")
        XCTAssertEqual(ConversationTitle.make(""), "Conversation")
    }

    func testPictureAndVideoOnlyTurnsAreNamed() {
        XCTAssertEqual(ConversationTitle.make("", hasImages: true), "Photo")
        XCTAssertEqual(ConversationTitle.make("\n", hasImages: true, hasVideos: true), "Video")
    }

    func testLongTitlesCutAtAWordWithEllipsis() {
        let long = "Can you help me with the thing I mentioned yesterday about the project deadline and the budget for Q4 in detail please"
        let t = ConversationTitle.make(long)
        XCTAssertTrue(t.hasSuffix("…"), t)
        XCTAssertLessThanOrEqual(t.count, ConversationTitle.maxLength, t)
        XCTAssertFalse(t.contains("deadlin…"), "no mid-word cut: \(t)")
        XCTAssertTrue(long.hasPrefix(String(t.dropLast())), t)
        // A single giant token (a URL) is cut hard but still marked.
        let url = "https://huggingface.co/cagataydev/loopl-2b-4bit/blob/main/README.md?download=true&x=1"
        XCTAssertEqual(ConversationTitle.make(url).count, ConversationTitle.maxLength)
        XCTAssertTrue(ConversationTitle.make(url).hasSuffix("…"))
        // Short messages are untouched (Turkish, emoji included).
        XCTAssertEqual(ConversationTitle.make("Bana İstanbul'daki hava durumunu söyle 📷"), "Bana İstanbul'daki hava durumunu söyle 📷")
    }

    func testSavedConversationUsesTheTitleRule() {
        var t = Transcript()
        t.user("\n\n  what's 2+2  ")
        t.apply(.startEventLoop(cycle: 1)); t.apply(.text("4"))
        let saved = SavedConversation.from(t, id: UUID(), modelName: "Qwen3-0.6B (4-bit)")
        XCTAssertEqual(saved?.title, "what's 2+2")
        let photo = Transcript().with { $0.user("", images: [ImageBlock(data: Data([0xFF, 0xD8, 0xFF]), mime: "image/jpeg", width: 1, height: 1)]) }
        XCTAssertEqual(SavedConversation.from(photo, id: UUID(), modelName: nil)?.title, "Photo")
        // Editing the first message re-titles with the same rule.
        let edited = saved?.replacing(userAt: 0, with: "\nwhat is 3+3\n")
        XCTAssertEqual(edited?.title, "what is 3+3")
    }

    func testReloadSweepsOrphanAttachmentFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let live = SavedConversation(id: UUID(), title: "live", updated: Date(), modelName: "m", items: [.user("live"), .assistant("ok")])
        let first = ConversationArchive(root: root)
        first.upsert(live)
        let liveDir = first.attachmentsDirectory(for: live.id)
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try Data([1]).write(to: liveDir.appendingPathComponent("clip.m4a"))
        let orphan = root.appendingPathComponent("\(UUID().uuidString).attachments", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: orphan.appendingPathComponent("rec.m4a"))
        let stray = root.appendingPathComponent("notes.attachments", isDirectory: true)   // not a thread id → left alone
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)

        let archive = ConversationArchive(root: root)   // init → reload → sweep
        XCTAssertEqual(archive.conversations.map(\.id), [live.id])
        XCTAssertFalse(fm.fileExists(atPath: orphan.path), "orphan folder removed")
        XCTAssertTrue(fm.fileExists(atPath: liveDir.appendingPathComponent("clip.m4a").path), "a live thread's attachments stay")
        XCTAssertTrue(fm.fileExists(atPath: stray.path), "only <uuid>.attachments folders are swept")
        XCTAssertEqual(archive.sweepOrphans(), 0, "second pass finds nothing")
    }

    /// A file written by an older build with the raw title is shown with the new one after a reload.
    func testOldFilesAreRetitledOnLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-retitle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = SavedConversation(id: UUID(), title: "\n\nhey can you summarise this", updated: Date(), modelName: "m",
                                    items: [.user("\n\nhey can you summarise this"), .assistant("ok")])
        ConversationArchive(root: root).upsert(old)
        XCTAssertEqual(ConversationArchive(root: root).conversations.first?.title, "hey can you summarise this")
    }

    func testPlainNameDropsBuildSuffixes() {
        XCTAssertEqual(ModelSpec.plainName("Qwen3-0.6B (4-bit)"), "Qwen3-0.6B")
        XCTAssertEqual(ModelSpec.plainName("Qwen3 0.6B · Q4_K_M (llama.cpp)"), "Qwen3 0.6B")
        XCTAssertEqual(ModelSpec.plainName("loopl 2B"), "loopl 2B")
        XCTAssertEqual(ModelSpec.plainName("Apple Intelligence (on-device)"), "Apple Intelligence (on-device)")
    }
}

private extension Transcript {
    func with(_ edit: (inout Transcript) -> Void) -> Transcript { var t = self; edit(&t); return t }
}
#endif
