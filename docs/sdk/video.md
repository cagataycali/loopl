---
title: "Video input"
description: "Send a clip to a Qwen3-VL model: VideoBlock in the message, frames sampled on device within a plan the app decides, the audio track as a transcript — and what a text-only model reads instead."
---

# Video input

A user message can carry a **video**. On a vision checkpoint (Qwen3-VL — the family mlx-swift-lm reads video with) the model sees
**evenly spaced frames** of the clip, natively, as part of the prompt; on a text-only model it reads an honest one-line stand-in.
Nothing is uploaded: the clip stays a file on the device, frames are decoded on the device, and the model runs on the device.

```swift
// snippet: compile(runtimes)
import Loopl
import LooplRuntimes

func ask(_ model: MLXModel, clip: URL) async throws -> String {
    let probe = try await VideoFrameSampler.probe(clip)             // duration, oriented size, has audio?
    let block = VideoBlock(path: clip.path, mime: "video/quicktime",
                           duration: probe.duration, width: probe.width, height: probe.height,
                           framePlan: VideoFramePlan(maxFrames: 16, fps: 1, maxEdge: 448),
                           transcript: nil)                          // ← fill from `transcribe` when probe.hasAudio
    let agent = Agent(model: model, tools: [])
    let result = try await agent([Message.user("What happens in this video?", images: [], videos: [block])])
    return result.text
}
```

## The block

`ContentBlock.video(VideoBlock)` is the fifth kind of content a message can hold. The clip's **bytes are never in the message**
— videos are too large for a JSON history and for a dataset row — the block carries what the UI and the runtime need:

| field | what |
|---|---|
| `path` | the file (the app keeps it in the thread's `<id>.attachments/` folder, deleted with the thread) |
| `duration`, `width`, `height` | from `VideoFrameSampler.probe` — the plan and the token estimate use them |
| `thumbnail` | a ≤ 256 px JPEG poster for chips and History; **not** given to the model |
| `framePlan` | how many frames, how dense, how large — see below |
| `transcript` | what was said in the clip, from on-device `transcribe`; `nil` = no audio / not transcribed |

`Message.user(_:images:videos:)` builds the turn; `message.videos`, `hasVideo`, `hasVisualMedia` read it back.

## Frames, not the file: the plan

`VideoFramePlan { maxFrames, fps, maxEdge }` decides the prompt's cost **before** anything is decoded:

- `frameCount(duration:)` = `min(maxFrames, duration × fps)` evenly spaced frames (`fps` is capped at 2 — Qwen3-VL's own default).
- Each frame is resized so its long edge is ≤ `maxEdge` (448 by default; never upscaled).
- `estimatedTokens(duration:width:height:)` — Qwen3-VL merges 16 px patches 2×2, so a frame costs one token per **32×32 block**,
  and **two consecutive frames share one temporal patch**: `ceil(frames/2) × ceil(h/32) × ceil(w/32)`.
  A 16:9 clip at 448 px ≈ 112 tokens per frame pair; 16 frames ≈ 900 tokens.
- `VideoFramePlan.fitting(tokenBudget:duration:width:height:)` shrinks a plan until it fits: **frames first** (halving, down to 2 —
  a readable frame beats one more blurry one), then the edge (448 → 336 → 224), and returns `nil` when even that misses, so the
  caller can say so instead of truncating silently.

The **app** decides the plan where the memory budget is known (`MemoryBudget.frameBudget`): 8 / 16 / 32 frames by headroom, then
`fitting` against the context window. The plan travels with the block, so a reopened thread re-renders the same prompt.

## What the runtime does

`MLXModel`'s vision path triggers when a message has images **or** videos. For every `VideoBlock` loopl's own sampler
(`VideoFrameSampler`, `AVAssetImageGenerator`) decodes `frameCount` frames at ≤ `maxEdge` and hands them to mlx-swift-lm as
`UserInput.Video.frames`; the checkpoint's processor patchifies them and swaps `<|video_pad|>` for the right number of tokens.
loopl samples the frames itself for two reasons found in mlx-swift-lm 3.32.3: its sampler's frame cap defaults to *unbounded*, and
its one `maxPixels` budget is **shared** between images and video frames — sampling at 448 px ourselves keeps photos in the same
turn at their 1 MP budget. (`VisionPrompt.videoSource = .url` hands the file to the library's sampler instead; it exists for the
A/B below.) If the prompt still overflows, `ContextWindowOverflowError` names the frame count and suggests fewer frames or a shorter clip.

A **text-only model** never receives pixels. Its chat template gets `Message.textWithVideoFallback`:

```
What happens in this video?
[video attached: IMG_0412.mov (0:42) — the frames need a vision model; this model cannot see them]
[audio transcript: so this is the harbour at six in the morning …]
```

## Audio: a transcript, by design

**Qwen3-VL has no audio input** (that is Qwen3-Omni). loopl does not pretend otherwise: when the clip has an audio track the app
runs it through the same on-device `transcribe` it uses for voice notes and stores the words in `VideoBlock.transcript`. A vision
model gets the frames **and** `[audio transcript: …]` in the same user turn; a text model gets the transcript alone. The UI shows
the transcript as its own chip under the clip, so what the model heard is visible, not implied.

## Measured (macOS, M-series, mlx-swift-lm 3.32.3)

`MLXVideoTests` (`TEST_RUNNER_LOOPL_VL_DIR=<checkpoint> xcodebuild test -scheme Loopl-Package -destination 'platform=macOS,arch=arm64'
-only-testing:LooplRuntimesTests/MLXVideoTests`; `LOOPL_VIDEO`, `LOOPL_VIDEO_SOURCE=frames|url`, `LOOPL_VIDEO_FRAMES`) prints one
`MEASURE` line per run. The numbers below come from the synthetic fixture clips (moving coloured squares on a dark background,
640×360, 30 fps, 10 s and 60 s, a sine audio track).

<!-- MEASUREMENTS: filled by the lane from ~/.tiny/loopl-phase8/video-sdk/evidence/matrix.log -->

## Where it is not

- No `describe_video` tool yet: a vision model reads the clip in the user turn, and the measurement decides whether a text-only
  parent needs a tool — fewer tools unless one earns its place.
- `UserInput.Video.avAsset` (library-side decoding on the fly) is not used; frames are decoded once, so the plan's cost is known up front.
