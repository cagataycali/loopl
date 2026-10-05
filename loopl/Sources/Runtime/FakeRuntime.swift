import Foundation

/// A scripted runtime: each `stream()` call plays the next script entry,
/// character by character. Drives the unit tests and the simulator demo
/// ("Demo (scripted)" in Settings) — clearly labelled, never a benchmark.
public actor FakeRuntime: LLMRuntime {
    public nonisolated let kind: RuntimeKind = .mlx
    public private(set) var loadedModelId: String?
    public var scripts: [String]
    public private(set) var seenPrompts: [[Message]] = []
    public var delayPerChunkNs: UInt64

    public init(scripts: [String], delayPerChunkNs: UInt64 = 0) {
        self.scripts = scripts
        self.delayPerChunkNs = delayPerChunkNs
    }
    public nonisolated static func availability() -> RuntimeAvailability { .ok }

    public func load(_ model: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        loadedModelId = model.id; progress(1)
    }
    public func unload() async { loadedModelId = nil }

    private func next(_ messages: [Message]) -> String {
        seenPrompts.append(messages)
        guard !scripts.isEmpty else { return "(script exhausted)" }
        return scripts.removeFirst()
    }

    public nonisolated func stream(messages: [Message], tools: [any AgentTool], params: GenerationParams) -> AsyncThrowingStream<Token, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let text = await self.next(messages)
                let started = Date()
                var stats = StreamStats()
                stats.contextMax = params.contextLength
                stats.promptTokens = messages.reduce(0) { $0 + $1.text.count / 4 }
                continuation.yield(.stats(stats))
                var n = 0
                for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                    try Task.checkCancellation()
                    if self.delayPerChunkNs > 0 { try await Task.sleep(nanoseconds: self.delayPerChunkNs) }
                    n += 1
                    if n == 1 { stats.ttftMs = Date().timeIntervalSince(started) * 1000 }
                    stats.generatedTokens = n
                    stats.contextUsed = stats.promptTokens + n
                    stats.tokensPerSecond = Double(n) / max(0.001, Date().timeIntervalSince(started))
                    continuation.yield(.text((n == 1 ? "" : " ") + String(word)))
                    continuation.yield(.stats(stats))
                }
                stats.finished = true; stats.stopReason = "stop"
                continuation.yield(.stats(stats))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
