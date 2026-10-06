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
    @State private var selected: HubCatalog.Hit?
    @Namespace private var zoom
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
                        Button { LooplDesign.haptic(); selected = hit } label: { HubHitRow(hit: hit, added: isAdded(hit)) }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: "mine-\(hit.id)", in: zoom)
                            .accessibilityIdentifier("mine-hit-\(hit.id)")
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
        .sheet(item: $selected) { hit in
            HubRepoSheet(repoId: hit.id, hint: hit, engine: engine, store: store, settings: settings) {}
                .navigationTransition(.zoom(sourceID: "mine-\(hit.id)", in: zoom))
        }
    }

    private func isAdded(_ hit: HubCatalog.Hit) -> Bool {
        store.catalog.models.contains { $0.repo == hit.id && (store.states[$0.id]?.isDownloaded ?? false) }
    }
}
