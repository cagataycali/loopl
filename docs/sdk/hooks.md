---
title: "Hooks & conversation"
description: "Observe, change or stop any step of the loop with typed hooks; keep long sessions inside the context window."
---

# Hooks & conversation

## Hooks

Typed callbacks at every step. Register them on `agent.hooks`:

```swift
// snippet: compile
import Loopl

func observe(_ agent: Agent) async {
    await agent.hooks.addCallback(BeforeToolCallEvent.self) { event in
        if event.toolUse.name == "http" {
            event.cancelTool = "Network tools are disabled in this session."   // the model reads this as the result
        }
    }
    await agent.hooks.addCallback(AfterModelCallEvent.self) { event in
        if let stop = event.stopResponse { print("model stopped: \(stop.stopReason)") }
    }
}
```

A reusable bundle is a `HookProvider`:

```swift
// snippet: compile
import Loopl

final class Telemetry: HookProvider, @unchecked Sendable {
    private(set) var toolCalls = 0
    func registerHooks(_ registry: HookRegistry) {
        registry.addCallback(AfterToolCallEvent.self) { [self] _ in toolCalls += 1 }
    }
}

func make(_ model: any Model) -> Agent { Agent(model: model, hooks: [Telemetry()]) }
```

| `HookEvent` | fires | you can set |
|---|---|---|
| `BeforeInvocationEvent` · `AfterInvocationEvent` | once per call | — |
| `BeforeModelCallEvent` · `AfterModelCallEvent` | each model call | `stopResponse` |
| `BeforeToolsEvent` · `AfterToolsEvent` | each tool round, always paired | `endTurn`, `requestState` |
| `BeforeToolCallEvent` · `AfterToolCallEvent` | each tool | `cancelTool`, `selectedTool`, `result` |
| `MessageAddedEvent` | every appended message | — |

After-events run in reverse order. `AfterToolsEvent` fires even when a tool throws or the turn is cancelled, so it is the place to close a span or flush a log.

### Stop after tools

```swift
// snippet: compile
import Loopl

func stopAfterTools(_ agent: Agent) async {
    // endTurn: no further model call; this text becomes the answer.
    await agent.hooks.addCallback(AfterToolsEvent.self) { event in
        let failures = event.message.content.compactMap(\.toolResult).filter { $0.isError }
        if failures.count > 2 { event.endTurn = .text("Too many tools failed; stopping here.") }
    }
    // stopEventLoop: stop after this round, keeping its stop reason.
    await agent.hooks.addCallback(AfterToolsEvent.self) { event in
        event.requestState["stopEventLoop"] = .bool(true)
    }
}
```

### Ask from a hook

```swift
// snippet: compile
import Loopl

func confirmDeletes(_ agent: Agent) async {
    await agent.hooks.addCallback(BeforeToolCallEvent.self) { event in
        guard event.toolUse.name == "delete_file" else { return }
        let answer = try event.interrupt("confirm_delete", reason: .string(event.toolUse.input.description))
        if answer != .string("yes") { event.cancelTool = "the user did not confirm" }
    }
}
```

The first call raises; once answered, the hook runs again and `interrupt` returns the answer. See [Interrupts](agent.md#interrupts).

## Conversation

A `ConversationManager` keeps history inside the context window. The budget comes from the loaded model — Apple's is 4,096 tokens, an MLX Qwen3 8k–32k — never from a constant.

```swift
// snippet: compile
import Loopl

func longRunning(_ model: any Model) async -> Agent {
    let manager = SlidingWindowConversationManager(windowSize: 60, compressionThreshold: 0.6, pinFirst: 2)
    let ctx = await model.contextWindow
    print(manager.windowSize(forContextWindow: ctx), TokenEstimator.isEstimate)
    return Agent(model: model, systemPrompt: "Keep going until the question is answered.",
                 conversationManager: manager)
}
```

Trimming starts early (token counts are estimates): large tool results shrink to head and tail first, then the oldest turns slide out — never the system prompt, never the current question, never a call without its result. If a runtime still refuses, the loop trims and retries once. `NullConversationManager` leaves the history to you.

This is what bounds a session instead of an iteration counter.

### The agent edits its own context — `manage_messages`

The manager above is the floor. Above it, the agent can tidy its own history on purpose: `ManageMessagesTool`
gives the model one tool whose actions are `compact` (strip old tool calls and results, keep every message's
text — by default all turns but the last 3), `drop` (whole old turns by number), `drop_tools` (single calls by
id or every call to a name), `clear` (keep only the current turn), and the read-only `list`, `list_tools`,
`stats`. Four rules never bend, and `HistoryEditor` (pure, unit-tested) enforces them before anything is
replaced: the **active turn** — the one running this very call — is never edited; a call left without its
result gets a **synthetic result** rather than an orphan; reasoning stays whole or goes with the tool blocks
it accompanied; and the structure is validated first — a request that would break the history is refused
with an error the model reads.

```swift
// snippet: compile
import Loopl

func selfManaging(_ model: any Model) -> Agent {
    Agent(model: model, tools: [CalculatorTool(), ManageMessagesTool()],
          systemPrompt: "When the context is long, call manage_messages with action compact before you continue.")
}
```

The edit is **effective for the next model call of the same turn**: the tool reaches the live agent through
`ToolContext` (a task-local the agent sets around every tool call) and `Agent.editHistory` replaces the
working history, so the prompt the model gets right after the tool result is already the shorter one.

What shrinks is the agent's *working context*, not the user's record. A `Transcript` is built from events,
so every row stays; the agent announces each edit as `AgentEvent.historyEdited` carrying a `HistoryEdit`,
and the transcript folds it into one quiet note — *"The model tidied 3 turns of notes · your conversation is
unchanged"*. Reopening a saved conversation already starts the model on a fresh context, so nothing else
changes for the host.

### The agent edits its own instructions — `system_prompt`

The same seam carries one more self-management tool. `SystemPromptTool` lets the model **read or change its
own system prompt**: `get` returns the prompt in force and where it came from, `append` adds a standing rule,
`set` replaces the whole prompt, `reset` restores the host's default. The prompt is *global* on purpose — "its
own system prompt" is the one the host sends to every conversation — so the tool writes through a
`SystemPromptStore` you provide (the app's is Settings › System prompt; `InMemorySystemPromptStore` for tests
and showcases).

```swift
// snippet: compile
import Loopl

func selfInstructing(_ model: any Model) -> Agent {
    let store = InMemorySystemPromptStore(prompt: "You are loopl. Answer concisely.")
    return Agent(model: model, tools: [SystemPromptTool(store: store)], systemPrompt: store.read())
}
```

Every write is **human-in-the-loop**: `requiresApproval` returns a medium-risk `ApprovalRequest` whose
`bodyPreview` is the change itself — `− old` / `+ new` for `set` and `reset`, `…N chars kept` / `+ rule` for
`append` — so the person sees that the model is about to change its own future behaviour. A denied card is an
`ERROR:` the model reads; nothing moves. A rule that is already present, or a reset when the prompt already is
the default, skips the card and answers honestly. Once approved, `Agent.changeSystemPrompt` installs the new
prompt for the **next model call of the same turn** and the store persists it for every later one; the agent
announces it as `AgentEvent.systemPromptChanged(SystemPromptChange)` and the transcript shows one quiet note —
*"The model added a rule to its instructions · undo in Settings › System prompt"*. `SystemPromptToolTests` (5)
include the end-to-end check: call *n* saw the old prompt, call *n + 1* ran on the new one.

## Transcript

`Transcript` folds events into rows — text, reasoning, tool rows with timing, metrics — that `LooplUI` draws.

```swift
// snippet: compile
import Loopl

@MainActor
func drive(_ agent: Agent, _ prompt: String, into transcript: inout Transcript) async throws {
    transcript.user(prompt)
    for try await event in agent.stream(prompt) {
        _ = transcript.apply(event)
    }
    print(transcript.items.count, transcript.lastResult?.stopReason as Any)
}
```

### Editing a message after the fact

"Hold a message and edit it" is a transcript operation, not an event-loop one. `truncated(before:)` /
`truncated(through:)` cut the visible thread, `userTurn(before:)` finds the user turn an answer belongs to
(Retry), and `messages` rebuilds the agent history from what is kept — then a **fresh** `Agent` on that
history streams the edited turn like any other, tools and approvals included.

```swift
// snippet: compile
import Loopl

@MainActor
func edit(_ item: TranscriptItem, to text: String, model: any Model, transcript: inout Transcript) async throws {
    let kept = transcript.truncated(before: item.id)          // the item and everything after it are gone
    let agent = Agent(model: model, messages: kept.messages)  // history ends on the assistant's side
    transcript = kept
    transcript.user(text)
    for try await event in agent.stream([.user(text)]) { _ = transcript.apply(event) }
}
```
