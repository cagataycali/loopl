import SwiftUI
import Loopl
import LooplUI
import LooplRuntimes

/// "Models" — one list in the order a first-time user needs it (owner, 2026-10-06): 1 On this iPhone (what is here,
/// the one in use marked, swipe left to delete) · 2 Browse Hugging Face · 3 Train your own · 4 loopl models (the
/// collection; GGUF builds and the rest of the curated catalog fold under it) · 5 Mine · then one **Storage** block LAST
/// (used AND free bytes on this iPhone and each drive, memory for a model, catalog line, a link to Settings › Storage —
/// the owner asked "how much space do we have" back after #112 folded it into a caption). Never the same repo twice.
/// Tap a row to switch (it downloads first if needed).
struct ModelsView: View {
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings
    @State private var confirmDelete: ModelSpec?
    @State private var mine = MineModel()
    @State private var trainFixturePushed = DesignFixture.trainScene != nil
    /// Mine row tapped → repo sheet. Presented HERE, from the List — see MineSection.selected.
    @State private var mineSelected: HubCatalog.Hit?
    /// The loopl collection (Models › "loopl models", top). Its tapped row → repo sheet, presented here like Mine's.
    @State private var collection = CollectionModel()
    @State private var collectionSelected: HubCatalog.Hit?
    /// "More models" (the curated catalog beyond the featured loopl models) starts folded.
    @State private var showMore = false
    @Namespace private var zoom
    @Namespace private var loadedMark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The models that are HERE (or arriving): downloaded, downloading, paused, failed, on a drive, moving, built in, in use.
    /// The one in use sorts first. A download in flight belongs on this shelf — its progress must never hide in a folded list.
    private var available: [ModelSpec] { store.catalog.models.filter { $0.runtime != .appleFM || AppleFoundationModel.availability().available } }
    private func onDevice(_ s: ModelSpec) -> Bool {
        guard let st = store.states[s.id] else { return !s.isDownloadable || engine.loadedModel?.id == s.id }
        if engine.loadedModel?.id == s.id || !s.isDownloadable { return true }
        switch st {
        case .downloaded, .downloading, .paused, .failed, .needsDrive, .driveUnreadable, .moving: return true
        case .notDownloaded: return false
        }
    }
    private var here: [ModelSpec] {
        available.filter(onDevice).sorted { a, b in (engine.loadedModel?.id == a.id) && engine.loadedModel?.id != b.id }
    }
    /// Everything else, with no repo twice: the collection section already lists the loopl models, so their models.json
    /// twins stay a bundled fallback only (they reappear under "On this iPhone" once downloaded).
    private var rest: [ModelSpec] {
        let inCollection = collection.repoIds
        var seen: Set<String> = []
        return available.filter { !onDevice($0) && !inCollection.contains($0.repo) && seen.insert($0.repo.isEmpty ? $0.id : $0.repo).inserted }
    }
    /// Added from Browse, not downloaded yet — they sit under the Browse row they came from.
    private var hub: [ModelSpec] { rest.filter(\.isFromHub) }
    /// The curated catalog beyond the loopl models — folded behind one "More models" row under the loopl models.
    private var curated: [ModelSpec] { rest.filter { !$0.isFromHub && $0.runtime != .gguf } }
    private var gguf: [ModelSpec] { rest.filter { !$0.isFromHub && $0.runtime == .gguf } }
    /// Header of section 1: the device this is — a model on a drive carries its own "On SanDisk" line.
    private var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    /// For the section-order test and the animation key: the headers, top to bottom, as a first-time user reads them.
    static let sectionOrder = ["On this iPhone", "Browse Hugging Face", "Your own model", "loopl models", "Mine", "Storage"]

    var body: some View {
        NavigationStack {
            List {
                // 1 — what is on the phone. Empty = a calm shelf, not an error; the hint points down at where models come from.
                Section {
                    ForEach(here) { spec in row(spec, onDevice: true) }
                    if !here.contains(where: \.isDownloadable) {
                        // Nothing downloaded (Apple Intelligence may still be here): one calm line pointing at where models come from.
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                if here.isEmpty { Text("Nothing downloaded yet").font(.body.weight(.medium)) }
                                Text("Get a model ↓ — pick a loopl model below, or browse Hugging Face. It downloads once, then runs offline.")
                                    .font(here.isEmpty ? .caption : .footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: { Image(systemName: "arrow.down.circle").foregroundStyle(LooplDesign.accent) }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("models-empty")
                    }
                    if settings.offline {
                        Label("Offline mode is on — downloads are refused, models on this \(deviceName) still load.", systemImage: LooplDesign.iconOffline).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("On this \(deviceName)").accessibilityIdentifier("models-header-device")
                }
                // 2 — Browse (and the repos added from it that are not here yet).
                Section {
                    NavigationLink {
                        HubBrowseView(engine: engine, store: store, settings: settings)
                            .navigationTransition(.zoom(sourceID: "browse", in: zoom))
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Search models").font(.body.weight(.medium))
                                Text(engine.hf.isSignedIn ? "Any model on Hugging Face — yours too, private included" : "Any public model on Hugging Face — no account needed").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "magnifyingglass").foregroundStyle(LooplDesign.accent) }
                        .matchedTransitionSource(id: "browse", in: zoom)
                    }
                    .accessibilityIdentifier("models-browse-hub")
                    ForEach(hub) { spec in row(spec) }
                } header: {
                    Text("Browse Hugging Face").accessibilityIdentifier("models-header-browse")
                } footer: {
                    if !hub.isEmpty { Text("Added from Browse. Swipe left to remove a row and its weights.") }
                }
                // 3 — Train.
                Section {
                    NavigationLink {
                        TrainView(engine: engine, store: store, settings: settings)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Train your own").font(.body.weight(.medium))
                                Text("Teach a model from your conversations — on Hugging Face, in your account").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "sparkles").foregroundStyle(LooplDesign.accent) }
                    }
                    .accessibilityIdentifier("models-train")
                } header: {
                    // Not "Train your own" again — the row already says it (IMPROVE-3 audit #12).
                    Text("Your own model").accessibilityIdentifier("models-header-train")
                }
                // 4 — the loopl models (the collection), with the GGUF builds and the rest of the catalog folded under them.
                CollectionSection(engine: engine, store: store, settings: settings, hf: engine.hf, model: collection, selected: $collectionSelected, zoom: zoom) {
                    moreRows
                }
                // 5 — the user's own repos.
                MineSection(engine: engine, store: store, settings: settings, hf: engine.hf, mine: mine, selected: $mineSelected, zoom: zoom)
                // Last — how much space there is. Readable rows, not a caption: used AND free here and on every drive.
                storageSection
            }
            .looplScrollClearance()
            .navigationDestination(isPresented: $trainFixturePushed) {
                TrainView(engine: engine, store: store, settings: settings, fixture: DesignFixture.trainSession(), fixtureSignedIn: DesignFixture.trainScene != nil)
            }
            .accessibilityIdentifier("pane-models")
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: here.map(\.id) + hub.map(\.id))
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: engine.loadedModel?.id)
            .animation(LooplDesign.Motion.crossfade, value: engine.readiness.isBusy)
            .navigationTitle("Models")
            .refreshable {
                store.refresh()
                async let a: Void = mine.load(author: engine.hf.author, force: true)
                async let b: Void = collection.load(author: engine.hf.author, force: true)
                _ = await (a, b)
            }
            .onAppear { store.refresh() }
            .sheet(item: $mineSelected) { hit in
                HubRepoSheet(repoId: hit.id, hint: hit, engine: engine, store: store, settings: settings) {}
                    .navigationTransition(.zoom(sourceID: "mine-\(hit.id)", in: zoom))
            }
            .sheet(item: $collectionSelected) { hit in
                HubRepoSheet(repoId: hit.id, hint: hit, engine: engine, store: store, settings: settings) {}
                    .navigationTransition(.zoom(sourceID: "collection-\(hit.id)", in: zoom))
            }
            .confirmationDialog("\(confirmDelete?.isFromHub == true ? "Remove" : "Delete") \(confirmDelete?.name ?? "") from this device?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button(confirmDelete?.isFromHub == true ? "Remove" : "Delete", role: .destructive) { if let s = confirmDelete { delete(s) } }
            }
        }
    }

    // MARK: Storage (last section)

    /// The Storage block: this iPhone (used · free), each remembered drive (used · free, or not connected), memory a model
    /// can take, the catalog line, and the way to Settings › Storage (move models, add a drive). Identifiers for the tests.
    @ViewBuilder private var storageSection: some View {
        Section {
            storageRow(system: "iphone", name: "On this \(deviceName)", value: StorageReadout.spaceLine(used: store.diskUsed, free: store.storage.internalFree), connected: true)
                .accessibilityIdentifier("models-storage")
            ForEach(store.storage.volumes) { v in
                storageRow(system: v.connected && !v.usable ? "externaldrive.badge.exclamationmark" : "externaldrive", name: v.name,
                           value: StorageReadout.volumeLine(connected: v.connected, usable: v.usable, used: v.used, free: v.free),
                           connected: v.usable)
                    .accessibilityIdentifier("models-storage-volume-\(v.name)")
            }
            if MemoryBudget.available > 0 {
                storageRow(system: "memorychip", name: "Memory for a model", value: MemoryBudget.label(MemoryBudget.available), connected: true)
                    .accessibilityIdentifier("models-storage-memory")
            }
            NavigationLink {
                StorageView(engine: engine, settings: settings, store: store)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings › Storage").font(.body.weight(.medium))
                        Text(store.storage.volumes.isEmpty ? "Move models to a USB-C drive, see what takes the space" : "Move models between this \(deviceName) and your drives").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "internaldrive").foregroundStyle(LooplDesign.accent) }
            }
            .accessibilityIdentifier("models-storage-settings")
        } header: {
            Text("Storage").accessibilityIdentifier("models-header-storage")
        } footer: {
            Text("Free space is what iOS lets a download use right now. Catalog v\(store.catalog.version) · \(store.catalog.updated)")
                .accessibilityIdentifier("models-catalog")
        }
    }

    /// One readable storage row: glyph · name · the numbers, read as one element ("On this iPhone, 2.1 GB used · 54 GB free").
    private func storageRow(system: String, name: String, value: String, connected: Bool) -> some View {
        Label {
            LabeledContent(name) {
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(connected ? .primary : .secondary)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        } icon: { Image(systemName: system).foregroundStyle(connected ? LooplDesign.accent : .secondary) }
        .accessibilityElement(children: .combine)
    }

    /// "More models" — the curated catalog the app is tested with, folded behind one row under the loopl models
    /// (and the GGUF builds of it when Settings shows GGUF). Opening it never reorders the sections above.
    @ViewBuilder private var moreRows: some View {
        if !curated.isEmpty {
            Button {
                LooplDesign.haptic(1)
                withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { showMore.toggle() }
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("More models").font(.body.weight(.medium))
                            Text(showMore ? "Qwen3, Qwen3-VL, Llama 3.2, Gemma 3, Phi-4 mini, SmolLM, DeepSeek — the models loopl is tested with"
                                          : "\(curated.count + (settings.showGGUF ? gguf.count : 0)) more the app is tested with — Qwen3, Llama 3.2, Gemma 3, Phi-4 mini…").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "square.stack.3d.up").foregroundStyle(LooplDesign.accent) }
                    Spacer()
                    DisclosureChevron(expanded: showMore, font: .footnote.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("models-more")
            .accessibilityAddTraits(.isButton)
            if showMore {
                ForEach(curated) { spec in row(spec) }
                if settings.showGGUF, !gguf.isEmpty {
                    Text("GGUF · llama.cpp · text only").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("models-more-gguf")
                    ForEach(gguf) { spec in row(spec) }
                }
            }
        }
    }

    /// `onDevice`: the row sits under "On this iPhone" — every row there is downloaded, so the ✓ would say the section's
    /// own title again and read as "selected" (IMPROVE-4 #7); only the ⚡ for the model in use stays.
    @ViewBuilder private func row(_ spec: ModelSpec, onDevice: Bool = false) -> some View {
        let state = store.states[spec.id] ?? .notDownloaded
        let isLoaded = engine.loadedModel?.id == spec.id
        let busy = engine.readiness.spec?.id == spec.id && engine.readiness.isBusy
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !busy, !isLoaded, !engine.isGenerating, !state.driveBlocked, !state.isMoving else { return }
                LooplDesign.haptic(1)
                Task { await engine.select(spec) }
            } label: {
                HStack {
                    ModelPickerRow(spec: spec, loaded: isLoaded, downloaded: state.isDownloaded, loadedMark: loadedMark, downloading: progress(state), quietWhenDownloaded: onDevice)
                    if busy, !isLoaded { PulsingMark().frame(width: 16, height: 16).padding(.leading, 4).transition(.opacity) }
                }
            }
            .buttonStyle(.plain)
            .opacity(state.driveBlocked ? 0.55 : 1)
            .accessibilityHint(state.needsDrive.map { "on \($0), not connected" } ?? state.unreadableDrive.map { "on \($0), which can't be read" } ?? (isLoaded ? "in use" : "switches to this model"))
            if state.isDownloaded, store.storage.location(of: spec.id).isExternal {
                Label("On \(store.locationName(spec))", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("models-location-\(spec.id)")
            }
            switch state {
            case .downloading(let done, let total, let fd, let files):
                DownloadProgressRow(done: done, total: total, fileIndex: fd, fileCount: files) { store.pause(spec) }
            case .paused(let done, let total):
                HStack {
                    Text("Paused · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { Task { await engine.select(spec) } }.font(.caption.weight(.semibold)).disabled(settings.offline)
                }
            case .failed(let msg):
                HStack(alignment: .top) {
                    Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("models-failed-\(spec.id)")
                    Spacer(minLength: 8)
                    Button("Retry") { LooplDesign.haptic(1); Task { await engine.select(spec) } }
                        .font(.caption.weight(.semibold)).disabled(settings.offline || busy)
                        .accessibilityIdentifier("models-retry-\(spec.id)")
                }
            case .needsDrive(let drive):
                Label("Needs \(drive) — plug it in to use", systemImage: "externaldrive.badge.xmark").font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("models-needs-drive-\(spec.id)")
            case .driveUnreadable(let drive, _):
                Label("\(drive) is connected but loopl can't read it — re-grant its folder in Settings › Storage", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("models-drive-unreadable-\(spec.id)")
            case .moving(let done, let total, let to):
                HStack(spacing: 10) {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0).tint(LooplDesign.accent)
                    Text("Moving to \(to) · \(ByteSize.label(done)) of \(ByteSize.label(total))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            case .downloaded, .notDownloaded:
                #if !targetEnvironment(simulator)
                if !MemoryBudget.fits(spec) && spec.isDownloadable {
                    Label("Tight on memory right now (needs ≈1.3× the weights free)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                #else
                EmptyView()
                #endif
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if state.driveBlocked || state.isMoving {
                // Nothing on the phone to delete; a move in flight owns the files.
            } else if spec.isFromHub {
                Button(role: .destructive) { confirmDelete = spec } label: { Label("Remove", systemImage: "trash") }
            } else if spec.isDownloadable, state.isDownloaded || { if case .paused = state { return true }; return false }() {
                Button(role: .destructive) { confirmDelete = spec } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .contextMenu {
            if !isLoaded { Button("Use this model", systemImage: LooplDesign.iconLoaded) { Task { await engine.select(spec) } } }
            if !spec.repo.isEmpty {
                Button("Copy repo id", systemImage: "doc.on.doc") { copy(spec.repo) }
                Link(destination: URL(string: "https://huggingface.co/\(spec.repo)")!) { Label("Open on Hugging Face", systemImage: "safari") }
            }
            if state.isDownloaded {
                let here = store.storage.location(of: spec.id).volumeId
                let targets = store.storage.volumes.filter { $0.connected && $0.id != here }
                if here != nil || !targets.isEmpty {
                    Divider()
                    if here != nil { Button("Move to this iPhone", systemImage: "iphone") { store.move(spec, to: nil) } }
                    ForEach(targets) { v in Button("Move to \(v.name)", systemImage: "externaldrive") { store.move(spec, to: v.id) } }
                }
            }
            if state.driveBlocked || state.isMoving { /* not deletable from here */ }
            else if spec.isFromHub { Button("Remove from loopl", systemImage: "trash", role: .destructive) { confirmDelete = spec } }
            else if spec.isDownloadable, state.isDownloaded { Button("Delete from device", systemImage: "trash", role: .destructive) { confirmDelete = spec } }
        }
    }

    /// The ring's fraction while the weights arrive (or sit paused), nil otherwise — the row's single glyph.
    private func progress(_ state: ModelStore.State) -> Double? {
        switch state {
        case .downloading(let done, let total, _, _), .paused(let done, let total): return total > 0 ? Double(done) / Double(total) : 0
        default: return nil
        }
    }

    private func delete(_ spec: ModelSpec) {
        withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) {
            engine.didDelete(spec)
            if spec.isFromHub { store.remove(spec) } else { store.delete(spec) }
        }
        LooplDesign.haptic()
    }
}
