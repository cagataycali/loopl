import Foundation

/// Strands `ModelRetryStrategy`: a `HookProvider` on `AfterModelCallEvent`.
/// Retries retryable model errors with exponential backoff — delays
/// `initialDelay · 2^attempt`, capped at `maxDelay`; defaults 4 s → 8 → 16 → 32
/// → 64 (5 retries, 6 attempts). State resets after a successful call and at
/// the end of each invocation.
public final class ModelRetryStrategy: HookProvider, @unchecked Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    private var currentAttempt = 0
    private let lock = NSLock()
    /// Observed by the agent so it can surface a throttle event (Strands `EventLoopThrottleEvent`).
    var lastDelay: TimeInterval?

    public init(maxAttempts: Int = 6, initialDelay: TimeInterval = 4, maxDelay: TimeInterval = 240) {
        self.maxAttempts = maxAttempts; self.initialDelay = initialDelay; self.maxDelay = maxDelay
    }

    /// Override point (Strands `is_retryable`).
    public func isRetryable(_ error: any Error) -> Bool { error is ModelThrottledError }

    public func delay(forAttempt attempt: Int) -> TimeInterval { min(initialDelay * pow(2, Double(attempt)), maxDelay) }

    public func registerHooks(_ registry: HookRegistry) {
        registry.addCallback(AfterModelCallEvent.self) { [self] event in await self.afterModelCall(&event) }
        registry.addCallback(AfterInvocationEvent.self) { [self] _ in self.reset() }
    }

    private func reset() { lock.lock(); currentAttempt = 0; lastDelay = nil; lock.unlock() }

    /// Synchronous bookkeeping; returns the delay to sleep before retrying, or nil.
    private func decide(_ event: AfterModelCallEvent) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let delay = self.delay(forAttempt: currentAttempt)
        lastDelay = nil
        if event.retry { return nil }
        if event.stopResponse != nil || event.error == nil { currentAttempt = 0; return nil }
        guard let error = event.error, isRetryable(error) else { return nil }
        currentAttempt += 1
        if currentAttempt >= maxAttempts { return nil }
        lastDelay = delay
        return delay
    }

    private func afterModelCall(_ event: inout AfterModelCallEvent) async {
        guard let delay = decide(event) else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        event.retry = true
    }
}
