import SwiftUI
import Loopl
import LooplUI

/// Models › "loopl models" — the Hugging Face collection `LooplCollection.slug`, in the curator's order:
/// MLX 4-bit rows (vision badge from the files, as Browse/Mine do) and the GGUF builds under a disclosure.
/// Datasets, bf16 merges and LoRA adapters in the collection are not runnable on the phone and stay hidden.
/// Tap a row → the same details sheet Browse uses → download → select.
///
/// Three sources, best available wins: the Hub (once per launch + pull), the disk cache (offline / Hub down),
/// the bundled snapshot `App/Resources/collection.json` (first launch offline, or an anonymous user while the
/// collection is private — `scripts/sync-collection.sh` refreshes it). The footer says which, and when.
@MainActor @Observable
final class CollectionModel {
    var listing: HubCollectionListing?
    var loading = false
    /// Why the Hub could not be asked this time — shown quietly in the footer, the rows stay.
    var error: String?
    private(set) var loadedFor: String?
    /// Bumped per load: a cancelled/stale load (the `.task(id: hf.author)` re-fires when the token resolves a moment after
    /// launch) must not write its error or rows over the newer one's — the footer once said "updated now · couldn't reach".
    private var generation = 0
    private let hub = HubCatalog(token: HFAccount.shared.provider)
    /// DEBUG `--design-collection bundled`: never touch the network (fixtures, UI tests, screenshots).
    static var bundledOnly: Bool {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--design-collection"), i + 1 < CommandLine.arguments.count { return CommandLine.arguments[i + 1] == "bundled" }
        #endif
        return false
    }

    init() { listing = Self.bundled() }

    static func bundled() -> HubCollectionListing? {
        guard let url = Bundle.main.url(forResource: "collection", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? HubCatalog.parseCollectionSnapshot(data)
    }

    /// `author` = the signed-in account (nil anonymous); a sign-in/out re-asks because private items appear/disappear.
    func load(author: String?, force: Bool = false) async {
        if Self.bundledOnly { return }
        let key = author ?? ""
        if !force, loadedFor == key, error == nil { return }
        generation += 1
        let mine = generation
        loading = true; error = nil
        defer { if mine == generation { loading = false } }
        do {
            let l = try await hub.collectionListing()
            guard mine == generation else { return }
            listing = l; loadedFor = key
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            self.error = Self.quiet(error)
            loadedFor = key
        }
    }

    /// Footer status when the collection is private and nobody is signed in. Deliberately NOT an instruction:
    /// `CollectionSection`'s key row carries the one "sign in in Settings" sentence, and the audit of build 10
    /// found both of them on screen 40 pt apart.
    static let privateStatus = "the collection is private right now"
    /// The single actionable sentence about signing in — the key row, or the empty-section row when nothing loaded.
    static let signInHint = "These loopl models are private. Sign in to Hugging Face in Settings to download them."

    /// Footer wording for a failed refresh: the rows are still there, so no red.
    static func quiet(_ error: any Error) -> String {
        if let e = error as? HubCatalog.HubError {
            switch e {
            case .offline: return "offline — showing the saved list"
            case .signInRequired: return Self.privateStatus
            case .noAccess: return "this account can't read the collection"
            default: break
            }
        }
        return "couldn't reach Hugging Face — showing the saved list"
    }

    /// Repo ids the section already shows — ModelsView hides the same curated models.json rows (dedupe by repo id).
    var repoIds: Set<String> { Set(listing?.rows.map(\.id) ?? []) }
}

struct CollectionSection<More: View>: View {
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings
    @Bindable var hf: HFSession
    @Bindable var model: CollectionModel
    /// The tapped row. OWNED BY ModelsView, which presents the sheet from the List (a `.sheet` on a Section never presents on iOS 26 — see MineSection).
    @Binding var selected: HubCatalog.Hit?
    var zoom: Namespace.ID
    /// Rows ModelsView folds under this section after the loopl models (the curated "More models" disclosure):
    /// the tab stays at five sections in the owner's order, and the catalog depth never outranks the loopl models.
    @ViewBuilder var more: More
    @State private var showGGUF = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(engine: Engine, store: ModelStore, settings: AppSettings, hf: HFSession, model: CollectionModel, selected: Binding<HubCatalog.Hit?>, zoom: Namespace.ID,
         @ViewBuilder more: () -> More = { EmptyView() }) {
        self.engine = engine; self.store = store; self.settings = settings; self.hf = hf; self.model = model
        self._selected = selected; self.zoom = zoom; self.more = more()
    }

    var body: some View {
        if let listing = model.listing, !listing.rows.isEmpty {
            Section {
                ForEach(listing.mlx) { row(row: $0) }
                if settings.showGGUF, !listing.gguf.isEmpty {
                    DisclosureGroup(isExpanded: $showGGUF) {
                        ForEach(listing.gguf) { row(row: $0) }
                    } label: {
                        HStack {
                            Text("GGUF · llama.cpp").font(.body)
                            Text("text only").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(listing.gguf.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { showGGUF.toggle() } }
                        .accessibilityIdentifier("collection-gguf")
                        .accessibilityAddTraits(.isButton)
                    }
                }
                if hf.author == nil, listing.rows.contains(where: \.hit.isPrivate) {
                    Label {
                        Text(CollectionModel.signInHint).font(.footnote).foregroundStyle(.secondary)
                    } icon: { Image(systemName: "key.horizontal").foregroundStyle(.secondary) }
                    .accessibilityIdentifier("collection-signed-out")
                }
                more
            } header: {
                HStack {
                    Text("loopl models")
                    if model.loading { PulsingMark().frame(width: 10, height: 10).transition(.opacity) }
                    Spacer()
                    Link(destination: LooplCollection.url) { Image(systemName: "arrow.up.right.square").font(.footnote) }
                        .accessibilityLabel("Open the collection on Hugging Face")
                }
            } footer: {
                Text(footer(listing))
                    .accessibilityIdentifier("collection-footer")
            }
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: listing.rows.map(\.id))
            .animation(LooplDesign.Motion.crossfade, value: model.loading)
            .task(id: hf.author) { await model.load(author: hf.author) }
        } else {
            // Nothing bundled, nothing cached, Hub unreachable: one honest row instead of a missing section.
            Section("loopl models") {
                if model.loading { SkeletonRow(); SkeletonRow() }
                else {
                    // A private collection with nothing cached is not an error the user can retry out of — it is the sign-in hint.
                    let signedOut = model.error == CollectionModel.privateStatus
                    Label(signedOut ? CollectionModel.signInHint : (model.error ?? "couldn't load the loopl collection"),
                          systemImage: signedOut ? "key.horizontal" : LooplDesign.iconWarning)
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier(signedOut ? "collection-signed-out" : "collection-error")
                    Button("Try again") { Task { await model.load(author: hf.author, force: true) } }.font(.footnote.weight(.semibold))
                }
                more
            }
            .task(id: hf.author) { await model.load(author: hf.author) }
        }
    }

    private func footer(_ l: HubCollectionListing) -> String {
        var parts: [String] = []
        // The Hub collection's description is written for the Hub ("MLX 4-bit (vision) = what the app downloads, bf16 =
        // post-tuning base…"); under the rows the app says what a person needs (IMPROVE-3 audit).
        parts.append("Made for loopl: tools, memory and pictures, tuned to work well on a phone. Tap a model to download it once; it runs offline.")
        var status: [String] = []
        if let d = l.updated { status.append("updated \(d.formatted(.relative(presentation: .named)))") }
        switch l.source {
        case .network: break
        case .cache: status.append("saved list")
        case .bundled: status.append("bundled list")
        }
        if let e = model.error { status.append(e) }
        if !status.isEmpty { parts.append(status.joined(separator: " · ")) }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder private func row(row: HubCollectionRow) -> some View {
        let spec = rowSpec(row.hit)
        let state = spec.flatMap { store.states[$0.id] }
        VStack(alignment: .leading, spacing: 6) {
            Button { LooplDesign.haptic(); selected = row.hit } label: {
                CollectionRowLabel(row: row, subtitle: spec.flatMap(ModelBlurb.known) ?? row.note.map(ModelBlurb.plain), added: isAdded(row.hit), loaded: spec.map { engine.loadedModel?.id == $0.id } ?? false, state: state, sizeBytes: spec.map(\.sizeBytes))
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: "collection-\(row.id)", in: zoom)
            .accessibilityIdentifier("collection-row-\(row.id)")
            if let spec, let state {
                switch state {
                case .downloading(let done, let total, let fd, let files):
                    DownloadProgressRow(done: done, total: total, fileIndex: fd, fileCount: files) { store.pause(spec) }
                        .accessibilityIdentifier("collection-downloading-\(row.id)")
                case .paused(let done, let total):
                    HStack {
                        Text("Paused · \(ByteSize.label(done)) of \(ByteSize.label(total))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Resume") { Task { await engine.select(spec) } }.font(.caption.weight(.semibold)).disabled(settings.offline)
                    }
                case .failed(let msg):
                    HStack(alignment: .top) {
                        Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("collection-failed-\(row.id)")
                        Spacer(minLength: 8)
                        Button("Retry") { LooplDesign.haptic(1); Task { await engine.select(spec) } }
                            .font(.caption.weight(.semibold)).disabled(settings.offline)
                            .accessibilityIdentifier("collection-retry-\(row.id)")
                    }
                case .moving(let done, let total, let to):
                    Text("Moving to \(to) · \(ByteSize.label(done)) of \(ByteSize.label(total))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .needsDrive(let drive):
                    Label("Needs \(drive) — plug it in to use", systemImage: "externaldrive.badge.xmark").font(.caption).foregroundStyle(.orange)
                case .driveUnreadable(let drive, _):
                    Label("\(drive) is connected but loopl can't read it — re-grant its folder in Settings › Storage", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                case .downloaded, .notDownloaded: EmptyView()
                }
            }
        }
        .contextMenu {
            Button("Copy repo id", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.id }
            Link(destination: URL(string: "https://huggingface.co/\(row.id)")!) { Label("Open on Hugging Face", systemImage: "safari") }
        }
    }

    private func isAdded(_ hit: HubCatalog.Hit) -> Bool {
        store.catalog.models.contains { $0.repo == hit.id && (store.states[$0.id]?.isDownloaded ?? false) }
    }
    /// The catalog row for this repo once the user added it (Download tapped at least once) — or the bundled models.json twin.
    private func rowSpec(_ hit: HubCatalog.Hit) -> ModelSpec? {
        store.catalog.models.first { $0.repo == hit.id && store.states[$0.id] != nil } ?? store.catalog.models.first { $0.repo == hit.id }
    }
}

/// name · curator's note · size + vision/private marks. The note is the subtitle — the collection speaks, not the file name.
struct CollectionRowLabel: View {
    var row: HubCollectionRow
    /// Plain words under the name (`ModelBlurb`); nil → the file name.
    var subtitle: String?
    var added: Bool
    var loaded: Bool
    var state: ModelStore.State?
    /// The catalog's byte count when the row IS a catalog model — the Hub figure is the weights file alone
    /// (1.72 GB) while onboarding and Models › On this iPhone say what is downloaded (1.75 GB): one model, one number (IMPROVE-4 #4).
    var sizeBytes: Int64? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    private var shownBytes: Int64? { sizeBytes ?? row.hit.sizeBytes }
    var body: some View {
        // At an accessibility size the size + marks column goes UNDER the text instead of beside it: sharing the row
        // left the curator's note ~150 pt wide on an SE and ~175 pt on a 16 Pro ("Smallest — quick answers and tools,
        // sees pictures" in four words per line) because a monospaced "1.75 GB" at 3x the type is wider than the note.
        // Same shape as #194 (Settings › Tools), #195 (the approval card) and #198 (the Models version line);
        // `TypeSqueezeUITests` now measures it on every push.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                // The NAME is the one word a person is looking for, so at an accessibility size it gets its own line
                // and the marks drop below it: sharing the row with "👁 sees pictures" truncated it to "loopl…" on an
                // SE (photographed). Nothing changes at normal sizes.
                titleLayout {
                    Text(title).font(.body.weight(loaded ? .semibold : .regular))
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                    if row.hit.isVision { (Text(Image(systemName: "eye")) + Text(" sees pictures")).font(.caption.weight(.medium)).foregroundStyle(LooplDesign.accent).accessibilityLabel("sees pictures") }
                    if row.hit.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("private") }
                }
                if let note = subtitle {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(row.hit.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            marksLayout {
                if let s = shownBytes, s > 0 { Text(ByteSize.label(s)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
                if loaded { Image(systemName: LooplDesign.iconLoaded).font(.footnote.weight(.semibold)).foregroundStyle(LooplDesign.accent).accessibilityLabel("in use") }
                else if added { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).accessibilityLabel("on this device") }
                else if case .downloading(let done, let total, _, _)? = state {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).progressViewStyle(.circular).controlSize(.small).tint(LooplDesign.accent)
                        .accessibilityLabel("downloading")
                } else if case .failed? = state {
                    Image(systemName: LooplDesign.iconWarning).font(.footnote.weight(.semibold)).foregroundStyle(.red).accessibilityLabel("download failed")
                } else if let s = row.hit.sizeBytes, s > 0 { FitBadge(fit: .verdict(bytes: HubCatalog.fitBytes(weights: s, vision: row.hit.isVision), available: MemoryBudget.budget)) }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
    /// Name + marks: one row normally, name above its marks at accessibility sizes.
    private var titleLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                     : AnyLayout(HStackLayout(spacing: 6))
    }
    /// The size + state marks: a trailing column beside the text, a leading row under it at accessibility sizes.
    private var marksLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
                                     : AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
    }
    /// "loopl 2B" from "loopl-2b-4bit" / "loopl-0.8b-v1.1-GGUF" → "loopl 0.8B v1.1".
    private var title: String {
        var n = row.hit.name
        for suffix in ["-4bit", "-8bit", "-GGUF", "-gguf", "-mlx"] where n.hasSuffix(suffix) { n.removeLast(suffix.count) }
        let parts = n.split(separator: "-").map(String.init)
        return parts.enumerated().map { i, p in
            if i == 0 { return p }
            if p.range(of: #"^\d+(\.\d+)?b$"#, options: .regularExpression) != nil { return p.uppercased() }
            if p == "vl" { return "VL" }   // "loopl-vl-2b-4bit" → "loopl VL 2B", not "loopl vl 2B"
            return p
        }.joined(separator: " ")
    }
}
