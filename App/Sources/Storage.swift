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
    private var accessing: Set<String> = []

    public init(root: URL = ModelStore.root) {
        file = root.appendingPathComponent("storage.json")
        manifest = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(StorageManifest.self, from: $0) } ?? StorageManifest()
        resolveAll()
    }

    // MARK: Volumes

    /// Re-opens every bookmark and starts security-scoped access on the ones
    /// that resolve. Cheap; called at launch, on foreground, and after any change.
    public func resolveAll() {
        internalFree = ExternalStorage.freeSpace(at: ModelStore.root)
        volumes = manifest.volumes.map { b in
            guard let r = try? ExternalStorage.resolve(b) else {
                return Volume(bookmark: b, url: nil, connected: false, free: 0, used: 0)
            }
            if !accessing.contains(b.id), r.url.startAccessingSecurityScopedResource() { accessing.insert(b.id) }
            // A stale bookmark still resolved — refresh it so the next launch does not pay the lookup.
            if r.stale, let fresh = try? ExternalStorage.makeBookmark(for: r.url, name: b.name) {
                var nb = b; nb.bookmark = fresh.bookmark; nb.volumeUUID = fresh.volumeUUID
                if let i = manifest.volumes.firstIndex(where: { $0.id == b.id }) { manifest.volumes[i] = nb; persist() }
            }
            let connected = ExternalStorage.isReachable(r.url)
            let used = connected ? manifest.locations.values.reduce(Int64(0)) { sum, loc in
                guard case .external(let id, let rel) = loc, id == b.id else { return sum }
                return sum + ExternalStorage.size(of: r.url.appendingPathComponent(rel, isDirectory: true))
            } : 0
            return Volume(bookmark: b, url: r.url, connected: connected, free: connected ? ExternalStorage.freeSpace(at: r.url) : 0, used: used)
        }
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
        if accessing.remove(id) != nil, let u = volume(id)?.url { u.stopAccessingSecurityScopedResource() }
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
            guard let v = volume(id), v.connected, let url = v.url else { return nil }
            return url.appendingPathComponent(rel, isDirectory: true)
        }
    }

    /// Name of the drive a model needs that is not here right now, else nil.
    public func missingDrive(for spec: ModelSpec) -> String? {
        guard case .external(let id, _) = location(of: spec.id) else { return nil }
        let v = volume(id)
        return (v?.connected ?? false) ? nil : (v?.name ?? "a removed drive")
    }

    /// Resolves a location for a NEW copy of `spec`: the iPhone, or `relativePath` under the drive.
    public func target(_ volumeId: String?, for spec: ModelSpec) -> (location: ModelLocation, url: URL)? {
        guard let volumeId else { return (.internalStorage, ModelStore.directory(for: spec)) }
        guard let v = volume(volumeId), v.connected, let base = v.url else { return nil }
        let rel = "loopl/" + spec.repo.replacingOccurrences(of: "/", with: "--")
        return (.external(volumeId: volumeId, relativePath: rel), base.appendingPathComponent(rel, isDirectory: true))
    }

    /// Free space of a target: the drive, or the iPhone when `volumeId` is nil / away.
    public func free(on volumeId: String?) -> Int64 {
        guard let volumeId, let v = volume(volumeId), v.connected else { return internalFree }
        return v.free
    }

    public func name(of volumeId: String?) -> String { volumeId.flatMap { volume($0)?.name } ?? "This iPhone" }

    /// The drive downloads should default to: the chosen target when it is
    /// connected and `need` bytes fit there — or, when the iPhone cannot hold
    /// `need`, any connected drive that can.
    public func suggestedTarget(need: Int64) -> String? {
        if let t = downloadTarget, let v = volume(t), v.connected, v.free >= need + ExternalStorage.headroom { return t }
        if internalFree >= need + ExternalStorage.headroom { return nil }
        return volumes.first { $0.connected && $0.free >= need + ExternalStorage.headroom }?.id
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(manifest) { try? d.write(to: file, options: .atomic) }
    }
}
