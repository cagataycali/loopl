import Foundation

/// How much a picture or a video costs a vision model — in TOKENS (context window) and in BYTES (KV cache).
/// Pure arithmetic from the checkpoint's geometry so the composer, the Models tab and the video pipeline (P8-B)
/// agree on one number. Qwen3-VL / Qwen3.5: patch 16 × spatial merge 2 → one token per 32 × 32 px; videos
/// additionally pair frames (temporal patch 2) → a frame costs HALF an image of the same size.
///
/// Numbers are estimates and are labelled so in the UI; measured truth lives in the P8-A scorecard
/// (~/.tiny/loopl-phase8/vl-models/SCORECARD.md).
public enum VisionBudget {
    /// Pixels per vision token for the Qwen3-VL family (patch 16, merge 2 → 32 px squares).
    public static let pixelsPerToken = 32 * 32
    /// loopl's image processing cap (`VisionPrompt.processing`, maxPixels 1280 × 28 × 28 ≈ 1.0 MP).
    public static let maxPixelsPerImage = 1280 * 28 * 28
    /// Frames are resized harder than photos (≤ 448 px long edge in P8-B's plan) — 448 × 336 ≈ 150 k px.
    public static let defaultFramePixels = 448 * 336

    /// Tokens one image adds to the prompt after loopl's resize (≈ 980 for a photo at the cap, plus 2 vision markers).
    public static func imageTokens(pixels: Int = maxPixelsPerImage) -> Int {
        max(4, min(pixels, maxPixelsPerImage) / pixelsPerToken) + 2
    }

    /// Tokens `frames` video frames add: pairs of frames share one temporal patch, so ≈ frames / 2 × tokens(frame).
    public static func videoTokens(frames: Int, framePixels: Int = defaultFramePixels) -> Int {
        guard frames > 0 else { return 0 }
        let perPair = max(4, min(framePixels, maxPixelsPerImage) / pixelsPerToken)
        return ((frames + 1) / 2) * perPair + 2
    }

    /// KV-cache bytes per token for a spec: 2 (K+V) × layers × kv_heads × head_dim × 2 bytes (bf16 cache).
    /// Qwen3-VL geometry by size band (28 layers / 8 kv heads / 128 for ≤ 3 B, 36 layers above); generic rows fall
    /// back to the 112 KiB figure the catalog notes already quote for Qwen3.
    public static func kvBytesPerToken(_ spec: ModelSpec) -> Int {
        guard spec.supportsVision else { return 112 * 1024 }
        let layers = spec.paramsB > 3 ? 36 : 28
        return 2 * layers * 8 * 128 * 2
    }

    /// Resident vision-tower activations while encoding one image/frame batch (tower hidden 1024, depth 24, bf16;
    /// a flat ~160 MB covers the 1 MP case we allow) — only while the picture is being encoded, but jetsam counts it.
    public static let towerActivationBytes: Int64 = 160 << 20

    /// Bytes a vision turn needs on top of the weights: KV for prompt + vision tokens, tower activations, and the
    /// 1.3× rule-of-thumb headroom the text estimate already uses.
    public static func bytesNeeded(_ spec: ModelSpec, promptTokens: Int, images: Int = 0, frames: Int = 0, framePixels: Int = defaultFramePixels) -> Int64 {
        let tokens = promptTokens + images * imageTokens() + videoTokens(frames: frames, framePixels: framePixels)
        let kv = Int64(tokens) * Int64(kvBytesPerToken(spec))
        let tower = (images + frames) > 0 ? towerActivationBytes : 0
        return Int64(Double(spec.sizeBytes) * 1.3) + kv + tower
    }

    /// The frame budget for a video: the largest frame count (≤ `cap`) whose tokens fit the context window
    /// (leaving `reserve` tokens for the question, the system prompt, tools and the answer) AND whose bytes fit
    /// `memoryBudget`. 0 means "this video cannot be sent to this model here"; callers say so honestly.
    /// P8-B calls this with the device's `MemoryBudget.budget` and the spec's usable context.
    public static func maxFrames(_ spec: ModelSpec, contextWindow: Int, reserve: Int = 2048, memoryBudget: Int64,
                                 framePixels: Int = defaultFramePixels, cap: Int = 32) -> Int {
        guard spec.supportsVision else { return 0 }
        var best = 0
        for frames in stride(from: 2, through: cap, by: 2) {
            let tokens = videoTokens(frames: frames, framePixels: framePixels)
            guard tokens + reserve <= contextWindow else { break }
            guard bytesNeeded(spec, promptTokens: reserve, frames: frames, framePixels: framePixels) <= memoryBudget else { break }
            best = frames
        }
        return best
    }
}
