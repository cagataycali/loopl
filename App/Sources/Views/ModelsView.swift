import SwiftUI
import Loopl
import LooplUI
import LooplRuntimes

/// "Models" — one list: the model in use, the ones on this device, the rest of
/// the catalog. Tap to switch (downloads first if needed), swipe left to delete.
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
    @Namespace private var zoom
    @Namespace private var loadedMark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// On this device (loaded first) · From Hugging Face · Recommended · Recommended GGUF.
    private var sections: [(String, [ModelSpec])] {
        var out: [(String, [ModelSpec])] = []
        let available = store.catalog.models.filter { $0.runtime != .appleFM || AppleFoundationModel.availability().available }
        func onDevice(_ s: ModelSpec) -> Bool {
            guard let st = store.states[s.id] else { return !s.isDownloadable || engine.loadedModel?.id == s.id }
            return !s.isDownloadable || st.isDownloaded || st.isMoving || st.driveBlocked || engine.loadedModel?.id == s.id
        }
        let here = available.filter(onDevice).sorted { a, b in (engine.loadedModel?.id == a.id) && engine.loadedModel?.id != b.id }
        // A model never appears twice: curated models.json rows for repos the collection section lists stay as the
        // bundled fallback only (they still show under "On this device" once downloaded).
        let inCollection = collection.repoIds
        let rest = available.filter { !onDevice($0) && !inCollection.contains($0.repo) }
        let hub = rest.filter(\.isFromHub)
        let curated = rest.filter { !$0.isFromHub && $0.runtime != .gguf }
        let gguf = rest.filter { !$0.isFromHub && $0.runtime == .gguf }
        if !here.isEmpty { out.append((store.storage.volumes.isEmpty ? "On this device" : "Downloaded", here)) }
        if !hub.isEmpty { out.append(("From Hugging Face", hub)) }
        if !curated.isEmpty { out.append(("Recommended", curated)) }
        if !gguf.isEmpty { out.append(("Recommended · GGUF", gguf)) }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                // The loopl models first: whoever installs the app sees them before anything else.
                CollectionSection(engine: engine, store: store, settings: settings, hf: engine.hf, model: collection, selected: $collectionSelected, zoom: zoom)
                Section {
                    NavigationLink {
                        HubBrowseView(engine: engine, store: store, settings: settings)
                            .navigationTransition(.zoom(sourceID: "browse", in: zoom))
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Browse Hugging Face").font(.body.weight(.medium))
                                Text(engine.hf.isSignedIn ? "Any MLX or GGUF repo — yours too, private included" : "Any public MLX or GGUF repo — no account needed").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "magnifyingglass").foregroundStyle(LooplDesign.accent) }
                        .matchedTransitionSource(id: "browse", in: zoom)
                    }
                    .accessibilityIdentifier("models-browse-hub")
                    NavigationLink {
                        TrainView(engine: engine, store: store, settings: settings)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Train your own").font(.body.weight(.medium))
                                Text("Post-tune Qwen3.5 on your conversations — on Hugging Face, in your account").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "sparkles").foregroundStyle(LooplDesign.accent) }
                    }
                    .accessibilityIdentifier("models-train")
                }
                MineSection(engine: engine, store: store, settings: settings, hf: engine.hf, mine: mine, selected: $mineSelected, zoom: zoom)
                ForEach(sections, id: \.0) { title, rows in
                    Section {
                        ForEach(rows) { spec in row(spec) }
                    } header: { Text(title) } footer: {
                        if title == "Recommended" { Text("Tap a model to use it — it downloads once, then runs offline. Context and output length are set to the model's recommended maximum automatically.") }
                        if title == "From Hugging Face" { Text("Added from Browse. Swipe left to remove a row and its weights.") }
                    }
                }
                Section {
                    LabeledContent("On this device", value: ByteSize.label(store.diskUsed))
                    ForEach(store.storage.volumes) { v in
                        LabeledContent("On \(v.name)", value: v.connected ? ByteSize.label(v.used) : "not connected")
                    }
                    LabeledContent("Memory available to loopl", value: MemoryBudget.label(MemoryBudget.available))
                    if settings.offline { Label("Offline mode is on — downloads are refused, models on the device still load.", systemImage: LooplDesign.iconOffline).font(.footnote).foregroundStyle(.orange) }
                } footer: {
                    // Nothing downloaded yet is an empty shelf, not an error: say so in one line.
                    Text(store.diskUsed == 0
                         ? "No weights on this device yet — tap a model above and it downloads once, then runs offline. Catalog v\(store.catalog.version) · \(store.catalog.updated)"
                         : "Catalog v\(store.catalog.version) · \(store.catalog.updated)")
                }
            }
            .looplScrollClearance()
            .navigationDestination(isPresented: $trainFixturePushed) {
                TrainView(engine: engine, store: store, settings: settings, fixture: DesignFixture.trainSession(), fixtureSignedIn: DesignFixture.trainScene != nil)
            }
            .accessibilityIdentifier("pane-models")
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: sections.map { $0.1.map(\.id) })
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

    @ViewBuilder private func row(_ spec: ModelSpec) -> some View {
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
                    ModelPickerRow(spec: spec, loaded: isLoaded, downloaded: state.isDownloaded, loadedMark: loadedMark)
                    if busy { PulsingMark().frame(width: 16, height: 16).padding(.leading, 4).transition(.opacity) }
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

    private func delete(_ spec: ModelSpec) {
        withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) {
            engine.didDelete(spec)
            if spec.isFromHub { store.remove(spec) } else { store.delete(spec) }
        }
        LooplDesign.haptic()
    }
}
