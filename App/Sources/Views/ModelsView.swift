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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sections: [(String, [ModelSpec])] {
        var out: [(String, [ModelSpec])] = []
        let available = store.catalog.models.filter { $0.runtime != .appleFM || AppleFoundationModel.availability().available }
        let gguf = available.filter { $0.runtime == .gguf }
        let others = available.filter { $0.runtime != .gguf }
        if !others.isEmpty { out.append(("Models", others)) }
        if !gguf.isEmpty { out.append(("GGUF · llama.cpp", gguf)) }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { title, rows in
                    Section {
                        ForEach(rows) { spec in row(spec) }
                    } header: { Text(title) } footer: {
                        if title == "Models" { Text("Tap a model to use it — it downloads once, then runs offline. Context and output length are set to the model's recommended maximum automatically.") }
                    }
                }
                Section {
                    LabeledContent("On this device", value: ByteCountFormatter.string(fromByteCount: store.diskUsed, countStyle: .file))
                    LabeledContent("Memory available to loopl", value: MemoryBudget.label(MemoryBudget.available))
                    if settings.offline { Label("Offline mode is on — downloads are refused, models on the device still load.", systemImage: LooplDesign.iconOffline).font(.footnote).foregroundStyle(.orange) }
                } footer: { Text("Catalog v\(store.catalog.version) · \(store.catalog.updated)") }
            }
            .navigationTitle("Model")
            .refreshable { store.refresh() }
            .onAppear { store.refresh() }
            .confirmationDialog("Delete \(confirmDelete?.name ?? "") from this device?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let s = confirmDelete { delete(s) } }
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
                    ModelPickerRow(spec: spec, loaded: isLoaded, downloaded: state.isDownloaded)
                    if busy { ProgressView().controlSize(.small).padding(.leading, 4) }
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
            if spec.isDownloadable, state.isDownloaded || { if case .paused = state { return true }; return false }() {
                Button(role: .destructive) { confirmDelete = spec } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .contextMenu {
            if !isLoaded { Button("Use this model", systemImage: LooplDesign.iconLoaded) { Task { await engine.select(spec) } } }
            if !spec.repo.isEmpty {
                Button("Copy repo id", systemImage: "doc.on.doc") { copy(spec.repo) }
                Link(destination: URL(string: "https://huggingface.co/\(spec.repo)")!) { Label("Open on Hugging Face", systemImage: "safari") }
            }
            if spec.isDownloadable, state.isDownloaded { Button("Delete from device", systemImage: "trash", role: .destructive) { confirmDelete = spec } }
        }
    }

    private func delete(_ spec: ModelSpec) {
        withAnimation(reduceMotion ? nil : LooplDesign.spring) {
            engine.didDelete(spec)
            store.delete(spec)
        }
        LooplDesign.haptic()
    }
}
