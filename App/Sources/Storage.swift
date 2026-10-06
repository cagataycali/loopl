import Foundation
import Loopl
import Observation

/// The drives the user granted and where each model lives. One small JSON
/// (`storage.json`) next to the weights; every bookmark is re-resolved at
/// launch and kept under `startAccessingSecurityScopedResource` for as long
/// as the app runs — the model loaders open files under it directly.
///
/// A drive that is NOT plugged in is not an error: its row dims, its models
/// stay in the catalog as "needs <drive>", and `url(for:)` returns nil so
/// nothing tries to read from it.
@MainActor @Observable
public final class StorageLocations {
    public struct Volume: Identifiable, Hashable, Sendable {
        public var bookmark: StorageBookmark
        /// Resolved folder URL, nil when the bookmark no longer resolves (grant revoked / reformatted).
        public var url: URL?
        /// Reachable right now (plugged in and mounted).
        public var connected: Bool
        /// `startAccessingSecurityScopedResource()` succeeded (or the folder needs no scope).
        public var accessGranted: Bool = true
        /// Connected, but the folder cannot be listed — the grant did not take (iOS is picky about
        /// bookmarks to a removable volume's root, and about drives that mount after launch). Nil when fine.
        public var unreadableReason: String? = nil
        /// Connected + access granted + listable: the only state in which model directories are read.
        public var usable: Bool { connected && accessGranted && unreadableReason == nil }
        /// Free space on the drive, or 0 when it is away.
        public var free: Int64
        /// Bytes loopl keeps there (sum of the model directories it knows about).
        public var used: Int64
        public var invalid: Bool { url == nil }
        public var id: String { bookmark.id }
        public var name: String { bookmark.name }
    }

    public private(set) var manifest: StorageManifest
    public private(set) var volumes: [Volume] = []
    /// Free space on the iPhone (what iOS lets an important write use).
    public private(set) var internalFree: Int64 = 0
    private let file: URL
    /// Volumes whose security scope is open right now → the URL it was opened on (stop/start stay balanced).
    private var accessing: [String: URL] = [:]
    /// Facts about every resolve/access/listing step, for the Storage screen's Diagnostics row and bug reports.
    public let diagnostics: StorageDiagnostics
    private var lateMountRetry: Task<Void, Never>?

    public init(root: URL = ModelStore.root) {
        file = root.appendingPathComponent("storage.json")
        diagnostics = StorageDiagnostics(directory: root)
        manifest = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(StorageManifest.self, from: $0) } ?? StorageManifest()
        diagnostics.log("launch: \(manifest.volumes.count) volume(s), \(manifest.locations.filter { $0.value.isExternal }.count) external model(s)")
        resolveAll()
        retryLateMounts()
    }

    /// Drives mount a few seconds after the app comes up — re-resolve every 2 s
    /// for ~10 s, stopping as soon as every granted folder is usable.
    public func retryLateMounts(seconds: Int = 10) {
        guard volumes.contains(where: { !$0.usable }) else { return }
        lateMountRetry?.cancel()
        lateMountRetry = Task { [weak self] in
            for _ in 0..<(seconds / 2) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.resolveAll()
                if !self.volumes.contains(where: { !$0.usable }) { self.diagnostics.log("late-mount retry: all volumes usable"); return }
            }
        }
    }

    // MARK: Volumes

    /// Re-opens every bookmark and starts security-scoped access on the ones
    /// that resolve. Cheap; called at launch, on foreground, and after any change.
    public func resolveAll() {
        internalFree = ExternalStorage.freeSpace(at: ModelStore.root)
        let before = volumes
        volumes = manifest.volumes.map { b in
            let r: (url: URL, stale: Bool)
            do { r = try ExternalStorage.resolve(b) } catch {
                if let held = accessing.removeValue(forKey: b.id) { held.stopAccessingSecurityScopedResource() }
                diagnostics.log("\(b.name): resolve FAILED — \(error.localizedDescription)")
                return Volume(bookmark: b, url: nil, connected: false, free: 0, used: 0)
            }
            // Scope is per-URL: a bookmark that now resolves elsewhere gets the old scope closed first.
            if let held = accessing[b.id], held != r.url { held.stopAccessingSecurityScopedResource(); accessing[b.id] = nil }
            var granted = accessing[b.id] != nil
            if !granted {
                granted = r.url.startAccessingSecurityScopedResource()
                if granted { accessing[b.id] = r.url }
            }
            // A stale bookmark still resolved — refresh it so the next launch does not pay the lookup.
            if r.stale, let fresh = try? ExternalStorage.makeBookmark(for: r.url, name: b.name) {
                var nb = b; nb.bookmark = fresh.bookmark; nb.volumeUUID = fresh.volumeUUID
                if let i = manifest.volumes.firstIndex(where: { $0.id == b.id }) { manifest.volumes[i] = nb; persist() }
                diagnostics.log("\(b.name): bookmark was stale, re-made")
            }
            let readiness = ExternalStorage.readiness(of: r.url, accessGranted: granted)
            let connected = readiness != .unreachable
            // Without the scope iOS may still let us list the folder (same-app grant) — go by the listing; a
            // refused scope with a listable folder is only noted, a refused scope with a failed listing is the fault.
            let unreadable: String? = readiness.reason
            let used = readiness.isReadable ? manifest.locations.values.reduce(Int64(0)) { sum, loc in
                guard case .external(let id, let rel) = loc, id == b.id else { return sum }
                return sum + ExternalStorage.size(of: r.url.appendingPathComponent(rel, isDirectory: true))
            } : 0
            let v = Volume(bookmark: b, url: r.url, connected: connected, accessGranted: granted, unreadableReason: unreadable,
                           free: readiness.isReadable ? ExternalStorage.freeSpace(at: r.url) : 0, used: used)
            if before.first(where: { $0.id == b.id }).map({ $0.connected != v.connected || $0.accessGranted != v.accessGranted || $0.unreadableReason != v.unreadableReason }) ?? true {
                diagnostics.log("\(b.name) [\(b.folderName)]: stale=\(r.stale) access=\(granted) reachable=\(connected) listing=\(readiness.isReadable ? "ok" : (unreadable ?? "n/a")) used=\(used) free=\(v.free)")
            }
            return v
        }
    }

    /// Replaces the bookmark of volume `id` with a fresh grant of `url` and
    /// keeps every model location (same id → `storage.json` entries untouched),
    /// so a refused grant is fixed with one picker tap and no re-download.
    public func regrant(_ id: String, folder url: URL) throws {
        guard let i = manifest.volumes.firstIndex(where: { $0.id == id }) else { _ = try add(folder: url); return }
        let fresh = try ExternalStorage.makeBookmark(for: url, name: manifest.volumes[i].name)
        if let held = accessing.removeValue(forKey: id) { held.stopAccessingSecurityScopedResource() }
        manifest.volumes[i].bookmark = fresh.bookmark
        manifest.volumes[i].folderName = fresh.folderName
        if manifest.volumes[i].volumeUUID != fresh.volumeUUID {
            diagnostics.log("\(fresh.name): re-grant picked a folder on a DIFFERENT volume (\(fresh.volumeUUID ?? "nil") vs \(manifest.volumes[i].volumeUUID ?? "nil")) — locations kept")
            manifest.volumes[i].volumeUUID = fresh.volumeUUID
        } else {
            diagnostics.log("\(fresh.name): re-granted folder \(fresh.folderName)")
        }
        persist(); resolveAll()
    }

    public func volume(_ id: String) -> Volume? { volumes.first { $0.id == id } }

    /// Adds a folder the picker returned (or, on the simulator, any folder) as a drive.
    @discardableResult
    public func add(folder url: URL, name: String? = nil) throws -> Volume {
        let b = try ExternalStorage.makeBookmark(for: url, name: name)
        // Same folder granted twice → keep the first grant, refresh its bookmark.
        if let i = manifest.volumes.firstIndex(where: { $0.folderName == b.folderName && $0.volumeUUID == b.volumeUUID && $0.volumeUUID != nil }) {
            manifest.volumes[i].bookmark = b.bookmark
        } else {
            manifest.volumes.append(b)
            if manifest.downloadTarget == nil { manifest.downloadTarget = b.id }
        }
        persist(); resolveAll()
        return volume(b.id) ?? volumes.last!
    }

    /// Forgets a drive. Files on it are left alone; the models that lived there
    /// leave the catalog's "downloaded" set (they come back if the folder is granted again).
    public func forget(_ id: String) {
        if let held = accessing.removeValue(forKey: id) { held.stopAccessingSecurityScopedResource() }
        diagnostics.log("\(volume(id)?.name ?? id): forgotten")
        manifest.volumes.removeAll { $0.id == id }
        manifest.locations = manifest.locations.filter { $0.value.volumeId != id }
        if manifest.downloadTarget == id { manifest.downloadTarget = nil }
        persist(); resolveAll()
    }

    // MARK: Locations

    public func location(of modelId: String) -> ModelLocation { manifest.location(of: modelId) }

    public func set(location: ModelLocation, for modelId: String) {
        if location == .internalStorage { manifest.locations[modelId] = nil } else { manifest.locations[modelId] = location }
        persist()
    }

    /// Where new downloads go: a connected drive the user chose, else the iPhone.
    public var downloadTarget: String? {
        get { manifest.downloadTarget }
        set { manifest.downloadTarget = newValue; persist() }
    }

    /// The directory a model's files live in, or nil when it sits on a drive
    /// that is not plugged in (or whose grant is gone).
    public func directory(for spec: ModelSpec) -> URL? {
        switch location(of: spec.id) {
        case .internalStorage: return ModelStore.directory(for: spec)
        case .external(let id, let rel):
            // Only a usable volume: "can't read the drive" must never look like "no files here".
            guard let v = volume(id), v.usable, let url = v.url else { return nil }
            return url.appendingPathComponent(rel, isDirectory: true)
        }
    }

    /// Name of the drive a model needs that is not here right now, else nil.
    public func missingDrive(for spec: ModelSpec) -> String? {
        guard case .external(let id, _) = location(of: spec.id) else { return nil }
        let v = volume(id)
        return (v?.connected ?? false) ? nil : (v?.name ?? "a removed drive")
    }

    /// The connected drive a model sits on that loopl cannot read right now (grant refused), with the reason.
    public func unreadableDrive(for spec: ModelSpec) -> (name: String, reason: String)? {
        guard case .external(let id, _) = location(of: spec.id), let v = volume(id), v.connected, !v.usable else { return nil }
        return (v.name, v.unreadableReason ?? (v.accessGranted ? "folder not listable" : "iOS refused access to the folder"))
    }

    /// Any drive that is connected but not readable, else nil.
    public func anyDriveProblem(for spec: ModelSpec) -> String? {
        if let d = missingDrive(for: spec) { return "\(spec.name) is on \(d). Plug it in to use it." }
        if let u = unreadableDrive(for: spec) { return "\(u.name) is connected but loopl can't read it — re-grant its folder in Settings › Storage. (\(u.reason))" }
        return nil
    }

    /// Resolves a location for a NEW copy of `spec`: the iPhone, or `relativePath` under the drive.
    public func target(_ volumeId: String?, for spec: ModelSpec) -> (location: ModelLocation, url: URL)? {
        guard let volumeId else { return (.internalStorage, ModelStore.directory(for: spec)) }
        guard let v = volume(volumeId), v.usable, let base = v.url else { return nil }
        let rel = "loopl/" + spec.repo.replacingOccurrences(of: "/", with: "--")
        return (.external(volumeId: volumeId, relativePath: rel), base.appendingPathComponent(rel, isDirectory: true))
    }

    /// Free space of a target: the drive, or the iPhone when `volumeId` is nil / away.
    public func free(on volumeId: String?) -> Int64 {
        guard let volumeId, let v = volume(volumeId), v.usable else { return internalFree }
        return v.free
    }

    public func name(of volumeId: String?) -> String { volumeId.flatMap { volume($0)?.name } ?? "This iPhone" }

    /// The drive downloads should default to: the chosen target when it is
    /// connected and `need` bytes fit there — or, when the iPhone cannot hold
    /// `need`, any connected drive that can.
    public func suggestedTarget(need: Int64) -> String? {
        if let t = downloadTarget, let v = volume(t), v.usable, v.free >= need + ExternalStorage.headroom { return t }
        if internalFree >= need + ExternalStorage.headroom { return nil }
        return volumes.first { $0.usable && $0.free >= need + ExternalStorage.headroom }?.id
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(manifest) { try? d.write(to: file, options: .atomic) }
    }
}
