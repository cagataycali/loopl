---
title: "Sub-agents"
description: "use_agent: a child Agent on the same on-device model with only the tools you list — inline, or in the background with a wake when it finishes."
---

# Sub-agents

An agent can delegate. `use_agent` spawns a **child `Agent`** with its own system prompt, one input and **only the tools the parent lists**. The child runs on the **same loaded model** — there is one set of weights on a phone — and its events stream back **nested** in the parent's stream, so a UI draws the child inside the parent's tool card.

```swift
// snippet: compile
import Loopl

func run(_ model: any Model) async throws {
    let hub = SubAgentHub()                        // one per host: slots, envelopes, the wake hook
    let gate = ModelGate()                         // one model → parent and children take turns
    let tools: [any Tool] = [HttpTool(), CalculatorTool()]
    let useAgent = UseAgentTool(hub: hub) {
        SubAgentContext(model: model, gate: gate, availableTools: tools)
    }
    let parent = Agent(model: model, tools: tools + [useAgent], systemPrompt: "Delegate fetches to a sub-agent.")
    await parent.setModelGate(gate)

    for try await event in parent.stream("What is the title of https://example.com? Delegate the fetch.") {
        switch event {
        case .childStarted(let info): print("child \(info.id) \(info.name) tools=\(info.tools)")
        case .child(let id, .text(let t)): print("[\(id)] \(t)")
        case .childStatus(let id, let status): print("[\(id)] \(status.rawValue)")
        case .result(let r): print(r.text)
        default: break
        }
    }
}
```

## The tool

```
use_agent {action: run | status | result | stop, system_prompt?, input?, tools?: [String], wait?: Bool, id?}
```

| action | does |
|---|---|
| `run` | spawns a child. `wait` (default `true`) returns the child's final answer inline when it finishes within **45 s**; otherwise — or with `wait:false` — it returns `{pending: true, id}` at once. |
| `status` | a snapshot of the envelope by `id`: status, elapsed, tool calls, result when done. Never waits. |
| `result` | the final answer by `id`. On a child still running it **waits up to 45 s** (measured: a 2B model polls right after `wait:false` whatever the note says — so the poll becomes the wait), then `{pending: true}`. A result delivered this way **claims the wake**: no second delivery. |
| `stop` | cancels a running or queued child. |

Tool names are validated against the parent's own tools — an unknown name is a sentence the model can read, and **`use_agent` itself is refused**: children cannot spawn (depth 1). The same applies to a name that is not in the registry: the child only ever gets what the parent could offer.

## One model, many agents

`ModelGate` is a FIFO lock around every model call. The parent and each child acquire it for **one call** — a child generating while the user sends a message makes the parent wait for that one call, never for the whole child. Children never interleave tokens on the Metal device. At most **three children** are alive at once; a fourth is `queued` and starts when a slot frees.

## Events

| event | when |
|---|---|
| `.childStarted(SubAgentInfo)` | once, before anything else of that child — id, the parent's `toolUseId`, name (first line of the system prompt), tools, `background` |
| `.child(id, AgentEvent)` | the child's own event, verbatim: `.text`, `.toolStarted`, `.toolResult`, `.approvalRequested`, `.result`… |
| `.childStatus(id, SubAgentStatus)` | `queued · running · background · done · failed · stopped` |

Order for an inline run: `.toolStarted(use_agent)` → `.childStarted` → `.childStatus(.queued / .running)` → `.child(…)*` → `.childStatus(.done)` → `.toolResult(use_agent)`. With `wait:false` (or after 45 s) the parent's `.toolResult` arrives early, `.childStatus(.background)` marks the hand-off, and the rest of the child's events flow through **`hub.detachedEvents()`** — the host subscribes once and folds them into the same transcript item.

`Transcript` understands all three: `.childStarted` adds a `TranscriptItem.Kind.agent(SubAgentRun)` right after the parent's `use_agent` row (siblings stack), `.child` applies into the run's **nested `Transcript`**, `.childStatus` updates the chip. A UI renders the child's rows with the same views it uses for the parent.

## Wake

A background child finishing calls `hub.onFinished(envelope)` **once**. The host (the app's `Engine`) turns it into a synthetic user turn on the parent:

```
[use_agent agent_… finished] <name> (done, 12 s, task: "…")
Result: <≤ 2000 chars>

No human typed this. Use the result to finish what the user asked; reply in a few sentences. …
```

Rules, same as tiny-tech's wake rail: one wake in flight, the rest FIFO; **never while the parent is generating or the user is typing** (the app's composer reports that); dropped when the child's thread is no longer on screen. The transcript shows one system-styled line — `SubAgentWake.line(for:)`, prefix `[use_agent ` — not a user bubble.

## Approvals from a child

A child's `http` POST asks exactly like the parent's: `.child(id, .approvalRequested(req))`. Answer it on the child — `await hub.resolve(child: id, approval: req.id, .approve)`. The app's `Engine.resolve` tries the parent first and then every live child, so one `ApprovalCard` callback serves both.

## Cancellation

A child belongs to the thread that spawned it. Switching threads (new conversation, open another, delete, clear) calls `hub.stopAll()` — live children are cancelled (`.stopped`) and wakes that have not run are dropped. Stopping the **parent** while it waits inline does not stop the child: it is detached and finishes in the background (stop it by id if you do not want the result). Finished envelopes stay answerable by id for the session and are persisted as small JSON summaries (`SubAgentHub(directory:)`), pruned after 24 h.
