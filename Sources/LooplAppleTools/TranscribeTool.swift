import Foundation
import Loopl
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFAudio)
import AVFAudio
#endif

/// `transcribe` — Speech framework, file-based. iOS 26: `SpeechAnalyzer` + `SpeechTranscriber`
/// (system-managed on-device model via `AssetInventory`, no microphone or speech permission
/// for files). Older iOS: `SFSpeechRecognizer` with `requiresOnDeviceRecognition` (needs the
/// speech-recognition permission → app Info.plist `NSSpeechRecognitionUsageDescription`).
public struct TranscribeTool: AppleTool {
    public init() {}
    public let name = "transcribe"
    public let description = "Transcribe an audio file on this device to text (speech recognition, offline). Give the file path; e.g. the file generate_voice saved, or a recording the user shared."
    public let parameters: JSONValue = ToolSchema.object([
        "path": ToolSchema.string("Absolute path (or file:// URL) of an audio file: m4a, caf, wav, mp3"),
        "language": ToolSchema.string("BCP-47 locale like en-US (default: device locale)"),
    ], required: ["path"])
    public static let onDeviceCopy = "Turns audio files into text with the iPhone's on-device speech recognition. Offline."
    public static func availability() -> ToolAvailability {
        #if canImport(Speech)
        if #available(iOS 26, macOS 26, *) { return .ok }
        return .no(Unavailable.ios("26"))
        #else
        return .no(Unavailable.sdk)
        #endif
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        guard let p = args.string("path"), !p.isEmpty else { throw ToolError("path is required") }
        let url = p.hasPrefix("file://") ? URL(string: p)! : URL(fileURLWithPath: p)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("no file at \(url.path)") }
        let a = Self.availability()
        guard a.available else { throw ToolError("transcribe is not available here: \(a.reason)") }
        #if canImport(Speech) && canImport(AVFAudio)
        guard #available(iOS 26, macOS 26, *) else { throw ToolError(Unavailable.ios("26")) }
        let locale = Locale(identifier: args.string("language") ?? Locale.current.identifier)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ToolError("speech recognition does not support \(locale.identifier) on this device")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()   // system-managed model, counted against the OS not the app
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        let t0 = Date()
        async let collected: String = {
            var out = ""
            for try await r in transcriber.results { out += String(r.text.characters) }
            return out
        }()
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = try await collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "no speech recognised in \(url.lastPathComponent) (\(String(format: "%.1f", seconds)) s)" }
        return "transcript of \(url.lastPathComponent) (\(String(format: "%.1f", seconds)) s audio, \(supported.identifier), \(String(format: "%.1f", Date().timeIntervalSince(t0))) s):\n\(text)"
        #else
        throw ToolError(Unavailable.sdk)
        #endif
    }
}
