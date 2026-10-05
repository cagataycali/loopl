# Strands mapping

loopl keeps the shape of [Strands Agents](https://strandsagents.com) where it reads naturally in Swift, and departs on
purpose where the phone is different. If you know Strands, this table is the whole SDK.

| Strands (Python) | loopl (Swift) | Notes |
|---|---|---|
| `Agent(model=…, tools=[…], system_prompt=…)` | `Agent(model:tools:systemPrompt:config:)` | same three arguments, plus an optional `AgentConfig` |
| `agent("prompt")` → `AgentResult` | `try await agent("prompt")` → `AgentResult` | `callAsFunction`; `.text`, `.iterations`, `.toolResults`, `.metrics`, `.reason` |
| `agent.stream_async("prompt")` | `agent.stream("prompt")` | `AsyncThrowingStream<AgentEvent, Error>` |
| `agent.messages` | `agent.messages` | `[Message]`, `Codable`, mutable for trimming |
| `@tool def f(x: int) -> str` | `struct F: Tool { name, description, parameters, call }` or `ClosureTool(name:description:parameters:) { args in … }` | no macros yet; `ToolSchema` builds the schema |
| `ToolSpec` (`name`, `description`, `inputSchema`) | `Tool.spec` → `{type: "function", function: {name, description, parameters}}` | the OpenAI/HF chat-template shape |
| `ToolUse` (`toolUseId`, `name`, `input`) | `ToolCall` (`id`, `name`, `arguments`) | |
| `ToolResult` (`toolUseId`, `status`, `content`) | `ToolResult` (`callId`, `isError`, `content`, `durationMs`) | |
| `Message` + `ContentBlock` list | `enum Message { system, user, assistant(text:toolCalls:), tool(result:callId:name:) }` | one case per turn kind — see [Messages](messages-events.md) |
| `Model` provider (`BedrockModel`, `OllamaModel`, …) | `Model` protocol (`MLXModel`, `AppleFoundationModel`, `GGUFModel`, `FakeModel`) | all on-device; actors |
| `model.stream(messages, tool_specs, system_prompt)` | `model.stream(messages:tools:params:)` | the system prompt is `messages[0]` |
| `StreamEvent` (`contentBlockDelta`, …) | `ModelEvent` (`text`, `toolCall`, `metrics`) | flattened |
| callback handler / `AgentResult` | `AgentEvent` stream / `AgentResult` | same two consumption modes |
| `max_iterations` (hard stop, default 8–10) | **none** — `Budget.unlimited` | opt-in caps: iterations, tool calls, wall time, tokens — see [Budget](budget.md) |
| — | `LoopDetector` (warns, never stops) | on-device specific |
| `ConversationManager` (sliding window) | mutate `agent.messages` | a built-in window manager is on the roadmap |
| `event_loop_metrics` | `Metrics` on `.metrics` events and in `AgentResult` | adds TTFT, tok/s, context used / max |
| hooks (`BeforeToolInvocation`, …) | observe `AgentEvent` | mutating hooks are roadmap |
| MCP tools | — | MCP servers are network; out of scope for an offline-first SDK |
| multi-agent (`Swarm`, `Graph`) | — | one agent per conversation; compose in your own code |

## Where loopl deliberately differs

- **No iteration cap.** The loop is bounded by the user, not by a constant.
- **Tools are values with instance properties, not decorated functions.** `Sendable` for free; `ClosureTool` when you
  want the one-liner.
- **The parser is in the core, not the provider.** Small open models speak three tool-call dialects (`ToolFamily`);
  `ToolCallParser` normalises them so the loop is dialect-agnostic and runtimes stay thin.
- **Everything is an actor.** Models own their weights; the agent owns its transcript; `stream` is `nonisolated`.

## Same idea, same words

The *event loop* — stream a turn, run the tool calls, append results, repeat until a turn has no tool call — is Strands'
algorithm verbatim. The difference is only where it runs.
