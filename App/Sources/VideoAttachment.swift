import SwiftUI
import Observation
import AVFoundation
import UniformTypeIdentifiers
import Loopl
import LooplRuntimes
import LooplAppleTools

/// A clip in the composer, before it is sent: already copied into the thread's attachments folder (so sending
/// costs nothing and removing the chip deletes the file), probed, with a poster — and, when it has an audio track,
/// a transcript being made on device. `block` is what goes into the message.
@MainActor @Observable
final class VideoClip: Identifiable {
    nonisolated let url: URL
    private(set) var block: VideoBlock
    private(set) var transcribing = false
    nonisolated var id: URL { url }

    init(url: URL, block: VideoBlock) { self.url = url; self.block = block }

    func setTranscript(_ t: String?) { block.transcript = t; transcribing = false }
    func setPlan(_ p: VideoFramePlan) { block.framePlan = p }
    func startTranscribing() { transcribing = true }
}

/// Import + sizing for clips. Files land next to the recordings (`AudioAttachment.directory`), as `<id>.mov|mp4`.
@MainActor enum VideoAttachment {
    static let maxClips = 1
    static let maxSeconds: TimeInterval = 10 * 60
    static let types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    /// Copy (or move, for a temp file we own) `source` into `dir`, probe it, make the poster, decide the plan.
    /// Returns nil when AVFoundation cannot read a video track — the caller says so.
    static func importClip(from source: URL, into dir: URL, move: Bool, spec: ModelSpec?) async -> VideoClip? {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let dest = dir.appendingPathComponent(UUID().uuidString.prefix(8).uppercased() + "." + ext)
        do {
            if move { try FileManager.default.moveItem(at: source, to: dest) } else { try FileManager.default.copyItem(at: source, to: dest) }
        } catch { return nil }
        guard let probe = try? await VideoFrameSampler.probe(dest), probe.duration > 0 else {
            try? FileManager.default.removeItem(at: dest); return nil
        }
        let thumb = await VideoFrameSampler.thumbnail(of: dest, duration: probe.duration)
        let plan = plan(for: spec, probe: probe)
        let mime = ext == "mp4" ? "video/mp4" : "video/quicktime"
        var block = VideoBlock(path: dest.path, mime: mime, duration: probe.duration, width: probe.width, height: probe.height,
                               thumbnail: thumb, framePlan: plan, transcript: nil)
        if probe.duration > maxSeconds { block.framePlan = plan }   // long clips just get the same evenly spaced frames
        let clip = VideoClip(url: dest, block: block)
        if probe.hasAudio { clip.startTranscribing(); Task { clip.setTranscript(await transcript(of: dest)) } }
        return clip
    }

    /// Frames for this device + model: headroom above 1.3× the weights picks 8 / 16 / 32, then the plan is shrunk
    /// until the clip fits half the model's context window (the other half is the conversation + the answer).
    /// P8-A's `VisionBudget` replaces the headroom rule when it lands — the per-frame arithmetic is `VideoFramePlan`'s.
    static func plan(for spec: ModelSpec?, probe: VideoFrameSampler.Probe) -> VideoFramePlan {
        let headroom = Double(MemoryBudget.budget) - Double(spec?.sizeBytes ?? 0) * 1.3
        let frames = headroom >= 3e9 ? 32 : headroom >= 1.5e9 ? 16 : 8
        let start = VideoFramePlan(maxFrames: frames, fps: 1, maxEdge: 448)
        let ctx = spec?.defaultParams.contextLength ?? 8192
        return VideoFramePlan.fitting(tokenBudget: ctx / 2, duration: probe.duration, width: probe.width, height: probe.height, start: start)
            ?? VideoFramePlan(maxFrames: 2, fps: 1, maxEdge: 224)
    }

    /// The clip's audio track → text, with the same on-device recogniser the `transcribe` tool uses. `nil` = no speech
    /// (or recognition unavailable here) — the chip then says "no speech" and the model gets no transcript line.
    static func transcript(of url: URL) async -> String? {
        let out = try? await TranscribeTool().call(["path": .string(url.path)])
        guard let out, let nl = out.firstIndex(of: "\n"), out.hasPrefix("transcript of") else { return nil }
        let text = out[out.index(after: nl)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func remove(_ clip: VideoClip) { try? FileManager.default.removeItem(at: clip.url) }
}

/// A movie from the Photos picker, received as a file (never loaded into memory): copied to a temp URL we own.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension))
            try FileManager.default.copyItem(at: received.file, to: tmp)
            return PickedMovie(url: tmp)
        }
    }
}

#if os(iOS)
import UIKit
/// The system camera in video mode. Hands back the temp movie URL (or nil on cancel).
struct VideoCameraPicker: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.mediaTypes = [UTType.movie.identifier]
        c.cameraCaptureMode = .video
        c.videoQuality = .typeMedium          // 480p is plenty: frames go to the model at ≤ 448 px
        c.videoMaximumDuration = VideoAttachment.maxSeconds
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VideoCameraPicker
        init(_ parent: VideoCameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onPick(info[.mediaURL] as? URL); parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onPick(nil); parent.dismiss() }
    }
}
#endif
