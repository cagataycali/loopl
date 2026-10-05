import SwiftUI

struct ModelsView: View {
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("On disk", systemImage: "internaldrive")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: store.diskUsed, countStyle: .file)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Memory available to loopl", systemImage: "memorychip")
                        Spacer()
                        Text(MemoryBudget.label(MemoryBudget.available)).foregroundStyle(.secondary)
                    }
                    if settings.offline {
                        Label("Offline mode — downloads refused, local models still load", systemImage: LooplDesign.iconOffline).foregroundStyle(.orange).font(.footnote)
                    }
                } footer: {
                    Text("Catalog v\(store.catalog.version) · \(store.catalog.updated). Sizes are the repos' 4-bit safetensors; usable context is a RAM budget on an 8 GB phone, not a model limit.")
                }
                ForEach(RuntimeKind.allCases) { kind in
                    let rows = store.catalog.models.filter { $0.runtime == kind }
                    if !rows.isEmpty {
                        Section(kind.label) {
                            ForEach(rows) { spec in ModelRow(spec: spec, engine: engine, store: store, settings: settings) }
                        }
                    }
                }
            }
            .navigationTitle("Models")
            .refreshable { store.refresh() }
            .onAppear { store.refresh() }
        }
    }
}

struct ModelRow: View {
    var spec: ModelSpec
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings

    private var state: ModelStore.State { store.states[spec.id] ?? .notDownloaded }
    private var isLoaded: Bool { engine.loadedModel?.id == spec.id }
    private var availability: RuntimeAvailability {
        switch spec.runtime {
        case .mlx: MLXRuntime.availability()
        case .appleFM: AppleFMRuntime.availability()
        case .gguf: GGUFRuntime.availability()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.name).font(.headline)
                Spacer()
                if isLoaded { Pill(text: "loaded") }
                if spec.gated { Pill(text: "gated", tint: .orange) }
            }
            if !spec.repo.isEmpty { Text(spec.repo).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
            HStack(spacing: 10) {
                if spec.isDownloadable { meta("\(spec.sizeLabel)") }
                meta("\(spec.paramsB.formatted(.number.precision(.fractionLength(0...1))))B")
                meta("ctx \(spec.ctxNominal.formatted()) · use \(spec.ctxUsable8GB.formatted())")
                meta(spec.family.rawValue)
            }
            if let n = spec.notes { Text(n).font(.caption).foregroundStyle(.secondary) }
            if !MemoryBudget.fits(spec) && spec.isDownloadable {
                Label("Over the memory budget right now (needs ≈1.3× weights free)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if !availability.available {
                Label(availability.reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            controls
        }
        .padding(.vertical, 4)
    }

    private func meta(_ s: String) -> some View { Text(s).font(.caption2).foregroundStyle(.secondary) }

    @ViewBuilder private var controls: some View {
        switch state {
        case .downloading(let done, let total, let fd, let files):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · file \(min(fd + 1, max(files, 1)))/\(files)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Pause") { store.pause(spec) }.font(.caption)
                }
            }
        case .paused(let done, let total):
            HStack {
                Text("Paused · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of ≈\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Resume") { store.download(spec) }.disabled(settings.offline)
                Button("Delete", role: .destructive) { store.delete(spec) }
            }.buttonStyle(.bordered).controlSize(.small)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Text(msg).font(.caption).foregroundStyle(.red)
                HStack { Button("Retry") { store.download(spec) }.disabled(settings.offline); Button("Delete", role: .destructive) { store.delete(spec) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .downloaded(let bytes):
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " on disk").font(.caption).foregroundStyle(.secondary)
                Spacer()
                loadButton
                Button("Delete", role: .destructive) { if isLoaded { Task { await engine.unload() } }; store.delete(spec) }.buttonStyle(.bordered).controlSize(.small)
            }
        case .notDownloaded:
            HStack {
                Spacer()
                if spec.isDownloadable {
                    Button { LooplDesign.haptic(); store.download(spec) } label: { Label("Download", systemImage: LooplDesign.iconDownload) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(settings.offline || (spec.gated && !settings.hasToken))
                } else {
                    loadButton
                }
            }
        }
    }

    private var loadButton: some View {
        Button {
            LooplDesign.haptic(.medium)
            Task { if isLoaded { await engine.unload() } else { await engine.load(spec) } }
        } label: {
            if engine.loadProgress != nil && !isLoaded { ProgressView().controlSize(.mini) }
            else { Text(isLoaded ? "Unload" : "Load") }
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
        .disabled(engine.loadProgress != nil || (!availability.available && !settings.demoRuntime) || engine.isGenerating)
    }
}
