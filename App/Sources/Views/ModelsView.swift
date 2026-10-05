import SwiftUI
import Loopl
import LooplUI
import LooplRuntimes

/// "Model" — one list: the model in use, the ones on this device, the rest of
/// the catalog. Tap to switch (downloads first if needed), swipe left to delete.
struct ModelsView: View {
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings
    @State private var confirmDelete: ModelSpec?
    @Namespace private var zoom
    @Namespace private var loadedMark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// On this device (loaded first) · From Hugging Face · Recommended · Recommended GGUF.
    private var sections: [(String, [ModelSpec])] {
        var out: [(String, [ModelSpec])] = []
        let available = store.catalog.models.filter { $0.runtime != .appleFM || AppleFoundationModel.availability().available }
        func onDevice(_ s: ModelSpec) -> Bool { !s.isDownloadable || (store.states[s.id]?.isDownloaded ?? false) || engine.loadedModel?.id == s.id }
        let here = available.filter(onDevice).sorted { a, b in (engine.loadedModel?.id == a.id) && engine.loadedModel?.id != b.id }
        let rest = available.filter { !onDevice($0) }
        let hub = rest.filter(\.isFromHub)
        let curated = rest.filter { !$0.isFromHub && $0.runtime != .gguf }
        let gguf = rest.filter { !$0.isFromHub && $0.runtime == .gguf }
        if !here.isEmpty { out.append(("On this device", here)) }
        if !hub.isEmpty { out.append(("From Hugging Face", hub)) }
        if !curated.isEmpty { out.append(("Recommended", curated)) }
        if !gguf.isEmpty { out.append(("Recommended · GGUF", gguf)) }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        HubBrowseView(engine: engine, store: store, settings: settings)
                            .navigationTransition(.zoom(sourceID: "browse", in: zoom))
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Browse Hugging Face").font(.body.weight(.medium))
                                Text("Any public MLX or GGUF repo — no account").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "magnifyingglass").foregroundStyle(LooplDesign.accent) }
                        .matchedTransitionSource(id: "browse", in: zoom)
                    }
                    .accessibilityIdentifier("models-browse-hub")
                }
                ForEach(sections, id: \.0) { title, rows in
                    Section {
                        ForEach(rows) { spec in row(spec) }
                    } header: { Text(title) } footer: {
                        if title == "Recommended" { Text("Tap a model to use it — it downloads once, then runs offline. Context and output length are set to the model's recommended maximum automatically.") }
                        if title == "From Hugging Face" { Text("Added from Browse. Swipe left to remove a row and its weights.") }
                    }
                }
                Section {
                    LabeledContent("On this device", value: ByteCountFormatter.string(fromByteCount: store.diskUsed, countStyle: .file))
                    LabeledContent("Memory available to loopl", value: MemoryBudget.label(MemoryBudget.available))
                    if settings.offline { Label("Offline mode is on — downloads are refused, models on the device still load.", systemImage: LooplDesign.iconOffline).font(.footnote).foregroundStyle(.orange) }
                } footer: { Text("Catalog v\(store.catalog.version) · \(store.catalog.updated)") }
            }
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: sections.map { $0.1.map(\.id) })
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: engine.loadedModel?.id)
            .animation(LooplDesign.Motion.crossfade, value: engine.readiness.isBusy)
            .navigationTitle("Model")
            .refreshable { store.refresh() }
            .onAppear { store.refresh() }
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
                guard !busy, !isLoaded, !engine.isGenerating else { return }
                LooplDesign.haptic(1)
                Task { await engine.select(spec) }
            } label: {
                HStack {
                    ModelPickerRow(spec: spec, loaded: isLoaded, downloaded: state.isDownloaded, loadedMark: loadedMark)
                    if busy { PulsingMark().frame(width: 16, height: 16).padding(.leading, 4).transition(.opacity) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(isLoaded ? "in use" : "switches to this model")
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
                Text(msg).font(.caption).foregroundStyle(.red)
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
            if spec.isFromHub {
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
            if spec.isFromHub { Button("Remove from loopl", systemImage: "trash", role: .destructive) { confirmDelete = spec } }
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
