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
        public var isDownloading: Bool { if case .downloading = self { return true }; return false }
        public var isDownloaded: Bool { if case .downloaded = self { return true }; return false }
    }

    public private(set) var catalog: Catalog
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

    public init(catalog: Catalog = .loadBundled()) {
        self.catalog = catalog
        refresh()
    }

    public static func directory(for spec: ModelSpec) -> URL {
        root.appendingPathComponent(spec.repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    public func localDirectory(_ spec: ModelSpec) -> URL? {
        states[spec.id]?.isDownloaded == true ? Self.directory(for: spec) : nil
    }

    /// A model counts as downloaded when its directory holds config.json and
    /// at least one *.safetensors with no *.part sidecars left.
    public func refresh() {
        var used: Int64 = 0
        for spec in catalog.models where spec.isDownloadable {
            if tasks[spec.id] != nil { continue }
            let dir = Self.directory(for: spec)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            used += bytes
            let names = Set(files.map(\.lastPathComponent))
            let complete = names.contains("config.json") && names.contains { $0.hasSuffix(".safetensors") } && !names.contains { $0.hasSuffix(".part") }
            if complete { states[spec.id] = .downloaded(bytes: bytes) }
            else if bytes > 0 { states[spec.id] = .paused(done: bytes, total: spec.sizeBytes) }
            else if case .failed? = states[spec.id] { /* keep the message */ }
            else { states[spec.id] = .notDownloaded }
        }
        diskUsed = used
    }

    public func download(_ spec: ModelSpec) {
        guard spec.isDownloadable, tasks[spec.id] == nil else { return }
        if NetworkPolicy.isOffline { states[spec.id] = .failed(HFDownloader.DLError.offline.localizedDescription); return }
        if spec.gated { states[spec.id] = .failed("gated repository — loopl only downloads public models"); return }
        states[spec.id] = .downloading(done: 0, total: spec.sizeBytes, filesDone: 0, files: 0)
        let dir = Self.directory(for: spec)
        tasks[spec.id] = Task {
            let dl = HFDownloader(token: nil)
            do {
                let files = try await dl.listFiles(repo: spec.repo, revision: spec.revision ?? "main")
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

    public func delete(_ spec: ModelSpec) {
        tasks[spec.id]?.cancel(); tasks[spec.id] = nil
        try? FileManager.default.removeItem(at: Self.directory(for: spec))
        states[spec.id] = .notDownloaded
        refresh()
    }

    public func deleteAll() { catalog.models.forEach(delete) }
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
    /// Weights + KV cache + activations: ~1.3× weight size is the rule of thumb we show, flagged as such.
    public static func fits(_ spec: ModelSpec) -> Bool { Double(available) > Double(spec.sizeBytes) * 1.3 }
    public static func label(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }
}
