import SwiftUI
import Loopl
#if canImport(AVFAudio)
import AVFAudio
#endif

/// How a recording travels with a user turn: one plain line in the message text, so the model can
/// read the path and decide to call `transcribe` on it — nothing is transcribed behind its back.
///
///     [audio attached: /…/thread.attachments/8F2A.m4a (5.2 s) — call transcribe with this path to hear it]
///
/// `UserTurn` parses the line back out and renders an `AudioClipChip` in its place.
public struct AudioAttachmentMarker: Hashable, Sendable {
    public var path: String
    public var duration: TimeInterval
    public init(path: String, duration: TimeInterval) { self.path = path; self.duration = duration }

    public var url: URL { URL(fileURLWithPath: path) }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// The line placed in the user message.
    public var line: String {
        "[audio attached: \(path) (\(Self.seconds(duration))) — call transcribe with this path to hear it]"
    }

    public static func seconds(_ d: TimeInterval) -> String { String(format: "%.1f s", d) }

    /// `m:ss` for chips and the recording bar.
    public static func clock(_ d: TimeInterval) -> String {
        let s = Int(d.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(
        pattern: #"^\[audio attached: (.+?) \(([0-9]+(?:\.[0-9]+)?) s\)(?: — [^\]]*)?\]$"#, options: [.anchorsMatchLines])

    /// Splits a user message into its spoken text and the recordings it carries.
    public static func split(_ text: String) -> (text: String, clips: [AudioAttachmentMarker]) {
        var clips: [AudioAttachmentMarker] = []
        var kept: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let ns = line as NSString
            if let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: m.range(at: 1))
                let dur = Double(ns.substring(with: m.range(at: 2))) ?? 0
                clips.append(AudioAttachmentMarker(path: path, duration: dur))
            } else {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), clips)
    }
}

/// One shared preview player: tapping a chip plays its file, tapping another swaps.
@MainActor @Observable
public final class AudioPreview: NSObject {
    public static let shared = AudioPreview()
    public private(set) var playing: URL?
    public private(set) var progress: Double = 0
    #if canImport(AVFAudio)
    private var player: AVAudioPlayer?
    #endif
    private var ticker: Timer?

    public func isPlaying(_ url: URL) -> Bool { playing == url }

    public func toggle(_ url: URL) {
        if playing == url { stop(); return }
        stop()
        #if canImport(AVFAudio)
        do {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            playing = url
            ticker = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let p = self.player, p.duration > 0 else { return }
                    self.progress = p.currentTime / p.duration
                }
            }
        } catch {
            playing = nil
        }
        #endif
    }

    public func stop() {
        #if canImport(AVFAudio)
        player?.stop(); player = nil
        #endif
        ticker?.invalidate(); ticker = nil
        playing = nil; progress = 0
    }
}

#if canImport(AVFAudio)
extension AudioPreview: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
#endif

/// A recording as a chip: play/stop, a small static waveform that fills as it plays, the duration,
/// and an optional remove button (composer only). Used in the composer and in the transcript.
public struct AudioClipChip: View {
    public var url: URL
    public var duration: TimeInterval
    public var onRemove: (() -> Void)?
    @State private var preview = AudioPreview.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(url: URL, duration: TimeInterval, onRemove: (() -> Void)? = nil) {
        self.url = url; self.duration = duration; self.onRemove = onRemove
    }

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private var playing: Bool { preview.isPlaying(url) }

    public var body: some View {
        HStack(spacing: 10) {
            Button {
                LooplDesign.haptic()
                withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion)) { preview.toggle(url) }
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(exists ? LooplDesign.accent : Color.secondary.opacity(0.4), in: Circle())
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!exists)
            .accessibilityLabel(playing ? "Stop" : "Play recording")

            StaticWaveform(seed: url.lastPathComponent, fill: playing ? preview.progress : 0)
                .frame(width: 72, height: 22)
                .animation(LooplDesign.Motion.faded(LooplDesign.Motion.value, reduceMotion), value: preview.progress)

            Text(AudioAttachmentMarker.clock(duration))
                .font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(.secondary)

            if let onRemove {
                Button {
                    LooplDesign.haptic()
                    if playing { preview.stop() }
                    onRemove()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).padding(6)
                        .background(Color.secondary.opacity(0.2), in: Circle())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove recording")
            }
        }
        .padding(.leading, 6).padding(.trailing, onRemove == nil ? 14 : 8).padding(.vertical, 6)
        .background(LooplDesign.secondaryBackground, in: Capsule())
        .overlay(alignment: .bottomLeading) {
            if !exists {
                Text("recording missing").font(.system(size: 9)).foregroundStyle(.tertiary).offset(y: 14)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording, \(AudioAttachmentMarker.clock(duration))")
    }
}

/// A deterministic little waveform (seeded by the file name, so a chip looks the same every time it is drawn)
/// whose bars light up left to right as `fill` (0…1) grows.
public struct StaticWaveform: View {
    public var seed: String
    public var fill: Double
    public var bars: Int = 18
    public init(seed: String, fill: Double, bars: Int = 18) { self.seed = seed; self.fill = fill; self.bars = bars }

    private var heights: [CGFloat] {
        var h = UInt64(1469598103934665603)
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return (0..<bars).map { i in
            h = h &* 6364136223846793005 &+ 1442695040888963407
            let r = Double((h >> 33) & 0xFFFF) / 65535
            // A gentle envelope so the ends are quieter than the middle.
            let env = 0.35 + 0.65 * sin(Double(i + 1) / Double(bars + 1) * .pi)
            return CGFloat(0.25 + 0.75 * r * env)
        }
    }

    public var body: some View {
        GeometryReader { g in
            let hs = heights
            let w = (g.size.width - CGFloat(bars - 1) * 2) / CGFloat(bars)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / Double(bars) < fill ? LooplDesign.accent : Color.secondary.opacity(0.45))
                        .frame(width: max(1.5, w), height: max(3, g.size.height * hs[i]))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// Live level meter while recording: the newest sample enters on the right, older ones slide left.
public struct LiveWaveform: View {
    public var levels: [Float]      // 0…1, newest last
    public var bars: Int = 28
    public init(levels: [Float], bars: Int = 28) { self.levels = levels; self.bars = bars }
    public var body: some View {
        GeometryReader { g in
            let w = (g.size.width - CGFloat(bars - 1) * 2) / CGFloat(bars)
            let shown = Array(levels.suffix(bars))
            let pad = bars - shown.count
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let v = i < pad ? 0 : CGFloat(shown[i - pad])
                    Capsule()
                        .fill(i < pad ? Color.secondary.opacity(0.25) : LooplDesign.accent.opacity(0.55 + 0.45 * Double(v)))
                        .frame(width: max(1.5, w), height: max(3, g.size.height * (0.12 + 0.88 * v)))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}
