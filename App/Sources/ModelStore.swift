import Foundation
import Loopl
import Observation
import os

private let log = Logger(subsystem: "technology.tiny.loopl", category: "download")

/// Where models live and how they get there. `@MainActor` because the
/// Models tab binds straight to its state; the byte-moving runs in
/// detached tasks and reports back here.
@MainActor @Observable
public final class ModelStore {
    public enum State: Sendable, Hashable {
        case notDownloaded
        case downloading(done: Int64, total: Int64, filesDone: Int, files: Int)
        case paused(done: Int64, total: Int64)
        case downloaded(bytes: Int64)
        case failed(String)
        /// The weights are on a drive that is not plugged in — still ours, not usable right now.
        case needsDrive(String)
        /// The drive is plugged in but loopl cannot read its folder (grant refused) — re-grant, never re-download.
        case driveUnreadable(String, reason: String)
        /// Being copied between the iPhone and a drive (`to` = the destination's name).
        case moving(done: Int64, total: Int64, to: String)
        public var isDownloading: Bool { if case .downloading = self { return true }; return false }
        public var isDownloaded: Bool { if case .downloaded = self { return true }; return false }
        public var isMoving: Bool { if case .moving = self { return true }; return false }
        public var needsDrive: String? { if case .needsDrive(let n) = self { return n }; return nil }
        public var unreadableDrive: String? { if case .driveUnreadable(let n, _) = self { return n }; return nil }
        /// On a drive we cannot use right now (away or unreadable): dim the row, never auto-download.
        public var driveBlocked: Bool { needsDrive != nil || unreadableDrive != nil }
    }

    /// Drives the user granted + where every model lives (storage.json).
    public let storage: StorageLocations
    /// The last failed move, for the Storage screen (a failed move leaves the model where it was).
    public private(set) var lastMoveError: String?

    /// Curated rows shipped in models.json ("Recommended").
    public private(set) var bundled: Catalog
    /// Repos the user added from "Browse Hugging Face" — persisted next to the weights.
    public private(set) var hubModels: [ModelSpec] = []
    /// Everything the app can run: curated + Hub additions (one list for Engine/ModelsView), with `vision` corrected
    /// from the downloaded config.json where the files disagree with the row (`localVision`).
    public var catalog: Catalog {
        Catalog(version: bundled.version, updated: bundled.updated, models: (bundled.models + hubModels).map(applyLocalVision), defaultModelId: bundled.defaultModelId)
    }
    /// spec.id → what `<dir>/config.json` says about a vision tower, for every downloaded MLX model (vision.json).
    /// The row (models.json / Hub listing) may be wrong or stale; the weights on the phone are the truth the
    /// composer's photo button and the MLX loader must follow.
    public private(set) var localVision: [String: Bool] = [:]
    static let visionFile = root.appendingPathComponent("vision.json")

    func applyLocalVision(_ spec: ModelSpec) -> ModelSpec {
        guard spec.runtime == .mlx, let local = localVision[spec.id], (spec.vision ?? false) != local else { return spec }
        var s = spec
        s.vision = local ? true : nil
        return s
    }

    /// Test/fixture seam: pretend `<dir>/config.json` said `vision` for `id` (nil forgets). Not persisted.
    public func overrideLocalVision(_ id: String, _ vision: Bool?) {
        if let vision { localVision[id] = vision } else { localVision.removeValue(forKey: id) }
    }

    /// Read `config.json` of a complete MLX download and remember whether it has a vision tower
    /// (`LocalModelFiles.hasVisionTower`). Called from `refresh()` for every downloaded model — a few KB per read.
    private func noteLocalVision(_ spec: ModelSpec, directory: URL) {
        guard spec.runtime == .mlx, let has = LocalModelFiles.hasVisionTower(in: directory) else { return }
        if localVision[spec.id] != has {
            localVision[spec.id] = has
            if (spec.vision ?? false) != has {
                log.info("\(spec.id, privacy: .public): config.json says vision=\(has) — row said \(spec.vision ?? false); following the files")
            }
            if let data = try? JSONEncoder().encode(localVision) { try? data.write(to: Self.visionFile, options: .atomic) }
        }
    }
    public private(set) var states: [String: State] = [:]
    public private(set) var diskUsed: Int64 = 0
    /// Test/fixture seam (`--design-models`): pretend `id` is in `state` — survives every `refresh()`, never persisted.
    /// Lets a simulator with no weights show "On this iPhone" rows, a download in flight, a model on a drive.
    private var fixtureStates: [String: State] = [:]
    public func overrideState(_ id: String, _ state: State?) {
        if let state { fixtureStates[id] = state; states[id] = state } else { fixtureStates.removeValue(forKey: id) }
    }
    private var tasks: [String: Task<Void, Never>] = [:]

    public static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true      // gigabytes of weights never ride iCloud backup
        var d = dir
        try? d.setResourceValues(values)
        return dir
    }()

    static let hubModelsFile = root.appendingPathComponent("hub-models.json")

    public init(catalog: Catalog = .loadBundled(), storage: StorageLocations? = nil) {
        self.bundled = catalog
        self.storage = storage ?? StorageLocations()
        if let data = try? Data(contentsOf: Self.hubModelsFile), let list = try? JSONDecoder().decode([ModelSpec].self, from: data) {
            hubModels = list.filter(\.isFromHub)
        }
        if let data = try? Data(contentsOf: Self.visionFile), let v = try? JSONDecoder().decode([String: Bool].self, from: data) { localVision = v }
        refresh()
    }

    /// Adds a Hub model (idempotent). If a curated row already runs the same repo + file, that row is returned instead.
    @discardableResult
    public func add(_ spec: ModelSpec) -> ModelSpec {
        if let twin = bundled.models.first(where: { $0.repo == spec.repo && $0.file == spec.file }) { return twin }
        if let existing = hubModels.first(where: { $0.id == spec.id }) { return existing }
        hubModels.append(spec)
        persistHub()
        refresh()
        return spec
    }

    /// Removes a Hub row from the list (and its weights, if it was the only spec using that directory).
    public func remove(_ spec: ModelSpec) {
        guard spec.isFromHub else { return }
        tasks[spec.id]?.cancel(); tasks[spec.id] = nil
        hubModels.removeAll { $0.id == spec.id }
        persistHub()
        let others = catalog.models.filter { $0.repo == spec.repo && $0.id != spec.id }
        if let dir = storage.directory(for: spec) {
            if others.isEmpty { try? FileManager.default.removeItem(at: dir) }
            else if let f = spec.file { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        }
        storage.set(location: .internalStorage, for: spec.id)
        states[spec.id] = nil
        forgetLocalVision(spec.id)
        refresh()
    }

    private func persistHub() {
        if let data = try? JSONEncoder().encode(hubModels) { try? data.write(to: Self.hubModelsFile, options: .atomic) }
    }

    /// The model's directory on the iPhone (its location when nothing says otherwise).
    public static func directory(for spec: ModelSpec) -> URL {
        root.appendingPathComponent(spec.repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// Where this model's files are right now — on the iPhone or on a connected
    /// drive — or nil when its drive is away. Loaders open from here.
    public func directory(for spec: ModelSpec) -> URL? { storage.directory(for: spec) }

    public func localDirectory(_ spec: ModelSpec) -> URL? {
        states[spec.id]?.isDownloaded == true ? storage.directory(for: spec) : nil
    }

    /// Re-fetch the SMALL files (tokenizer, templates, configs) of a downloaded MLX model from the Hub when they differ
    /// from the Hub's current version — the weights are never downloaded again. This is how a model whose repo was
    /// fixed after the download (tokenizer_class "Qwen3_5Tokenizer" → Qwen2Tokenizer, 2026-10-06) heals in place.
    /// Returns the file names that changed; throws `HFDownloader.DLError` (offline, denied, http).
    @discardableResult
    public func repairFiles(_ spec: ModelSpec) async throws -> [String] {
        guard spec.runtime == .mlx, let dir = localDirectory(spec) else { return [] }
        let dl = HFDownloader(token: HFAccount.shared.provider)
        let changed = try await dl.repairSmallFiles(repo: spec.repo, revision: spec.revision ?? "main", in: dir)
        log.info("repair \(spec.id, privacy: .public): \(changed.isEmpty ? "all small files current" : changed.joined(separator: ", "), privacy: .public)")
        storage.diagnostics.log("\(spec.id): repaired small files \(changed)")
        refresh()
        return changed
    }

    /// Human label for where a model lives ("This iPhone" / the drive's name).
    public func locationName(_ spec: ModelSpec) -> String { storage.name(of: storage.location(of: spec.id).volumeId) }

    /// A model counts as downloaded when its directory holds config.json and
    /// at least one *.safetensors (MLX) — or the single .gguf the spec names —
    /// with no *.part sidecars left.
    public func refresh() {
        storage.resolveAll()
        var used: Int64 = 0
        var counted: Set<URL> = []   // GGUF quants of one repo share a directory — count the bytes once
        for spec in catalog.models where spec.isDownloadable {
            if tasks[spec.id] != nil { continue }
            if let drive = storage.missingDrive(for: spec) { states[spec.id] = .needsDrive(drive); continue }
            if let u = storage.unreadableDrive(for: spec) { states[spec.id] = .driveUnreadable(u.name, reason: u.reason); continue }
            guard let dir = storage.directory(for: spec) else { states[spec.id] = .notDownloaded; continue }
            let external = storage.location(of: spec.id).isExternal
            var files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) } catch {
                let ns = error as NSError
                if external, ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError {
                    files = []                                   // recorded external, directory gone → honestly not downloaded
                } else if external {
                    // The volume listed but this directory did not: a read failure, not an empty folder.
                    storage.diagnostics.log("\(spec.id): listing \(dir.lastPathComponent) failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
                    states[spec.id] = .driveUnreadable(locationName(spec), reason: ns.localizedDescription); continue
                } else { files = [] }
            }
            // `.part` next to its finished file = a leftover of a download that ran against a complete model
            // (the failed relaunch created `config.json.part` beside a whole `config.json`). Drop, don't re-download.
            let orphans = ExternalStorage.orphanParts(in: files.map(\.lastPathComponent))
            if !orphans.isEmpty {
                for o in orphans { try? FileManager.default.removeItem(at: dir.appendingPathComponent(o)) }
                files.removeAll { orphans.contains($0.lastPathComponent) }
                storage.diagnostics.log("\(spec.id): removed orphan sidecars \(orphans)")
            }
            let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            if !external, counted.insert(dir).inserted { used += bytes }
            let names = Set(files.map(\.lastPathComponent))
            let complete: Bool = if let gguf = spec.file {
                names.contains(gguf) && !names.contains { $0.hasSuffix(".part") }          // one .gguf file (llama.cpp)
            } else {
                names.contains("config.json") && names.contains { $0.hasSuffix(".safetensors") } && !names.contains { $0.hasSuffix(".part") }
            }
            // Partial = this spec's own bytes on disk (for a GGUF quant: its .part sidecar, not a sibling quant).
            let partial: Int64 = if let gguf = spec.file {
                files.first { $0.lastPathComponent == gguf + ".part" }.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
            } else { bytes }
            if complete {
                states[spec.id] = .downloaded(bytes: spec.file == nil ? bytes : (files.first { $0.lastPathComponent == spec.file }.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? bytes))
                noteLocalVision(spec, directory: dir)
            }
            else if partial > 0 { states[spec.id] = .paused(done: partial, total: spec.sizeBytes) }
            else if case .failed? = states[spec.id] { /* keep the message */ }
            else { states[spec.id] = .notDownloaded }
        }
        for (id, st) in fixtureStates {
            states[id] = st
            if case .downloaded(let b) = st, catalog.models.contains(where: { $0.id == id }) { used += b }
        }
        diskUsed = used
    }

    /// Why a download cannot start RIGHT NOW — decided synchronously, before any
    /// bytes move. Every case has a sentence the user can act on; `download(_:to:)`
    /// returns it so a Download button can show the reason instead of dismissing.
    public enum DownloadRefusal: Equatable, Sendable {
        /// Apple Foundation Models and friends: nothing to download.
        case notDownloadable
        /// A download (or move) for this model is already in flight — not an error.
        case alreadyRunning
        case offline
        /// Private/gated repo and no Hugging Face token on this device.
        case signInRequired(repo: String)
        /// The chosen drive is not connected (or its grant is gone).
        case driveNotConnected(name: String)
        /// The drive is mounted but iOS refuses loopl's folder grant — re-grant in Settings › Storage.
        case driveUnreadable(name: String)
        /// Nowhere connected can hold it. `drives` = the user's granted drives (connected or not), for the hint.
        case notEnoughSpace(need: Int64, free: Int64, volume: String, drives: [String], anyDriveConnected: Bool)
        /// The target directory could not be created (read-only stick, permission gone).
        case cannotWrite(volume: String, reason: String)

        /// True when the row/sheet should offer Settings › Storage.
        public var suggestsStorageSettings: Bool {
            switch self { case .notEnoughSpace, .driveNotConnected, .driveUnreadable, .cannotWrite: true; default: false }
        }
        /// True for the two non-failures (nothing to show the user).
        public var isSilent: Bool { self == .notDownloadable || self == .alreadyRunning }

        public var message: String {
            switch self {
            case .notDownloadable: return "This model runs from the system — nothing to download."
            case .alreadyRunning: return "Already downloading."
            case .offline: return HFDownloader.DLError.offline.localizedDescription
            case .signInRequired(let repo): return HFDownloader.DLError.signInRequired(repo).localizedDescription
            case .driveNotConnected(let name): return "\(name) is not plugged in — connect it, or pick another place under Settings › Storage."
            case .driveUnreadable(let name): return "\(name) is connected but loopl can't read it — re-grant its folder in Settings › Storage"
            case .notEnoughSpace(let need, let free, let volume, let drives, let connected):
                let base = "Not enough space on \(volume): needs \(ByteSize.label(need)), \(ByteSize.label(free)) free."
                if drives.isEmpty { return base + " Free up space, or add a USB-C drive under Settings › Storage." }
                if connected { return base + " Your drive is full too — free up space on one of them." }
                return base + " Plug in \(ListFormatter.localizedString(byJoining: drives)) to download there, or free up space."
            case .cannotWrite(_, let reason): return reason + " — check the drive under Settings › Storage"
            }
        }
    }

    /// The synchronous checks `download` runs, without starting anything or touching
    /// state. nil = a download would start now. Used by the Download button to
    /// decide whether to dismiss, and by tests.
    public func preflight(_ spec: ModelSpec, to volume: String?? = nil) -> DownloadRefusal? {
        resolveTarget(spec, to: volume).refusal
    }

    private func resolveTarget(_ spec: ModelSpec, to volume: String??) -> (target: (location: ModelLocation, url: URL)?, chosen: String?, refusal: DownloadRefusal?) {
        guard spec.isDownloadable else { return (nil, nil, .notDownloadable) }
        guard tasks[spec.id] == nil else { return (nil, nil, .alreadyRunning) }
        if NetworkPolicy.isOffline { return (nil, nil, .offline) }
        if spec.gated, HFAccount.shared.token == nil { return (nil, nil, .signInRequired(repo: spec.repo)) }
        // Where the bytes go. Resuming keeps the existing location; a fresh download picks the target.
        let resuming: Bool = if case .paused = states[spec.id] ?? .notDownloaded { true } else { false }
        let chosen: String? = resuming ? storage.location(of: spec.id).volumeId : (volume ?? storage.suggestedTarget(need: spec.sizeBytes))
        guard let target = storage.target(chosen, for: spec) else {
            // storage-fix (#64): a connected drive whose grant iOS refuses is "unreadable", not "unplugged".
            if chosen.flatMap({ storage.volume($0) })?.connected == true { return (nil, chosen, .driveUnreadable(name: storage.name(of: chosen))) }
            return (nil, chosen, .driveNotConnected(name: storage.name(of: chosen)))
        }
        // Prove the target takes a file BEFORE touching storage.json or the network (a refused grant makes
        // `createFile` on the drive return false — the owner saw that as "config.json.part doesn't exist").
        do { try ExternalStorage.ensureWritable(target.url, volumeName: storage.name(of: chosen)) }
        catch { return (target, chosen, .cannotWrite(volume: storage.name(of: chosen), reason: error.localizedDescription)) }
        let have = ExternalStorage.size(of: target.url)
        let need = max(0, spec.sizeBytes - have) + ExternalStorage.headroom
        let free = ExternalStorage.freeSpace(at: target.url)
        if free < need {
            return (target, chosen, .notEnoughSpace(need: need, free: free, volume: storage.name(of: chosen),
                                                    drives: storage.volumes.map(\.name), anyDriveConnected: storage.volumes.contains(where: \.connected)))
        }
        return (target, chosen, nil)
    }

    /// Downloads `spec` to `volume` (a drive id), or — `volume == nil` — to
    /// `storage.suggestedTarget`: the chosen drive when it is connected and has
    /// room, else the iPhone, else any connected drive that fits. A paused
    /// download resumes where its .part files already are.
    ///
    /// Returns the reason when nothing started (also written to `states[spec.id]`
    /// as `.failed`, except for the two silent cases) so the caller can show it
    /// where the user is looking — a tap on Download must never do nothing.
    @discardableResult
    public func download(_ spec: ModelSpec, to volume: String?? = nil) -> DownloadRefusal? {
        let (target, chosen, refusal) = resolveTarget(spec, to: volume)
        if let refusal {
            if !refusal.isSilent { states[spec.id] = .failed(refusal.message); storage.diagnostics.log("\(spec.id): download refused — \(refusal.message)") }
            let volumesDesc = storage.volumes.map { "\($0.name):" + ($0.connected ? "connected free=\($0.free)" : "away") }.joined(separator: ",")
            let tokenState = HFAccount.shared.token == nil ? "nil" : "set"
            log.error("download refused for \(spec.id, privacy: .public) (\(spec.repo, privacy: .public)) → \(String(describing: refusal), privacy: .public); target=\(self.storage.name(of: chosen), privacy: .public) internalFree=\(self.storage.internalFree) volumes=[\(volumesDesc, privacy: .public)] token=\(tokenState, privacy: .public)")
            return refusal
        }
        guard let target else { return nil }
        log.info("download start \(spec.id, privacy: .public) (\(spec.repo, privacy: .public)) → \(self.storage.name(of: chosen), privacy: .public) \(target.url.path, privacy: .public) size=\(spec.sizeBytes)")
        storage.set(location: target.location, for: spec.id)
        states[spec.id] = .downloading(done: 0, total: spec.sizeBytes, filesDone: 0, files: 0)
        let dir = target.url
        tasks[spec.id] = Task {
            let dl = HFDownloader(token: HFAccount.shared.provider)   // anonymous until a token is pasted in Settings
            do {
                let files = try await dl.files(for: spec)
                let total = files.reduce(Int64(0)) { $0 + $1.size }
                let counter = ByteCounter()
                for (filesDone, f) in files.enumerated() {
                    try Task.checkCancellation()
                    try await dl.download(repo: spec.repo, revision: spec.revision ?? "main", file: f, to: dir.appendingPathComponent(f.path)) { delta in
                        let done = counter.add(delta)
                        Task { @MainActor in
                            guard self.tasks[spec.id] != nil else { return }
                            self.states[spec.id] = .downloading(done: done, total: total, filesDone: filesDone, files: files.count)
                        }
                    }
                }
                self.finish(spec)
            } catch is CancellationError {
                self.finish(spec)
            } catch {
                self.finish(spec, error: error.localizedDescription)
            }
        }
        return nil
    }

    private func finish(_ spec: ModelSpec, error: String? = nil) {
        tasks[spec.id] = nil
        refresh()
        if let error { states[spec.id] = .failed(error); log.error("download failed \(spec.id, privacy: .public): \(error, privacy: .public)") }
        else { log.info("download finished \(spec.id, privacy: .public) → \(String(describing: self.states[spec.id]), privacy: .public)") }
    }

    public func pause(_ spec: ModelSpec) { tasks[spec.id]?.cancel() }

    /// Deletes the weights. A model on a drive that is away cannot be deleted
    /// from the phone (there is nothing here to delete) — the row says so.
    public func delete(_ spec: ModelSpec) {
        guard let dir = storage.directory(for: spec) else { return }
        tasks[spec.id]?.cancel(); tasks[spec.id] = nil
        let shared = catalog.models.contains { $0.repo == spec.repo && $0.id != spec.id && $0.file != spec.file && (states[$0.id]?.isDownloaded ?? false) }
        if shared, let f = spec.file { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        else { try? FileManager.default.removeItem(at: dir) }
        storage.set(location: .internalStorage, for: spec.id)
        states[spec.id] = .notDownloaded
        forgetLocalVision(spec.id)
        refresh()
    }

    /// The files are gone → the row describes the model again until the next download.
    private func forgetLocalVision(_ id: String) {
        guard localVision.removeValue(forKey: id) != nil else { return }
        if let data = try? JSONEncoder().encode(localVision) { try? data.write(to: Self.visionFile, options: .atomic) }
    }

    public func deleteAll() { catalog.models.forEach(delete) }

    // MARK: Moving between the iPhone and a drive

    /// Copies a downloaded model to `volume` (nil = the iPhone), verifies every
    /// file, then removes the original. Progress shows in the row; a failure
    /// leaves the model exactly where it was and the reason in `lastMoveError`.
    public func move(_ spec: ModelSpec, to volume: String?) {
        guard tasks[spec.id] == nil, states[spec.id]?.isDownloaded == true, let src = storage.directory(for: spec) else { return }
        guard storage.location(of: spec.id).volumeId != volume else { return }
        guard let target = storage.target(volume, for: spec) else { lastMoveError = "\(storage.name(of: volume)) is not plugged in"; return }
        lastMoveError = nil
        let total = ExternalStorage.size(of: src)
        let name = storage.name(of: volume)
        states[spec.id] = .moving(done: 0, total: total, to: name)
        tasks[spec.id] = Task {
            do {
                try await ExternalStorage.move(directory: src, to: target.url) { done, total in
                    Task { @MainActor in
                        guard self.tasks[spec.id] != nil else { return }
                        self.states[spec.id] = .moving(done: done, total: total, to: name)
                    }
                }
                self.storage.set(location: target.location, for: spec.id)
                // GGUF quants of one repo share a directory — they moved together.
                for twin in self.catalog.models where twin.repo == spec.repo && twin.id != spec.id { self.storage.set(location: target.location, for: twin.id) }
                self.tasks[spec.id] = nil
                self.refresh()
            } catch {
                self.tasks[spec.id] = nil
                self.lastMoveError = "\(spec.name): \(error.localizedDescription)"
                self.refresh()
            }
        }
    }

    public func cancelMove(_ spec: ModelSpec) { if states[spec.id]?.isMoving == true { tasks[spec.id]?.cancel() } }
}

/// Lock-free-enough running total shared by the per-file progress closures.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ d: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; value += d; return value }
}

/// Memory budget — `os_proc_available_memory` is the number iOS will
/// actually let this process grow to before jetsam, which is what matters
/// for mapping weights.
public enum MemoryBudget {
    public static var available: Int64 { Int64(os_proc_available_memory()) }
    public static var physical: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }
    /// What the fit badge compares against: the jetsam budget, or (simulator / no limit → 0) 70 % of physical RAM.
    public static var budget: Int64 { available > 0 ? available : Int64(Double(physical) * 0.7) }
    /// Weights + KV cache + activations: ~1.3× weight size is the rule of thumb we show, flagged as such.
    public static func fits(_ spec: ModelSpec) -> Bool { Double(available) > Double(spec.sizeBytes) * 1.3 }
    /// Vision turn: weights + KV for the prompt and `images` pictures (+ `frames` video frames) + tower activations
    /// (`VisionBudget`, Qwen3-VL geometry). Text models ignore the pictures (they never see them).
    public static func fitsVision(_ spec: ModelSpec, promptTokens: Int = 2048, images: Int = 1, frames: Int = 0) -> Bool {
        guard spec.supportsVision else { return fits(spec) }
        return VisionBudget.bytesNeeded(spec, promptTokens: promptTokens, images: images, frames: frames) <= budget
    }
    /// How many video frames this device can hand the model (P8-B's pipeline caps at this; 0 = say it cannot).
    public static func maxVideoFrames(_ spec: ModelSpec) -> Int {
        VisionBudget.maxFrames(spec, contextWindow: spec.ctxUsable8GB, memoryBudget: budget)
    }
    public static func label(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }
}
