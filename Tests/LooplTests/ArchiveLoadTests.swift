import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// the app's archive reads its folder off the main actor. 200 threads with picture thumbnails are the
/// measurement bed (the sim seed that found the issue); the numbers print to the log for AUDIT.md.
@MainActor
final class ArchiveLoadTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-archive-load-\(UUID().uuidString)", isDirectory: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// 200 threads; every 4th carries a 60 KB "thumbnail", every 10th is 12 turns long.
    private func seed(_ n: Int = 200) {
        let a = ConversationArchive(root: root)
        let blob = Data((0..<60_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for i in 0..<n {
            var items: [SavedConversation.Item] = [.user("message \(i)", images: i % 4 == 0 ? [ImageBlock(data: blob, mime: "image/jpeg", width: 512, height: 384)] : nil, videos: nil),
                                                   .assistant(String(repeating: "lorem ipsum ", count: 300))]
            if i % 10 == 0 { items = Array(repeating: items, count: 6).flatMap { $0 } }
            a.upsert(SavedConversation(id: UUID(), title: "message \(i)", updated: Date().addingTimeInterval(-Double(i) * 3600), modelName: "m", items: items))
        }
    }

    func testBackgroundReadReturnsAtOnceAndLandsTheSameThreads() async {
        seed()
        let t0 = Date()
        let sync = ConversationArchive(root: root, inBackground: false)
        let syncMs = Date().timeIntervalSince(t0) * 1000
        XCTAssertEqual(sync.conversations.count, 200)

        let t1 = Date()
        let bg = ConversationArchive(root: root, inBackground: true)
        let initMs = Date().timeIntervalSince(t1) * 1000
        XCTAssertTrue(bg.isLoading)
        XCTAssertTrue(bg.conversations.isEmpty, "nothing decoded on the caller's thread")
        await bg.waitUntilLoaded()
        let totalMs = Date().timeIntervalSince(t1) * 1000
        XCTAssertFalse(bg.isLoading)
        XCTAssertEqual(bg.conversations.map(\.id), sync.conversations.map(\.id), "same threads, same order")
        print("ARCHIVE-LOAD 200 threads: synchronous read \(Int(syncMs)) ms on the main actor · background init returned in \(Int(initMs)) ms · loaded after \(Int(totalMs)) ms")
        XCTAssertLessThan(initMs, syncMs / 4, "init must not pay for the decode")
    }

    /// A thread saved or deleted while the read runs is not undone when the read lands.
    func testWritesDuringTheReadWin() async {
        seed(60)
        let before = ConversationArchive(root: root, inBackground: false).conversations
        let archive = ConversationArchive(root: root, inBackground: true)
        let fresh = SavedConversation(id: UUID(), title: "fresh", updated: Date().addingTimeInterval(60), modelName: "m", items: [.user("fresh"), .assistant("ok")])
        archive.upsert(fresh)
        let gone = before[3]
        XCTAssertEqual(archive.delete(ids: [gone.id]), 0, "not in memory yet — the file is removed all the same")
        await archive.waitUntilLoaded()
        XCTAssertEqual(archive.conversations.first?.id, fresh.id, "the thread written during the read is kept")
        XCTAssertFalse(archive.conversations.contains { $0.id == gone.id }, "the thread deleted during the read stays deleted")
        XCTAssertEqual(archive.conversations.count, 60, "59 old + 1 fresh")
        XCTAssertEqual(ConversationArchive(root: root, inBackground: false).conversations.count, 60, "disk agrees")
    }
}
#endif
