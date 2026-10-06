import SwiftUI
import Network
import Loopl
import LooplRuntimes
import LooplUI

/// First launch (no model ever used, nothing downloaded): ONE sheet to pick the first model instead of silently
/// fetching 335 MB. Three cards (size, what it can do, vision), a network line that tells the truth about Wi-Fi vs
/// cellular, the mark as the progress ring once chosen, and "nothing leaves the device". Skip = today's bootstrap.
enum Onboarding {
    static let doneKey = "loopl.onboarded"
    /// The three first-run picks, smallest first. Missing ids (a trimmed catalog) simply drop out.
    static let picks = ["qwen3-0.6b-4bit", "qwen3.5-0.8b-4bit", "qwen3.5-2b-4bit"]

    @MainActor static func needed(settings: AppSettings, store: ModelStore) -> Bool {
        #if DEBUG
        if DesignFixture.requested { return DesignFixture.scene == "onboarding" }
        if CommandLine.arguments.contains("--skip-onboarding") { return false }
        #endif
        if UserDefaults.standard.bool(forKey: doneKey) || settings.lastModelId != nil { return false }
        return !store.catalog.models.contains { store.states[$0.id]?.isDownloaded == true }
    }
    static func markDone() { UserDefaults.standard.set(true, forKey: doneKey) }

    static func cards(_ catalog: Catalog) -> [ModelSpec] {
        picks.compactMap { id in catalog.models.first { $0.id == id } }
    }

    /// One line of plain language per pick; anything else falls back to the row's own notes.
    static func blurb(_ spec: ModelSpec) -> String {
        switch spec.id {
        case "qwen3-0.6b-4bit": "Fastest. Chat, tools and quick answers — runs on any recent iPhone."
        case "qwen3.5-0.8b-4bit": "Small and sees pictures. Ask about a photo or a screenshot."
        case "qwen3.5-2b-4bit": "Smartest of the three. Photos + tools — needs about 3 GB of memory."
        default: spec.notes.map { String($0.prefix(90)) } ?? ""
        }
    }
}

/// Wi-Fi vs cellular, live — so the download line never promises what the network isn't.
@MainActor @Observable final class NetworkWatch {
    var expensive = false
    var online = true
    private let monitor = NWPathMonitor()
    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--design-cellular") { expensive = true; return }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.expensive = path.isExpensive; self?.online = path.status == .satisfied }
        }
        monitor.start(queue: .main)
    }
    deinit { monitor.cancel() }
}

struct OnboardingView: View {
    @Bindable var engine: Engine
    var store: ModelStore
    var onFinish: () -> Void
    @State private var chosen: ModelSpec?
    @State private var started = false
    @State private var net = NetworkWatch()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cards: [ModelSpec] { Onboarding.cards(store.catalog) }
    private var defaultId: String? { store.catalog.defaultModelId }
    private var selection: ModelSpec? { chosen ?? cards.first { $0.id == defaultId } ?? cards.first }
    private var appleFM: ModelSpec? {
        guard AppleFoundationModel.availability().available else { return nil }
        return store.catalog.models.first { $0.runtime == .appleFM }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if started { progress } else { picker }
                }
                .padding(.horizontal, LooplDesign.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                // While downloading there is little to show — centre it in the sheet instead of leaving the lower half blank.
                .modifier(CentredWhen(on: started))
            }
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar {
                if !started {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") { skip() }.accessibilityIdentifier("onboarding-skip")
                    }
                }
            }
        }
        .interactiveDismissDisabled(started && !isReady)
        #if DEBUG
        .task { if DesignFixture.onboardingFrozenAt != nil, !started { start(selection) } }   // screenshot of the ring mid-download
        #endif
        .onChange(of: isReady) { _, ready in
            guard ready else { return }
            Task { try? await Task.sleep(for: .seconds(0.9)); onFinish() }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if started { LooplProgressMark(progress: fraction) } else { LooplMarkIntro() }
            }
            .frame(width: started ? 128 : 84, height: started ? 128 : 84)
            .accessibilityIdentifier("onboarding-mark")
            Text(started ? title : "Pick your first model")
                .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                .contentTransition(.opacity)
            Label("Runs on this \(LooplDesign.deviceName). Nothing you type leaves the device.", systemImage: "lock.fill")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: .infinity)
    }

    private var picker: some View {
        VStack(spacing: 10) {
            ForEach(cards) { spec in
                ModelCard(spec: spec, blurb: Onboarding.blurb(spec), recommended: spec.id == defaultId,
                          selected: selection?.id == spec.id) {
                    withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { chosen = spec }
                    LooplDesign.haptic()
                }
            }
            networkLine.padding(.top, 4)
            Text("You can add, move or delete models any time in Models.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var networkLine: some View {
        let size = selection?.sizeLabel ?? ""
        let (icon, text): (String, String) =
            !net.online ? ("wifi.slash", "You're offline — connect to download \(size).")
            : net.expensive ? ("antenna.radiowaves.left.and.right", "You're on cellular — this is a \(size) download. Wi-Fi is better.")
            : ("wifi", "Downloads once over Wi-Fi (\(size)), then works offline.")
        return Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(net.expensive || !net.online ? Color.orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("onboarding-network")
    }

    private var progress: some View {
        VStack(spacing: 8) {
            if let s = engine.readiness.spec ?? selection {
                Text(s.name).font(.headline)
            }
            Text(detail).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .accessibilityIdentifier("onboarding-progress")
            if case .failed(_, let msg) = engine.readiness {
                Text(msg).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 8) {
            if !started {
                Button { start(selection) } label: {
                    Text(selection.map { "Download \($0.name.replacingOccurrences(of: " (4-bit)", with: "")) · \($0.sizeLabel)" } ?? "Continue")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(selection == nil || !net.online)
                .accessibilityIdentifier("onboarding-continue")
                if let fm = appleFM {
                    Button("Use Apple Intelligence instead — no download") { start(fm) }
                        .font(.footnote).accessibilityIdentifier("onboarding-apple-fm")
                }
            } else if case .failed = engine.readiness {
                Button("Choose again") { withAnimation { started = false } }
                    .buttonStyle(.bordered).controlSize(.large)
            } else if !isReady {
                Button("Keep downloading in the background") { onFinish() }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("onboarding-background")
            }
        }
        .padding(.horizontal, LooplDesign.gutter).padding(.vertical, 10)
        .frame(maxWidth: 560).frame(maxWidth: .infinity)
        // Chrome, not content: capped so the button never eats half an SE at AX sizes (the cards above still scale fully).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(.bar)
    }

    private var isReady: Bool { if case .ready = engine.readiness { return started }; return false }
    private var fraction: Double? {
        switch engine.readiness {
        case .downloading(_, let done, let total): total > 0 ? Double(done) / Double(total) * 0.92 : nil
        case .loading(_, let p): 0.92 + 0.08 * p
        case .ready: 1
        default: nil
        }
    }
    private var title: String {
        switch engine.readiness {
        case .downloading: "Downloading"
        case .loading, .repairing: "Getting ready"
        case .ready: "Ready"
        case .failed: "That didn't work"
        case .idle: "Starting"
        }
    }
    private var detail: String {
        switch engine.readiness {
        case .downloading(_, let done, let total): "\(ByteSize.label(done)) of \(ByteSize.label(total))"
        case .loading(_, let p): "Loading into memory · \(Int(p * 100)) %"
        case .repairing: "Fixing model files"
        case .ready: "Say hi."
        case .failed: ""
        case .idle: "…"
        }
    }

    private func start(_ spec: ModelSpec?) {
        guard let spec else { return }
        Onboarding.markDone()
        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.spring, reduceMotion)) { started = true }
        #if DEBUG
        if DesignFixture.requested { DesignFixture.playOnboarding(engine, spec); return }
        #endif
        Task { await engine.select(spec) }
    }
    private func skip() {
        Onboarding.markDone()
        #if DEBUG
        if DesignFixture.requested { onFinish(); return }
        #endif
        engine.bootstrap()
        onFinish()
    }
}

/// Centre the content in the visible height (min-height, so taller content still scrolls) — only while `on`.
private struct CentredWhen: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.containerRelativeFrame(.vertical, alignment: .center) { h, _ in h } } else { content }
    }
}

private struct ModelCard: View {
    var spec: ModelSpec
    var blurb: String
    var recommended: Bool
    var selected: Bool
    var tap: () -> Void
    @Environment(\.dynamicTypeSize) private var type
    var body: some View {
        let ax = type.isAccessibilitySize
        Button(action: tap) {
            HStack(alignment: .top, spacing: 12) {
                if !ax {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? LooplDesign.accent : Color.secondary)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(spec.name.replacingOccurrences(of: " (4-bit)", with: "")).font(.headline)
                    // At accessibility sizes the pills + size get their own line instead of crushing the name.
                    HStack(spacing: 6) {
                        if spec.supportsVision { Pill("vision") }
                        if recommended { Pill("default", tint: .secondary) }
                        if ax { Text(spec.sizeLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    Text(blurb).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !ax {
                    Spacer(minLength: 8)
                    Text(spec.sizeLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? LooplDesign.accent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding-card-\(spec.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
