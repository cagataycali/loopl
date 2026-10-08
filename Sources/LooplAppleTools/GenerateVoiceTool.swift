import Foundation
import Loopl
#if canImport(AVFAudio)
import AVFAudio
#endif

/// `generate_voice` — AVSpeechSynthesizer (iOS 7+; `write(_:toBufferCallback:)` iOS 13+).
/// Speaks the text through the device speaker and, optionally, renders it to a CAF
/// file in the app's tmp dir. Personal Voice (iOS 17+) is used when the user has
/// authorised it and asked for `voice: "personal"`.
public struct GenerateVoiceTool: AppleTool {
    public init() {}
    public let name = "generate_voice"
    public let description = "Speak text aloud with the iPhone's on-device voices (optionally the user's Personal Voice). Use when the user asks to hear something or wants a voice-over. Returns the voice used and duration."
    public let parameters: JSONValue = ToolSchema.object([
        "text": ToolSchema.string("What to say (≤ 1000 characters)"),
        "language": ToolSchema.string("BCP-47 code like en-US, tr-TR; default = the device language"),
        "voice": ToolSchema.string("'personal' for the user's Personal Voice, or a voice name/identifier; default = best installed voice for the language"),
        "rate": ToolSchema.number("Speech rate 0.0–1.0 (default 0.5)"),
        "save": ToolSchema.boolean("Also write a .caf audio file and return its path (default false)"),
    ], required: ["text"])
    public static let onDeviceCopy = "Speaks with the voices you already have, including Personal Voice if you allow it. Works offline."
    public static let maxChars = 1000

    public static func availability() -> ToolAvailability {
        #if canImport(AVFAudio)
        return .ok
        #else
        return .no(Unavailable.sdk)
        #endif
    }

    /// Names + quality of the voices on this device (for Settings and the model's `voice` arg).
    public static func installedVoices(language: String? = nil) -> [(name: String, identifier: String, language: String, quality: String, personal: Bool)] {
        #if canImport(AVFAudio)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { language == nil || $0.language.lowercased().hasPrefix(language!.lowercased().prefix(2)) }
            .map { v in
                let q: String = switch v.quality { case .premium: "premium"; case .enhanced: "enhanced"; default: "default" }
                var personal = false
                if #available(iOS 17, macOS 14, *) { personal = v.voiceTraits.contains(.isPersonalVoice) }
                return (v.name, v.identifier, v.language, q, personal)
            }
        #else
        return []
        #endif
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        guard let text = args.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw ToolError("text is required") }
        guard text.count <= Self.maxChars else { throw ToolError("text is \(text.count) characters; keep it under \(Self.maxChars)") }
        let rate = min(1, max(0, args.double("rate") ?? 0.5))
        #if canImport(AVFAudio)
        let language = args.string("language") ?? Locale.preferredLanguages.first ?? "en-US"
        // Measured (ToolsE2ETests, loopl-0.8b): the model asks for `voice: "personal"` unprompted and the whole request failed on
        // the authorisation. The user asked to HEAR something — speak with the best installed voice and say what happened.
        var note: String? = nil
        let voice: AVSpeechSynthesisVoice
        do { voice = try await Self.resolveVoice(args.string("voice"), language: language) } catch let e as ToolError where args.string("voice")?.lowercased() == "personal" {
            voice = try await Self.resolveVoice(nil, language: language)
            note = "Personal Voice not used: \(e.message). Spoke with \(voice.name) instead."
        }
        let save = args.bool("save") ?? false
        let speaker = await Speaker()
        let result = try await speaker.speak(text: text, voice: voice, rate: Float(rate), save: save)
        var lines = ["spoke \(text.count) characters with voice \(voice.name) (\(voice.language), \(result.quality))",
                     "duration: \(String(format: "%.1f", result.seconds)) s"]
        if let p = result.file { lines.append("audio file: \(p)") }
        if let note { lines.append(note) }
        return lines.joined(separator: "\n")
        #else
        throw ToolError(Unavailable.sdk)
        #endif
    }

    #if canImport(AVFAudio)
    static func resolveVoice(_ requested: String?, language: String) async throws -> AVSpeechSynthesisVoice {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let r = requested?.lowercased(), !r.isEmpty {
            if r == "personal" {
                guard #available(iOS 17, macOS 14, *) else { throw ToolError(Unavailable.ios("17")) }
                let status = await withCheckedContinuation { (c: CheckedContinuation<AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus, Never>) in
                    AVSpeechSynthesizer.requestPersonalVoiceAuthorization { c.resume(returning: $0) }
                }
                guard status == .authorized else { throw ToolError("Personal Voice is not authorised for loopl (Settings › Accessibility › Personal Voice › Allow apps to request to use)") }
                guard let pv = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.voiceTraits.contains(.isPersonalVoice) }) else {
                    throw ToolError("no Personal Voice has been created on this iPhone")
                }
                return pv
            }
            if let v = voices.first(where: { $0.identifier.lowercased() == r || $0.name.lowercased() == r }) { return v }
            throw ToolError("no installed voice named '\(requested!)'. Installed: \(voices.prefix(12).map(\.name).joined(separator: ", "))")
        }
        // Best installed voice for the language: premium > enhanced > default.
        let candidates = voices.filter { $0.language.lowercased() == language.lowercased() || $0.language.lowercased().hasPrefix(language.lowercased().prefix(2)) }
        if let v = candidates.max(by: { $0.quality.rawValue < $1.quality.rawValue }) { return v }
        if let v = AVSpeechSynthesisVoice(language: language) { return v }
        throw ToolError("no voice installed for \(language)")
    }

    /// Owns the synthesizer for one utterance; AVSpeechSynthesizer is not Sendable, so it lives on the main actor.
    @MainActor final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
        private let synth = AVSpeechSynthesizer()
        private var done: CheckedContinuation<Void, any Error>?
        struct Result { var seconds: Double; var quality: String; var file: String? }

        func speak(text: String, voice: AVSpeechSynthesisVoice, rate: Float, save: Bool) async throws -> Result {
            let utt = AVSpeechUtterance(string: text)
            utt.voice = voice
            utt.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * rate
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            let t0 = Date()
            var file: String?
            if save {
                file = try await render(utt)
            }
            synth.delegate = self
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                done = c
                synth.speak(utt)
            }
            let q: String = switch voice.quality { case .premium: "premium"; case .enhanced: "enhanced"; default: "default" }
            return Result(seconds: Date().timeIntervalSince(t0), quality: q, file: file)
        }

        /// `write(_:toBufferCallback:)` → CAF in tmp. Returns the path.
        private func render(_ utt: AVSpeechUtterance) async throws -> String {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-voice-\(UUID().uuidString.prefix(8)).caf")
            let writer = AVSpeechSynthesizer()
            var out: AVAudioFile?
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                var resumed = false
                writer.write(utt) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 { if !resumed { resumed = true; c.resume() }; return }
                    do {
                        if out == nil { out = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                        try out?.write(from: pcm)
                    } catch { if !resumed { resumed = true; c.resume(throwing: error) } }
                }
            }
            return url.path
        }

        nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.done?.resume(); self.done = nil }
        }
        nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor in self.done?.resume(throwing: ToolError("speech was interrupted")); self.done = nil }
        }
    }
    #endif
}
