---
title: "Checkpoints"
description: "Snapshot an agent — messages, metrics, what it was waiting for — and come back to it later."
---

# Checkpoints

An agent's state is its messages, its metrics and whatever it is waiting on. `AgentCheckpoint` holds all three — `Codable`, versioned.

```swift
// snippet: compile
import Loopl

func save(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [CalculatorTool()])
    _ = try await agent("What is 23 × 47?")
    try FileCheckpointStore().save(await agent.checkpoint(id: "chat-1", label: "after the sum"))
}

func resume(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [CalculatorTool()])
    await agent.restore(try FileCheckpointStore().load("chat-1"))
    _ = try await agent("and times two?")
}
```

| Field | |
|---|---|
| `messages` · `systemPrompt` | the conversation, tool calls included |
| `metrics` | cycles, tool calls, usage |
| `runtime` · `modelId` | which engine and weights |
| `pendingApprovals` · `interrupt` | what was waiting when the snapshot was taken |
| `userInfo` | yours; the SDK never reads it |

Model, tools and hooks are not saved — they belong to your app, and a restored agent is built with the same ones.

## While waiting

```swift
// snippet: compile
import Loopl

func snapshotWhileWaiting(_ agent: Agent) async {
    let snapshot = await agent.checkpoint()
    if snapshot.isSuspended {
        print(snapshot.pendingApprovals.map(\.title), snapshot.interrupt?.kind ?? "")
    }
}
```

Restoring does not replay a decision nobody made: calling the agent again re-asks the person.

## Versions & stores

A file from a newer loopl throws `CheckpointError.unsupportedVersion` rather than half-decoding; unknown fields are ignored. JSON is sorted with millisecond dates, so snapshots round-trip byte for byte. `FileCheckpointStore` writes one file per snapshot under Application Support; conform to `CheckpointStore` for your own database (`CheckpointSummary` rows make a cheap history list).
