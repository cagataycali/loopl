import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// `ModelStore.download` used to early-out SILENTLY from the user's point of view: `.failed(msg)` landed on a
/// row in a section below the fold while the sheet dismissed ("the download is not starting"). Every early-out
/// is now a typed `DownloadRefusal` the Download button can show where the finger is. One test per case,
/// with the message each must carry. Runs in the Xcode-hosted LooplTests (ModelStore lives in the app);
/// `swift test` compiles this file empty.
@MainActor
final class DownloadRefusalTests: XCTestCase {
    private var root: URL!
    private var store: ModelStore!

    private static let mlx = ModelSpec(id: "hub:cagataydev/loopl-0.8b-4bit", name: "loopl-0.8b-4bit", repo: "cagataydev/loopl-0.8b-4bit",
                                       runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 500 << 20, ctxNominal: 32_768, ctxUsable8GB: 8192, minRAMGB: 2)
    private static let gated = ModelSpec(id: "hub:cagataydev/private", name: "private", repo: "cagataydev/private",
                                         runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 100 << 20, ctxNominal: 4096, ctxUsable8GB: 4096, minRAMGB: 2, gated: true)
    private static let fm = ModelSpec(id: "apple-fm", name: "Apple Intelligence", repo: "", runtime: .appleFM, family: .generic, paramsB: 3,
                                      sizeBytes: 0, ctxNominal: 4096, ctxUsable8GB: 4096, minRAMGB: 0)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = Catalog(version: 1, updated: "test", models: [Self.mlx, Self.gated, Self.fm], defaultModelId: Self.mlx.id)
        store = ModelStore(catalog: catalog, storage: StorageLocations(root: root))
        NetworkPolicy.setOffline(false)
    }

    override func tearDown() async throws {
        ExternalStorage.freeSpaceOverride = nil
        NetworkPolicy.setOffline(false)
        try? FileManager.default.removeItem(at: root)
    }

    /// A drive granted then unplugged: its folder is gone, the bookmark still resolves → "not connected".
    private func addAwayDrive(named name: String) throws -> String {
        let folder = root.appendingPathComponent("stick-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let v = try store.storage.add(folder: folder, name: name)
        try FileManager.default.removeItem(at: folder)
        store.storage.resolveAll()
        XCTAssertFalse(store.storage.volume(v.id)?.connected ?? true, "fixture: the drive should read as away")
        return v.id
    }

    // MARK: full iPhone

    func testFullPhoneNoDrivesSaysNeedVsFreeAndOffersAUSBDrive() {
        ExternalStorage.freeSpaceOverride = { _ in 50 << 20 }
        store.storage.resolveAll()
        let r = store.preflight(Self.mlx)
        guard case .notEnoughSpace(let need, let free, let volume, let drives, let connected)? = r else { return XCTFail("\(String(describing: r))") }
        XCTAssertEqual(need, (500 << 20) + ExternalStorage.headroom, "need = the weights + the 200 MB headroom")
        XCTAssertEqual(free, 50 << 20)
        XCTAssertEqual(volume, "This iPhone")
        XCTAssertEqual(drives, []); XCTAssertFalse(connected)
        let m = r!.message
        XCTAssertTrue(m.contains("Not enough space on This iPhone"), m)
        XCTAssertTrue(m.contains("needs 734 MB") && m.contains("52.4 MB free"), "need vs free missing: \(m)")
        XCTAssertTrue(m.contains("Settings › Storage"), "must point at the external-drive option: \(m)")
        XCTAssertFalse(r!.isSilent); XCTAssertTrue(r!.suggestsStorageSettings)
    }

    func testFullPhoneWithTheChosenDriveAwayNamesTheDrive() throws {
        let id = try addAwayDrive(named: "cagatayusb")
        store.storage.downloadTarget = id      // the owner's storage.json: download_target = the stick
        ExternalStorage.freeSpaceOverride = { _ in 50 << 20 }
        store.storage.resolveAll()
        // Nothing connected fits → suggestedTarget falls back to the (full) iPhone, as on the owner's phone.
        XCTAssertNil(store.storage.suggestedTarget(need: Self.mlx.sizeBytes))
        let r = store.preflight(Self.mlx)
        guard case .notEnoughSpace(_, _, let volume, let drives, let connected)? = r else { return XCTFail("\(String(describing: r))") }
        XCTAssertEqual(volume, "This iPhone"); XCTAssertEqual(drives, ["cagatayusb"]); XCTAssertFalse(connected)
        XCTAssertTrue(r!.message.contains("Plug in cagatayusb"), r!.message)
    }

    func testFullPhoneAndFullConnectedDrive() throws {
        let folder = root.appendingPathComponent("stick", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let v = try store.storage.add(folder: folder, name: "SanDisk")
        store.storage.downloadTarget = v.id
        ExternalStorage.freeSpaceOverride = { _ in 10 << 20 }       // every volume is full
        store.storage.resolveAll()
        let r = store.preflight(Self.mlx)
        guard case .notEnoughSpace(_, _, _, let drives, let connected)? = r else { return XCTFail("\(String(describing: r))") }
        XCTAssertEqual(drives, ["SanDisk"]); XCTAssertTrue(connected)
        XCTAssertTrue(r!.message.contains("Your drive is full too"), r!.message)
    }

    // MARK: the other early-outs

    func testExplicitTargetDriveAwayIsDriveNotConnected() throws {
        let id = try addAwayDrive(named: "Old stick")
        let r = store.preflight(Self.mlx, to: .some(id))
        XCTAssertEqual(r, .driveNotConnected(name: "Old stick"))
        XCTAssertTrue(r!.message.contains("Old stick is not plugged in") && r!.message.contains("Settings › Storage"), r!.message)
    }

    func testOfflineModeRefuses() {
        NetworkPolicy.setOffline(true)
        XCTAssertEqual(store.preflight(Self.mlx), .offline)
        XCTAssertEqual(store.preflight(Self.mlx)?.message, HFDownloader.DLError.offline.localizedDescription)
    }

    func testGatedRepoWithoutATokenNeedsSignIn() throws {
        try XCTSkipIf(HFAccount.shared.token != nil, "a token is present in this run (env/Keychain) — the gated guard cannot fire")
        let r = store.preflight(Self.gated)
        XCTAssertEqual(r, .signInRequired(repo: "cagataydev/private"))
        XCTAssertTrue(r!.message.contains("sign in to Hugging Face"), r!.message)
    }

    func testSilentCasesDoNotMarkTheRowFailed() {
        XCTAssertEqual(store.download(Self.fm), .notDownloadable)
        XCTAssertNil(store.states[Self.fm.id], "nothing to download → no state written")
        XCTAssertTrue(ModelStore.DownloadRefusal.alreadyRunning.isSilent)
        XCTAssertTrue(ModelStore.DownloadRefusal.notDownloadable.isSilent)
    }

    /// `download` (the Engine path) must leave the same sentence on the Models row that the sheet shows.
    func testDownloadWritesTheRefusalMessageIntoTheRowState() {
        ExternalStorage.freeSpaceOverride = { _ in 50 << 20 }
        store.storage.resolveAll()
        let r = store.download(Self.mlx)
        XCTAssertNotNil(r)
        guard case .failed(let msg)? = store.states[Self.mlx.id] else { return XCTFail("row not marked failed: \(String(describing: store.states[Self.mlx.id]))") }
        XCTAssertEqual(msg, r!.message)
    }

    func testRoomEverywhereIsNoRefusal() {
        ExternalStorage.freeSpaceOverride = { _ in 10 << 30 }
        store.storage.resolveAll()
        XCTAssertNil(store.preflight(Self.mlx))
        XCTAssertNil(store.states[Self.mlx.id].flatMap { if case .failed = $0 { return true } else { return nil } }, "preflight never writes state")
    }
}
#endif
