import XCTest
@testable import Loopl

/// Two temp directories stand in for the iPhone and a USB-C drive.
final class ExternalStorageTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ext-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func model(_ name: String, files: [String: Int]) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (f, n) in files { try Data(repeating: UInt8(f.utf8.first!), count: n).write(to: dir.appendingPathComponent(f)) }
        return dir
    }
    private func listing(_ dir: URL) -> [String: Int] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) })
    }

    // MARK: manifest

    func testManifestDecodesMissingKeysToInternal() throws {
        let m = try JSONDecoder().decode(StorageManifest.self, from: Data("{}".utf8))
        XCTAssertEqual(m.version, 1); XCTAssertTrue(m.volumes.isEmpty); XCTAssertNil(m.downloadTarget)
        XCTAssertEqual(m.location(of: "anything"), .internalStorage)
    }

    func testManifestRoundTrips() throws {
        var m = StorageManifest()
        let b = StorageBookmark(name: "SanDisk", folderName: "loopl", volumeUUID: "ABC", bookmark: Data([1, 2, 3]))
        m.volumes = [b]
        m.locations["qwen"] = .external(volumeId: b.id, relativePath: "mlx-community--Qwen3.5-0.8B-4bit")
        m.downloadTarget = b.id
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(StorageManifest.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.location(of: "qwen").volumeId, b.id)
        XCTAssertTrue(back.location(of: "qwen").isExternal)
        // Wire names are stable snake_case (the file sits next to the weights and outlives app versions).
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"download_target\"")); XCTAssertTrue(json.contains("\"volume_id\""))
    }

    func testLocationDecodesUnknownKindAsInternal() throws {
        let l = try JSONDecoder().decode(ModelLocation.self, from: Data(#"{"kind":"icloud"}"#.utf8))
        XCTAssertEqual(l, .internalStorage)
    }

    // MARK: free space guard

    func testFreeSpaceIsPositiveHereAndGuardRefusesTheAbsurd() throws {
        let free = ExternalStorage.freeSpace(at: base)
        XCTAssertGreaterThan(free, 0)
        XCTAssertNoThrow(try ExternalStorage.ensureSpace(need: 1, at: base, volumeName: "tmp"))
        XCTAssertThrowsError(try ExternalStorage.ensureSpace(need: Int64.max / 2, at: base, volumeName: "tmp")) { e in
            guard case StorageError.notEnoughSpace(_, let f, let v) = e as! StorageError else { return XCTFail("\(e)") }
            XCTAssertEqual(f, free); XCTAssertEqual(v, "tmp")
            XCTAssertTrue(e.localizedDescription.contains("Not enough space on tmp"))
        }
    }

    // MARK: move

    func testMoveCopiesVerifiesAndDeletesSource() async throws {
        let src = try model("src/qwen", files: ["config.json": 300, "model.safetensors": 5_000_000, "tokenizer.json": 1_200])
        let dst = base.appendingPathComponent("drive/qwen", isDirectory: true)
        let before = listing(src)
        var reports: [(Int64, Int64)] = []
        let box = Box()
        try await ExternalStorage.move(directory: src, to: dst, verify: .sha256) { d, t in box.append((d, t)) }
        reports = box.values
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "source deleted after verification")
        XCTAssertEqual(listing(dst), before)
        // Same volume in a test → rename path, one (1,1) report; different volumes would report per file.
        XCTAssertFalse(reports.isEmpty)
        XCTAssertEqual(reports.last?.0, reports.last?.1)
    }

    func testCrossVolumeCopyPathVerifiesEveryFileAndRollsBackOnCorruption() async throws {
        let src = try model("src/m", files: ["config.json": 300, "a.safetensors": 2_000_000])
        let dst = base.appendingPathComponent("drive/m", isDirectory: true)
        // Force the copy path (as if dst were another volume) by corrupting one copy: verification must fail
        // and the destination must be removed while the source is untouched.
        do {
            try await ExternalStorage.move(directory: src, to: dst, verify: .sha256, forceCopy: true) { _, _ in } afterCopy: { copied in
                if copied.lastPathComponent == "a.safetensors" {
                    let h = try FileHandle(forWritingTo: copied); try h.seek(toOffset: 10); try h.write(contentsOf: Data([0xFF])); try h.close()
                }
            }
            XCTFail("corrupted copy must not verify")
        } catch let e as StorageError {
            guard case .verifyFailed(let f, let reason) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(f, "a.safetensors"); XCTAssertTrue(reason.contains("checksum"))
            XCTAssertTrue(e.localizedDescription.contains("nothing was deleted"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.safetensors").path), "source kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path), "half-written destination removed")
    }

    func testCrossVolumeCopyReportsProgressPerFileAndSkipsPartSidecars() async throws {
        let src = try model("src/p", files: ["config.json": 100, "w.safetensors": 1_000, "w.safetensors.part": 50])
        let dst = base.appendingPathComponent("drive/p", isDirectory: true)
        let box = Box()
        try await ExternalStorage.move(directory: src, to: dst, verify: .default, forceCopy: true) { d, t in box.append((d, t)) }
        XCTAssertEqual(box.values.count, 2, "one report per file")
        XCTAssertEqual(box.values.last?.1, 1_100)
        XCTAssertEqual(box.values.last?.0, 1_100)
        XCTAssertEqual(Set(listing(dst).keys), ["config.json", "w.safetensors"], ".part leftovers are not models")
    }

    func testSizeMismatchIsCaughtWithoutHashing() throws {
        let dir = try model("v", files: ["a": 10, "b": 11])
        XCTAssertThrowsError(try ExternalStorage.check(src: dir.appendingPathComponent("a"), copy: dir.appendingPathComponent("b"), verify: .size)) { e in
            XCTAssertTrue("\(e)".contains("size"))
        }
        XCTAssertNoThrow(try ExternalStorage.check(src: dir.appendingPathComponent("a"), copy: dir.appendingPathComponent("a"), verify: .sha256Below(5)))
    }

    func testSha256StreamsAndMatchesCryptoKit() throws {
        let dir = try model("h", files: ["x": 9_000_000])
        let h = try ExternalStorage.sha256(of: dir.appendingPathComponent("x"))
        XCTAssertEqual(h.count, 64)
        XCTAssertEqual(h, try ExternalStorage.sha256(of: dir.appendingPathComponent("x")))
    }

    func testSizeOfDirectoryCountsRegularFiles() throws {
        let dir = try model("s", files: ["a": 10, "b": 20])
        XCTAssertEqual(ExternalStorage.size(of: dir), 30)
    }

    func testBookmarkRoundTripOnThisHost() throws {
        let dir = try model("bm", files: ["config.json": 1])
        let b = try ExternalStorage.makeBookmark(for: dir, name: "Stick")
        XCTAssertEqual(b.name, "Stick"); XCTAssertEqual(b.folderName, "bm")
        let r = try ExternalStorage.resolve(b)
        XCTAssertEqual(r.url.standardizedFileURL.resolvingSymlinksInPath(), dir.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(ExternalStorage.isReachable(r.url))
        try FileManager.default.removeItem(at: dir)
        XCTAssertFalse(ExternalStorage.isReachable(r.url), "pulled drive → unreachable, not a crash")
        XCTAssertThrowsError(try ExternalStorage.resolve(StorageBookmark(name: "Gone", folderName: "x", volumeUUID: nil, bookmark: Data([0, 1, 2])))) { e in
            XCTAssertEqual(e as? StorageError, .bookmarkInvalid(name: "Gone"))
        }
        // The raw variant keeps the system's error so diagnostics can name domain + code.
        XCTAssertThrowsError(try ExternalStorage.resolveRaw(StorageBookmark(name: "Gone", folderName: "x", volumeUUID: nil, bookmark: Data([0, 1, 2])))) { e in
            XCTAssertNil(e as? StorageError); XCTAssertFalse((e as NSError).domain.isEmpty)
        }
    }

    // MARK: storage-fix (owner: "config.json.part doesn't exist" after relaunch with models on the drive)

    /// A folder that is mounted but cannot be listed must read as `.unreadable`, never as an empty folder.
    func testUnreadableFolderIsReportedNotTreatedAsEmpty() throws {
        let dir = base.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(ExternalStorage.readiness(of: dir, accessGranted: true), .readable)
        XCTAssertEqual(ExternalStorage.readiness(of: base.appendingPathComponent("absent"), accessGranted: true), .unreachable)
        guard getuid() != 0 else { throw XCTSkip("root lists anything") }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let r = ExternalStorage.readiness(of: dir, accessGranted: false)
        guard case .unreadable(let reason) = r else { return XCTFail("expected unreadable, got \(r)") }
        XCTAssertTrue(reason.contains("security-scoped access was refused"), reason)
        XCTAssertTrue(reason.contains("listing failed"), reason)
    }

    /// The write probe refuses a read-only target with the volume named — before storage.json or the network are touched.
    func testWriteProbeNamesAnUnwritableTarget() throws {
        let ok = base.appendingPathComponent("loopl/model", isDirectory: true)
        XCTAssertNoThrow(try ExternalStorage.ensureWritable(ok, volumeName: "SanDisk"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ok.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ok.path).isEmpty, "probe file must be removed")
        guard getuid() != 0 else { throw XCTSkip("root writes anywhere") }
        let ro = base.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        XCTAssertThrowsError(try ExternalStorage.ensureWritable(ro, volumeName: "SanDisk")) { e in
            guard case StorageError.notWritable(let volume, let path, _) = e as! StorageError else { return XCTFail("\(e)") }
            XCTAssertEqual(volume, "SanDisk"); XCTAssertEqual(path, ro.path)
            XCTAssertTrue(e.localizedDescription.contains("SanDisk"), e.localizedDescription)
        }
    }

    /// HFDownloader must throw a named error when the `.part` file cannot be created instead of
    /// letting FileHandle say "doesn't exist".
    func testDownloaderNamesTheFolderWhenPartCannotBeCreated() async throws {
        guard getuid() != 0 else { throw XCTSkip("root writes anywhere") }
        let ro = base.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        let dl = HFDownloader()
        let f = HFDownloader.RemoteFile(path: "config.json", size: 10, type: "file")
        do {
            try await dl.download(repo: "x/y", file: f, to: ro.appendingPathComponent("config.json")) { _ in }
            XCTFail("expected a throw")
        } catch let e as HFDownloader.DLError {
            guard case .io(let msg) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(msg.contains("config.json.part"), msg)
            XCTAssertTrue(msg.contains(ro.path), msg)
            XCTAssertTrue(msg.contains("read-only"), msg)
        }
    }

    /// `config.json.part` beside a whole `config.json` is a leftover, not progress: the model stays complete.
    func testOrphanPartSidecarsAreRecognised() {
        let names = ["config.json", "config.json.part", "model.safetensors", "tokenizer.json", "big.safetensors.part"]
        XCTAssertEqual(ExternalStorage.orphanParts(in: names), ["config.json.part"])
        XCTAssertEqual(ExternalStorage.orphanParts(in: ["model.gguf.part"]), [])
        // After dropping orphans the MLX completeness rule (config + safetensors, no .part) holds again.
        let kept = Set(names).subtracting(ExternalStorage.orphanParts(in: names)).subtracting(["big.safetensors.part"])
        XCTAssertTrue(kept.contains("config.json") && kept.contains { $0.hasSuffix(".safetensors") } && !kept.contains { $0.hasSuffix(".part") })
    }

    /// Relaunch: the owner's exact storage.json (bookmark shortened) decodes to the same three external locations —
    /// nothing in the manifest ever turns an external model internal or drops it.
    func testOwnersManifestKeepsLocationsAcrossRelaunch() throws {
        let json = """
        {"volumes":[{"name":"cagatayusb","id":"B2D6CEDC-A6A4-48AA-82B8-4192746BD087","folder_name":"DB8E88CF-4EEB-30E1-85B7-2D06B3D78E33",
          "volume_uuid":"DB8E88CF-4EEB-30E1-85B7-2D06B3D78E33","bookmark":"Ym9va5AHAAAA","created_at":812956575.669778}],
         "locations":{"qwen3-0.6b-4bit":{"relative_path":"loopl/mlx-community--Qwen3-0.6B-4bit","kind":"external","volume_id":"B2D6CEDC-A6A4-48AA-82B8-4192746BD087"},
           "deepseek-r1-distill-qwen-1.5b-4bit":{"relative_path":"loopl/mlx-community--DeepSeek-R1-Distill-Qwen-1.5B-4bit","kind":"external","volume_id":"B2D6CEDC-A6A4-48AA-82B8-4192746BD087"},
           "qwen3.5-0.8b-4bit":{"relative_path":"loopl/mlx-community--Qwen3.5-0.8B-4bit","kind":"external","volume_id":"B2D6CEDC-A6A4-48AA-82B8-4192746BD087"}},
         "download_target":"B2D6CEDC-A6A4-48AA-82B8-4192746BD087","version":1}
        """
        let m = try JSONDecoder().decode(StorageManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.volumes.count, 1)
        XCTAssertEqual(m.volumes[0].folderName, m.volumes[0].volumeUUID, "the owner granted the DRIVE ROOT")
        for id in ["qwen3-0.6b-4bit", "deepseek-r1-distill-qwen-1.5b-4bit", "qwen3.5-0.8b-4bit"] {
            XCTAssertEqual(m.location(of: id).volumeId, "B2D6CEDC-A6A4-48AA-82B8-4192746BD087", id)
        }
        // Round trip = what a relaunch reads back.
        let again = try JSONDecoder().decode(StorageManifest.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(again, m)
    }

    /// The diagnostics log rotates at its cap and keeps whole lines.
    func testDiagnosticsLogRotates() {
        let d = StorageDiagnostics(directory: base)
        for i in 0..<3000 { d.log("line \(i) " + String(repeating: "x", count: 100)) }
        let size = (try? FileManager.default.attributesOfItem(atPath: d.url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0); XCTAssertLessThanOrEqual(size, StorageDiagnostics.limit + 256)
        let text = d.text
        XCTAssertTrue(text.hasSuffix("\n")); XCTAssertTrue(text.contains("line 2999"))
        XCTAssertTrue(text.split(separator: "\n").first!.contains(" line "), "must start on a whole line")
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var v: [(Int64, Int64)] = []
    func append(_ x: (Int64, Int64)) { lock.lock(); v.append(x); lock.unlock() }
    var values: [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return v }

}
