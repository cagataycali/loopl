import SwiftUI
import os
import Loopl
import LooplUI

/// "Browse Hugging Face" — any public repo, no account (private ones too once signed in). Search (MLX · GGUF), paste a
/// repo id, open the details sheet, pick a quant, download. The chosen spec joins
/// `ModelStore.hubModels` and the Models list takes over (progress, load, delete).
struct HubBrowseView: View {
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var kind: HubCatalog.Kind = .mlx
    @State private var hits: [HubCatalog.Hit] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selected: HubCatalog.Hit?
    @State private var pastedRepo: String?
    @State private var searchTask: Task<Void, Never>?
    @Namespace private var zoom
    /// Authenticated when a token is in the Keychain → private repos resolve; anonymous otherwise, exactly as before.
    private let hub = HubCatalog(token: HFAccount.shared.provider)

    /// "mlx-community/Qwen3-1.7B-4bit" or a full huggingface.co URL pasted into the search field.
    private var typedRepoId: String? {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = q.range(of: "huggingface.co/") { q = String(q[r.upperBound...]) }
        q = q.split(separator: "?").first.map(String.init) ?? q
        let parts = q.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty, !q.contains(" ") else { return nil }
        return parts[0] + "/" + parts[1].split(separator: "/").first.map(String.init)!
    }

    var body: some View {
        List {
            Section {
                Picker("Format", selection: $kind) {
                    ForEach(HubCatalog.Kind.allCases) { k in Text(k.label).tag(k) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: LooplDesign.gutter, bottom: 4, trailing: LooplDesign.gutter))
                .accessibilityIdentifier("hub-kind")
            } footer: {
                // said "mlx-community conversions — fastest on this iPhone (Metal)." /  "Any GGUF repo,
                // via llama.cpp. Pick the quant in the details." The format NAMES stay — they are the picker's own
                // labels and someone choosing between them needs them. What was missing is what the choice MEANS:
                // "conversions", "Metal", "repo" and "the quant" are four words that explain nothing to the person
                // deciding, and the GGUF sentence sent them to a screen without saying what they would choose there.
                Text(kind == .mlx
                     ? "Models converted by the mlx-community team — the fastest option on this iPhone."
                     : "Any GGUF model, run by llama.cpp. Open one to choose a size: smaller is faster, larger answers better.")
            }

            if let repo = typedRepoId {
                Section("Repo id") {
                    Button {
                        LooplDesign.haptic(); pastedRepo = repo
                    } label: {
                        Label { Text(repo).font(.body.monospaced()).lineLimit(1) } icon: { Image(systemName: "arrow.right.circle") }
                    }
                    .accessibilityIdentifier("hub-open-repo")
                }
            }

            if settings.offline {
                Section {
                    Label("Offline mode is on — results come from the cache; downloads are refused.", systemImage: LooplDesign.iconOffline)
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            if loading && hits.isEmpty {
                Section { ForEach(0..<6, id: \.self) { _ in SkeletonRow() } }
            } else if let error, hits.isEmpty {
                Section {
                    ContentUnavailableView { Label("Nothing to show", systemImage: LooplDesign.iconWarning) } description: { Text(error) } actions: {
                        Button("Try again") { search(immediate: true) }
                    }
                }
            } else if hits.isEmpty, typedRepoId == nil {
                Section { ContentUnavailableView.search(text: query) }
            } else if !hits.isEmpty {
                Section {
                    ForEach(hits) { hit in
                        Button { LooplDesign.haptic(); selected = hit } label: { HubHitRow(hit: hit, added: isAdded(hit)) }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: hit.id, in: zoom)
                            .accessibilityIdentifier("hub-hit-\(hit.id)")
                    }
                } header: {
                    Text(query.isEmpty ? "Most downloaded · \(kind.label)" : "\(hits.count) results · \(kind.label)")
                } footer: {
                    // said "Chat and instruct checkpoints only; gated repos are hidden. Sizes for MLX
                    // are estimated until you open the details." Two problems. "Checkpoint", "instruct", "gated"
                    // and "repo" are the packager's words. And the first clause was simply NOT TRUE: the filter is
                    // `Hit.isTextGeneration`, which drops speech, transcription, embedding and rerank models (and
                    // allows vision ones on MLX) — a plain base model passes it fine. This footer is the only place
                    // that explains why a model someone expects is missing, so being unreadable AND wrong here
                    // makes the search look broken.
                    Text("Most downloaded first. Models for speech, transcription and search are left out, and so are models that need the owner's permission on Hugging Face. Sizes here are an estimate until you open a model.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .looplScrollClearance()
        .navigationTitle("Hugging Face")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models or paste a repo id")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) { search(immediate: true) }
        .onChange(of: query) { _, _ in search() }
        .onChange(of: kind) { _, _ in search(immediate: true) }
        .task { if hits.isEmpty { search(immediate: true) } }
        .sheet(item: $selected) { hit in
            HubRepoSheet(repoId: hit.id, hint: hit, engine: engine, store: store, settings: settings) { dismiss() }
                // iOS 18 zoom: the details grow out of the tapped row and shrink back into it.
                .navigationTransition(.zoom(sourceID: hit.id, in: zoom))
        }
        .sheet(item: Binding(get: { pastedRepo.map(RepoId.init) }, set: { pastedRepo = $0?.id })) { r in
            HubRepoSheet(repoId: r.id, hint: nil, engine: engine, store: store, settings: settings) { dismiss() }
        }
    }

    private struct RepoId: Identifiable { var id: String }

    private func isAdded(_ hit: HubCatalog.Hit) -> Bool {
        store.catalog.models.contains { $0.repo == hit.id && (store.states[$0.id]?.isDownloaded ?? false) }
    }

    private func search(immediate: Bool = false) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines), k = kind
        if typedRepoId != nil { hits = []; loading = false; return }
        searchTask = Task {
            if !immediate { try? await Task.sleep(nanoseconds: 350_000_000) }   // debounce typing
            if Task.isCancelled { return }
            loading = true; error = nil
            do {
                let rows = try await hub.search(q, kind: k).filter(\.isTextGeneration)
                if Task.isCancelled { return }
                withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { hits = rows }
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
                hits = []
            }
            loading = false
        }
    }
}

/// One search result: name · author, downloads, size/ctx, fit badge.
struct HubHitRow: View {
    var hit: HubCatalog.Hit
    var added: Bool
    /// Models-tab state of the row the user already added (Mine passes it); nil = never added / unknown.
    var state: ModelStore.State? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.name).font(.body).lineLimit(2)
                // One Text so a narrow column wraps between items, never inside a word ("ca-gatay", "pri-vate").
                metaLine.font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let s = hit.sizeBytes, s > 0 { Text(ByteSize.label(s)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
                if added { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).accessibilityLabel("on this device") }
                else if case .downloading(let done, let total, _, _)? = state {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).progressViewStyle(.circular).controlSize(.small).tint(LooplDesign.accent)
                        .accessibilityLabel("downloading")
                } else if case .failed? = state {
                    Image(systemName: LooplDesign.iconWarning).font(.footnote.weight(.semibold)).foregroundStyle(.red).accessibilityLabel("download failed")
                } else if let s = hit.sizeBytes, s > 0 { FitBadge(fit: .verdict(bytes: HubCatalog.fitBytes(weights: s, vision: hit.isVision), available: MemoryBudget.budget)) }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
    private var metaLine: Text {
        var t = Text(hit.author) + Text(" · ") + Text(Image(systemName: "arrow.down.to.line")) + Text(" \(hit.downloads.formatted(.number.notation(.compactName)))")
        if let p = hit.paramsB { t = t + Text(" · \(p.formatted(.number.precision(.fractionLength(0...1))))B") }
        if let b = hit.bits { t = t + Text(" · \(b)-bit") }
        if let c = hit.ctx { t = t + Text(" · ctx \(c.formatted(.number.notation(.compactName)))") }
        if hit.isVision { t = t + Text(" · ") + (Text(Image(systemName: "eye")) + Text(" vision")).foregroundColor(LooplDesign.accent) }
        if hit.isPrivate { t = t + Text(" · ") + Text(Image(systemName: "lock.fill")) + Text(" private") }
        return t
    }
}

/// fits · tight · too big — advice, never a wall.
struct FitBadge: View {
    var fit: HubCatalog.Fit
    var body: some View {
        Text(fit.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel(fitSpoken)
    }
    private var fitSpoken: String {
        switch fit { case .green: "fits in memory"; case .amber: "tight on memory"; case .red: "too big for this device's memory" }
    }
    private var color: Color {
        switch fit { case .green: .green; case .amber: LooplDesign.amber; case .red: .red }
    }
}

/// Loading placeholder rows (no spinners).
struct SkeletonRow: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 220, height: 14)
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 140, height: 10)
        }
        .padding(.vertical, 6)
        .opacity(on && !reduceMotion ? 0.45 : 1)
        // Scoped to `on` only — a `withAnimation(.repeatForever)` in onAppear leaks into the enclosing
        // transaction and leaves the sheet's list animating forever (buttons stop receiving taps).
        .animation(reduceMotion ? nil : LooplDesign.Motion.pulse, value: on)
        .onAppear { on = true }
        .accessibilityHidden(true)
    }
}

private let hubLog = Logger(subsystem: "technology.tiny.loopl", category: "download")

/// Repo details: files with sizes, context, quant picker (GGUF), fit, Download.
struct HubRepoSheet: View {
    var repoId: String
    var hint: HubCatalog.Hit?
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings
    var didStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var repo: HubCatalog.Repo?
    @State private var config: HubCatalog.Config?
    @State private var error: String?
    @State private var quant: HubCatalog.File?
    @State private var showAllFiles = false
    /// Why the last Download tap did not start (space, drive, sign-in): shown above the button, sheet stays.
    @State private var refusal: ModelStore.DownloadRefusal?
    @State private var showStorage = false
    /// Finger-following offset of the whole sheet while its header is dragged (interactive spring).
    @State private var drag: CGFloat = 0
    private let hub = HubCatalog(token: HFAccount.shared.provider)

    private var spec: ModelSpec? {
        guard let repo else { return nil }
        return try? HubCatalog.spec(for: repo, config: config, ggufFile: repo.kind == .gguf ? quant : nil)
    }
    private var existing: ModelSpec? {
        guard let spec else { return nil }
        return store.catalog.models.first { $0.repo == spec.repo && $0.file == spec.file }
    }

    var body: some View {
        NavigationStack {
            List {
                if let repo, let spec {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(spec.name).font(.title3.weight(.semibold))
                            Text(repo.id).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack(spacing: 8) {
                                tag(spec.runtime.label)
                                tag(HubCatalog.detectFamily(repo: repo.id, modelType: config?.modelType ?? repo.modelType).label)
                                if spec.supportsVision { tag("vision", color: LooplDesign.accent) }
                                if spec.toolsUnverified == true { tag("tool calls unverified", color: LooplDesign.amber) }
                                FitBadge(fit: .verdict(bytes: HubCatalog.fitBytes(weights: spec.sizeBytes, vision: spec.supportsVision), available: MemoryBudget.budget))
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        // Interruptible drag-to-dismiss from the header: follows the finger, dismisses on
                        // distance or velocity, otherwise springs back. Reduce Motion: plain tap-to-close only.
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { v in
                                    guard !reduceMotion else { return }
                                    withAnimation(LooplDesign.Motion.interactive) { drag = max(0, v.translation.height) }
                                }
                                .onEnded { v in
                                    let dy = v.translation.height, vy = v.predictedEndTranslation.height - dy
                                    if dy > 120 || vy > LooplDesign.Motion.dismissVelocity { dismiss() }
                                    else { withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { drag = 0 } }
                                }
                        )
                    }
                    Section {
                        LabeledContent("Download", value: spec.sizeLabel)
                        LabeledContent("Parameters", value: spec.paramsB > 0 ? "\(spec.paramsB.formatted(.number.precision(.fractionLength(0...1))))B" : "—")
                        LabeledContent("Context") { Text("\(spec.ctxUsable8GB.formatted()) of \(spec.ctxNominal.formatted())").monospacedDigit() }
                        if let b = config?.bits { LabeledContent("Quantization", value: "\(b)-bit\(config?.groupSize.map { ", group \($0)" } ?? "")") }
                        LabeledContent("Downloads", value: repo.downloads.formatted(.number.notation(.compactName)))
                        LabeledContent("Memory now", value: MemoryBudget.label(MemoryBudget.budget))
                    } footer: {
                        Text(fitFootnote(spec))
                    }
                    if repo.kind == .gguf {
                        Section("Quant") {
                            ForEach(repo.ggufFiles, id: \.path) { f in
                                Button {
                                    LooplDesign.haptic(); withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion)) { quant = f }
                                } label: {
                                    HStack {
                                        Text(f.quant ?? f.path).font(.body.monospaced())
                                        Spacer()
                                        Text(ByteSize.label(f.size, zero: "size unknown")).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                        Image(systemName: quant?.path == f.path ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(quant?.path == f.path ? LooplDesign.accent : Color.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("hub-quant-\(f.quant ?? f.path)")
                            }
                        }
                    } else {
                        Section {
                            ForEach(showAllFiles ? repo.files : repo.mlxFiles, id: \.path) { f in
                                HStack {
                                    Text(f.path).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(ByteSize.label(f.size, zero: "size unknown")).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            if repo.files.count > repo.mlxFiles.count {
                                Button(showAllFiles ? "Show downloaded files only" : "Show all \(repo.files.count) files") {
                                    withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { showAllFiles.toggle() }
                                }.font(.footnote)
                            }
                        } header: { Text("Files") } footer: {
                            // said "Weights, tokenizer and configs are downloaded; README and git
                            // files are not." Same shape as #205's fixes — it names the parts of a model
                            // package rather than telling the reader the thing they care about, which is that
                            // the download skips what it does not need.
                            Text("Only the files needed to run the model are downloaded — not its readme or page history.")
                        }
                    }
                    Section {
                        Link(destination: URL(string: "https://huggingface.co/\(repo.id)")!) { Label("Open on Hugging Face", systemImage: "safari") }
                    }
                } else if let error {
                    ContentUnavailableView { Label("Could not open \(repoId)", systemImage: LooplDesign.iconWarning) } description: { Text(error) } actions: { Button("Try again") { Task { await load() } } }
                } else {
                    Section { ForEach(0..<5, id: \.self) { _ in SkeletonRow() } }
                }
            }
            .listStyle(.insetGrouped)
            // A sheet: no tab bar behind it, and its own Download bar is a safeAreaInset
            // below this one, so the last row keeps its air either way.
            .looplBottomBar(false)
            .looplScrollClearance()
            .navigationTitle(hint?.name ?? repoId.split(separator: "/").last.map(String.init) ?? repoId)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if let spec {
                  VStack(spacing: 8) {
                    if let refusal {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(refusal.message, systemImage: LooplDesign.iconWarning)
                                .font(.footnote).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("hub-download-refused")
                            if refusal.suggestsStorageSettings {
                                Button("Open Settings › Storage", systemImage: "externaldrive") { showStorage = true }
                                    .font(.footnote.weight(.semibold))
                                    .accessibilityIdentifier("hub-download-storage")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Button {
                        start(spec)
                    } label: {
                        Label(buttonTitle(spec), systemImage: existing.flatMap { store.states[$0.id]?.isDownloaded } == true ? LooplDesign.iconLoaded : LooplDesign.iconDownload)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LooplDesign.accent)
                    .disabled(settings.offline && !(existing.flatMap { store.states[$0.id]?.isDownloaded } ?? false))
                    .accessibilityIdentifier("hub-download")
                  }
                  .padding(.horizontal, LooplDesign.gutter).padding(.vertical, 10)
                  .background(.bar)
                  .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: refusal)
                }
            }
            .sheet(isPresented: $showStorage) {
                NavigationStack { StorageView(engine: engine, settings: settings, store: store) }
                    // Back from Storage (drive added / target changed): re-check so the footnote clears itself.
                    .onDisappear { if let row = existing ?? spec { let r = store.preflight(row); refusal = (r?.isSilent ?? true) ? nil : r } }
            }
        }
        .offset(y: drag)
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private func tag(_ s: String, color: Color = .secondary) -> some View {
        Text(s).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule()).foregroundStyle(color)
    }

    private func buttonTitle(_ spec: ModelSpec) -> String {
        if let existing, store.states[existing.id]?.isDownloaded == true {
            return engine.loadedModel?.id == existing.id ? "In use" : "Use this model"
        }
        return spec.sizeBytes > 0 ? "Download · \(spec.sizeLabel)" : "Download"
    }

    private func fitFootnote(_ spec: ModelSpec) -> String {
        switch HubCatalog.Fit.verdict(bytes: HubCatalog.fitBytes(weights: spec.sizeBytes, vision: spec.supportsVision), available: MemoryBudget.budget) {
        case .green: spec.supportsVision ? "Fits comfortably (≈1.3× the weights plus the vision tower and up to 1280 image tokens per picture)." : "Fits comfortably (≈1.3× the weights in memory)."
        case .amber: "Tight: it should load, but close other apps and expect a smaller context."
        case .red: "Likely too big for the memory iOS gives loopl right now. You can still try — it may load with a short context, or fail to."
        }
    }

    private func load() async {
        error = nil
        do {
            let r = try await hub.repo(repoId)
            if r.gated, HFAccount.shared.token == nil { throw HubCatalog.HubError.signInRequired(repoId) }
            let c: HubCatalog.Config? = r.kind == .mlx || r.files.contains(where: { $0.path == "config.json" }) ? try await hub.config(repoId) : nil
            withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) {
                repo = r; config = c
                if r.kind == .gguf { quant = r.preferredGGUF }
            }
            if (try? HubCatalog.spec(for: r, config: c, ggufFile: r.kind == .gguf ? quant : nil)) == nil {
                error = HubCatalog.HubError.noWeights(repoId).localizedDescription; repo = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Download (or switch to) the repo. A download that cannot start RIGHT NOW — no
    /// space, drive away, not signed in — keeps the sheet open and says why here, where
    /// the finger is; before this the sheet closed and the reason landed as a footnote
    /// in a section below the fold ("the download is not starting").
    private func start(_ spec: ModelSpec) {
        LooplDesign.haptic(1)
        let row = store.add(spec)
        let alreadyHere = store.states[row.id]?.isDownloaded == true
        if !alreadyHere, let why = store.download(row), !why.isSilent {
            hubLog.error("Download tap refused in sheet for \(row.id, privacy: .public): \(why.message, privacy: .public)")
            withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion)) { refusal = why }
            LooplDesign.haptic(2)
            return
        }
        refusal = nil
        hubLog.info("Download tap accepted in sheet for \(row.id, privacy: .public) (downloaded=\(alreadyHere))")
        dismiss()
        didStart()
        Task { await engine.select(row) }
    }
}
