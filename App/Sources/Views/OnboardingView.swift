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
    /// The pick the flow lands on: loopl 2B — the best balance of speed and quality on an iPhone.
    static let preferredId = "loopl-2b-4bit"
    /// Legacy picks, only for a trimmed catalog with no `featured` rows at all (tests with an old fixture).
    static let fallbackPicks = ["qwen3-0.6b-4bit", "qwen3.5-0.8b-4bit", "qwen3.5-2b-4bit"]

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

    /// The first-run picks are OUR models: the catalog's `featured` MLX rows (loopl 0.8B · 2B · 4B), smallest first.
    /// Apple Intelligence is featured too but is its own card (`appleFM`), not a download.
    static func cards(_ catalog: Catalog) -> [ModelSpec] {
        let ours = catalog.featured.filter { $0.runtime == .mlx }.sorted { $0.paramsB < $1.paramsB }
        if !ours.isEmpty { return ours }
        return fallbackPicks.compactMap { id in catalog.models.first { $0.id == id } }
    }
    /// The card the flow preselects: loopl 2B, else the catalog default, else the first.
    static func preselected(_ cards: [ModelSpec], defaultId: String?) -> ModelSpec? {
        cards.first { $0.id == preferredId } ?? cards.first { $0.id == defaultId } ?? cards.first
    }

    /// One line of plain language per pick; anything else falls back to the row's own notes.
    static func blurb(_ spec: ModelSpec) -> String {
        switch spec.id {
        case "loopl-0.8b-4bit": "Smallest — quick answers and tools, sees pictures. Any recent iPhone."
        case "loopl-2b-4bit": "The best balance of speed and quality on iPhone. Photos, tools, memory."
        case "loopl-4b-4bit": "Most capable — needs a Pro-class iPhone (8 GB of memory)."
        case "qwen3-0.6b-4bit": "Fastest. Chat, tools and quick answers — runs on any recent iPhone."
        case "qwen3.5-0.8b-4bit": "Small and sees pictures. Ask about a photo or a screenshot."
        case "qwen3.5-2b-4bit": "Smartest of the three. Photos + tools — needs about 3 GB of memory."
        default: spec.notes.map { String($0.prefix(90)) } ?? ""
        }
    }
    /// The badge text on the preferred card.
    static let recommendedBadge = "Recommended · fast + smart"

    /// Will it fit in memory on THIS device? Weights + KV + activations ≈ 1.3× the weights against what iOS lets the
    /// process grow to (`MemoryBudget.budget`). `--design-ram-gb N` (DEBUG) stands in for a 6 GB phone on the sim.
    static func fit(_ spec: ModelSpec) -> HubCatalog.Fit {
        HubCatalog.Fit.verdict(bytes: HubCatalog.fitBytes(weights: spec.sizeBytes, vision: spec.supportsVision), available: budget)
    }
    static var budget: Int64 {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--design-ram-gb"), i + 1 < CommandLine.arguments.count,
           let gb = Double(CommandLine.arguments[i + 1]) {
            return Int64(gb * 1024 * 1024 * 1024 * 0.7)   // the jetsam budget is ≈ 70 % of physical RAM
        }
        #endif
        return MemoryBudget.budget
    }
    /// Why a card is amber/red, in one line — only for the model that needs it.
    static func fitLine(_ spec: ModelSpec, fit: HubCatalog.Fit) -> String? {
        switch fit {
        case .green: nil
        case .amber: "Tight on this \(LooplDesign.deviceName) — \(MemoryBudget.label(budget)) available to apps. Works with a shorter context."
        case .red: "Too big for this \(LooplDesign.deviceName) (\(MemoryBudget.label(budget)) available to apps) — it wants a Pro-class iPhone with 8 GB. Pick 2B here."
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
    /// The pick needs a Hugging Face token (a `gated` row, nobody signed in): the sign-in step replaces the cards.
    @State private var needsSignIn = false
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
    private var selection: ModelSpec? { chosen ?? Onboarding.preselected(cards, defaultId: defaultId) }
    /// The Apple Intelligence row (its card shows whenever the catalog has it; `appleFMReady` says whether it can run here).
    private var appleFM: ModelSpec? { store.catalog.models.first { $0.runtime == .appleFM } }
    private var appleFMAvailability: RuntimeAvailability {
        #if DEBUG
        if CommandLine.arguments.contains("--design-apple-fm") { return .ok }
        #endif
        return AppleFoundationModel.availability()
    }
    private var appleFMReady: Bool { appleFMAvailability.available }
    /// Signed in to Hugging Face? (`--design-mine` stands in for a token on the sim.)
    private var hfSignedIn: Bool {
        #if DEBUG
        if engine.hf.identity != nil { return true }
        #endif
        return engine.hf.isSignedIn
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
            hero
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
            HFSignInSheet(hf: engine.hf) {
                hfDismissed = true
                if needsSignIn { needsSignIn = false; start(selection, force: true) }
            }
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

    // MARK: the hero mark — ONE view that follows a placeholder in whichever stage is current

    /// Each stage lays out an invisible `markSlot` where the mark belongs and is the matched-geometry SOURCE only while
    /// it is the current stage; this single overlay follows, so the mark glides intro → header → pick → ring instead
    /// of two copies crossfading. While downloading its content is the progress ring; `morphFromCard` parks it on the
    /// chosen model card for one frame so the card is what grows into the ring.
    @State private var morphFromCard = false
    private var hero: some View {
        Group {
            if started { LooplProgressMark(progress: fraction) }
            else if stage == .intro { LooplMarkDrawing(progress: introProgress) }
            else { LooplMark() }
        }
        .matchedGeometryEffect(id: "mark", in: ns, isSource: false)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    private func markSlot(_ side: CGFloat, source: Bool) -> some View {
        Color.clear.frame(width: side, height: side)
            .matchedGeometryEffect(id: "mark", in: ns, isSource: source)
    }

    // MARK: intro — the mark draws itself, the word settles, one line

    @State private var introProgress: Double = 0
    @State private var introWord = false

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            markSlot(128, source: stage == .intro)
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
                markSlot(28, source: stage == .story)
                Spacer()
                skipButton
            }
            .padding(.horizontal, LooplDesign.gutter).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)   // chrome, like the footer

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
                    if started { progress.transition(.opacity) }
                    else if needsSignIn { signInStep.transition(.opacity) }
                    else { picker.transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .top).combined(with: .opacity)) }
                }
                .padding(.horizontal, LooplDesign.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                // While downloading there is little to show — centre it instead of leaving the lower half blank.
                // Not at accessibility sizes: there the content is taller than the screen and must scroll from the top.
                .modifier(CentredWhen(on: started && !type.isAccessibilitySize))
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar {
                if !started {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", systemImage: "chevron.backward") {
                            if needsSignIn { withAnimation(stageMotion) { needsSignIn = false } } else { advance(to: .story) }
                        }
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
            markSlot(started ? 128 : 56, source: (stage == .pick || stage == .download) && !morphFromCard)
                .accessibilityIdentifier("onboarding-mark")
                .accessibilityElement()
                .accessibilityLabel(started ? "Download progress" : "loopl")
                .accessibilityValue(started ? (fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "in progress") : "")
            Text(started ? title : needsSignIn ? "One more step" : "Pick your first model")
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
                let fit = Onboarding.fit(spec)
                let card = ModelCard(spec: spec, blurb: Onboarding.blurb(spec), recommended: spec.id == Onboarding.preferredId,
                                     fit: fit, fitLine: Onboarding.fitLine(spec, fit: fit),
                                     selected: selection?.id == spec.id, downloaded: store.states[spec.id]?.isDownloaded == true) {
                    withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { chosen = spec }
                    LooplDesign.haptic()
                }
                // The selected card is what morphs into the ring when Download is tapped (see `hero`). The effect is
                // attached only for that frame — a card carrying it with isSource == false would FOLLOW the mark slot.
                if morphFromCard, selection?.id == spec.id {
                    card.matchedGeometryEffect(id: "mark", in: ns, isSource: true)
                } else {
                    card
                }
            }
            networkLine.padding(.top, 4)
            if let fm = appleFM {
                appleCard(fm).padding(.top, 6)
            }
            Text("You can add, move or delete models any time in Models.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// Apple Intelligence as a real choice, not a footnote: already on the phone, nothing to download, private and
    /// offline — with the honest limits. On a device without it the card says why in one line.
    private func appleCard(_ fm: ModelSpec) -> some View {
        let ready = appleFMReady
        let why = appleFMAvailability.reason
        return Button { start(fm) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "apple.intelligence")
                    .font(.title2).foregroundStyle(ready ? AnyShapeStyle(LooplDesign.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 32).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(ready ? "Use Apple Intelligence" : "Apple Intelligence").font(.headline)
                        if ready { Pill("no download", tint: .green) }
                    }
                    Text(ready ? "Already on this \(LooplDesign.deviceName) — nothing to download. Private, instant, works offline."
                               : "Not available here: \(why).")
                        .font(.subheadline).foregroundStyle(ready ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
                    Text(ready ? "Text only, 4k context — no photos. You can switch any time in Models." : "Pick a loopl model above instead.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if ready { Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 3) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .accessibilityIdentifier("onboarding-apple-fm")
        .accessibilityLabel(ready ? "Use Apple Intelligence — already on this device, no download" : "Apple Intelligence not available: \(why)")
    }

    /// The pick is a private/gated repo and nobody is signed in: ask for the free Hugging Face account right here
    /// (same token sheet as the download's dead time), or take Apple Intelligence, or pick another model. Never a
    /// dead end. After PUBLISH flips the loopl rows to `gated: false` this step simply never shows.
    private var signInStep: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Image(systemName: "person.badge.key").font(.largeTitle).foregroundStyle(LooplDesign.accent)
                Text("Sign in to Hugging Face to download \(selection?.name ?? "this model")")
                    .font(.headline).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("The loopl models live on Hugging Face. A free account and a read token are all it takes — the weights then download straight to this \(LooplDesign.deviceName).")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboarding-signin")
            Button { hfSheet = true } label: {
                Text("Sign in to Hugging Face").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .accessibilityIdentifier("onboarding-signin-go")
            if let fm = appleFM, appleFMReady {
                Button { start(fm) } label: {
                    Label("Use Apple Intelligence instead — no account, no download", systemImage: "apple.intelligence")
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .accessibilityIdentifier("onboarding-signin-apple")
            }
            Button("Pick another model") { withAnimation(stageMotion) { needsSignIn = false } }
                .font(.subheadline).accessibilityIdentifier("onboarding-signin-back")
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
            if !hfSignedIn, !hfDismissed, !isReady {
                hfLine.padding(.top, 28).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The download's dead time asks the one optional question: a Hugging Face account unlocks private models,
    /// Share-to-dataset and Train your own. No permission prompts live here — mic/photos/camera stay just-in-time.
    private var hfLine: some View {
        VStack(spacing: 10) {
            Text("Have a Hugging Face account?").font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Sign in to download your private models and train on your own conversations.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            let buttons = type.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
            buttons {
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
            if needsSignIn, !started {
                EmptyView()
            } else if !started {
                Button { start(selection) } label: {
                    Text(downloadLabel)
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(selection == nil || (!net.online && !selectionDownloaded))
                .accessibilityIdentifier("onboarding-continue")
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

    private func start(_ spec: ModelSpec?, force: Bool = false) {
        guard let spec else { return }
        // A private/gated download with no token would fail on the first byte — ask for the account first instead.
        var gated = spec.gated
        #if DEBUG
        // Fixtures have no network: the sign-in step shows on demand (`--design-gated`), never from models.json.
        if DesignFixture.requested { gated = DesignFixture.flag("--design-gated") }
        #endif
        if !force, gated, spec.isDownloadable, !hfSignedIn, store.states[spec.id]?.isDownloaded != true {
            LooplDesign.haptic()
            withAnimation(stageMotion) { needsSignIn = true }
            return
        }
        Onboarding.markDone()
        LooplDesign.haptic(1)
        if reduceMotion || stage != .pick || spec.id != selection?.id {
            withAnimation(stageMotion) { started = true; stage = .download }
        } else {
            // Frame 1 (no animation): the hero parks on the chosen card. Frame 2: card and hero become the ring together.
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { morphFromCard = true }
            DispatchQueue.main.async {
                withAnimation(stageMotion) { morphFromCard = false; started = true; stage = .download }
            }
        }
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
    var fit: HubCatalog.Fit = .green
    var fitLine: String? = nil
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
                    HStack(alignment: .firstTextBaseline) {
                        Text(spec.name.replacingOccurrences(of: " (4-bit)", with: "")).font(.headline)
                        Spacer(minLength: 8)
                        // The size shares the title row so the blurb below can use the card's full width.
                        if !ax { Text(spec.sizeLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    // The pills wrap when they must: 2B carries "Recommended · fast + smart" + "vision" (+ a fit badge).
                    WrapPills {
                        if recommended { Pill(Onboarding.recommendedBadge) }
                        if spec.supportsVision { Pill("vision", tint: .secondary) }
                        if downloaded { Pill("on device", tint: .green) }
                        else if fit != .green { FitBadge(fit: fit) }
                        if ax { Text(spec.sizeLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    Text(blurb).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let fitLine, !downloaded {
                        Label(fitLine, systemImage: fit == .red ? "exclamationmark.triangle.fill" : "memorychip")
                            .font(.footnote).foregroundStyle(fit == .red ? Color.red : LooplDesign.amber)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("onboarding-fit-\(spec.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// Pills on one line when they fit, wrapping to the next otherwise (the 2B card carries three).
private struct WrapPills<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { FlowLayout(spacing: 6) { content } }
}

/// Minimal left-to-right flow: each subview at its ideal size, new row when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
