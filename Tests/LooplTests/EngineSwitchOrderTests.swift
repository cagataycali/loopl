import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// A model switch must never hold two models in RAM at once. iOS has no swap: the jetsam ceiling for a foreground app
/// is ~5 GB on an 8 GB iPhone, so loading the new weights while the old ones are still resident (`old + new`) killed
/// the process on switches where either model alone fit. The engine now unloads first, loads second, and if the new
/// load fails it reloads the previous model from disk. Runs in the Xcode-hosted LooplTests; `swift test` compiles
/// this file empty.
@MainActor
final class EngineSwitchOrderTests: XCTestCase {
    /// Records the global order of load/unload events across all fakes, and can be told to fail its load.
    actor Ledger {
        var events: [String] = []
        func note(_ s: String) { events.append(s) }
    }

    actor RecordingModel: Model {
        nonisolated let kind: RuntimeKind = .mlx
        private(set) var loadedModelId: String?
        private(set) var params = GenerationParams()
        let name: String; let ledger: Ledger; let failLoad: Bool
        init(name: String, ledger: Ledger, failLoad: Bool = false) { self.name = name; self.ledger = ledger; self.failLoad = failLoad }
        nonisolated static func availability() -> RuntimeAvailability { .ok }
        func updateConfig(_ params: GenerationParams) { self.params = params }
        func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
            await ledger.note("load \(name)")
            if failLoad { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "weights unreadable"]) }
            loadedModelId = spec.id; progress(1)
        }
        func unload() async { await ledger.note("unload \(name)"); loadedModelId = nil }
        nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    // `.appleFM` is the one runtime whose spec is not downloadable (`ModelSpec.isDownloadable`), so `load` never looks
    // for files on disk — with every other runtime it answers "not downloaded yet" before touching the model. The
    // runtime kind only picks which class `makeModel` would build, and the factory hook replaces that anyway.
    private static let a = ModelSpec(id: "test:a", name: "A", repo: "", runtime: .appleFM, family: .generic, paramsB: 1,
                                     sizeBytes: 0, ctxNominal: 8192, ctxUsable8GB: 8192, minRAMGB: 0)
    private static let b = ModelSpec(id: "test:b", name: "B", repo: "", runtime: .appleFM, family: .generic, paramsB: 1,
                                     sizeBytes: 0, ctxNominal: 8192, ctxUsable8GB: 8192, minRAMGB: 0)

    /// The old model is gone BEFORE the new one starts loading — the peak is one model, never two.
    func testSwitchUnloadsTheOldModelBeforeLoadingTheNew() async {
        let ledger = Ledger()
        let e = Engine(settings: AppSettings(), store: ModelStore())
        let old = RecordingModel(name: "A", ledger: ledger)
        e.adoptForTesting(old, spec: Self.a)
        e.modelFactoryForTesting = { spec in RecordingModel(name: spec.name, ledger: ledger) }

        await e.load(Self.b)

        let events = await ledger.events
        XCTAssertEqual(events, ["unload A", "load B"], "free before fill")
        XCTAssertEqual(e.loadedModel?.id, Self.b.id)
        XCTAssertNil(e.lastError)
    }

    /// The new model fails to load: the previous one is reloaded from disk and the failure is said inline, not as a
    /// dead screen. (Before, the old model was simply still there; now it has to come back — and it does.)
    func testFailedSwitchReloadsThePreviousModel() async {
        let ledger = Ledger()
        let e = Engine(settings: AppSettings(), store: ModelStore())
        e.adoptForTesting(RecordingModel(name: "A", ledger: ledger), spec: Self.a)
        e.modelFactoryForTesting = { spec in RecordingModel(name: spec.name, ledger: ledger, failLoad: spec.id == Self.b.id) }

        await e.load(Self.b)

        let events = await ledger.events
        XCTAssertEqual(events, ["unload A", "load B", "load A"], "unload, try the new one, bring the old one back")
        XCTAssertEqual(e.loadedModel?.id, Self.a.id, "back on A")
        XCTAssertEqual(e.lastError, "B failed to load: weights unreadable")
    }

    /// Nothing loaded yet and the load fails: the banner carries the message, there is nothing to restore.
    func testFailedFirstLoadReportsOnTheBanner() async {
        let ledger = Ledger()
        let e = Engine(settings: AppSettings(), store: ModelStore())
        e.modelFactoryForTesting = { spec in RecordingModel(name: spec.name, ledger: ledger, failLoad: true) }

        await e.load(Self.b)

        let events = await ledger.events
        XCTAssertEqual(events, ["load B"])
        XCTAssertNil(e.loadedModel)
        if case .failed(let spec, let msg) = e.readiness { XCTAssertEqual(spec?.id, Self.b.id); XCTAssertTrue(msg.contains("weights unreadable"), msg) }
        else { XCTFail("expected .failed, got \(e.readiness)") }
    }

    /// A switch while the model is mid-answer is refused — unload-first would pull the weights out from under the
    /// streaming agent. Same convention as the other mutators: nothing happens, the inline line says why.
    func testSwitchDuringAnAnswerIsRefused() async {
        let ledger = Ledger()
        let e = Engine(settings: AppSettings(), store: ModelStore())
        let talking = FakeModel(turns: [.hang(after: 0)])
        e.adoptForTesting(talking, spec: Self.a)
        defer { e.archive.delete(id: e.currentId) }
        e.modelFactoryForTesting = { spec in RecordingModel(name: spec.name, ledger: ledger) }
        e.send("keep talking")
        XCTAssertTrue(e.isGenerating)

        await e.load(Self.b)

        let events = await ledger.events
        XCTAssertEqual(events, [], "nothing unloaded, nothing loaded")
        XCTAssertEqual(e.loadedModel?.id, Self.a.id, "still on A")
        XCTAssertEqual(e.lastError, "wait for the answer to finish, then pick B again")
        e.stop()
        let t0 = Date()
        while e.isGenerating, Date().timeIntervalSince(t0) < 5 { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The previous model cannot be reloaded either (its files went away): say both, keep the screen honest.
    func testFailedSwitchWhoseRestoreAlsoFails() async {
        let ledger = Ledger()
        let e = Engine(settings: AppSettings(), store: ModelStore())
        e.adoptForTesting(RecordingModel(name: "A", ledger: ledger), spec: Self.a)
        e.modelFactoryForTesting = { spec in RecordingModel(name: spec.name, ledger: ledger, failLoad: true) }

        await e.load(Self.b)

        let events = await ledger.events
        XCTAssertEqual(events, ["unload A", "load B", "load A"])
        XCTAssertNil(e.loadedModel)
        if case .failed(_, let msg) = e.readiness { XCTAssertTrue(msg.contains("A could not be reloaded either"), msg) }
        else { XCTFail("expected .failed, got \(e.readiness)") }
    }
}
#endif
