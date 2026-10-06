import Foundation

// MARK: - Reading a granted folder: facts, not guesses

extension ExternalStorage {
    /// What the app can do with a granted folder RIGHT NOW. Every step that
    /// can fail on a removable volume is reported separately, so "the drive
    /// is here but iOS refused the grant" is never mistaken for "no files".
    public enum Readiness: Sendable, Equatable {
        /// Listable: the catalog may read model directories under it.
        case readable
        /// Not mounted / unplugged (`checkResourceIsReachable` false).
        case unreachable
        /// Mounted, but listing failed — `startAccessingSecurityScopedResource` false, permission denied, …
        case unreadable(reason: String)

        public var isReadable: Bool { self == .readable }
        public var reason: String? { if case .unreadable(let r) = self { return r }; return nil }
    }

    /// Is `url` (a granted folder) mounted AND listable? `accessGranted` is what
    /// `startAccessingSecurityScopedResource()` returned — recorded in the reason
    /// so the diagnostics name the failing step.
    public static func readiness(of url: URL, accessGranted: Bool) -> Readiness {
        guard isReachable(url) else { return .unreachable }
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            return .readable
        } catch {
            let ns = error as NSError
            let grant = accessGranted ? "" : "security-scoped access was refused; "
            return .unreadable(reason: "\(grant)listing failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        }
    }

    /// Can the app create a file in `dir`? Creates and deletes a tiny probe so
    /// a download never starts into a folder it will not be able to write.
    /// Throws `StorageError.notWritable(dir, reason)`.
    public static func ensureWritable(_ dir: URL, volumeName: String) throws {
        let fm = FileManager.default
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            throw StorageError.notWritable(volume: volumeName, path: dir.path, reason: "cannot create folder: \((error as NSError).localizedDescription)")
        }
        let probe = dir.appendingPathComponent(".loopl-write-probe-\(UUID().uuidString)")
        guard fm.createFile(atPath: probe.path, contents: Data("ok".utf8)) else {
            throw StorageError.notWritable(volume: volumeName, path: dir.path,
                                           reason: fm.isWritableFile(atPath: dir.path) ? "createFile returned false" : "folder is read-only")
        }
        try? fm.removeItem(at: probe)
    }

    /// `.part` sidecars whose finished file is already there (a download that
    /// re-ran against a complete model, like the failed relaunch attempt that
    /// created `config.json.part` next to a whole `config.json`). They are
    /// leftovers, not progress — ignoring/deleting them keeps the model
    /// "downloaded" instead of forcing a re-download.
    public static func orphanParts(in names: some Sequence<String>) -> [String] {
        let set = Set(names)
        return set.filter { $0.hasSuffix(".part") && set.contains(String($0.dropLast(5))) }.sorted()
    }
}

// MARK: - storage-diagnostics.log

/// Timestamped facts about the drive (resolve / access / reachable / listing /
/// createFile outcomes) in one small rotating file next to the weights, so the
/// next bug report is a log rather than a guess. ≤ `limit` bytes: when the
/// file outgrows it, the older half is dropped.
public final class StorageDiagnostics: @unchecked Sendable {
    public static let fileName = "storage-diagnostics.log"
    public static let limit = 200 << 10
    public let url: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    public init(directory: URL) { url = directory.appendingPathComponent(Self.fileName) }

    public func log(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let entry = "\(formatter.string(from: Date())) \(line)\n"
        let fm = FileManager.default
        var existing = (try? Data(contentsOf: url)) ?? Data()
        existing.append(contentsOf: entry.utf8)
        if existing.count > Self.limit {
            // Drop the first half, then cut to the next newline so the file still starts on a whole line.
            var cut = existing.count / 2
            while cut < existing.count, existing[existing.startIndex + cut] != UInt8(ascii: "\n") { cut += 1 }
            existing = Data(existing.dropFirst(min(cut + 1, existing.count)))
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? existing.write(to: url, options: .atomic)
    }

    public var text: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}
