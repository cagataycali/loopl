import Foundation

/// What a running tool may know about the agent that called it — tiny-tech's `ToolContext.agent`,
/// as a task-local so no tool needs an agent reference wired in by the host.
///
/// `Agent.runTool` sets it around `tool.call(…)`; tools that manage the agent itself
/// (`manage_messages`, `manage_tools`, `use_agent`) read `ToolContext.current`. Outside an agent
/// run it is `nil` and such a tool reports that honestly instead of guessing.
public struct ToolContext: Sendable {
    /// The live agent executing this call. Its actor methods are the only writers of its state.
    public let agent: Agent
    /// This call's own `toolUseId` — the one id surgery must never remove (it is still unresolved).
    public let toolUseId: String
    public init(agent: Agent, toolUseId: String) { self.agent = agent; self.toolUseId = toolUseId }

    @TaskLocal public static var current: ToolContext?
}
