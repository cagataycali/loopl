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
    /// Catalog id of the model to load at launch (the last one the user picked).
    public var lastModelId: String? { didSet { UserDefaults.standard.set(lastModelId, forKey: "loopl.lastModel") } }
    /// Settings › Ask before: which `http` calls show an approval card (SDK `ApprovalPolicy.Mode`). Read by the policy hook on every call.
    public var askBefore: ApprovalPolicy.Mode { didSet { UserDefaults.standard.set(askBefore.rawValue, forKey: Self.askBeforeKey) } }
    nonisolated public static let askBeforeKey = "loopl.askBefore"

    public static let defaultSystemPrompt = "You are loopl, a helpful assistant running fully on this iPhone. Use tools when they help; answer concisely."
    public static let allToolNames = ["current_time", "calculator", "device_info", "remember", "recall", "http"]

    public init() {
        let d = UserDefaults.standard
        offline = d.bool(forKey: NetworkPolicy.offlineKey)
        systemPrompt = d.string(forKey: "loopl.system") ?? Self.defaultSystemPrompt
        var saved = Set((d.array(forKey: "loopl.tools") as? [String]) ?? Self.allToolNames)
        if saved.remove("http_get") != nil { saved.insert("http") }     // 0.1 → http (http_get is a deprecated SDK alias)
        enabledTools = saved
        askBefore = ApprovalPolicy.Mode(rawValue: d.string(forKey: Self.askBeforeKey) ?? "") ?? .mutating
        showPerformance = d.bool(forKey: "loopl.perf")
        lastModelId = d.string(forKey: "loopl.lastModel")
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
    case ready(ModelSpec)
    case failed(ModelSpec?, String)

    public var spec: ModelSpec? {
        switch self {
        case .idle: nil
        case .downloading(let s, _, _), .loading(let s, _), .ready(let s): s
        case .failed(let s, _): s
        }
    }
    public var isBusy: Bool { if case .downloading = self { return true }; if case .loading = self { return true }; return false }
}

/// The main-actor face of the SDK: owns the active `Model`, the `Agent`, the
/// readiness state and the `Transcript` the Chat tab renders.
@MainActor @Observable
public final class Engine {
    public let settings: AppSettings
    public let store: ModelStore
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
    private var model: (any Model)?
    private var agent: Agent?
    private var runTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?

    public init(settings: AppSettings, store: ModelStore) {
        self.settings = settings
        self.store = store
    }

    public var loadedModel: ModelSpec? { if case .ready(let s) = readiness { return s }; return nil }
    public var loadProgress: Double? { if case .loading(_, let p) = readiness { return p }; return nil }
    public var isGenerating: Bool { transcript.isRunning }
    public var allTools: [any Tool] { [CurrentTimeTool(), CalculatorTool(), DeviceInfoTool(), RememberTool(), RecallTool(), HttpTool()] }
    /// Human-in-the-loop policy: reads Settings › Ask before on every call, so no agent rebuild is needed.
    private let approvalPolicy = ApprovalPolicy(modeProvider: {
        ApprovalPolicy.Mode(rawValue: UserDefaults.standard.string(forKey: AppSettings.askBeforeKey) ?? "") ?? .mutating
    })
    /// Answer an `ApprovalCard` (the transcript shows it until the agent emits `.approvalResolved`).
    public func resolve(_ request: ApprovalRequest, _ decision: ApprovalDecision) {
        guard let agent else {
            if DesignFixture.requested { Task { await DesignFixture.resolve(self, request, decision) } }   // DEBUG fixture, no model
            return
        }
        Task { await agent.resolve(approval: request.id, decision) }
    }
    public var activeTools: [any Tool] { allTools.filter { settings.enabledTools.contains($0.name) } + AppleToolPrefs.shared.active }

    /// The model to bring up at launch: the last used one, else the catalog default
    /// (mlx-community/Qwen3-0.6B-4bit), else the smallest downloadable model.
    public var startupSpec: ModelSpec? {
        let models = store.catalog.models.filter { $0.runtime != .appleFM || AppleFoundationModel.availability().available }
        if let id = settings.lastModelId, let s = models.first(where: { $0.id == id }) { return s }
        if let id = store.catalog.defaultModelId, let s = models.first(where: { $0.id == id }) { return s }
        return models.filter(\.isDownloadable).min { $0.sizeBytes < $1.sizeBytes }
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
        if spec.isDownloadable, store.localDirectory(spec) == nil {
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
                case .paused, .notDownloaded: readiness = .failed(spec, "download stopped"); return
                }
                break
            }
        }
        await load(spec)
    }

    public func load(_ spec: ModelSpec) async {
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
            readiness = previous.map { .ready($0) } ?? .failed(spec, error.localizedDescription)
            lastError = error.localizedDescription
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

    public func clear() { transcript.clear(); agent = nil }

    /// Save what is on screen (if anything was said) and start fresh.
    public func newConversation() {
        guard !isGenerating else { return }
        archiveCurrent()
        transcript.clear(); agent = nil; currentId = UUID(); currentEditedAt = nil
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
    }

    func delete(_ c: SavedConversation) {
        archive.delete(c)
        if c.id == currentId { transcript.clear(); agent = nil; currentId = UUID(); currentEditedAt = nil }
    }

    private func archiveCurrent() {
        if let saved = SavedConversation.from(transcript, id: currentId, modelName: loadedModel?.name, editedAt: currentEditedAt) { archive.upsert(saved) }
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
            let a = Agent(model: model, tools: activeTools, systemPrompt: settings.systemPrompt, messages: kept.messages, hooks: [approvalPolicy])
            agent = a
        } else {
            agent = nil
        }
    }

    /// Can the loaded model look at pictures? (`ModelSpec.vision`, MLX runtime.) Gates the composer's attach button.
    public var canSeeImages: Bool { loadedModel?.supportsVision == true }

    public func send(_ text: String, images: [ImageBlock] = []) {
        guard !isGenerating else { return }
        guard let model, let spec = loadedModel else { lastError = "the model is still loading"; haptics.emit(.error); return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        lastError = nil
        haptics.emit(.send)
        // Generation params are the model's own maxed defaults (spec.defaultParams, set at load): no caps here.
        let agent = self.agent ?? Agent(model: model, tools: activeTools, systemPrompt: settings.systemPrompt, hooks: [approvalPolicy])
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
        let message = Loopl.Message.user(prompt, images: sent)
        let tools = activeTools, system = settings.systemPrompt
        runTask = Task { [weak self] in
            await agent.setTools(tools); await agent.setSystemPrompt(system)
            do {
                for try await event in agent.stream([message]) {
                    guard let self else { return }
                    if self.transcript.apply(event) { self.archiveCurrent() }
                    switch event {
                    case .toolStarted: self.haptics.emit(.toolStart)
                    case .approvalRequested: self.haptics.emit(.approvalNeeded)
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
        }
    }

    public func stop() { runTask?.cancel() }
}
