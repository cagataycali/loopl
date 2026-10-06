import Foundation
import Loopl
import Observation

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
        /// Being copied between the iPhone and a drive (`to` = the destination's name).
        case moving(done: Int64, total: Int64, to: String)
        public var isDownloading: Bool { if case .downloading = self { return true }; return false }
        public var isDownloaded: Bool { if case .downloaded = self { return true }; return false }
        public var isMoving: Bool { if case .moving = self { return true }; return false }
        public var needsDrive: String? { if case .needsDrive(let n) = self { return n }; return nil }
    }

    /// Drives the user granted + where every model lives (storage.json).
    public let storage: StorageLocations
    /// The last failed move, for the Storage screen (a failed move leaves the model where it was).
    public private(set) var lastMoveError: String?

    /// Curated rows shipped in models.json ("Recommended").
    public private(set) var bundled: Catalog
    /// Repos the user added from "Browse Hugging Face" — persisted next to the weights.
    public private(set) var hubModels: [ModelSpec] = []
    /// Everything the app can run: curated + Hub additions (one list for Engine/ModelsView).
    public var catalog: Catalog {
        Catalog(version: bundled.version, updated: bundled.updated, models: bundled.models + hubModels, defaultModelId: bundled.defaultModelId)
    }
    public private(set) var states: [String: State] = [:]
    public private(set) var diskUsed: Int64 = 0
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
            guard let dir = storage.directory(for: spec) else { states[spec.id] = .notDownloaded; continue }
            let external = storage.location(of: spec.id).isExternal
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
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
            if complete { states[spec.id] = .downloaded(bytes: spec.file == nil ? bytes : (files.first { $0.lastPathComponent == spec.file }.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? bytes)) }
            else if partial > 0 { states[spec.id] = .paused(done: partial, total: spec.sizeBytes) }
            else if case .failed? = states[spec.id] { /* keep the message */ }
            else { states[spec.id] = .notDownloaded }
        }
        diskUsed = used
    }

    /// Downloads `spec` to `volume` (a drive id), or — `volume == nil` — to
    /// `storage.suggestedTarget`: the chosen drive when it is connected and has
    /// room, else the iPhone, else any connected drive that fits. A paused
    /// download resumes where its .part files already are.
    public func download(_ spec: ModelSpec, to volume: String?? = nil) {
        guard spec.isDownloadable, tasks[spec.id] == nil else { return }
        if NetworkPolicy.isOffline { states[spec.id] = .failed(HFDownloader.DLError.offline.localizedDescription); return }
        if spec.gated, HFAccount.shared.token == nil { states[spec.id] = .failed(HFDownloader.DLError.signInRequired(spec.repo).localizedDescription); return }
        // Where the bytes go. Resuming keeps the existing location; a fresh download picks the target.
        let resuming: Bool = if case .paused = states[spec.id] ?? .notDownloaded { true } else { false }
        let chosen: String? = resuming ? storage.location(of: spec.id).volumeId : (volume ?? storage.suggestedTarget(need: spec.sizeBytes))
        guard let target = storage.target(chosen, for: spec) else {
            states[spec.id] = .failed("\(storage.name(of: chosen)) is not plugged in"); return
        }
        do {
            try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
            let have = ExternalStorage.size(of: target.url)
            try ExternalStorage.ensureSpace(need: max(0, spec.sizeBytes - have), at: target.url, volumeName: storage.name(of: chosen))
        } catch {
            states[spec.id] = .failed(error.localizedDescription); return
        }
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
    }

    private func finish(_ spec: ModelSpec, error: String? = nil) {
        tasks[spec.id] = nil
        refresh()
        if let error { states[spec.id] = .failed(error) }
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
        refresh()
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
    public static func label(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }
}
