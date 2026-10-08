import Foundation

// `tools/executors/*`.

/// `ToolExecutor`: how the toolUse blocks of one assistant message run.
/// `run` is the agent's per-tool pipeline (hooks → tool → hooks); `emit`
/// publishes a result the moment it exists. The returned array is in
/// `toolUses` order whatever the completion order (collects per task id).
public protocol ToolExecutor: Sendable {
    func execute(_ toolUses: [ToolUse],
                 run: @Sendable @escaping (ToolUse) async -> ToolResult,
                 emit: @Sendable @escaping (ToolResult) -> Void) async -> [ToolResult]
}

/// `ConcurrentToolExecutor` — the default: every tool of the message at once.
public struct ConcurrentToolExecutor: ToolExecutor {
    public init() {}
    public func execute(_ toolUses: [ToolUse],
                        run: @Sendable @escaping (ToolUse) async -> ToolResult,
                        emit: @Sendable @escaping (ToolResult) -> Void) async -> [ToolResult] {
        guard !toolUses.isEmpty else { return [] }
        var slots = [ToolResult?](repeating: nil, count: toolUses.count)
        await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (i, use) in toolUses.enumerated() {
                group.addTask { (i, await run(use)) }
            }
            for await (i, result) in group {
                emit(result)
                slots[i] = result
            }
        }
        return slots.enumerated().map { i, r in r ?? .error(toolUses[i], "tool did not produce a result") }
    }
}

/// `SequentialToolExecutor`: one after another, in message order.
public struct SequentialToolExecutor: ToolExecutor {
    public init() {}
    public func execute(_ toolUses: [ToolUse],
                        run: @Sendable @escaping (ToolUse) async -> ToolResult,
                        emit: @Sendable @escaping (ToolResult) -> Void) async -> [ToolResult] {
        var out: [ToolResult] = []
        for use in toolUses {
            let r = await run(use)
            emit(r)
            out.append(r)
        }
        return out
    }
}
