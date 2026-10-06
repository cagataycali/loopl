import SwiftUI
import Loopl
import LooplUI

/// Models › "Mine" — the MLX/GGUF repos on the signed-in Hugging Face account, private ones included
/// (a training job's output lands here). Tap a row → the same details sheet Browse uses; the Bearer
/// token makes a private repo resolve and download. Signed out: one quiet row pointing at Settings.
@MainActor @Observable
final class MineModel {
    var hits: [HubCatalog.Hit] = []
    var loading = false
    var error: String?
    private(set) var loadedFor: String?
    private let hub = HubCatalog(token: HFAccount.shared.provider)

    /// `force` bypasses nothing on the Hub side (2-minute cache) but re-asks even when `author` is unchanged — pull-to-refresh.
    func load(author: String?, force: Bool = false) async {
        guard let author else { hits = []; error = nil; loadedFor = nil; return }
        if !force, loadedFor == author, error == nil { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let rows = try await hub.mine(author: author)
            hits = rows; loadedFor = author
        } catch {
            self.error = error.localizedDescription
            if loadedFor != author { hits = [] }
        }
    }
}

struct MineSection: View {
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings
    @Bindable var hf: HFSession
    @Bindable var mine: MineModel
    /// The tapped repo. OWNED BY ModelsView, which presents the sheet from the List: a `.sheet` attached to a
    /// `Section` inside a `List` never presented on iOS 26 (with the zoom transition it presented and was torn
    /// down in the same frame — "Trying to dismiss the presentation controller while transitioning already",
    /// SIGTRAP). Tapping a Mine row did nothing / crashed; the Download button was never reached.
    @Binding var selected: HubCatalog.Hit?
    var zoom: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            if let author = hf.author {
                if mine.loading && mine.hits.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
                } else if let error = mine.error, mine.hits.isEmpty {
                    Label(error, systemImage: LooplDesign.iconWarning).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("mine-error")
                    Button("Try again") { Task { await mine.load(author: author, force: true) } }.font(.footnote.weight(.semibold))
                } else if mine.hits.isEmpty {
                    Label {
                        Text("No MLX or GGUF repos under @\(author) yet").font(.footnote).foregroundStyle(.secondary)
                    } icon: { Image(systemName: "tray").foregroundStyle(.secondary) }
                    .accessibilityIdentifier("mine-empty")
                } else {
                    ForEach(mine.hits) { hit in
                        let row = rowSpec(hit)
                        let state = row.flatMap { store.states[$0.id] }
                        VStack(alignment: .leading, spacing: 6) {
                            Button { LooplDesign.haptic(); selected = hit } label: { HubHitRow(hit: hit, added: isAdded(hit), state: state) }
                                .buttonStyle(.plain)
                                .matchedTransitionSource(id: "mine-\(hit.id)", in: zoom)
                                .accessibilityIdentifier("mine-hit-\(hit.id)")
                            // The same inline status the Models rows show — a Download tap from here must stay visible here.
                            if let row, let state {
                                switch state {
                                case .downloading(let done, let total, let fd, let files):
                                    DownloadProgressRow(done: done, total: total, fileIndex: fd, fileCount: files) { store.pause(row) }
                                        .accessibilityIdentifier("mine-downloading-\(hit.id)")
                                case .paused(let done, let total):
                                    HStack {
                                        Text("Paused · \(ByteSize.label(done)) of \(ByteSize.label(total))").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Resume") { Task { await engine.select(row) } }.font(.caption.weight(.semibold)).disabled(settings.offline)
                                    }
                                case .failed(let msg):
                                    HStack(alignment: .top) {
                                        Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                            .accessibilityIdentifier("mine-failed-\(hit.id)")
                                        Spacer(minLength: 8)
                                        Button("Retry") { LooplDesign.haptic(1); Task { await engine.select(row) } }
                                            .font(.caption.weight(.semibold)).disabled(settings.offline)
                                            .accessibilityIdentifier("mine-retry-\(hit.id)")
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
                    }
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Hugging Face models").font(.body.weight(.medium))
                        Text("Sign in under Settings to list them here — private repos included").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "key.horizontal").foregroundStyle(LooplDesign.accent) }
                .accessibilityIdentifier("mine-signed-out")
            }
        } header: {
            HStack {
                Text(hf.author.map { "Mine · @\($0)" } ?? "Mine")
                if mine.loading, !mine.hits.isEmpty { PulsingMark().frame(width: 10, height: 10).transition(.opacity) }
            }
        } footer: {
            if hf.author != nil, !mine.hits.isEmpty {
                let p = mine.hits.filter(\.isPrivate).count
                Text(p > 0 ? "\(mine.hits.count) runnable repos on your account, \(p) private. A finished training job appears here — pull to refresh." : "\(mine.hits.count) runnable repos on your account. A finished training job appears here — pull to refresh.")
            }
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: mine.hits.map(\.id))
        .animation(LooplDesign.Motion.crossfade, value: mine.loading)
        .task(id: hf.author) { await mine.load(author: hf.author) }
    }

    private func isAdded(_ hit: HubCatalog.Hit) -> Bool {
        store.catalog.models.contains { $0.repo == hit.id && (store.states[$0.id]?.isDownloaded ?? false) }
    }
    /// The catalog row for this repo once the user added it (Download tapped at least once), else nil.
    private func rowSpec(_ hit: HubCatalog.Hit) -> ModelSpec? {
        store.catalog.models.first { $0.repo == hit.id && store.states[$0.id] != nil }
    }
}
