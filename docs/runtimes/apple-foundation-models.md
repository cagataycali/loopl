# Apple Foundation Models (iOS 26)

`AppleFoundationModel` wraps `FoundationModels.LanguageModelSession`. Zero download, always offline, Apple's ~3B
on-device model (2-bit QAT weights, 8-bit KV cache).

```swift
let avail = AppleFoundationModel.availability()          // nonisolated static
if avail.available {
    let model = AppleFoundationModel()
    try await model.load(spec, from: nil) { _ in }       // nothing to load; marks loadedModelId
    let agent = Agent(model: model, tools: [CurrentTimeTool(), CalculatorTool()])
} else {
    print(avail.reason)                                  // show it verbatim
}
```

## Availability

`SystemLanguageModel.default.availability` → `RuntimeAvailability`:

| Apple | `reason` the SDK returns |
|---|---|
| `.available` | `.ok` |
| `.unavailable(.deviceNotEligible)` | "device not eligible for Apple Intelligence" |
| `.unavailable(.appleIntelligenceNotEnabled)` | "Apple Intelligence is off — Settings › Apple Intelligence & Siri" |
| `.unavailable(.modelNotReady)` | "model not ready (still downloading / device busy)" |
| iOS < 26 | "needs iOS 26 or later" |
| SDK without the framework | "FoundationModels framework not in this SDK" |

## Context: 4,096 tokens, hard

Apple states it three times in the docs: *prompts, instructions, tool definitions and their input and output, generable
schemas, and all responses* share one 4,096-token window per session. The runtime reports `Metrics.contextMax = 4096`
and — because the framework exposes no tokenizer — **estimates** prompt tokens at ~4 characters each with
`Metrics.estimated = true` (the app shows ≈). Overflow surfaces as `GenerationError.exceededContextWindowSize`, mapped
to a `ModelError`; trim `agent.messages` and retry.

## Tools: manual, not native (v1)

Apple's native `Tool` protocol needs compile-time typed `@Generable` arguments, which does not fit a toolset defined at
runtime by JSON schema. So v1 prompts manually: `PromptBuilder.toolSystemPrompt(tools:family: .generic, base:)` goes
into the session **instructions**, the model answers with a bare JSON object, and the agent's
`ToolCallParser(family: .generic)` lifts the call. Native bridging is noted for v2.

## Streaming

`streamResponse` yields **snapshots** (accumulated text), not deltas. The runtime diffs consecutive snapshots into
`ModelEvent.text` deltas so the transcript view behaves the same for both runtimes. Earlier turns are flattened into the
prompt as `User: … / Assistant: …` lines because a session's transcript is append-only.

## Other errors you will see

`rateLimited` (background or aggressive use — foreground interactive use is not limited), `guardrailViolation`,
`refusal`, `concurrentRequests` (one in-flight request per session — the agent serialises),
`unsupportedLanguageOrLocale`.

!!! warning "iOS 27 APIs"
    Apple's docs already show iOS 27 material: custom `LanguageModel` providers, `MLXLanguageModel`, `ToolCallingMode`,
    `ContextOptions`, Private Cloud Compute. None of it is usable on an iOS 26 target; loopl keeps two engines behind the
    one `Model` protocol instead.
