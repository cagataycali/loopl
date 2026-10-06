import SwiftUI
import UniformTypeIdentifiers
import Loopl
import LooplUI

/// Settings › Storage — where models live. The iPhone, plus any folder the
/// user granted on a USB-C drive (or another Files provider). Models move
/// between the two with a verified copy; a drive that is away keeps its
/// models in the catalog, dimmed.
struct StorageView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var store: ModelStore
    @State private var pickingFolder = false
    /// Non-nil while the picker is open to REPLACE this volume's grant (keeps its models).
    @State private var regranting: StorageLocations.Volume?
    @State private var pickError: String?
    @State private var confirmForget: StorageLocations.Volume?
    @State private var confirmClear = false
    @State private var confirmHistory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var storage: StorageLocations { store.storage }
    private var connectedVolumes: [StorageLocations.Volume] { storage.volumes.filter(\.connected) }
    /// Downloaded (or drive-bound, or moving) models — the ones that have somewhere to be.
    private var placed: [ModelSpec] {
        store.catalog.models.filter { s in
            guard s.isDownloadable, let st = store.states[s.id] else { return false }
            return st.isDownloaded || st.isMoving || st.driveBlocked
        }
    }

    var body: some View {
        Form {
            Section {
                VolumeRow(name: "This iPhone", detail: "Internal storage", connected: true,
                          used: store.diskUsed, free: storage.internalFree, system: "iphone")
                    .accessibilityIdentifier("storage-internal")
            } footer: {
                Text("Free space is what iOS lets a download use right now. loopl keeps \(ByteSize.label(ExternalStorage.headroom)) free on every volume.")
            }

            Section {
                ForEach(storage.volumes) { v in
                    VStack(alignment: .leading, spacing: 6) {
                        VolumeRow(name: v.name,
                                  detail: !v.connected ? "Not connected — plug it in to use its models"
                                        : v.usable ? "Folder “\(v.bookmark.folderName)”"
                                        : "Connected, but loopl can't read folder “\(v.bookmark.folderName)”",
                                  connected: v.usable, used: v.used, free: v.free, system: v.connected && !v.usable ? "externaldrive.badge.exclamationmark" : "externaldrive")
                        if v.connected, !v.usable {
                            Text(v.accessGranted ? "The folder could not be listed. Pick it again to renew the grant — your models stay where they are."
                                                 : "iOS refused access to the folder. Pick it again to renew the grant — your models stay where they are.")
                                .font(.caption).foregroundStyle(.orange)
                            Button { LooplDesign.haptic(1); regranting = v; pickingFolder = true } label: {
                                Label("Re-grant folder…", systemImage: "folder.badge.questionmark").font(.callout.weight(.semibold))
                            }
                            .accessibilityIdentifier("storage-regrant-\(v.name)")
                        }
                    }
                        .accessibilityIdentifier("storage-volume-\(v.name)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { confirmForget = v } label: { Label("Forget", systemImage: "eject") }
                        }
                        .contextMenu {
                            Button("Re-grant folder…", systemImage: "folder.badge.questionmark") { regranting = v; pickingFolder = true }
                            Button("Forget this drive", systemImage: "eject", role: .destructive) { confirmForget = v }
                        }
                }
                Button {
                    LooplDesign.haptic(1); pickingFolder = true
                } label: {
                    Label(storage.volumes.isEmpty ? "Use an external drive…" : "Add another drive…", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("storage-add-drive")
                if let pickError { Text(pickError).font(.caption).foregroundStyle(.red) }
            } header: { Text("External drives") } footer: {
                Text("Plug a USB-C drive into the iPhone and pick a folder on it. loopl only ever reads and writes inside that folder. Weights load more slowly from a drive than from the iPhone's own flash — on a USB 3 phone a 0.8B model takes a few seconds, on USB 2 about a minute.")
            }

            if !storage.volumes.isEmpty {
                Section {
                    Picker(selection: Binding(get: { storage.downloadTarget ?? "" }, set: { storage.downloadTarget = $0.isEmpty ? nil : $0 })) {
                        Text("This iPhone").tag("")
                        ForEach(storage.volumes) { v in
                            Text(v.connected ? v.name : "\(v.name) (not connected)").tag(v.id)
                        }
                    } label: { Label("Download new models to", systemImage: LooplDesign.iconDownload) }
                    .accessibilityIdentifier("storage-download-target")
                } footer: {
                    Text("When the chosen drive is away or full, downloads fall back to the iPhone; when the iPhone is full, to any connected drive with room.")
                }
            }

            if !placed.isEmpty {
                Section {
                    ForEach(placed) { spec in modelRow(spec) }
                } header: { Text("Models") } footer: {
                    if let err = store.lastMoveError { Text(err).foregroundStyle(.red) }
                    else { Text("Moving copies every file, checks each copy, then removes the original — a move that stops half-way leaves the model where it was.") }
                }
            }

            Section {
                Button("Delete all downloaded models", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Delete every downloaded model?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Delete all", role: .destructive) { Task { await engine.unload() }; store.deleteAll(); settings.lastModelId = nil }
                    }
                Button("Delete conversation history", role: .destructive) { confirmHistory = true }
                    .confirmationDialog("Delete all saved conversations?", isPresented: $confirmHistory, titleVisibility: .visible) {
                        Button("Delete history", role: .destructive) { engine.archive.deleteAll(); engine.clear() }
                    }
                    .disabled(engine.archive.conversations.isEmpty)
            } footer: {
                if storage.volumes.contains(where: { !$0.connected }) {
                    Text("Models on a drive that is not connected are left alone — nothing on the phone to delete.")
                }
            }

            if !storage.volumes.isEmpty || FileManager.default.fileExists(atPath: storage.diagnostics.url.path) {
                Section {
                    ShareLink(item: storage.diagnostics.url) {
                        Label("Diagnostics", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(!FileManager.default.fileExists(atPath: storage.diagnostics.url.path))
                    .accessibilityIdentifier("storage-diagnostics")
                } footer: {
                    Text("A small log of what happened with each drive (grant, mount, listing, writes). Share it when a drive misbehaves.")
                }
            }
        }
        .looplScrollClearance()
        .accessibilityIdentifier("pane-storage")
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: storage.volumes.map(\.connected))
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: placed.map(\.id))
        .onAppear { store.refresh() }
        .onChange(of: scenePhase) { _, p in if p == .active { store.refresh() } }
        .sheet(isPresented: $pickingFolder, onDismiss: { regranting = nil }) {
            FolderPicker { url in
                guard let url else { return }
                do {
                    if let v = regranting { try storage.regrant(v.id, folder: url) } else { _ = try storage.add(folder: url) }
                    pickError = nil; store.refresh(); LooplDesign.success()
                }
                catch { pickError = error.localizedDescription; LooplDesign.failure() }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Forget \(confirmForget?.name ?? "")?", isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }), titleVisibility: .visible) {
            Button("Forget drive", role: .destructive) {
                if let v = confirmForget {
                    for spec in store.catalog.models where store.storage.location(of: spec.id).volumeId == v.id { engine.didDelete(spec) }
                    storage.forget(v.id); store.refresh(); LooplDesign.haptic()
                }
            }
        } message: { Text("The files stay on the drive. Its models leave this list until you pick the folder again.") }
    }

    @ViewBuilder private func modelRow(_ spec: ModelSpec) -> some View {
        let state = store.states[spec.id] ?? .notDownloaded
        let here = store.storage.location(of: spec.id).volumeId
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name).font(.body.weight(.medium))
                    Text(locationLine(spec, state)).font(.caption).foregroundStyle(state.driveBlocked ? Color.orange : Color.secondary)
                }
                Spacer()
                if state.isDownloaded {
                    Menu {
                        if here != nil { Button("Move to this iPhone", systemImage: "iphone") { store.move(spec, to: nil) } }
                        ForEach(connectedVolumes.filter { $0.id != here }) { v in
                            Button("Move to \(v.name)", systemImage: "externaldrive") { store.move(spec, to: v.id) }
                        }
                    } label: {
                        Label("Move", systemImage: "arrow.left.arrow.right").labelStyle(.titleOnly).font(.callout.weight(.semibold))
                    }
                    .disabled(connectedVolumes.filter { $0.id != here }.isEmpty && here == nil)
                    .disabled(engine.loadedModel?.id == spec.id && engine.isGenerating)
                    .accessibilityIdentifier("storage-move-\(spec.id)")
                }
            }
            if case .moving(let done, let total, let to) = state {
                HStack(spacing: 10) {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0).tint(LooplDesign.accent)
                    Text("→ \(to) · \(ByteSize.label(done)) of \(ByteSize.label(total))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Cancel") { store.cancelMove(spec) }.font(.caption.weight(.semibold))
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .opacity(state.driveBlocked ? 0.55 : 1)
        .accessibilityIdentifier("storage-model-\(spec.id)")
    }

    private func locationLine(_ spec: ModelSpec, _ state: ModelStore.State) -> String {
        switch state {
        case .needsDrive(let d): return "On \(d) — not connected"
        case .driveUnreadable(let d, _): return "On \(d) — connected, but can't be read (re-grant the folder)"
        case .moving: return "Moving…"
        case .downloaded(let bytes): return "\(ByteSize.label(bytes)) on \(store.locationName(spec))"
        default: return store.locationName(spec)
        }
    }
}

/// One volume: icon, name, connection dot, used / free.
struct VolumeRow: View {
    var name: String
    var detail: String
    var connected: Bool
    var used: Int64
    var free: Int64
    var system: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: system)
                .font(.title3)
                .foregroundStyle(connected ? LooplDesign.accent : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium))
                    Circle().fill(connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        .accessibilityLabel(connected ? "connected" : "not connected")
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if connected {
                    Text(used > 0 ? "\(ByteSize.label(free)) free · \(ByteSize.label(used)) used by loopl" : "\(ByteSize.label(free)) free")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(connected ? 1 : 0.6)
    }
}

/// The system folder picker. `onPick(nil)` on cancel.
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        vc.allowsMultipleSelection = false
        vc.shouldShowFileExtensions = false
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}

/// Simulator / UITest stand-in for a USB-C drive: `--storage-fixture <folder>`
/// grants `<folder>` as a drive named "SanDisk" holding a fake Qwen3.5-0.8B,
/// and adds a second drive "Old stick" whose folder is gone (= not connected)
/// holding Qwen3-1.7B. DEBUG only.
enum StorageFixture {
    /// `--free-space <bytes>`: every volume reports this much free (a full iPhone on the simulator). DEBUG only.
    static var freeSpace: Int64? {
        #if DEBUG
        guard let i = CommandLine.arguments.firstIndex(of: "--free-space"), i + 1 < CommandLine.arguments.count else { return nil }
        return Int64(CommandLine.arguments[i + 1])
        #else
        return nil
        #endif
    }

    static var folder: URL? {
        #if DEBUG
        guard let i = CommandLine.arguments.firstIndex(of: "--storage-fixture"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        #else
        return nil
        #endif
    }

    @MainActor static func apply(to store: ModelStore) {
        if let freeSpace {
            ExternalStorage.freeSpaceOverride = { _ in freeSpace }
            store.refresh()
        }
        guard let folder else { return }
        let fm = FileManager.default
        // Start from a clean manifest so the fixture is deterministic.
        for v in store.storage.volumes { store.storage.forget(v.id) }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let drive = try? store.storage.add(folder: folder, name: "SanDisk") else { return }
        if let qwen = store.catalog.models.first(where: { $0.id == "qwen3.5-0.8b-4bit" }), let t = store.storage.target(drive.id, for: qwen) {
            fake(model: t.url)
            store.storage.set(location: t.location, for: qwen.id)
        }
        // A drive that is not here: grant a folder, then make it vanish.
        let gone = fm.temporaryDirectory.appendingPathComponent("loopl-gone-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: gone, withIntermediateDirectories: true)
        if let old = try? store.storage.add(folder: gone, name: "Old stick"),
           let small = store.catalog.models.first(where: { $0.id == "qwen3-1.7b-4bit" }) {
            store.storage.set(location: .external(volumeId: old.id, relativePath: "loopl/x"), for: small.id)
            store.storage.downloadTarget = drive.id
        }
        try? fm.removeItem(at: gone)
        store.refresh()
    }

    /// config.json + a 1 MiB "safetensors" + tokenizer — enough for ModelStore to call it downloaded.
    static func fake(model dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(#"{"model_type":"qwen3"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        try? Data(count: 1 << 20).write(to: dir.appendingPathComponent("model.safetensors"))
        try? Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
    }
}
