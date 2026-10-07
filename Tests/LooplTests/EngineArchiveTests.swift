import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// IMPROVE-5 #1: a turn reaches History on EVERY exit, not only when the agent loop ends normally.
/// Before: `archiveCurrent()` ran on `Transcript.apply → true` (loop ended), Stop, open and new — a model error, a tool
/// crash or a cancelled task left the user's message (and a brand-new thread) off disk; a kill mid-answer lost it all.
/// Runs in the Xcode-hosted LooplTests; `swift test` compiles this file empty.
@MainActor
final class EngineArchiveTests: XCTestCase {
    private static let spec = ModelSpec(id: "test:fake", name: "Fake (4-bit)", repo: "", runtime: .mlx, family: .generic, paramsB: 1,
                                        sizeBytes: 0, ctxNominal: 8192, ctxUsable8GB: 8192, minRAMGB: 0)

    private func engine(_ model: FakeModel) -> Engine {
        let e = Engine(settings: AppSettings(), store: ModelStore())
        e.adoptForTesting(model, spec: Self.spec)
        return e
    }

    private func onDisk(_ e: Engine) -> SavedConversation? {
        ConversationArchive(root: e.archive.root, inBackground: false).conversations.first { $0.id == e.currentId }   // #165: the app archive loads in the background; the test wants the synchronous read
    }

    private func waitUntilIdle(_ e: Engine, _ timeout: TimeInterval = 5) async {
        let t0 = Date()
        while e.isGenerating, Date().timeIntervalSince(t0) < timeout { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The message is on disk the moment it is sent — before the model has said a word.
    func testUserTurnIsSavedBeforeTheModelAnswers() async {
        let e = engine(FakeModel(turns: [.hang(after: 0)]))
        defer { e.archive.delete(id: e.currentId) }
        e.send("remember this")
        let saved = onDisk(e)
        XCTAssertNotNil(saved, "thread written when the turn starts")
        XCTAssertEqual(saved?.items.first.flatMap { if case .user(let s, _, _) = $0 { return s }; return nil }, "remember this")
        XCTAssertEqual(saved?.title, "remember this")
        e.stop()
        await waitUntilIdle(e)
    }

    /// A model error ends the turn with ONE plain line — and the thread (message + line) survives a relaunch.
    /// The duplicate was real: the agent yields `.forceStop(why)` and throws the same error, so the thread held
    /// `stopped: the model fell over` AND `error: the model fell over`.
    func testErrorTurnIsSavedWithOneLine() async {
        struct Boom: LocalizedError { var errorDescription: String? { "the model fell over" } }
        let e = engine(FakeModel(turns: [.failure(Boom())]))
        defer { e.archive.delete(id: e.currentId) }
        e.send("first message of a new thread")
        await waitUntilIdle(e)
        XCTAssertFalse(e.isGenerating)
        let saved = onDisk(e)
        XCTAssertNotNil(saved, "a failed first turn still creates the thread")
        XCTAssertEqual(saved?.items.count, 2, "user row + ONE failure line: \(String(describing: saved?.items))")
        if case .note(let s)? = saved?.items.last {
            XCTAssertEqual(s, "Couldn't finish this answer — the model fell over")
            XCTAssertFalse(s.hasPrefix("error:"), "no developer prefix")
        } else { XCTFail("last item is the failure note") }
        XCTAssertEqual(e.lastError, "the model fell over", "the banner still has the raw reason")
    }

    /// The same line, in plain words, whichever side reports it.
    func testFailureNoteWording() {
        XCTAssertEqual(Transcript.failureNote("out of memory"), "Couldn't finish this answer — out of memory")
        XCTAssertEqual(Transcript.failureNote("  "), "Couldn't finish this answer.")
    }

    /// Stop mid-answer keeps the message and the partial text (the Stop path already saved; the fallback path now does too).
    func testStoppedTurnIsSaved() async {
        let e = engine(FakeModel(turns: [.hang(after: 3)], delayPerChunkNs: 5_000_000))
        defer { e.archive.delete(id: e.currentId) }
        e.send("tell me a long story")
        try? await Task.sleep(for: .milliseconds(150))
        e.stop()
        await waitUntilIdle(e)
        let saved = onDisk(e)
        XCTAssertNotNil(saved)
        XCTAssertTrue(saved?.items.contains { if case .user = $0 { return true }; return false } ?? false)
    }

    /// `saveNow()` (scenePhase → background) writes the partial answer while the model is still streaming.
    func testSaveNowWritesThePartialAnswer() async {
        let e = engine(FakeModel(turns: [.hang(after: 2)], delayPerChunkNs: 5_000_000))
        defer { e.archive.delete(id: e.currentId) }
        e.send("go")
        try? await Task.sleep(for: .milliseconds(200))
        e.saveNow()
        let saved = onDisk(e)
        XCTAssertEqual(saved?.items.count, 2, "user row + the partial assistant row: \(String(describing: saved?.items))")
        e.stop()
        await waitUntilIdle(e)
    }
}
#endif
