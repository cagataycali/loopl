import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// History › Select → Delete. Deleting a batch removes each thread's JSON *and* its
/// `.attachments` folder (pictures, recordings), in one list mutation; deleting the open thread resets the chat.
/// Runs in the Xcode-hosted LooplTests; `swift test` compiles this file empty.
@MainActor
final class HistoryDeleteTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-history-delete-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func thread(_ title: String, ago: TimeInterval) -> SavedConversation {
        SavedConversation(id: UUID(), title: title, updated: Date().addingTimeInterval(-ago), modelName: "m",
                          items: [.user(title), .assistant("ok")])
    }

    /// Writes a thread plus an attachments folder holding a picture and a recording, like the composer does.
    private func seed(_ archive: ConversationArchive, _ c: SavedConversation) throws {
        archive.upsert(c)
        let dir = archive.attachmentsDirectory(for: c.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: dir.appendingPathComponent("photo.jpg"))
        try Data([0x00, 0x00, 0x00, 0x1C]).write(to: dir.appendingPathComponent("clip.m4a"))
    }

    func testBatchDeleteRemovesFilesAndAttachments() throws {
        let archive = ConversationArchive(root: root)
        let a = thread("a", ago: 10), b = thread("b", ago: 20), keep = thread("keep", ago: 30)
        try [a, b, keep].forEach { try seed(archive, $0) }
        XCTAssertEqual(archive.conversations.count, 3)

        XCTAssertEqual(archive.delete(ids: [a.id, b.id]), 2)

        XCTAssertEqual(archive.conversations.map(\.id), [keep.id])
        let fm = FileManager.default
        for gone in [a, b] {
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("\(gone.id.uuidString).json").path), "\(gone.title) json")
            XCTAssertFalse(fm.fileExists(atPath: archive.attachmentsDirectory(for: gone.id).path), "\(gone.title) attachments")
        }
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("\(keep.id.uuidString).json").path))
        XCTAssertTrue(fm.fileExists(atPath: archive.attachmentsDirectory(for: keep.id).appendingPathComponent("clip.m4a").path))
        // Disk agrees with memory after a cold reload.
        XCTAssertEqual(ConversationArchive(root: root).conversations.map(\.id), [keep.id])
    }

    func testDeleteAllEmptiesTheArchive() throws {
        let archive = ConversationArchive(root: root)
        try [thread("a", ago: 1), thread("b", ago: 2)].forEach { try seed(archive, $0) }
        archive.deleteAll()
        XCTAssertTrue(archive.conversations.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(left.isEmpty, "nothing left on disk: \(left)")
    }

    func testUnknownIdsAreHarmless() throws {
        let archive = ConversationArchive(root: root)
        try seed(archive, thread("a", ago: 1))
        XCTAssertEqual(archive.delete(ids: [UUID(), UUID()]), 0)
        XCTAssertEqual(archive.delete(ids: []), 0)
        XCTAssertEqual(archive.conversations.count, 1)
    }

    /// Deleting the thread that is open resets the chat to a fresh one (new id, empty transcript); deleting others leaves it.
    func testDeletingTheOpenThreadResetsTheChat() {
        let engine = Engine(settings: AppSettings(), store: ModelStore())
        let others = Set(engine.archive.conversations.map(\.id))   // whatever the host app already has — leave it alone
        let open = SavedConversation(id: UUID(), title: "open", updated: Date(), modelName: "m", items: [.user("open"), .assistant("hi")])
        let other = SavedConversation(id: UUID(), title: "other", updated: Date(), modelName: "m", items: [.user("other"), .assistant("hi")])
        engine.archive.upsert(open); engine.archive.upsert(other)
        defer { engine.archive.delete(ids: [open.id, other.id]) }

        engine.open(open)
        XCTAssertEqual(engine.currentId, open.id)
        XCTAssertEqual(engine.transcript.items.count, 2)

        XCTAssertEqual(engine.delete(ids: [other.id]), 1)
        XCTAssertEqual(engine.currentId, open.id, "deleting another thread keeps the open one")
        XCTAssertEqual(engine.transcript.items.count, 2)

        XCTAssertEqual(engine.delete(ids: [open.id]), 1)
        XCTAssertNotEqual(engine.currentId, open.id, "a fresh thread id")
        XCTAssertTrue(engine.transcript.items.isEmpty, "nothing stale on screen")
        XCTAssertNil(engine.openedUnder)
        XCTAssertEqual(Set(engine.archive.conversations.map(\.id)), others)
    }
}
#endif
