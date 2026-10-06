import SwiftUI
import Observation
import AVFoundation
import LooplUI

/// A recording made in the composer, before it is sent. The file already lives in the thread's attachments
/// directory, so sending costs nothing and removing the chip deletes the file.
struct AudioClip: Hashable, Identifiable {
    var url: URL
    var duration: TimeInterval
    var id: URL { url }
    /// The line that goes into the user message — the model reads the path and may call `transcribe`.
    var marker: AudioAttachmentMarker { AudioAttachmentMarker(path: url.path, duration: duration) }
}

@MainActor enum AudioAttachment {
    /// `Application Support/conversations/<id>.attachments/` — next to the thread's JSON, deleted with it
    /// (`ConversationArchive.delete`). Recordings are AAC 16 kHz mono (`.m4a`): ~2 KB/s, plenty for speech.
    static func directory(for conversation: UUID) -> URL {
        let dir = ConversationArchive.root.appendingPathComponent("\(conversation.uuidString).attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func removeDirectory(for conversation: UUID) {
        try? FileManager.default.removeItem(at: ConversationArchive.root.appendingPathComponent("\(conversation.uuidString).attachments", isDirectory: true))
    }

    static var settings: [String: Any] { [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ] }
}

/// Tap-to-record: `start` asks for the microphone once, then meters at 20 Hz for the live waveform;
/// `stop` hands back the clip, `cancel` deletes the file. One recording at a time.
@MainActor @Observable
final class AudioRecorder: NSObject {
    enum State: Equatable { case idle, recording, denied, failed(String) }
    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Normalised 0…1 power samples, newest last (the live waveform shows the tail).
    private(set) var levels: [Float] = []
    private var recorder: AVAudioRecorder?
    private var ticker: Timer?
    private var startedAt: Date?
    static let maxSeconds: TimeInterval = 120

    var isRecording: Bool { state == .recording }

    /// Begin a new recording into `dir`. Returns false when the microphone is not allowed (state explains).
    @discardableResult
    func start(in dir: URL) async -> Bool {
        guard !isRecording else { return true }
        let allowed = await Self.requestPermission()
        guard allowed else { state = .denied; return false }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            #endif
            let url = dir.appendingPathComponent(UUID().uuidString.prefix(8).uppercased() + ".m4a")
            let r = try AVAudioRecorder(url: url, settings: AudioAttachment.settings)
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.record() else { throw NSError(domain: "loopl.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "the recorder would not start"]) }
            recorder = r
            levels = []
            elapsed = 0
            startedAt = Date()
            state = .recording
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        // Average power in dBFS (−160…0) → 0…1 with a speech-friendly floor at −50 dB.
        let db = max(-50, r.averagePower(forChannel: 0))
        let v = Float((db + 50) / 50)
        levels.append(v * v)   // perceptual-ish curve: quiet rooms stay low, speech moves the bars
        if levels.count > 120 { levels.removeFirst(levels.count - 120) }
        elapsed = r.currentTime
        if elapsed >= Self.maxSeconds { _ = stop() }
    }

    /// Finish and return the clip (nil if nothing usable was captured — under 0.3 s is a mis-tap).
    func stop() -> AudioClip? {
        guard let r = recorder else { return nil }
        let duration = r.currentTime
        r.stop()
        finish()
        let url = r.url
        guard duration >= 0.3, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return AudioClip(url: url, duration: duration)
    }

    /// Throw the take away.
    func cancel() {
        guard let r = recorder else { return }
        r.stop()
        r.deleteRecording()
        finish()
    }

    /// Clear a `.denied` / `.failed` notice.
    func dismissNotice() { if !isRecording { state = .idle } }

    private func finish() {
        ticker?.invalidate(); ticker = nil
        recorder = nil
        state = .idle
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    static func requestPermission() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
        #else
        return true
        #endif
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let msg = error?.localizedDescription ?? "encoding failed"
        Task { @MainActor in self.state = .failed(msg); self.finish() }
    }
}
