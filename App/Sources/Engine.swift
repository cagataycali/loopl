import Foundation
import Observation
import SwiftUI
import Loopl
import LooplRuntimes

/// App-wide settings, persisted in UserDefaults (token lives in Keychain).
@MainActor @Observable
public final class AppSettings {
    public var offline: Bool { didSet { NetworkPolicy.setOffline(offline) } }
    public var preferredRuntime: RuntimeKind { didSet { UserDefaults.standard.set(preferredRuntime.rawValue, forKey: "loopl.runtime") } }
    public var demoRuntime: Bool { didSet { UserDefaults.standard.set(demoRuntime, forKey: "loopl.demo") } }
    public var systemPrompt: String { didSet { UserDefaults.standard.set(systemPrompt, forKey: "loopl.system") } }
    /// 0 = unlimited (the loopl default — Budget.maxIterations nil).
    public var maxIterations: Int { didSet { UserDefaults.standard.set(maxIterations, forKey: "loopl.maxIter") } }
    public var enabledTools: Set<String> { didSet { UserDefaults.standard.set(Array(enabledTools), forKey: "loopl.tools") } }
    public var temperature: Double { didSet { UserDefaults.standard.set(temperature, forKey: "loopl.temp") } }
    public var maxTokens: Int { didSet { UserDefaults.standard.set(maxTokens, forKey: "loopl.maxTokens") } }
    public var contextLength: Int { didSet { UserDefaults.standard.set(contextLength, forKey: "loopl.ctx") } }
    public var hasToken: Bool = Keychain.hfToken != nil

    public static let defaultSystemPrompt = "You are loopl, a helpful assistant running fully on this iPhone. Use tools when they help; answer concisely."

    public init() {
        let d = UserDefaults.standard
        offline = d.bool(forKey: NetworkPolicy.offlineKey)
        preferredRuntime = RuntimeKind(rawValue: d.string(forKey: "loopl.runtime") ?? "") ?? .mlx
        demoRuntime = d.bool(forKey: "loopl.demo")
        systemPrompt = d.string(forKey: "loopl.system") ?? Self.defaultSystemPrompt
        maxIterations = d.integer(forKey: "loopl.maxIter")
        enabledTools = Set((d.array(forKey: "loopl.tools") as? [String]) ?? ["current_time", "calculator", "device_info", "remember", "recall", "http_get"])
        let t = d.double(forKey: "loopl.temp"); temperature = t == 0 ? 0.6 : t
        let mt = d.integer(forKey: "loopl.maxTokens"); maxTokens = mt == 0 ? 1024 : mt
        let cx = d.integer(forKey: "loopl.ctx"); contextLength = cx == 0 ? 4096 : cx
    }

    public func setToken(_ t: String) { Keychain.set(t.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.hfTokenAccount); hasToken = Keychain.hfToken != nil }
}

/// The main-actor face of the SDK: owns the active `Model`, the `Agent`, the
/// model load state and the `Transcript` the Chat tab renders.
@MainActor @Observable
public final class Engine {
    public let settings: AppSettings
    public let store: ModelStore
    public var transcript = Transcript()
    public var loadedModel: ModelSpec?
    public var loadProgress: Double?
    public var lastError: String?
    private var model: (any Model)?
    private var agent: Agent?
    private var runTask: Task<Void, Never>?

    public init(settings: AppSettings, store: ModelStore) {
        self.settings = settings
        self.store = store
    }

    public var isGenerating: Bool { transcript.isRunning }
    public var allTools: [any Tool] { [CurrentTimeTool(), CalculatorTool(), DeviceInfoTool(), RememberTool(), RecallTool(), HttpGetTool()] }
    public var activeTools: [any Tool] { allTools.filter { settings.enabledTools.contains($0.name) } }

    public func makeModel(for kind: RuntimeKind) -> any Model {
        if settings.demoRuntime { return FakeModel(scripts: DemoScript.lines, delayPerChunkNs: 40_000_000, fallback: DemoScript.fallback) }
        switch kind {
        case .mlx: return MLXModel()
        case .appleFM: return AppleFoundationModel()
        case .gguf: return GGUFModel()
        }
    }

    public func load(_ spec: ModelSpec) async {
        lastError = nil
        loadProgress = 0
        let m = makeModel(for: spec.runtime)
        let dir = spec.isDownloadable ? store.localDirectory(spec) : nil
        if spec.isDownloadable && dir == nil && !settings.demoRuntime {
            lastError = "\(spec.name) is not downloaded yet"; loadProgress = nil; return
        }
        do {
            try await m.load(spec, from: dir) { p in Task { @MainActor in self.loadProgress = p } }
            if let old = model { await old.unload() }
            model = m
            loadedModel = spec
            agent = nil
            transcript.note("Loaded \(spec.name) · \(spec.runtime.label)\(settings.demoRuntime ? " · DEMO scripted runtime, not the model" : "")")
        } catch {
            lastError = error.localizedDescription
        }
        loadProgress = nil
    }

    public func unload() async {
        await model?.unload()
        model = nil; agent = nil
        loadedModel = nil
    }

    public func clear() { transcript.clear(); agent = nil }

    private func config(for spec: ModelSpec) -> AgentConfig {
        var c = AgentConfig()
        c.budget = Budget(maxIterations: settings.maxIterations > 0 ? settings.maxIterations : nil)
        c.family = spec.family
        c.params.temperature = Float(settings.temperature)
        c.params.maxTokens = settings.maxTokens
        c.params.contextLength = min(settings.contextLength, spec.ctxNominal)
        return c
    }

    public func send(_ text: String) {
        guard !isGenerating else { return }
        guard let model, let spec = loadedModel else { lastError = "load a model first (Models tab)"; return }
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
                    self.transcript.apply(event)
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

enum DemoScript {
    static let lines = [
        "Let me check both. <tool_call>\n{\"name\": \"current_time\", \"arguments\": {\"timezone\": \"Europe/Istanbul\"}}\n</tool_call> <tool_call>\n{\"name\": \"calculator\", \"arguments\": {\"expression\": \"23*47\"}}\n</tool_call>",
        "It is the time shown above in Istanbul, and 23 × 47 = 1081. (This is the scripted DEMO runtime — switch it off in Settings to run a real model.)",
    ]
    static let fallback = "Still the demo runtime: I can only replay scripted lines here. Load a real model on an iPhone to chat."
}
