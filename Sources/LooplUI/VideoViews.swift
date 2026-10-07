import SwiftUI
import Loopl

/// One attached clip: poster (from `VideoBlock.thumbnail`), duration, the frame count the model gets, optional
/// remove. Below it, when the clip had speech, the transcript as its own quiet row — what the model *heard* is
/// visible, because Qwen3-VL reads the words, not the audio.
public struct VideoClipChip: View {
    public var video: VideoBlock
    public var onRemove: (() -> Void)?
    /// Composer: the transcript is still being made.
    public var transcribing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(video: VideoBlock, transcribing: Bool = false, onRemove: (() -> Void)? = nil) {
        self.video = video; self.transcribing = transcribing; self.onRemove = onRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    if let t = video.thumbnail, let img = ImageBlockDecoder.shared.image(for: t) {
                        Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.25)
                    }
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(6).background(Color.black.opacity(0.55), in: Circle())
                }
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(video.exists ? video.clock : "video missing").font(.caption.weight(.semibold)).monospacedDigit()
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(video.frameCount) frames").font(.caption)
                    }
                    .foregroundStyle(video.exists ? .primary : .secondary)
                    if transcribing {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("listening…").font(.caption2) }.foregroundStyle(.secondary)
                    } else if video.transcript == nil {
                        Text("no speech").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text("with transcript").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let onRemove {
                    Button {
                        LooplDesign.haptic()
                        onRemove()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).padding(6)
                            .background(Color.secondary.opacity(0.2), in: Circle())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove video")
                }
            }
            .padding(.leading, 6).padding(.trailing, onRemove == nil ? 14 : 8).padding(.vertical, 6)
            .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
        .accessibilityIdentifier("video-chip")
    }

    private var accessibility: String {
        var s = video.exists ? "Video, \(video.clock), \(video.frameCount) frames" : "Video, file missing"
        if transcribing { s += ", transcribing" } else if video.transcript != nil { s += ", with transcript" }
        return s
    }
}

/// The spoken words of a clip, under its chip in the transcript. Collapsed to two lines; tap to expand.
public struct VideoTranscriptRow: View {
    public var text: String
    @State private var expanded = false
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Button { withAnimation(LooplDesign.Motion.snappy) { expanded.toggle() } } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2).multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio transcript: \(text)")
        .accessibilityIdentifier("video-transcript")
    }
}
