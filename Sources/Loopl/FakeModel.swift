import Foundation

/// A scripted model: each `stream()` call plays the next script entry, word
/// by word. Drives the unit tests, the SwiftUI previews and the app's
/// "Demo (scripted)" switch — clearly labelled, never a benchmark.
public actor FakeModel: Model {
    public nonisolated let kind: RuntimeKind = .mlx
    public private(set) var loadedModelId: String?
    public var scripts: [String]
    public private(set) var seenPrompts: [[Message]] = []
    public nonisolated let delayPerChunkNs: UInt64
    /// When the script runs out, answer with this instead of "(script exhausted)".
    public var fallback: String?

    public init(scripts: [String], delayPerChunkNs: UInt64 = 0, fallback: String? = nil) {
        self.scripts = scripts
        self.delayPerChunkNs = delayPerChunkNs
        self.fallback = fallback
    }
    public nonisolated static func availability() -> RuntimeAvailability { .ok }

    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        loadedModelId = spec.id; progress(1)
    }
    public func unload() async { loadedModelId = nil }

    private func next(_ messages: [Message]) -> String {
        seenPrompts.append(messages)
        guard !scripts.isEmpty else { return fallback ?? "(script exhausted)" }
        return scripts.removeFirst()
    }

    public nonisolated func stream(messages: [Message], tools: [any Tool], params: GenerationParams) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let text = await self.next(messages)
                let started = Date()
                var m = Metrics()
                m.contextMax = params.contextLength
                m.promptTokens = messages.reduce(0) { $0 + $1.text.count / 4 }
                m.estimated = true
                continuation.yield(.metrics(m))
                var n = 0
                for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                    try Task.checkCancellation()
                    if self.delayPerChunkNs > 0 { try await Task.sleep(nanoseconds: self.delayPerChunkNs) }
                    n += 1
                    if n == 1 { m.ttftMs = Date().timeIntervalSince(started) * 1000 }
                    m.generatedTokens = n
                    m.contextUsed = m.promptTokens + n
                    m.tokensPerSecond = Double(n) / max(0.001, Date().timeIntervalSince(started))
                    continuation.yield(.text((n == 1 ? "" : " ") + String(word)))
                    continuation.yield(.metrics(m))
                }
                m.finished = true; m.stopReason = "stop"
                continuation.yield(.metrics(m))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
