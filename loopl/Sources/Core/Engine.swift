import Foundation
import Observation
import SwiftUI

/// One row in the Chat transcript.
public struct ChatItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case user(String)
        case assistant(String)
        case toolCall(ToolCall, result: String?, durationMs: Double?, isError: Bool)
        case note(String)
    }
    public var id = UUID()
    public var kind: Kind
}

/// App-wide settings, persisted in UserDefaults (token lives in Keychain).
@MainActor @Observable
public final class AppSettings {
    public var offline: Bool { didSet { NetworkPolicy.setOffline(offline) } }
    public var preferredRuntime: RuntimeKind { didSet { UserDefaults.standard.set(preferredRuntime.rawValue, forKey: "loopl.runtime") } }
    public var demoRuntime: Bool { didSet { UserDefaults.standard.set(demoRuntime, forKey: "loopl.demo") } }
    public var systemPrompt: String { didSet { UserDefaults.standard.set(systemPrompt, forKey: "loopl.system") } }
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
        let it = d.integer(forKey: "loopl.maxIter"); maxIterations = it == 0 ? 8 : it
        enabledTools = Set((d.array(forKey: "loopl.tools") as? [String]) ?? ["current_time", "calculator", "device_info", "remember", "recall", "http_get"])
        let t = d.double(forKey: "loopl.temp"); temperature = t == 0 ? 0.6 : t
        let mt = d.integer(forKey: "loopl.maxTokens"); maxTokens = mt == 0 ? 1024 : mt
        let cx = d.integer(forKey: "loopl.ctx"); contextLength = cx == 0 ? 4096 : cx
    }

    public func setToken(_ t: String) { Keychain.set(t.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.hfTokenAccount); hasToken = Keychain.hfToken != nil }
}

/// The main-actor face of the runtime: owns the active engine, the model
/// load state and the live transcript the Chat tab renders.
@MainActor @Observable
public final class Engine {
    public let settings: AppSettings
    public let store: ModelStore
    public var transcript: [ChatItem] = []
    public var stats = StreamStats()
    public var isGenerating = false
    public var loadedModel: ModelSpec?
    public var loadProgress: Double?
    public var lastError: String?
    public var iteration = 0
    private var runtime: (any LLMRuntime)?
    private var history: [Message] = []
    private var runTask: Task<Void, Never>?

    public init(settings: AppSettings, store: ModelStore) {
        self.settings = settings
        self.store = store
    }

    public var allTools: [any AgentTool] { [CurrentTimeTool(), CalculatorTool(), DeviceInfoTool(), RememberTool(), RecallTool(), HttpGetTool()] }
    public var activeTools: [any AgentTool] { allTools.filter { settings.enabledTools.contains($0.name) } }

    public func runtime(for kind: RuntimeKind) -> any LLMRuntime {
        if settings.demoRuntime { return FakeRuntime(scripts: DemoScript.lines, delayPerChunkNs: 40_000_000) }
        switch kind {
        case .mlx: return MLXRuntime()
        case .appleFM: return AppleFMRuntime()
        case .gguf: return GGUFRuntime()
        }
    }

    public func load(_ spec: ModelSpec) async {
        lastError = nil
        loadProgress = 0
        let rt = runtime(for: spec.runtime)
        let dir = spec.isDownloadable ? store.localDirectory(spec) : nil
        if spec.isDownloadable && dir == nil && !settings.demoRuntime {
            lastError = "\(spec.name) is not downloaded yet"; loadProgress = nil; return
        }
        do {
            try await rt.load(spec, from: dir) { p in Task { @MainActor [weak self] in self?.loadProgress = p } }
            if let old = runtime { await old.unload() }
            runtime = rt
            loadedModel = spec
            transcript.append(.init(kind: .note("Loaded \(spec.name) · \(spec.runtime.label)\(settings.demoRuntime ? " · DEMO scripted runtime, not the model" : "")")))
        } catch {
            lastError = error.localizedDescription
        }
        loadProgress = nil
    }

    public func unload() async {
        await runtime?.unload()
        runtime = nil
        loadedModel = nil
    }

    public func clear() { transcript.removeAll(); history.removeAll(); stats = StreamStats(); iteration = 0 }

    public func send(_ text: String) {
        guard !isGenerating, let runtime, let loadedModel else { lastError = runtime == nil ? "load a model first (Models tab)" : nil; return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastError = nil
        if history.isEmpty { history.append(.system(settings.systemPrompt)) }
        history.append(.user(text))
        transcript.append(.init(kind: .user(text)))
        isGenerating = true
        var config = AgentConfig()
        config.maxIterations = settings.maxIterations
        config.family = loadedModel.family
        config.params.temperature = Float(settings.temperature)
        config.params.maxTokens = settings.maxTokens
        config.params.contextLength = min(settings.contextLength, loadedModel.ctxNominal)
        let tools = activeTools
        let messages = history
        runTask = Task { [weak self] in
            guard let self else { return }
            var assistantIndex: Int?
            var newMessages: [Message] = []
            do {
                for try await event in AgentLoop.run(messages: messages, runtime: runtime, tools: tools, config: config) {
                    switch event {
                    case .iterationStarted(let i):
                        self.iteration = i
                        assistantIndex = nil
                    case .token(let t):
                        if let idx = assistantIndex, case .assistant(let s) = self.transcript[idx].kind {
                            self.transcript[idx].kind = .assistant(s + t)
                        } else {
                            self.transcript.append(.init(kind: .assistant(t)))
                            assistantIndex = self.transcript.count - 1
                        }
                    case .stats(let s): self.stats = s
                    case .assistantMessage(let m):
                        newMessages.append(m)
                        if let idx = assistantIndex { self.transcript[idx].kind = .assistant(m.text) }   // markup stripped
                        if let idx = assistantIndex, m.text.isEmpty { self.transcript.remove(at: idx); assistantIndex = nil }
                    case .toolStarted(let call):
                        self.transcript.append(.init(kind: .toolCall(call, result: nil, durationMs: nil, isError: false)))
                    case .toolFinished(let callId, let name, let result, let ms, let isError):
                        newMessages.append(.tool(result: result, callId: callId, name: name))
                        if let idx = self.transcript.lastIndex(where: { if case .toolCall(let c, nil, _, _) = $0.kind { return c.id == callId }; return false }),
                           case .toolCall(let c, _, _, _) = self.transcript[idx].kind {
                            self.transcript[idx].kind = .toolCall(c, result: result, durationMs: ms, isError: isError)
                        }
                    case .finished(let n, let reason):
                        if reason != .answered { self.transcript.append(.init(kind: .note("stopped: \(reason.rawValue) after \(n) iteration\(n == 1 ? "" : "s")"))) }
                    }
                }
            } catch {
                self.lastError = error.localizedDescription
                self.transcript.append(.init(kind: .note("error: \(error.localizedDescription)")))
            }
            self.history.append(contentsOf: newMessages)
            self.isGenerating = false
        }
    }

    public func stop() { runTask?.cancel() }
}

enum DemoScript {
    static let lines = [
        "Let me check both. <tool_call>\n{\"name\": \"current_time\", \"arguments\": {\"timezone\": \"Europe/Istanbul\"}}\n</tool_call> <tool_call>\n{\"name\": \"calculator\", \"arguments\": {\"expression\": \"23*47\"}}\n</tool_call>",
        "It is the time shown above in Istanbul, and 23 × 47 = 1081. (This is the scripted DEMO runtime — switch it off in Settings to run a real model.)",
        "Still the demo runtime: I can only replay scripted lines here. Load a real model on an iPhone to chat.",
    ]
}
