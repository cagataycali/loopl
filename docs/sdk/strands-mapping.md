---
description: Strands Agents (Python / TypeScript) ↔ loopl (Swift) — symbol by symbol, and the handful of places the on-device port deliberately differs.
---

# Strands mapping

loopl is a port, not a re-imagining: `Sources/Loopl` mirrors `strands-agents/harness-sdk`'s `strands-py/src/strands`
(and its TypeScript twin) file by file. If you have Strands code, this table is the translation.

!!! strands "Reading the table"
    Python on the left, Swift on the right. Where a Swift name differs it is only to follow Swift conventions
    (`lowerCamelCase`, enums over strings, actors over classes). Semantics are kept unless the **Deliberate differences**
    section says otherwise.

## Agent & results

| Strands (Python)                                                  | loopl (Swift)                                                       |
|-------------------------------------------------------------------|---------------------------------------------------------------------|
| `Agent(model=, tools=, system_prompt=, messages=, conversation_manager=, hooks=, tool_executor=)` | `Agent(model:tools:systemPrompt:messages:conversationManager:hooks:toolExecutor:retryStrategy:)` |
| `agent("prompt")` → `AgentResult`                                 | `try await agent("prompt")` → `AgentResult`                          |
| `agent.stream_async("prompt")` → async iterator of events          | `agent.stream("prompt")` → `AsyncThrowingStream<AgentEvent, Error>` |
| `agent.messages`                                                  | `agent.messages`                                                    |
| `agent.hooks` (`HookRegistry`)                                    | `agent.hooks` (`HookRegistry`)                                      |
| `agent.event_loop_metrics`                                        | `agent.eventLoopMetrics`                                            |
| `AgentResult.stop_reason` / `.message` / `.metrics`                | `AgentResult.stopReason` / `.message` / `.metrics`                  |
| `StopReason` literal `"end_turn" "tool_use" "max_tokens" "stop_sequence" "content_filtered"` (+ `checkpoint`, `interrupt`, `guardrail_intervened`, `limit_*`) | `StopReason.endTurn .toolUse .maxTokens .stopSequence .contentFiltered` + `.cancelled`; the server-side reasons are not ported |
| `EventLoopMetrics.cycle_count` / `.accumulated_usage`              | `EventLoopMetrics.cycleCount` / `.accumulatedUsage`                 |

## Event loop

| Strands                                                           | loopl                                                                |
|-------------------------------------------------------------------|----------------------------------------------------------------------|
| `event_loop.event_loop_cycle` / `recurse_event_loop`              | `Agent.eventLoopCycle` (private, recursive) — [page](event-loop.md)  |
| `streaming.process_stream`                                        | `StreamAssembler.feed(_:)`                                           |
| `_recover_message_on_max_tokens_reached`                          | `recoverMessageOnMaxTokensReached(_:)`                               |
| `_retry.ModelRetryStrategy(max_attempts=6, initial_delay=4, max_delay=240)` | `ModelRetryStrategy(maxAttempts: 6, initialDelay: 4, maxDelay: 240)` |
| `ModelThrottledException` / `ContextWindowOverflowException` / `EventLoopException` / `MaxTokensReachedException` | `ModelThrottledError` / `ContextWindowOverflowError` / `EventLoopError` / `MaxTokensReachedError` |
| `tools.executors.ConcurrentToolExecutor` / `SequentialToolExecutor` | `ConcurrentToolExecutor` / `SequentialToolExecutor`                 |

## Events

| Strands `TypedEvent`                 | `AgentEvent`                                   |
|--------------------------------------|------------------------------------------------|
| `InitEventLoopEvent`                 | `.initEventLoop`                               |
| `StartEvent` + `StartEventLoopEvent` | `.startEventLoop(cycle:)`                      |
| `ModelStreamChunkEvent`              | `.modelStreamChunk(StreamEvent)`               |
| `TextStreamEvent`                    | `.text(String)`                                |
| `ReasoningTextStreamEvent`           | `.reasoning(String)`                           |
| `ToolUseStreamEvent`                 | `.toolUseStream(name:toolUseId:partialInput:)` |
| `ModelMessageEvent`                  | `.modelMessage(Message)`                       |
| `EventLoopThrottleEvent`             | `.throttle(delay:)`                            |
| `ToolResultEvent`                    | `.toolResult(ToolResult)`                      |
| `ToolResultMessageEvent`             | `.toolResultMessage(Message)`                  |
| `ForceStopEvent`                     | `.forceStop(String)`                           |
| `AgentResultEvent`                   | `.result(AgentResult)`                         |
| —                                    | `.toolStarted(ToolUse)`, `.metrics(Metrics)` (loopl additions for the UI) |

Model-side: `StreamEvent` is the Bedrock-shaped `messageStart · contentBlockStart · contentBlockDelta · contentBlockStop ·
messageStop · metadata` that Strands' `streaming.py` consumes.

## Messages & content

| Strands                                                | loopl                                                        |
|--------------------------------------------------------|--------------------------------------------------------------|
| `Message = {role, content: [ContentBlock]}`             | `struct Message { role: Role; content: [ContentBlock] }`      |
| `ContentBlock.text / toolUse / toolResult / reasoningContent` | `.text / .toolUse / .toolResult / .reasoning`         |
| `ToolUse {toolUseId, name, input}`                      | `ToolUse(toolUseId:name:input:)`                             |
| `ToolResult {toolUseId, status, content}`               | `ToolResult(toolUseId:name:status:content:durationMs:)`      |
| `Usage {inputTokens, outputTokens, totalTokens}`        | `Usage(inputTokens:outputTokens:totalTokens:)`               |

## Tools

| Strands                                   | loopl                                                        |
|-------------------------------------------|--------------------------------------------------------------|
| `@tool def f(x: str) -> str`               | `struct F: Tool { name, description, parameters, call }`     |
| `ToolSpec {name, description, inputSchema}` | `ToolSpec(name:description:inputSchema:)` (from `tool.toolSpec`) |
| `AgentTool.stream(...)`                   | `Tool.call(_:) async throws -> String`                       |
| `tool_registry`                           | `agent.tools` / `setTools(_:)`                               |

## Hooks

| Strands                                                     | loopl                                                      |
|-------------------------------------------------------------|------------------------------------------------------------|
| `HookRegistry.add_callback(EventType, fn)` / `add_hook(provider)` | `hooks.addCallback(EventType.self) { event in … }` / `hooks.addHook(provider)` |
| `HookProvider.register_hooks(registry)`                     | `HookProvider.registerHooks(_:)`                           |
| `BeforeInvocationEvent` … `AfterToolCallEvent`, `MessageAddedEvent` | same names, `struct … : HookEvent`                 |
| `should_reverse_callbacks`                                  | `static var shouldReverseCallbacks`                        |

## Conversation managers

| Strands                                                          | loopl                                                           |
|------------------------------------------------------------------|-----------------------------------------------------------------|
| `ConversationManager.apply_management / reduce_context / register_hooks` | `applyManagement / reduceContext(_:error:) / registerHooks` |
| `SlidingWindowConversationManager(window_size=40, should_truncate_results=True)` | `SlidingWindowConversationManager(windowSize: 40, shouldTruncateResults: true, compressionThreshold: 0.7, pinFirst: 0)` |
| `NullConversationManager`                                        | `NullConversationManager`                                       |
| `SummarizingConversationManager`                                 | not yet — [changelog](../changelog.md)                          |

## Models

| Strands                                                    | loopl                                                                   |
|------------------------------------------------------------|-------------------------------------------------------------------------|
| `Model.stream(messages, tool_specs, system_prompt)`         | `Model.stream(_ messages:, toolSpecs:, systemPrompt:)`                   |
| `Model.get_config() / update_config()`                      | `params` / `updateConfig(_:)`                                           |
| `BedrockModel`, `OllamaModel`, `OpenAIModel`, …             | `MLXModel`, `AppleFoundationModel`, `GGUFModel` — [runtimes](../runtimes/index.md) |
| —                                                          | `load(_:from:progress:)`, `unload()`, `availability()` (weights live on the device) |

## Deliberate differences

1. **No iteration cap.** Strands' `max_iterations`-style guards protect a server bill; on a phone the context window
   and the Stop button are the guards. loopl has no budget type and no loop detector.
2. **Proactive trimming.** `SlidingWindowConversationManager` also trims *before* a model call when the projected prompt
   exceeds `compressionThreshold × contextWindow` (a token estimate), because small on-device contexts overflow often.
3. **Tool-call parsing is part of the SDK.** Cloud providers return structured tool calls; small local models emit
   text. `ToolCallParser` / `ToolCallStreamGate` turn Hermes, Llama 3 and generic JSON dialects into native
   `contentBlockStart(.toolUse)` events so the loop stays identical.
4. **Two extra events** — `.toolStarted` and `.metrics` — for a phone UI (spinner on the tool row, tok/s in a debug sheet).
5. **Cancellation keeps the partial text.** Strands substitutes *"Cancelled by user"*; loopl keeps what was generated and
   uses that string only when nothing was. The result's `stopReason` is `.cancelled` (a loopl-only case).
6. **Context overflow is silent.** Strands yields `ForceStopEvent` before the overflow is caught one level up; loopl skips
   that event because the loop continues after trimming.
7. **`ToolResult.content` is one string** — no image / JSON / document blocks; `Role` has no `system` case and `ContentBlock`
   has no image/document/video variants (nothing on the edge produces them).
8. **Not ported (server concerns):** interrupts, checkpoints, structured output, middleware, sessions, tracing,
   agent-as-tool, `Swarm`/`Graph`, MCP clients, `SummarizingConversationManager`. The hook points are identical, so
   each can be added without touching the cycle.
