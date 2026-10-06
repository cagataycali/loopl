import Foundation
import Observation
import SwiftUI
import Loopl
import LooplRuntimes
import LooplUI
import LooplAppleTools

/// App-wide settings, persisted in UserDefaults. Generation limits are not
/// settings any more: the loop runs until the model stops, the context is the
/// model's recommended window, max new tokens is bounded only by that window.
@MainActor @Observable
public final class AppSettings {
    public var offline: Bool { didSet { NetworkPolicy.setOffline(offline) } }
    public var systemPrompt: String { didSet { UserDefaults.standard.set(systemPrompt, forKey: "loopl.system") } }
    public var enabledTools: Set<String> { didSet { UserDefaults.standard.set(Array(enabledTools), forKey: "loopl.tools") } }
    /// Settings › Show performance details — OFF by default; one quiet footer line when on.
    public var showPerformance: Bool { didSet { UserDefaults.standard.set(showPerformance, forKey: "loopl.perf") } }
    /// Settings › Show GGUF builds — OFF by default: the Models tab leads with the MLX models; llama.cpp builds (text only) appear when on.
    /// Downloaded GGUF models always stay listed under "On this device".
    public var showGGUF: Bool { didSet { UserDefaults.standard.set(showGGUF, forKey: "loopl.gguf") } }
    /// Catalog id of the model to load at launch (the last one the user picked).
    public var lastModelId: String? { didSet { UserDefaults.standard.set(lastModelId, forKey: "loopl.lastModel") } }
    /// Settings › Ask before: which `http` calls show an approval card (SDK `ApprovalPolicy.Mode`). Read by the policy hook on every call.
    public var askBefore: ApprovalPolicy.Mode { didSet { UserDefaults.standard.set(askBefore.rawValue, forKey: Self.askBeforeKey) } }
    /// Settings › Haptics — ON by default; off silences loopl's own feedback (send, tool start/finish, model loaded…).
    public var haptics: Bool { didSet { UserDefaults.standard.set(haptics, forKey: "loopl.haptics"); LooplDesign.hapticsEnabled = haptics } }
    /// Settings › Appearance — follows the system unless the user picks light or dark.
    public var appearance: Appearance { didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "loopl.appearance") } }
    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark
        public var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
        public var label: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
    }
    nonisolated public static let askBeforeKey = "loopl.askBefore"

    /// The default system prompt — yours to edit in Settings; nothing is added in front of it for any model (PR #89).
    /// The memory sentence is MEASURED (MemoryProbeTests, 2026-10-06): without it Qwen3.5-0.8B never calls remember/recall
    /// (0/16 greedy) and loopl-0.8b answers "what is my name?" about itself; with it both reach 8/8. Mirrored in
    /// loopl-train data/system/app-default.md (1.1.0 = Phase 6 directives: manage_tools mount before "I can't", manage_messages stats/compact,
    /// use_agent; measured in ManageToolsMeasurement / ManageMessagesMeasurement, 2026-10-06) — bump its version when this text changes.
    public static let defaultSystemPrompt = "You are loopl, a helpful assistant running fully on this device. Use tools when they help; answer concisely. Your only memory between conversations is the remember and recall tools: when the user asks you to remember something, call remember; before answering anything about the user, call recall. If a task needs a tool that is not in your tool list, call manage_tools with action mount and its name before saying you can't — it works on your very next step. When this conversation gets long or you are asked how big it is, call manage_messages (stats to measure, compact to shrink your own context; the user's chat is unchanged). For a side task or a long one, call use_agent with a short system prompt, the task and only the tools it needs; a background agent wakes you when it finishes."
    /// Earlier defaults (build ≤ 9; builds 10–14 = 1.0.1) — an unedited stored prompt equal to one of them is upgraded to the current default on launch.
    public static let legacyDefaultSystemPrompts: Set<String> = ["You are loopl, a helpful assistant running fully on this device. Use tools when they help; answer concisely.",
        "You are loopl, a helpful assistant running fully on this device. Use tools when they help; answer concisely. Your only memory between conversations is the remember and recall tools: when the user asks you to remember something, call remember; before answering anything about the user, call recall."]
    public static let allToolNames = ["current_time", "calculator", "device_info", "remember", "recall", "http", "manage_messages", "use_agent"]
    /// Portable tools added after build 12 — switched ON for installs whose saved set predates them (once; a user
    /// who turns one off afterwards stays off because the name is then recorded in `loopl.toolsSeen`).
    public static let laterCoreTools = ["manage_messages", "use_agent"]

    public init() {
        let d = UserDefaults.standard
        offline = d.bool(forKey: NetworkPolicy.offlineKey)
        let stored = d.string(forKey: "loopl.system")
        systemPrompt = stored.map { Self.legacyDefaultSystemPrompts.contains($0) ? Self.defaultSystemPrompt : $0 } ?? Self.defaultSystemPrompt
        var saved = Set((d.array(forKey: "loopl.tools") as? [String]) ?? Self.allToolNames)
        if saved.remove("http_get") != nil { saved.insert("http") }     // 0.1 → http (http_get is a deprecated SDK alias)
        var seen = Set((d.array(forKey: "loopl.toolsSeen") as? [String]) ?? [])
        for name in Self.laterCoreTools where !seen.contains(name) { saved.insert(name); seen.insert(name) }
        d.set(Array(seen), forKey: "loopl.toolsSeen")
        enabledTools = saved
        askBefore = ApprovalPolicy.Mode(rawValue: d.string(forKey: Self.askBeforeKey) ?? "") ?? .mutating
        showPerformance = d.bool(forKey: "loopl.perf")
        showGGUF = d.bool(forKey: "loopl.gguf") || CommandLine.arguments.contains("--design-gguf")
        lastModelId = d.string(forKey: "loopl.lastModel")
        haptics = d.object(forKey: "loopl.haptics") == nil ? true : d.bool(forKey: "loopl.haptics")
        appearance = Appearance(rawValue: d.string(forKey: "loopl.appearance") ?? "") ?? .system
        LooplDesign.hapticsEnabled = haptics
        // Retired keys from 0.1 (demo runtime, HF token, iteration cap) are simply ignored.
        for k in ["loopl.demo", "loopl.maxIter", "loopl.runtime", "loopl.maxTokens", "loopl.ctx", "loopl.temp"] { d.removeObject(forKey: k) }
    }
}

/// Where the engine is between launch and "a model is ready" — rendered inline
/// at the top of the chat, never as a modal.
public enum Readiness: Hashable, Sendable {
    case idle
    case downloading(ModelSpec, done: Int64, total: Int64)
    case loading(ModelSpec, progress: Double)
    /// Re-fetching the model's small files (tokenizer/template/config) from the Hub after a tokenizer load error — weights stay.
    case repairing(ModelSpec)
    case ready(ModelSpec)
    case failed(ModelSpec?, String)

    public var spec: ModelSpec? {
        switch self {
        case .idle: nil
        case .downloading(let s, _, _), .loading(let s, _), .repairing(let s), .ready(let s): s
        case .failed(let s, _): s
        }
    }
    public var isBusy: Bool {
        switch self { case .downloading, .loading, .repairing: true; default: false }
    }
    public var isFailed: Bool { if case .failed = self { return true }; return false }
}

/// The main-actor face of the SDK: owns the active `Model`, the `Agent`, the
/// readiness state and the `Transcript` the Chat tab renders.
@MainActor @Observable
public final class Engine {
    public let settings: AppSettings
    public let store: ModelStore
    /// Hugging Face sign-in state (Settings › Hugging Face, Models › Mine). The token itself stays in `HFAccount.shared`.
    public let hf = HFSession()
    public var transcript = Transcript()
    public var readiness: Readiness = .idle
    public var lastError: String?
    /// Every haptic the engine wants felt (send, tool start/finish, model loaded, download done,
    /// error) goes through this bus; `RootView` plays it with `.sensoryFeedback`, ≤ 1 per 250 ms.
    public let haptics = HapticBus()
    let archive = ConversationArchive()
    private(set) var currentId = UUID()
    /// When the current thread was last rewritten by Edit / Retry / Delete from here (persisted with it).
    private(set) var currentEditedAt: Date?
    /// #21: the model that wrote the answers of a REOPENED thread, as it was saved with it (`SavedConversation.modelName`).
    /// Set by `open`, cleared by `newConversation` / `clear` — nil for a thread started in this session.
    private(set) var openedUnder: String?
    /// True once this session has generated into that reopened thread, so the subtitle can say *earlier* answers.
    private(set) var continuedHere = false
    private var model: (any Model)?
    private var agent: Agent?
    private var runTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    /// Sub-agents (`use_agent`): every child of this engine, their envelopes and the detached event stream (SDK SubAgentHub).
    public let hub: SubAgentHub
    /// One loaded model, many agents: the parent and every child take this gate for each model call (FIFO).
    private let gate = ModelGate()
    /// Background children that finished while the parent was busy or the user was typing — woken in order when idle.
    private(set) var pendingWakes: [SubAgentEnvelope] = []
    /// The composer has focus and text in it: a wake waits (wake.ts: never run an autonomous turn over a human mid-sentence).
    public var userIsTyping = false { didSet { if !userIsTyping { drainWakes() } } }
    private var detachedTask: Task<Void, Never>?

    public init(settings: AppSettings, store: ModelStore) {
        self.settings = settings
        self.store = store
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.hub = SubAgentHub(directory: base.appendingPathComponent("agents", isDirectory: true))
        // A background child's events after the parent's turn ended: fold them into the card on screen.
        detachedTask = Task { [weak self] in
            guard let hub = self?.hub else { return }
            for await event in hub.detachedEvents() {
                guard let self else { return }
                if self.transcript.agentIndex(Self.childId(of: event)) != nil { self.transcript.apply(event); self.archiveCurrent() }
            }
        }
        let hub = self.hub
        Task { [weak self] in
            await hub.setOnFinished { env in Task { @MainActor in self?.childFinished(env) } }
        }
    }

    /// The child id an event is about (nil for the parent's own events).
    nonisolated static func childId(of e: AgentEvent) -> String {
        switch e {
        case .childStarted(let i): i.id
        case .child(let id, _), .childStatus(let id, _): id
        default: ""
        }
    }

    public var loadedModel: ModelSpec? { if case .ready(let s) = readiness { return s }; return nil }
    /// #21: the name to show under the chat title — set only when the turns on screen were answered by a
    /// DIFFERENT model than the one loaded now (reopen a thread, or switch model with it open). A reopened
    /// thread gets a fresh context, so without this the old answers look like the current model's work.
    public var answeredBy: String? {
        guard let openedUnder, !openedUnder.isEmpty, openedUnder != loadedModel?.name else { return nil }
        return openedUnder
    }
    public var loadProgress: Double? { if case .loading(_, let p) = readiness { return p }; return nil }
    public var isGenerating: Bool { transcript.isRunning }
    public var allTools: [any Tool] { [CurrentTimeTool(), CalculatorTool(), DeviceInfoTool(), RememberTool(), RecallTool(), HttpTool(), ManageMessagesTool(), useAgentTool] }
    /// `use_agent`: children are built from the parent's model, gate, tools (minus use_agent — depth 1) and approval hook,
    /// read at spawn time so a model switch is honoured.
    private var useAgentTool: UseAgentTool {
        UseAgentTool(hub: hub) { [weak self] in
            await MainActor.run {
                guard let self, let model = self.model else { return nil }
                return SubAgentContext(model: model, gate: self.gate, availableTools: self.activeTools, hooks: [self.approvalPolicy])
            }
        }
    }
    /// Human-in-the-loop policy: reads Settings › Ask before on every call, so no agent rebuild is needed.
    private let approvalPolicy = ApprovalPolicy(modeProvider: {
        ApprovalPolicy.Mode(rawValue: UserDefaults.standard.string(forKey: AppSettings.askBeforeKey) ?? "") ?? .mutating
    })
    /// Answer an `ApprovalCard` (the transcript shows it until the agent emits `.approvalResolved`). A card inside a
    /// sub-agent's card is answered on that child (the parent knows nothing about it).
    public func resolve(_ request: ApprovalRequest, _ decision: ApprovalDecision) {
        guard let agent else {
            if DesignFixture.requested { Task { await DesignFixture.resolve(self, request, decision) } }   // DEBUG fixture, no model
            return
        }
        let children = transcript.agents.filter { !$0.status.isFinished }.map(\.info.id)
        Task {
            if await agent.resolve(approval: request.id, decision) { return }
            for id in children where await hub.resolve(child: id, approval: request.id, decision) { return }
        }
    }
    public var activeTools: [any Tool] { allTools.filter { settings.enabledTools.contains($0.name) } + AppleToolPrefs.shared.active }
    /// Settings' one-line answer to "how many tools does the model get?" — the portable tools AND the
    /// on-device Apple ones that are switched on and runnable here (`ToolCountSummary`). Counting only
    /// `allTools` is what made build 10 say "6 of 6" above eight Apple toggles that were all on.
    public var toolSummary: String {
        ToolCountSummary.label(core: allTools.count,
                               coreEnabled: allTools.filter { settings.enabledTools.contains($0.name) }.count,
                               apple: AppleTools.all.map { (AppleToolPrefs.shared.enabled.contains($0.name), type(of: $0).availability().available) })
    }

    /// The model to bring up at launch: the last used one, else the catalog default
    /// (mlx-community/Qwen3-0.6B-4bit), else the smallest downloadable model.
    public var startupSpec: ModelSpec? {
        let models = store.catalog.models.filter { $0.runtime != .appleFM || AppleFoundationModel.availability().available }
        if let id = settings.lastModelId, let s = models.first(where: { $0.id == id }) {
            // Last used model lives on a drive that is not plugged in → start on the default instead, and say so.
            if let drive = store.storage.missingDrive(for: s) {
                transcript.note("\(s.name) is on \(drive), which isn't plugged in — using the default model until it is.")
            } else if let u = store.storage.unreadableDrive(for: s) {
                transcript.note("\(s.name) is on \(u.name), which is connected but can't be read right now — re-grant its folder in Settings › Storage. Using the default model until then.")
            } else { return s }
        }
        // The default (or anything else) sitting on a drive that is away/unreadable is not a startup candidate —
        // a model that IS here beats a download, and a download beats a drive error on the launch screen.
        let onDevice = models.filter { store.states[$0.id]?.isDownloaded == true }
        if let id = store.catalog.defaultModelId, let s = models.first(where: { $0.id == id }) {
            if store.storage.anyDriveProblem(for: s) == nil { return s }
            if let here = onDevice.first { return here }
            return s
        }
        if let here = onDevice.min(by: { $0.sizeBytes < $1.sizeBytes }) { return here }
        return models.filter { $0.isDownloadable && store.storage.anyDriveProblem(for: $0) == nil }.min { $0.sizeBytes < $1.sizeBytes }
    }

    /// First launch: download the default model with inline progress, then load.
    /// Every launch: load the last-used model. Idempotent.
    public func bootstrap() {
        guard case .idle = readiness, bootstrapTask == nil, let spec = startupSpec else { return }
        bootstrapTask = Task { [weak self] in
            await self?.select(spec)
            self?.bootstrapTask = nil
        }
    }

    /// Switch to `spec`: download if needed (progress inline), then load. Remembers the choice.
    public func select(_ spec: ModelSpec) async {
        lastError = nil
        if let problem = store.storage.anyDriveProblem(for: spec) {
            readiness = loadedModel.map { .ready($0) } ?? .failed(spec, problem)
            lastError = problem
            haptics.emit(.error); return
        }
        if spec.isDownloadable, store.localDirectory(spec) == nil {
            // A model RECORDED on a drive is never re-downloaded behind the user's back: if its files are not
            // where storage.json says, the row has to say so (needs drive / unreadable / gone), not fetch 500 MB.
            if store.storage.location(of: spec.id).isExternal {
                store.refresh()
                let msg = store.storage.anyDriveProblem(for: spec) ?? "\(spec.name) should be on \(store.locationName(spec)) but its files are not there — download it again from Models."
                store.storage.diagnostics.log("\(spec.id): select refused auto-download — \(msg)")
                readiness = loadedModel.map { .ready($0) } ?? .failed(spec, msg); lastError = msg; haptics.emit(.error); return
            }
            if settings.offline || NetworkPolicy.isOffline {
                readiness = .failed(spec, "\(spec.name) is not on this device and offline mode is on."); return
            }
            readiness = .downloading(spec, done: 0, total: spec.sizeBytes)
            store.download(spec)
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { readiness = .idle; return }
                switch store.states[spec.id] ?? .notDownloaded {
                case .downloading(let done, let total, _, _): readiness = .downloading(spec, done: done, total: total); continue
                case .downloaded: haptics.emit(.downloadFinished); break
                case .failed(let msg): readiness = .failed(spec, msg); haptics.emit(.error); return
                case .paused: readiness = .failed(spec, "Download paused — resume it from Models."); return
                case .notDownloaded: readiness = .failed(spec, "download stopped"); return
                case .needsDrive(let d): readiness = .failed(spec, "\(spec.name) is on \(d). Plug it in to use it."); return
                case .driveUnreadable(let d, _): readiness = .failed(spec, "\(d) is connected but loopl can't read it — re-grant its folder in Settings › Storage."); return
                case .moving: continue
                }
                break
            }
        }
        await load(spec)
    }

    public func load(_ spec: ModelSpec) async { await load(spec, repaired: false) }

    /// Loads `spec`; when the load fails ON THE TOKENIZER FILES (unknown tokenizer_class, missing chat template) and the
    /// model came from the Hub, refresh its small files once (`ModelStore.repairFiles`, weights untouched) and retry.
    private func load(_ spec: ModelSpec, repaired: Bool) async {
        lastError = nil
        let previous = loadedModel
        readiness = .loading(spec, progress: 0)
        let m: any Model = switch spec.runtime {
        case .mlx: MLXModel()
        case .appleFM: AppleFoundationModel()
        case .gguf: GGUFModel()
        }
        let dir = spec.isDownloadable ? store.localDirectory(spec) : nil
        if spec.isDownloadable && dir == nil {
            if let problem = store.storage.anyDriveProblem(for: spec) { readiness = .failed(spec, problem); return }
            readiness = .failed(spec, "\(spec.name) is not downloaded yet"); return
        }
        do {
            try await m.load(spec, from: dir) { p in Task { @MainActor in if case .loading = self.readiness { self.readiness = .loading(spec, progress: p) } } }
            if let old = model { await old.unload() }
            model = m
            agent = nil
            readiness = .ready(spec)
            settings.lastModelId = spec.id
            if previous != nil || !transcript.items.isEmpty { transcript.note("Switched to \(spec.name)") }
            haptics.emit(.modelLoaded)
        } catch {
            if !repaired, spec.isDownloadable, spec.runtime == .mlx, TokenizerFiles.isTokenizerError(error),
               !settings.offline, !NetworkPolicy.isOffline {
                // The files next to the weights are wrong for this app (e.g. a repo exported with transformers 5 that has
                // since been fixed on the Hub). Refresh just those — a few KB — and try once more. Never the weights.
                readiness = .repairing(spec)
                transcript.note("Repairing \(spec.name)'s model files…")
                do {
                    let changed = try await store.repairFiles(spec)
                    if !changed.isEmpty { await load(spec, repaired: true); return }
                    lastError = nil
                    readiness = .failed(spec, "\(spec.name) can't load: \(error.localizedDescription). Its files match Hugging Face, so the repo itself needs fixing.")
                } catch let repairError {
                    readiness = .failed(spec, TokenizerFiles.repairMessage(for: spec.name) + " Repair failed: \(repairError.localizedDescription)")
                }
                haptics.emit(.error)
                return
            }
            if TokenizerFiles.isTokenizerError(error), spec.isDownloadable, spec.runtime == .mlx {
                readiness = .failed(spec, TokenizerFiles.repairMessage(for: spec.name) + " (\(error.localizedDescription))")
                lastError = nil; haptics.emit(.error); return
            }
            // A drive pulled mid-load reads as a missing file: say which drive, not "No such file".
            let reason = store.storage.location(of: spec.id).isExternal && store.storage.directory(for: spec) == nil
                ? "\(store.locationName(spec)) was disconnected while loading \(spec.name)."
                : error.localizedDescription
            // Said once: with no model to fall back to, the readiness banner carries the message (and Try again);
            // when the previous model stays loaded, the banner shows nothing and the inline line says what failed.
            if let previous { readiness = .ready(previous); lastError = "\(spec.name) failed to load: \(reason)" }
            else { readiness = .failed(spec, reason); lastError = nil }
            haptics.emit(.error)
        }
    }

    public func unload() async {
        await model?.unload()
        model = nil; agent = nil
        readiness = .idle
    }

    /// The model is gone from disk — drop it if it is the loaded one.
    public func didDelete(_ spec: ModelSpec) {
        if loadedModel?.id == spec.id { Task { await unload() } }
        if settings.lastModelId == spec.id { settings.lastModelId = nil }
    }

    public func clear() { transcript.clear(); agent = nil; openedUnder = nil; continuedHere = false; stopChildren() }

    /// A child belongs to the thread that spawned it: leaving the thread (new / open / delete / clear) cancels every live
    /// child and drops wakes that have not run — a finished envelope stays answerable by id for this session.
    private func stopChildren() {
        pendingWakes.removeAll()
        Task { await hub.stopAll() }
    }

    /// Save what is on screen (if anything was said) and start fresh.
    public func newConversation() {
        guard !isGenerating else { return }
        archiveCurrent()
        transcript.clear(); agent = nil; currentId = UUID(); currentEditedAt = nil
        openedUnder = nil; continuedHere = false
        stopChildren()
    }

    /// Reopen a saved conversation. The model starts a fresh context — the
    /// visible turns are restored, not the raw token history.
    func open(_ c: SavedConversation) {
        guard !isGenerating else { return }
        archiveCurrent()
        currentId = c.id
        currentEditedAt = c.editedAt
        transcript = c.transcript()
        agent = nil
        openedUnder = c.modelName
        continuedHere = false
        stopChildren()
    }

    func delete(_ c: SavedConversation) { delete(ids: [c.id]) }

    /// Delete several saved conversations at once (History › Select → Delete). If the thread on screen is among
    /// them, the chat resets to a fresh, empty one — transcript, agent and model context — so nothing stale is kept.
    /// Returns how many threads were removed.
    @discardableResult
    func delete(ids: Set<UUID>) -> Int {
        let n = archive.delete(ids: ids)
        if ids.contains(currentId) { transcript.clear(); agent = nil; currentId = UUID(); currentEditedAt = nil; openedUnder = nil; continuedHere = false; stopChildren() }
        return n
    }

    private func archiveCurrent() {
        if let saved = SavedConversation.from(transcript, id: currentId, modelName: loadedModel?.name, editedAt: currentEditedAt,
                                              modelId: loadedModel.map { $0.repo.isEmpty ? $0.id : $0.repo }, tools: activeTools.map(\.toolSpec)) { archive.upsert(saved) }
    }

    // MARK: - Hold a message: Edit · Delete from here · Retry

    /// Edit a user turn and regenerate: everything from that turn on is removed, the model's history is
    /// rebuilt from what is kept (`Transcript.messages`), a FRESH agent is started on it and the edited
    /// text is sent as an ordinary turn — tools, approvals and the event loop exactly as for a new message.
    /// The pictures attached to the original turn travel with the edit.
    public func edit(_ itemId: UUID, text: String) {
        guard !isGenerating, loadedModel != nil, let item = transcript.item(itemId), case .user = item.kind else { return }
        let kept = transcript.truncated(before: itemId)
        rewrite(kept)
        regenerate(text, images: item.images)
    }

    /// Re-run the agent from the user turn that owns `itemId` (an assistant row, a tool row — or a user row itself).
    public func retry(_ itemId: UUID) {
        guard !isGenerating, loadedModel != nil, let turn = transcript.userTurn(before: itemId), case .user(let text) = turn.kind else { return }
        let kept = transcript.truncated(before: turn.id)
        rewrite(kept)
        regenerate(text, images: turn.images)
    }

    /// The edited / retried turn goes through `send` like any other. DEBUG design fixtures have no model
    /// behind the "ready" state, so they replay a scripted answer instead (captures only).
    private func regenerate(_ text: String, images: [ImageBlock]) {
        if model == nil, DesignFixture.requested { Task { await DesignFixture.regenerate(self, text: text, images: images) }; return }
        send(text, images: images)
    }

    /// Remove `itemId` and everything after it. The thread stays open for a new message.
    public func deleteFrom(_ itemId: UUID) {
        guard !isGenerating, transcript.index(of: itemId) != nil else { return }
        rewrite(transcript.truncated(before: itemId))
        if transcript.items.isEmpty { archive.delete(id: currentId) } else { archiveCurrent() }
    }

    /// Install a truncated transcript: the agent is rebuilt lazily on the kept history, the edit is stamped.
    private func rewrite(_ kept: Transcript) {
        transcript = kept
        currentEditedAt = Date()
        lastError = nil
        if let model {
            let a = Agent(model: model, tools: activeTools, systemPrompt: effectiveSystemPrompt, messages: kept.messages, hooks: [approvalPolicy])
            agent = a
        } else {
            agent = nil
        }
    }

    /// Can the loaded model look at pictures? (`ModelSpec.vision`, MLX runtime.) Gates the composer's attach button.
    public var canSeeImages: Bool { loadedModel?.supportsVision == true }

    /// The system prompt the model gets: Settings › System prompt, as the user wrote it, for every model. loopl's own
    /// models carry their identity in their weights (loopl-train bakes it in), so nothing is prepended here.
    public var effectiveSystemPrompt: String { settings.systemPrompt }

    public func send(_ text: String, images: [ImageBlock] = []) {
        guard !isGenerating else { return }
        #if DEBUG
        // A design fixture is "ready" with nothing behind it. Replay the scripted answer instead of refusing —
        // the same path Edit / Retry already take (`regenerate`), so a fixture can be continued for a capture.
        if model == nil, DesignFixture.requested, case .ready = readiness, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            continuedHere = true
            Task { await DesignFixture.regenerate(self, text: text, images: images) }
            return
        }
        #endif
        guard let model, let spec = loadedModel else { lastError = "the model is still loading"; haptics.emit(.error); return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        lastError = nil
        haptics.emit(.send)
        continuedHere = true   // #21: from here on the thread also holds this model's answers
        // Generation params are the model's own maxed defaults (spec.defaultParams, set at load): no caps here.
        let agent = self.agent ?? Agent(model: model, tools: activeTools, systemPrompt: effectiveSystemPrompt, hooks: [approvalPolicy])
        self.agent = agent
        // A text model cannot see: keep the picture in the transcript (so the user knows what was sent)
        // but tell them, and send the words only — never silently drop or pretend.
        var sent = images
        if !images.isEmpty, !spec.supportsVision {
            sent = []
            transcript.note("\(spec.name) can't see pictures — pick a vision model (Qwen3-VL, Qwen3.5…) in Models. Sent the text only.")
        }
        transcript.user(text, images: images)
        let prompt = text.isEmpty ? "What's in this image?" : text
        start(agent, Loopl.Message.user(prompt, images: sent))
    }

    /// Run one turn of `agent` on `message`, folding every event into the transcript. Shared by `send` and the wake.
    private func start(_ agent: Agent, _ message: Loopl.Message) {
        let tools = activeTools, system = effectiveSystemPrompt, gate = self.gate
        transcript.isRunning = true
        runTask = Task { [weak self] in
            await agent.setTools(tools); await agent.setSystemPrompt(system); await agent.setModelGate(gate)
            do {
                for try await event in agent.stream([message]) {
                    guard let self else { return }
                    if self.transcript.apply(event) { self.archiveCurrent() }
                    switch event {
                    case .toolStarted: self.haptics.emit(.toolStart)
                    case .approvalRequested, .child(_, .approvalRequested): self.haptics.emit(.approvalNeeded)
                    case .toolResult(let r): self.haptics.emit(r.isError ? .error : .toolFinish)
                    default: break
                    }
                }
            } catch {
                self?.haptics.emit(.error)
                self?.lastError = error.localizedDescription
                self?.transcript.note("error: \(error.localizedDescription)")
                self?.transcript.isRunning = false
            }
            self?.drainWakes()      // a child that finished while this turn ran
        }
    }

    // MARK: - Sub-agent wake (SDK `SubAgentHub.onFinished` → a synthetic turn on the parent)

    /// A DETACHED child finished (any outcome). Runs the parent on "[use_agent <id> finished] <result>" now, or queues
    /// it while the parent is generating / the user is typing / no model is loaded (FIFO, one in flight — wake.ts).
    private func childFinished(_ env: SubAgentEnvelope) {
        guard transcript.agentIndex(env.id) != nil else { return }   // belongs to a thread that is no longer on screen
        pendingWakes.append(env)
        drainWakes()
    }

    private func drainWakes() {
        guard !isGenerating, !userIsTyping, let model, loadedModel != nil, !pendingWakes.isEmpty else { return }
        let env = pendingWakes.removeFirst()
        let prompt = SubAgentWake.prompt(for: env)
        let agent = self.agent ?? Agent(model: model, tools: activeTools, systemPrompt: effectiveSystemPrompt, hooks: [approvalPolicy])
        self.agent = agent
        transcript.note(SubAgentWake.line(for: env))   // one system-styled line (`SubAgentWake.prefix`), not the user speaking
        haptics.emit(.toolFinish)
        start(agent, Loopl.Message.user(prompt))
    }

    public func stop() {
        runTask?.cancel()
        #if DEBUG
        DesignFixture.replay?.cancel()
        #endif
    }
}
