# Apple Foundation Models (iOS 26)

`AppleFoundationModel` wraps `FoundationModels.LanguageModelSession`. Zero download, always offline,
Apple's ~3B on-device model (2-bit QAT weights, 8-bit KV cache).

```swift
if #available(iOS 26, *), AppleFoundationModel.availability == .available {
    let agent = Agent(model: AppleFoundationModel(), tools: [Clock(), Calculator()])
}
```

## Availability

`SystemLanguageModel.default.availability` →

| Value | Meaning | What the app shows |
|---|---|---|
| `.available` | ready | nothing |
| `.unavailable(.deviceNotEligible)` | needs iPhone 15 Pro / 16 / 17 / M-series iPad | "Apple Intelligence is not supported on this device" |
| `.unavailable(.appleIntelligenceNotEnabled)` | user has it off | deep link to Settings → Apple Intelligence & Siri |
| `.unavailable(.modelNotReady)` | OS still downloading assets | "Apple is still downloading the model — try again later" |

## Context: 4,096 tokens, hard

Apple states it three times in the docs: *prompts, instructions, tool definitions and their input and
output, generable schemas, and all responses* share one 4,096-token window per session. Roughly 3–4
characters per token for Latin text. `tokenCount(for:)` (iOS 26.4) powers the context meter; overflow is
`GenerationError.exceededContextWindowSize`, mapped to `ModelError.contextExceeded`.

`AppleFoundationModel` starts a **new session seeded with a condensed transcript** when the running
total passes ~3,000 tokens, so an agent conversation can outlive a single window.

## Tools, natively

Apple's `Tool` protocol (`name`, `description`, `parameters`, `call(arguments:)`) is bridged from loopl's
`ToolSpec`: the JSON schema becomes a `DynamicGenerationSchema`, and the framework performs the call
inside `respond` — the strands recursion is implicit there. The runtime surfaces each call as
`ModelEvent.toolUse` + the appended `Transcript.ToolOutput` so the transcript looks identical to the MLX
path.

## Streaming

`streamResponse` yields **snapshots** (accumulated text), not deltas. The runtime diffs consecutive
snapshots into `textDelta`s so `StreamingTextView` behaves the same for both runtimes.

## Other errors you will see

`rateLimited` (background or aggressive use — foreground interactive use is not limited),
`guardrailViolation`, `refusal`, `concurrentRequests` (one in-flight request per session — the agent
serialises), `unsupportedLanguageOrLocale`.

!!! warning "iOS 27 APIs"
    Apple's docs already show iOS 27 material: custom `LanguageModel` providers, `MLXLanguageModel`,
    `ToolCallingMode`, `ContextOptions`, Private Cloud Compute. None of it is usable on an iOS 26 target;
    loopl keeps two engines behind the one `Model` protocol instead.
