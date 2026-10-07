import Foundation
import Loopl
#if canImport(AVFoundation) && canImport(CoreImage)
import AVFoundation
import CoreImage
import CoreMedia

/// Evenly spaced frames from a clip, resized so the long edge is ≤ `plan.maxEdge`, via `AVAssetImageGenerator`.
/// This is loopl's own sampler: the count/density/edge come from the `VideoFramePlan` the app decided with its
/// memory budget, so the processor (Qwen3-VL in mlx-swift-lm) only patchifies what it is given. Shared by the
/// model path (`VisionPrompt.video`) and the app (poster thumbnail, "N frames" chip).
public enum VideoFrameSampler {
    public struct Frame: @unchecked Sendable {
        public let image: CIImage
        public let time: CMTime
    }

    public struct Probe: Sendable, Hashable {
        public var duration: TimeInterval
        public var width: Int
        public var height: Int
        public var hasAudio: Bool
    }

    /// Duration, oriented pixel size and whether the clip has an audio track (→ transcribe).
    public static func probe(_ url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ModelError("no video track in \(url.lastPathComponent)")
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let oriented = size.applying(transform)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return Probe(duration: duration.isFinite ? duration : 0,
                     width: Int(abs(oriented.width).rounded()), height: Int(abs(oriented.height).rounded()),
                     hasAudio: !audio.isEmpty)
    }

    /// The timestamps a plan samples: `frameCount` points spread over the clip (first at 0, last just before the end).
    public static func sampleTimes(duration: TimeInterval, plan: VideoFramePlan) -> [CMTime] {
        let count = plan.frameCount(duration: duration)
        guard count > 1, duration > 0 else { return [.zero] }
        // Keep the last sample a little inside the clip; the final frame of many recordings is black/duplicate.
        let span = max(0, duration - min(0.25, duration / Double(count)))
        let step = span / Double(count - 1)
        return (0..<count).map { CMTime(seconds: Double($0) * step, preferredTimescale: 600) }
    }

    /// Sample + resize. Frames the generator cannot produce (corrupt GOP, past the end) are skipped, not faked.
    public static func frames(of url: URL, plan: VideoFramePlan, duration: TimeInterval? = nil) async throws -> [Frame] {
        let asset = AVURLAsset(url: url)
        let dur: TimeInterval
        if let duration { dur = duration } else { dur = try await asset.load(.duration).seconds }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: plan.maxEdge, height: plan.maxEdge)   // aspect-fit: long edge = maxEdge
        var out: [Frame] = []
        for t in sampleTimes(duration: dur, plan: plan) {
            do {
                let (cg, actual) = try await gen.image(at: t)
                out.append(Frame(image: CIImage(cgImage: cg), time: actual))
            } catch {
                continue
            }
        }
        return out
    }

    /// A JPEG poster (first readable frame near 10 % in) for chips and History.
    public static func thumbnail(of url: URL, maxEdge: Int = 256, duration: TimeInterval? = nil) async -> ImageBlock? {
        let asset = AVURLAsset(url: url)
        let dur: TimeInterval
        if let duration { dur = duration } else if let d = try? await asset.load(.duration).seconds { dur = d } else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: min(dur * 0.1, 1), preferredTimescale: 600)) else { return nil }
        let ci = CIImage(cgImage: cg)
        let ctx = CIContext()
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ctx.jpegRepresentation(of: ci, colorSpace: cs, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]) else { return nil }
        return ImageBlock(data: data, mime: "image/jpeg", width: cg.width, height: cg.height, alt: "video poster")
    }
}
#endif
