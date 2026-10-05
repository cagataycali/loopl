# loopl 🔁

**On-device LLMs on iPhone, with a tiny agent loop.** Download a model from Hugging Face
with your own token, run it fully offline with token streaming, and let it call tools
("strands" style: stream → parse tool calls → run → append → recurse).

iOS-only. SwiftUI, Swift 6, iOS 18.0 target. Bundle `technology.tiny.loopl`.

## What
- **Chat** — streaming bubbles, live HUD: TTFT, tok/s, prompt/gen tokens, context used vs max, stop button, expandable tool-call cards (args + result + ms).
- **Models** — bundled `models.json` catalog (runtime, repo, size, ctx, RAM budget, gated flag); download with resume + progress, delete, disk usage, memory budget from `os_proc_available_memory`.
- **Agent** — toggle tools, max iterations, system prompt.
- **Settings** — HF token (Keychain only), **offline mode** (every network path refuses), runtime preference, generation params, clear cache.

## Runtimes
| Runtime | Status | Notes |
|---|---|---|
| **MLX** (`ml-explore/mlx-swift-lm` → `MLXLLM`, `MLXLMCommon`) | built | Metal; real device only (simulator shows "device only"). Loads **from the local directory only** — this file has no network code, so offline inference is structural, not a flag. |
| **Apple Foundation Models** | built, `@available(iOS 26)` | `SystemLanguageModel.default` / `LanguageModelSession.streamResponse`. Zero download. Needs Apple Intelligence on. 4096-token window. Tools via manual prompt + parser (native typed `Tool` protocol is v2). |
| **llama.cpp (GGUF)** | stub (v2) | type exists so the picker can say so honestly. |

Tokenizer + chat templates: `huggingface/swift-transformers` (`Tokenizers`), bridged by hand to
`MLXLMCommon.Tokenizer` (we deliberately do **not** link `MLXHuggingFace`: its macros pull
`MLXFoundationModels`, which needs iOS 27 types under the default package trait).

## Agent loop (pure Swift, unit-tested)
`Message` (system/user/assistant(text, toolCalls)/tool(result, callId)) · `AgentTool` protocol
(name, description, JSON-schema parameters, `call(args) async throws -> String`) ·
`ToolCallParser` for Hermes/Qwen `<tool_call>{…}</tool_call>`, Llama 3.x `<|python_tag|>` / bare
JSON, generic fenced JSON · `PromptBuilder` renders manual tool specs when the chat template
has no `tools` support · `AgentLoop.run` streams `AgentEvent`s so every step shows in the UI.
Built-in tools: `current_time`, `calculator` (own recursive-descent evaluator — no NSExpression),
`device_info`, `remember`/`recall`, `http_get` (refused while offline).

MLX's own streaming tool-call detector runs too (`generate(tools:)` → `.toolCall`), our parser
is the fallback for models it does not know.

## How
```sh
brew install xcodegen
xcodegen generate
xcodebuild -scheme loopl -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme loopl -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test   # pure parts only
# device
xcodebuild -scheme loopl -destination id=<udid> -configuration Debug DEVELOPMENT_TEAM=K6B7JDYLLL -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> <path/to/loopl.app>
```
First build resolves `mlx-swift` (large; several minutes).

On the phone: Settings → paste HF token (optional, gated repos only) → Models → Download
`Qwen3 1.7B (4-bit)` → Load → Chat: *"what time is it in Istanbul and what is 23*47?"* → watch the
two tool cards and the HUD. Then flip **Offline mode** (or real Airplane Mode) and ask again.

## Honesty
- No benchmarks are claimed; the HUD shows measured numbers for *your* run. Apple FM exposes no
  tokenizer, so its token counts are `chars/4` estimates (labelled).
- `ctx_usable_8gb` in the catalog is a RAM budget guess until measured on device.
- The **Demo (scripted) runtime** in Settings replays a canned conversation for simulator UI work;
  the Chat header says DEMO while it is on.

Private repo of @cagataycali. Lane notes live in `~/.tiny/loopl-20261005/`.
