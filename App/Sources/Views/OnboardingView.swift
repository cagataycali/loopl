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
    /// Settings › About › "Show intro again" posts this; the root presents the flow in replay mode.
    static let replay = Notification.Name("loopl.onboarding.replay")
    /// Posted when the flow closes with a model ready — the chat focuses its composer so the first message is one tap away.
    static let finished = Notification.Name("loopl.onboarding.finished")

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

/// Where the first run is: the mark intro, the three story pages, the model pick, then the ring while the first
/// model downloads. Every stage is skippable; the chat is one tap away at any point.
enum OnboardingStage: String, Equatable { case intro, story, pick, download }

struct OnboardingView: View {
    @Bindable var engine: Engine
    var store: ModelStore
    /// Replaying from Settings › About: the pick stage can simply keep the model that is already there.
    var replay = false
    var onFinish: () -> Void
    @State private var stage: OnboardingStage = .intro
    @State private var pageIndex = 0
    @State private var chosen: ModelSpec?
    @State private var started = false
    @State private var net = NetworkWatch()
    @State private var hfDismissed = false
    @State private var hfSheet = false
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var type

    init(engine: Engine, store: ModelStore, replay: Bool = false, onFinish: @escaping () -> Void) {
        self.engine = engine; self.store = store; self.replay = replay; self.onFinish = onFinish
        #if DEBUG
        // `--design-onboarding-step story|pick|download [--design-onboarding-page N]` lands a fixture on one stage.
        if let i = CommandLine.arguments.firstIndex(of: "--design-onboarding-step"), i + 1 < CommandLine.arguments.count,
           let st = OnboardingStage(rawValue: CommandLine.arguments[i + 1]) {
            _stage = State(initialValue: st == .download ? .pick : st)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--design-onboarding-page"), i + 1 < CommandLine.arguments.count,
           let n = Int(CommandLine.arguments[i + 1]) {
            _pageIndex = State(initialValue: max(0, min(OnboardingStory.pages.count - 1, n)))
        }
        #endif
    }

    private var cards: [ModelSpec] { Onboarding.cards(store.catalog) }
    private var defaultId: String? { store.catalog.defaultModelId }
    private var selection: ModelSpec? { chosen ?? cards.first { $0.id == defaultId } ?? cards.first }
    private var appleFM: ModelSpec? {
        guard AppleFoundationModel.availability().available else { return nil }
        return store.catalog.models.first { $0.runtime == .appleFM }
    }
    private var pages: [OnboardingStory.Page] { OnboardingStory.pages }
    private var stageMotion: Animation? { LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion) }

    var body: some View {
        ZStack {
            canvas.ignoresSafeArea()
            switch stage {
            case .intro: intro.transition(.opacity)
            case .story: story.transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            case .pick, .download: pickAndDownload.transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(stageMotion, value: stage)
        .animation(stageMotion, value: started)
        .interactiveDismissDisabled(true)
        #if DEBUG
        .task {
            if DesignFixture.onboardingFrozenAt != nil, !started { stage = .pick; start(selection) }   // screenshot of the ring mid-download
            else if CommandLine.arguments.contains("--design-onboarding-step"), CommandLine.arguments.contains("download"), !started { start(selection) }
        }
        #endif
        .onChange(of: isReady) { _, ready in
            guard ready else { return }
            LooplDesign.success()
            Task { try? await Task.sleep(for: .seconds(0.9)); onFinish() }
        }
        .onChange(of: pageIndex) { _, _ in LooplDesign.haptic() }
        .sheet(isPresented: $hfSheet) {
            HFSignInSheet(hf: engine.hf) { hfDismissed = true }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    /// Black or paper behind the intro; the system background afterwards (the stages crossfade on it).
    private var canvas: some View {
        Group {
            if stage == .intro { scheme == .dark ? LooplDesign.ink : LooplDesign.cream } else { Color(.systemBackground) }
        }
    }

    // MARK: intro — the mark draws itself, the word settles, one line

    @State private var introProgress: Double = 0
    @State private var introWord = false

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            LooplMarkDrawing(progress: introProgress)
                .frame(width: 128, height: 128)
                .matchedGeometryEffect(id: "mark", in: ns)
                .accessibilityIdentifier("onboarding-mark")
            Text("loopl")
                .font(.system(size: 40, weight: .semibold, design: .rounded)).tracking(-1)
                .opacity(introWord ? 1 : 0)
                .offset(y: introWord || reduceMotion ? 0 : 10)
                .blur(radius: introWord || reduceMotion ? 0 : 6)
            Text(OnboardingStory.tagline)
                .font(.title3).foregroundStyle(.secondary)
                .opacity(introWord ? 1 : 0)
                .offset(y: introWord || reduceMotion ? 0 : 8)
            Spacer()
            Text("Tap to continue").font(.footnote).foregroundStyle(.tertiary)
                .opacity(introWord ? 1 : 0)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { advance(to: .story) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-intro")
        .accessibilityAction(named: "Continue") { advance(to: .story) }
        .task {
            if reduceMotion {
                introProgress = 1; introWord = true
                try? await Task.sleep(for: .seconds(1.6))
            } else {
                try? await Task.sleep(for: .seconds(LooplDesign.Motion.drawDelay))
                withAnimation(.easeInOut(duration: 0.9)) { introProgress = 1 }
                try? await Task.sleep(for: .seconds(0.75))
                withAnimation(LooplDesign.Motion.spring) { introWord = true }
                try? await Task.sleep(for: .seconds(1.25))
            }
            guard !Task.isCancelled, stage == .intro else { return }
            advance(to: .story)
        }
    }

    // MARK: story — three live pages

    private var story: some View {
        VStack(spacing: 0) {
            HStack {
                LooplMark().frame(width: 28, height: 28).matchedGeometryEffect(id: "mark", in: ns)
                    .accessibilityHidden(true)
                Spacer()
                skipButton
            }
            .padding(.horizontal, LooplDesign.gutter).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)

            StoryPager(index: $pageIndex, count: pages.count) { i in
                StoryPageView(page: pages[i], active: stage == .story && i == pageIndex)
            }
            .accessibilityIdentifier("onboarding-pager")

            VStack(spacing: 14) {
                PageDots(count: pages.count + 1, index: pageIndex)
                Button { next() } label: {
                    Text(pageIndex == pages.count - 1 ? "Pick a model" : "Continue")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .contentTransition(.opacity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("onboarding-next")
            }
            .padding(.horizontal, LooplDesign.gutter).padding(.top, 10).padding(.bottom, 8)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    private var skipButton: some View {
        Button("Skip") { skip() }
            .font(.subheadline.weight(.medium))
            .accessibilityIdentifier("onboarding-skip")
    }

    private func next() {
        if pageIndex < pages.count - 1 { withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.interactive, reduceMotion)) { pageIndex += 1 } }
        else { advance(to: .pick) }
    }
    private func advance(to s: OnboardingStage) {
        guard stage != s else { return }
        LooplDesign.haptic()
        withAnimation(stageMotion) { stage = s }
    }

    // MARK: pick + download — #80's cards, the chosen one becoming the ring

    private var pickAndDownload: some View {
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
                // While downloading there is little to show — centre it instead of leaving the lower half blank.
                .modifier(CentredWhen(on: started))
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar {
                if !started {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", systemImage: "chevron.backward") { advance(to: .story) }
                            .labelStyle(.iconOnly).accessibilityIdentifier("onboarding-back")
                    }
                    ToolbarItem(placement: .confirmationAction) { skipButton }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if started {
                    LooplProgressMark(progress: fraction)
                        .matchedGeometryEffect(id: "pick", in: ns)
                } else {
                    LooplMark().matchedGeometryEffect(id: "mark", in: ns)
                }
            }
            .frame(width: started ? 128 : 56, height: started ? 128 : 56)
            .accessibilityIdentifier("onboarding-mark")
            Text(started ? title : "Pick your first model")
                .font(.system(.title, design: .rounded, weight: .semibold)).multilineTextAlignment(.center)
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
                          selected: selection?.id == spec.id, downloaded: store.states[spec.id]?.isDownloaded == true) {
                    withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { chosen = spec }
                    LooplDesign.haptic()
                }
                // The selected card is what morphs into the ring when Download is tapped.
                .matchedGeometryEffect(id: selection?.id == spec.id ? "pick" : "card-\(spec.id)", in: ns, isSource: true)
            }
            networkLine.padding(.top, 4)
            Text("You can add, move or delete models any time in Models.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var networkLine: some View {
        let size = selection?.sizeLabel ?? ""
        let have = selection.map { store.states[$0.id]?.isDownloaded == true } ?? false
        let (icon, text): (String, String) =
            have ? ("checkmark.circle", "Already on this \(LooplDesign.deviceName) — nothing to download.")
            : !net.online ? ("wifi.slash", "You're offline — connect to download \(size).")
            : net.expensive ? ("antenna.radiowaves.left.and.right", "You're on cellular — this is a \(size) download. Wi-Fi is better.")
            : ("wifi", "Downloads once over Wi-Fi (\(size)), then works offline.")
        return Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(!have && (net.expensive || !net.online) ? Color.orange : .secondary)
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
            if !engine.hf.isSignedIn, !hfDismissed, !isReady {
                hfLine.padding(.top, 28).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The download's dead time asks the one optional question: a Hugging Face account unlocks private models,
    /// Share-to-dataset and Train your own. No permission prompts live here — mic/photos/camera stay just-in-time.
    private var hfLine: some View {
        VStack(spacing: 10) {
            Text("Have a Hugging Face account?").font(.subheadline.weight(.semibold))
            Text("Sign in to download your private models and train on your own conversations.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Sign in") { hfSheet = true }.buttonStyle(.bordered).controlSize(.regular)
                    .accessibilityIdentifier("onboarding-hf-signin")
                Button("Later") { withAnimation(stageMotion) { hfDismissed = true } }.buttonStyle(.borderless).controlSize(.regular)
                    .accessibilityIdentifier("onboarding-hf-later")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-hf")
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 8) {
            if !started {
                Button { start(selection) } label: {
                    Text(downloadLabel)
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(selection == nil || (!net.online && !selectionDownloaded))
                .accessibilityIdentifier("onboarding-continue")
                if let fm = appleFM {
                    Button("Use Apple Intelligence instead — no download") { start(fm) }
                        .font(.footnote).accessibilityIdentifier("onboarding-apple-fm")
                }
            } else if case .failed = engine.readiness {
                Button("Choose again") { withAnimation(stageMotion) { started = false } }
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

    private var selectionDownloaded: Bool { selection.map { store.states[$0.id]?.isDownloaded == true } ?? false }
    private var downloadLabel: String {
        guard let s = selection else { return "Continue" }
        let name = s.name.replacingOccurrences(of: " (4-bit)", with: "")
        return selectionDownloaded ? "Use \(name)" : "Download \(name) · \(s.sizeLabel)"
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
        LooplDesign.haptic(1)
        withAnimation(stageMotion) { started = true; stage = .download }
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
        if !replay { engine.bootstrap() }
        onFinish()
    }
}

/// Paste a Hugging Face token (Settings › Hugging Face does the same, with more room). Verified with `whoami`
/// before it is stored; the sheet closes itself on success.
private struct HFSignInSheet: View {
    var hf: HFSession
    var onDone: () -> Void
    @State private var token = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("hf_…", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("onboarding-hf-token")
                    if let e = hf.error { Text(e).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Access token") } footer: {
                    Text("A read token is enough to download your private models; a write token lets you share conversations and train. Stored in the Keychain, sent only to huggingface.co.")
                }
                Section {
                    Link("Create a token on huggingface.co", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                }
            }
            .navigationTitle("Hugging Face")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if hf.verifying { ProgressView() } else {
                        Button("Sign in") {
                            Task { if await hf.signIn(token) { LooplDesign.success(); onDone(); dismiss() } else { LooplDesign.failure() } }
                        }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("onboarding-hf-submit")
                    }
                }
            }
        }
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
    var downloaded = false
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
                        if downloaded { Pill("on device", tint: .green) }
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
