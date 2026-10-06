import Foundation
import CryptoKit

// MARK: - Where a model lives

/// Where one model's weights are kept. `internal` is the app's own
/// Application Support directory; `external` is a folder the user granted on a
/// USB-C drive (or any Files provider), addressed by the bookmark that holds
/// the grant plus the path under it.
///
/// Absent from a manifest written before this type existed → `.internal`
/// (`StorageManifest` decodes missing keys to their defaults), so the
/// migration is one line and never deletes anything.
public enum ModelLocation: Sendable, Hashable, Codable {
    case internalStorage
    case external(volumeId: String, relativePath: String)

    public var isExternal: Bool { if case .external = self { return true }; return false }
    public var volumeId: String? { if case .external(let id, _) = self { return id }; return nil }

    private enum CodingKeys: String, CodingKey { case kind, volumeId = "volume_id", relativePath = "relative_path" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "internal" {
        case "external":
            self = .external(volumeId: try c.decode(String.self, forKey: .volumeId), relativePath: try c.decode(String.self, forKey: .relativePath))
        default: self = .internalStorage
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .internalStorage: try c.encode("internal", forKey: .kind)
        case .external(let id, let path):
            try c.encode("external", forKey: .kind); try c.encode(id, forKey: .volumeId); try c.encode(path, forKey: .relativePath)
        }
    }
}

/// One granted folder: the security-scoped bookmark the system handed back
/// from the document picker plus what we need to talk about it when it is
/// NOT plugged in (its name) and to recognise it when it comes back (volume
/// UUID). The bookmark is the only thing that re-opens the folder; the rest is UI.
public struct StorageBookmark: Sendable, Hashable, Codable, Identifiable {
    public var id: String                 // our own stable key (UUID string) — `ModelLocation.external.volumeId`
    public var name: String               // drive display name ("SanDisk") — shown dimmed when unplugged
    public var folderName: String         // the granted folder's last path component
    public var volumeUUID: String?        // `volumeUUIDString`; nil for providers that do not report one
    public var bookmark: Data
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, folderName: String, volumeUUID: String?, bookmark: Data, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.folderName = folderName; self.volumeUUID = volumeUUID; self.bookmark = bookmark; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, folderName = "folder_name", volumeUUID = "volume_uuid", bookmark, createdAt = "created_at" }
}

/// Everything the app persists about storage, in ONE small JSON next to the
/// weights (`storage.json`): the granted drive(s), where each model lives, and
/// where new downloads should go. Additive: every key has a default so an
/// older file — or none — decodes to "everything internal".
public struct StorageManifest: Sendable, Hashable, Codable {
    public var version: Int = 1
    public var volumes: [StorageBookmark] = []
    /// model id → location. Models absent here are internal.
    public var locations: [String: ModelLocation] = [:]
    /// Where NEW downloads land: a volume id, or nil for the iPhone.
    public var downloadTarget: String? = nil

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, volumes, locations, downloadTarget = "download_target" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        volumes = try c.decodeIfPresent([StorageBookmark].self, forKey: .volumes) ?? []
        locations = try c.decodeIfPresent([String: ModelLocation].self, forKey: .locations) ?? [:]
        downloadTarget = try c.decodeIfPresent(String.self, forKey: .downloadTarget)
    }

    public func location(of modelId: String) -> ModelLocation { locations[modelId] ?? .internalStorage }
}

// MARK: - Errors

public enum StorageError: LocalizedError, Equatable, Sendable {
    /// Not enough room on the target volume for `need` bytes (after headroom).
    case notEnoughSpace(need: Int64, free: Int64, volume: String)
    /// The granted folder is not reachable right now (drive unplugged / ejected).
    case volumeUnavailable(name: String)
    /// A copied file did not match its source (size or digest).
    case verifyFailed(file: String, reason: String)
    /// The bookmark could not be resolved (grant revoked, drive reformatted).
    case bookmarkInvalid(name: String)
    /// Permission to the folder could not be obtained (`startAccessingSecurityScopedResource` false).
    case accessDenied(name: String)
    /// The folder is reachable but loopl cannot create files in it (`createFile` false / read-only).
    case notWritable(volume: String, path: String, reason: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let need, let free, let volume):
            "Not enough space on \(volume): needs \(ByteSize.label(need)), \(ByteSize.label(free)) free"
        case .volumeUnavailable(let name): "\(name) is not plugged in"
        case .verifyFailed(let file, let reason): "\(file) did not copy correctly (\(reason)) — nothing was deleted"
        case .bookmarkInvalid(let name): "loopl lost access to the folder on \(name) — choose it again in Settings › Storage"
        case .accessDenied(let name): "iOS refused access to the folder on \(name) — choose it again in Settings › Storage"
        case .notWritable(let volume, let path, let reason): "can't write to \(path) on \(volume): \(reason)"
        case .cancelled: "move cancelled — the original is untouched"
        }
    }
}

// MARK: - Volumes, bookmarks, free space

/// Pure Foundation helpers behind Settings › Storage. No UIKit: the folder
/// picker lives in the app; everything here is testable with `swift test`
/// against two temp directories standing in for two volumes.
public enum ExternalStorage {
    /// Bytes the TARGET volume will let an important write use (purgeable
    /// space counts). This — not `systemFreeSize` — is what iOS itself
    /// consults before a download, so it is the honest number for the guard.
    public static func freeSpace(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(v.volumeAvailableCapacity ?? 0)
    }

    /// Headroom kept free on any volume after a download (the OS needs air; a
    /// FAT/exFAT stick with 0 bytes free corrupts its directory).
    public static let headroom: Int64 = 200 << 20

    /// Refuses a download/move that would not fit on the volume holding `url`.
    public static func ensureSpace(need: Int64, at url: URL, volumeName: String, headroom: Int64 = headroom) throws {
        let free = freeSpace(at: url)
        guard free >= need + headroom else { throw StorageError.notEnoughSpace(need: need + headroom, free: free, volume: volumeName) }
    }

    /// Drive name + volume UUID as the system reports them for a granted folder.
    /// Falls back to the folder name when the provider reports no volume name.
    public static func volumeIdentity(of url: URL) -> (name: String, uuid: String?) {
        let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeLocalizedNameKey, .volumeUUIDStringKey])
        let name = v?.volumeLocalizedName ?? v?.volumeName ?? url.lastPathComponent
        return (name.isEmpty ? url.lastPathComponent : name, v?.volumeUUIDString)
    }

    /// Is the folder there right now? False the moment the stick is pulled.
    public static func isReachable(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true
    }

    /// Creates the bookmark the app persists for a folder the picker returned.
    /// On iOS a bookmark made from a picker URL carries the security scope
    /// implicitly; macOS needs `.withSecurityScope` (tests run there).
    public static func makeBookmark(for url: URL, name: String? = nil) throws -> StorageBookmark {
        #if os(macOS)
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)
        #else
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)
        #endif
        let ident = volumeIdentity(of: url)
        return StorageBookmark(name: name ?? ident.name, folderName: url.lastPathComponent, volumeUUID: ident.uuid, bookmark: data)
    }

    /// Re-opens a granted folder. Throws `.bookmarkInvalid` when the grant is
    /// gone for good; returns `reachable == false` (no throw) when the drive is
    /// merely unplugged — the catalog keeps the model, the row dims.
    public static func resolve(_ b: StorageBookmark) throws -> (url: URL, stale: Bool) {
        do { return try resolveRaw(b) } catch { throw StorageError.bookmarkInvalid(name: b.name) }
    }

    /// `resolve` with the system's own error (domain / code — e.g. NSFileNoSuchFile 4 while the
    /// drive is unplugged vs a permission error) so diagnostics can tell "unplugged" from "revoked".
    public static func resolveRaw(_ b: StorageBookmark) throws -> (url: URL, stale: Bool) {
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let opts: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url = try URL(resolvingBookmarkData: b.bookmark, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    // MARK: Moving a model between volumes

    /// How a copied file is checked before the source is deleted.
    public enum Verify: Sendable, Equatable {
        /// Byte count only — what a 4 GB weight file gets (reading it twice over USB 2 would take minutes).
        case size
        /// Byte count + SHA-256 of every file.
        case sha256
        /// SHA-256 for files up to `bytes`, size only above — the default: config/tokenizer/manifest
        /// files are checksummed, the weights are size-checked.
        case sha256Below(Int64)
        public static let `default`: Verify = .sha256Below(64 << 20)
    }

    /// Progress of a move: bytes copied so far out of the total.
    public typealias Progress = @Sendable (_ done: Int64, _ total: Int64) -> Void

    /// Moves a model directory across volumes SAFELY: copy every file, verify
    /// each copy (size, or size + SHA-256), and only then delete the source.
    /// Any failure or cancellation removes the half-written destination and
    /// leaves the source exactly as it was. Same-volume moves are a rename.
    ///
    /// `afterCopy` is a test seam (corrupt the copy → verify must fail and roll back);
    /// `forceCopy` takes the copy+verify path even on one volume (tests run on one disk).
    public static func move(directory src: URL, to dst: URL, verify: Verify = .default,
                            forceCopy: Bool = false,
                            progress: Progress? = nil,
                            afterCopy: (@Sendable (URL) throws -> Void)? = nil) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { throw StorageError.verifyFailed(file: src.lastPathComponent, reason: "source missing") }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }   // a stale half-move from last time

        // Same volume → a rename is atomic and free.
        if !forceCopy, sameVolume(src, dst.deletingLastPathComponent()) {
            try fm.moveItem(at: src, to: dst); progress?(1, 1); return
        }

        let files = try (fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !$0.lastPathComponent.hasSuffix(".part") }
        let total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var done: Int64 = 0
        do {
            try ensureSpace(need: total, at: dst.deletingLastPathComponent(), volumeName: dst.deletingLastPathComponent().lastPathComponent)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for f in files {
                try Task.checkCancellation()
                let out = dst.appendingPathComponent(f.lastPathComponent)
                try fm.copyItem(at: f, to: out)
                try afterCopy?(out)
                try Task.checkCancellation()
                try check(src: f, copy: out, verify: verify)
                done += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                progress?(done, total)
            }
        } catch is CancellationError {
            try? fm.removeItem(at: dst); throw StorageError.cancelled
        } catch {
            try? fm.removeItem(at: dst); throw error
        }
        // Every copy verified → the source can go. If THIS fails the model is simply present twice; never lost.
        try fm.removeItem(at: src)
    }

    /// Size — and, when asked, SHA-256 — of `copy` must equal `src`.
    static func check(src: URL, copy: URL, verify: Verify) throws {
        let a = Int64((try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        let b = Int64((try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2)
        guard a == b else { throw StorageError.verifyFailed(file: src.lastPathComponent, reason: "size \(b) ≠ \(a)") }
        let hash: Bool = switch verify { case .size: false; case .sha256: true; case .sha256Below(let limit): a <= limit }
        if hash {
            let ha = try sha256(of: src), hb = try sha256(of: copy)
            guard ha == hb else { throw StorageError.verifyFailed(file: src.lastPathComponent, reason: "checksum mismatch") }
        }
    }

    /// Streaming SHA-256 (8 MiB chunks) so a 4 GB weight file never sits in memory.
    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let kb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let ka, let kb else { return false }
        return ka.isEqual(kb)
    }

    /// Bytes of the regular files directly inside `dir` (what a model directory holds).
    public static func size(of dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
