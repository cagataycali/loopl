# Strands mapping

loopl keeps the shape of [Strands Agents](https://strandsagents.com) where it reads naturally in Swift,
and departs on purpose where the phone is different. If you know Strands, this table is the whole SDK.

| Strands (Python) | loopl (Swift) | Notes |
|---|---|---|
| `Agent(model=…, tools=[…], system_prompt=…)` | `Agent(model:tools:systemPrompt:)` | same three arguments |
| `agent("prompt")` | `try await agent("prompt")` | `callAsFunction`; returns `AgentResult` |
| `agent.stream_async("prompt")` | `agent.stream("prompt")` | `AsyncThrowingStream<AgentEvent, Error>` |
| `agent.messages` | `agent.messages` | `[Message]`, `Codable` |
| `@tool def f(x: int) -> str` | `struct F: Tool { static let spec; func call }` | no macros yet; `ToolSpec` + `JSONSchema` builder |
| `ToolSpec` (`name`, `description`, `inputSchema`) | `ToolSpec(name:description:parameters:)` | identical fields |
| `ToolResult` (`toolUseId`, `status`, `content`) | `ToolResult` (`toolUseId`, `status`, `content`) | identical |
| `Message` / `ContentBlock` (`text`, `toolUse`, `toolResult`) | `Message` / `ContentBlock` | identical cases |
| `Model` provider (`BedrockModel`, `OllamaModel`, …) | `Model` protocol (`MLXModel`, `AppleFoundationModel`, `GGUFModel`) | all on-device |
| `model.stream(messages, tool_specs, system_prompt)` | `model.stream(messages:tools:params:)` | system prompt is a `Message` |
| `StreamEvent` (`contentBlockDelta`, …) | `ModelEvent` (`textDelta`, `toolUse`, `usage`, `metrics`, `stop`) | flattened |
| callback handler / `AgentResult` | `AgentEvent` stream / `AgentResult` | same two consumption modes |
| `max_iterations` (hard stop, default 8–10) | **none** — `Budget.unlimited` | see [Budget](budget.md) |
| `ConversationManager` (sliding window) | roadmap | the app trims interactively today |
| `event_loop_metrics` | `Metrics` on `.turnEnd` and in `AgentResult` | adds TTFT, tok/s, context used |
| hooks (`BeforeToolInvocation`, …) | `AgentEvent` observers | observe the stream; mutating hooks are roadmap |
| MCP tools | — | MCP servers are network; out of scope for an offline-first SDK |
| multi-agent (`Swarm`, `Graph`) | — | one agent per conversation; compose in your own code |

## Where loopl deliberately differs

- **No iteration cap.** The loop is bounded by the user, not by a constant.
- **Tools are types, not functions.** A static `spec` makes the schema inspectable at compile time and
  trivially snapshot-testable, and a value type is `Sendable` for free.
- **The parser is in the core, not the provider.** Small open models speak four tool-call dialects;
  `ToolCallParser` normalises them so the loop is dialect-agnostic.
- **Memory is a first-class error.** `ModelError.insufficientMemory` and `contextExceeded` exist because
  the KV cache competes with your UI for the same 8 GB.

## Same idea, same words

The *event loop* — stream a turn, run the tool uses, append results, repeat until a turn has no tool
use — is Strands' algorithm verbatim. The difference is only where it runs.
