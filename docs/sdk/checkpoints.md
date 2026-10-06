---
title: Checkpoints
description: Snapshot an agent — messages, metrics, what it was waiting for — write it to disk, come back to it.
---

# Checkpoints

A loopl agent's state is its messages, its accumulated metrics and whatever it is suspended on. `AgentCheckpoint` is all three, `Codable` and versioned:

```swift
// snippet: compile
import Loopl

func save(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [CalculatorTool()])
    _ = try await agent("What is 23 × 47?")

    let store = FileCheckpointStore()
    try store.save(await agent.checkpoint(id: "chat-1", label: "after the sum"))
}

func resume(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [CalculatorTool()])
    await agent.restore(try FileCheckpointStore().load("chat-1"))
    _ = try await agent("and times two?")
}
```

What is in it:

| Field | |
|---|---|
| `messages` · `systemPrompt` | the conversation (tool calls and results included) |
| `metrics` | `EventLoopMetrics` — cycles, tool calls, accumulated usage |
| `runtime` · `modelId` | which engine and weights produced it |
| `pendingApprovals` | tool calls suspended for a human when the snapshot was taken |
| `interrupt` | `InterruptSnapshot` — generic `{kind, toolUseId, payload}` for whatever else suspended the run |
| `userInfo` | your own `[String: JSONValue]`; the SDK never reads it |
| `version` | `AgentCheckpoint.currentVersion` |

The model, the tools and the hooks are **not** in a checkpoint: they are the host's, and a restored agent is built with the same ones. That keeps a snapshot small (a conversation) and portable between builds.

## Mid-interrupt

Take a snapshot while a tool call is waiting for approval and it carries that wait:

```swift
// snippet: compile
import Loopl

func snapshotWhileWaiting(_ agent: Agent) async {
    let snapshot = await agent.checkpoint()        // from any task, while the call is suspended
    if snapshot.isSuspended {
        print(snapshot.pendingApprovals.map(\.title))
        print(snapshot.interrupt?.kind ?? "")      // "approval"
    }
}
```

Restoring does not resume the suspended call — the model's tool-use message is still the last message in history, so calling the agent again re-makes the call and asks the human again. That is deliberate: a decision a person never gave should not be replayed from a file.

## Versions

`version` is checked on decode. A file from a newer loopl throws `CheckpointError.unsupportedVersion` instead of decoding half of itself; every field added after v1 is optional, so a newer file still loads in an older build when the version allows it, and unknown fields are ignored.

`AgentCheckpoint.jsonData()` / `init(jsonData:)` use ISO-8601 with milliseconds and sorted keys, so a snapshot round trips byte-for-byte and diffs cleanly.

## Your own store

`FileCheckpointStore` writes one atomic JSON file per checkpoint under *Application Support/loopl/checkpoints* (pass a directory for an app group). A host with its own database conforms to `CheckpointStore` instead — `save` / `load` / `list` / `delete`, where `list` returns `CheckpointSummary` rows cheap enough for a history screen.

API: `AgentCheckpoint` · `InterruptSnapshot` · `CheckpointStore` · `FileCheckpointStore` · `CheckpointSummary` · `CheckpointError`.

## Strands

| Strands | loopl |
|---|---|
| `SessionManager` / `FileSessionManager` | `CheckpointStore` / `FileCheckpointStore` |
| `SnapshotSessionManager` | `agent.checkpoint()` + `agent.restore(_:)` |
| session repository rows per message | one JSON file per snapshot (a phone has one user) |
| interrupt state in the session | `pendingApprovals` + `InterruptSnapshot` |

Strands restores agents automatically through a session manager hook; loopl keeps it explicit — on a phone the host already decides when a chat is saved.
