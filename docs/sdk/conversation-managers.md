---
description: Conversation managers keep an unlimited agent loop inside the model's context window — SlidingWindowConversationManager, NullConversationManager, and how to write your own.
---

# Conversation managers

loopl has no iteration cap. What keeps a long-running loop healthy is the **conversation manager** — the same
abstraction Strands uses (`ConversationManager`, `SlidingWindowConversationManager`, `NullConversationManager`),
with one edge-specific addition: it also trims **proactively** on a token estimate, before the model ever throws.

```swift
public protocol ConversationManager: Sendable {
    /// Strands apply_management — after every event-loop run.
    func applyManagement(_ messages: inout [Message])
    /// Strands reduce_context — on ContextWindowOverflowError (error set) or proactively (error nil).
    /// Throws ContextWindowOverflowError when nothing more can be removed.
    func reduceContext(_ messages: inout [Message], error: (any Error)?) throws
    /// Optional: register as a HookProvider.
    func registerHooks(_ registry: HookRegistry)
}
```

## SlidingWindowConversationManager (default)

```swift
public final class SlidingWindowConversationManager: ConversationManager, HookProvider {
    public init(windowSize: Int = 40,                 // keep the last N messages
                shouldTruncateResults: Bool = true,   // shrink huge tool results before dropping turns
                compressionThreshold: Double = 0.7,   // trim when projected prompt > 70 % of the window
                pinFirst: Int = 0)                    // never evict the first N messages
    public private(set) var removedMessageCount: Int
}
```

What it does, in the order it does it:

1. **After every appended message** (`applyManagement`, driven by `MessageAddedEvent`): if there are more than
   `windowSize` messages, drop the oldest — but never split a `toolUse` from its `toolResult`, and never evict the
   `pinFirst` messages (Strands `pin_first`).
2. **Before every model call** (`BeforeModelCallEvent`): the loop hands it `projectedInputTokens` and
   `contextWindow`; when the projection exceeds `compressionThreshold × contextWindow`, it trims *now* — so the model
   is never asked for something that cannot fit. This is what makes "no cap" safe on an 8 GB phone.
3. **On `ContextWindowOverflowError`** (`reduceContext(error:)`): first truncate the oldest big tool results to their
   first and last 200 characters (Strands `_truncate_tool_results`, marker `... [truncated: N chars removed] ...`), then
   drop the oldest turns; if nothing is left to remove, the overflow error is re-thrown and the loop ends with `.forceStop`.

```swift
// snippet: compile
import Loopl

func longRunning(_ model: any Model) -> Agent {
    Agent(model: model,
          systemPrompt: "You are a research assistant. Keep going until the question is fully answered.",
          conversationManager: SlidingWindowConversationManager(windowSize: 60,
                                                                compressionThreshold: 0.6,
                                                                pinFirst: 2))   // keep the user's brief
}
```

!!! tip "Token estimates"
    On-device runtimes do not always expose a tokenizer before generation, so the projection uses
    `TokenEstimator.estimate(_:)` (≈ 4 bytes per token) unless the model reports exact counts. `Metrics.estimated`
    tells you which one you got. A 0.7 threshold leaves room for the error.

## NullConversationManager

Never trims; an overflow is re-thrown. Use it in tests or when *you* manage `agent.messages` yourself.

## Writing your own

Summarising managers (Strands `SummarizingConversationManager`) are a natural fit for a phone: run the same local model
over the oldest turns, replace them with one assistant summary message. Conform to `ConversationManager`, keep
`toolUse`/`toolResult` pairs together, and register a `BeforeModelCallEvent` callback if you want the proactive path.

!!! strands "Strands → loopl"
    `SlidingWindowConversationManager(window_size=40, should_truncate_results=True)` → `SlidingWindowConversationManager(windowSize: 40, shouldTruncateResults: true)` ·
    `NullConversationManager()` → `NullConversationManager()` · `conversation_manager.removed_message_count` → `removedMessageCount`.
    No `SummarizingConversationManager` yet — see the [changelog](../changelog.md).
