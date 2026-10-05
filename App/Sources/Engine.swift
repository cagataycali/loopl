import Foundation
import Observation
import SwiftUI
import Loopl
import LooplRuntimes
import LooplUI

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

    public static let defaultSystemPrompt = "You are loopl, a helpful assistant running fully on this iPhone. Use tools when they help; answer concisely."
    public static let allToolNames = ["current_time", "calculator", "device_info", "remember", "recall", "http_get"]

    public init() {
        let d = UserDefaults.standard
        offline = d.bool(forKey: NetworkPolicy.offlineKey)
        systemPrompt = d.string(forKey: "loopl.system") ?? Self.defaultSystemPrompt
        enabledTools = Set((d.array(forKey: "loopl.tools") as? [String]) ?? Self.allToolNames)
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
    let archive = ConversationArchive()
    private(set) var currentId = UUID()
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
    public var allTools: [any Tool] { [CurrentTimeTool(), CalculatorTool(), DeviceInfoTool(), RememberTool(), RecallTool(), HttpGetTool()] }
    public var activeTools: [any Tool] { allTools.filter { settings.enabledTools.contains($0.name) } }

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
                case .downloaded: break
                case .failed(let msg): readiness = .failed(spec, msg); return
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
            LooplDesign.success()
        } catch {
            readiness = previous.map { .ready($0) } ?? .failed(spec, error.localizedDescription)
            lastError = error.localizedDescription
            LooplDesign.failure()
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
        transcript.clear(); agent = nil; currentId = UUID()
    }

    /// Reopen a saved conversation. The model starts a fresh context — the
    /// visible turns are restored, not the raw token history.
    func open(_ c: SavedConversation) {
        guard !isGenerating else { return }
        archiveCurrent()
        currentId = c.id
        transcript = c.transcript()
        agent = nil
    }

    func delete(_ c: SavedConversation) {
        archive.delete(c)
        if c.id == currentId { transcript.clear(); agent = nil; currentId = UUID() }
    }

    private func archiveCurrent() {
        if let saved = SavedConversation.from(transcript, id: currentId, modelName: loadedModel?.name) { archive.upsert(saved) }
    }

    /// Maxed-out defaults per model: the recommended context for this phone's RAM,
    /// new tokens bounded only by that context, the model card's temperature.
    private func config(for spec: ModelSpec) -> AgentConfig {
        var c = AgentConfig()
        c.family = spec.family
        c.params.contextLength = min(spec.ctxUsable8GB, spec.ctxNominal)
        c.params.maxTokens = c.params.contextLength
        return c
    }

    public func send(_ text: String) {
        guard !isGenerating else { return }
        guard let model, let spec = loadedModel else { lastError = "the model is still loading"; return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastError = nil
        let agent = self.agent ?? Agent(model: model, tools: activeTools, systemPrompt: settings.systemPrompt, config: config(for: spec))
        self.agent = agent
        transcript.user(text)
        let tools = activeTools, cfg = config(for: spec)
        runTask = Task { [weak self] in
            await agent.update(tools: tools, config: cfg)
            do {
                for try await event in agent.stream(text) {
                    guard let self else { return }
                    if self.transcript.apply(event) { self.archiveCurrent() }
                    if case .toolFinished(let r) = event { if r.isError { LooplDesign.failure() } else { LooplDesign.haptic() } }
                }
            } catch {
                self?.lastError = error.localizedDescription
                self?.transcript.note("error: \(error.localizedDescription)")
                self?.transcript.isRunning = false
            }
        }
    }

    public func stop() { runTask?.cancel() }
}

extension Agent {
    func update(tools: [any Tool], config: AgentConfig) { self.tools = tools; self.config = config }
}
