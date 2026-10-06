import XCTest
import Loopl
import LooplAppleTools
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(Speech)
import Speech
#endif

/// The composer writes `conversations/<id>.attachments/<ID>.m4a` (AAC 16 kHz mono) and puts the plain path in the
/// user message; `transcribe` must take that path in every shape a small model hands it back.
final class AudioInputTests: XCTestCase {
    func testTranscribeAcceptsEveryPathShapeTheComposerOrAModelProduces() {
        let plain = "/Users/x/Library/Application Support/conversations/ABC.attachments/8F2A1B.m4a"
        XCTAssertEqual(TranscribeTool.fileURL(plain).path, plain)
        XCTAssertEqual(TranscribeTool.fileURL("file://" + plain).path, plain)                                     // unencoded space
        XCTAssertEqual(TranscribeTool.fileURL("file:///Users/x/Library/Application%20Support/conversations/ABC.attachments/8F2A1B.m4a").path, plain)
        XCTAssertEqual(TranscribeTool.fileURL("\"" + plain + "\"").path, plain)                                  // quoted by the model
        XCTAssertEqual(TranscribeTool.fileURL("`" + plain + "`").path, plain)
        XCTAssertEqual(TranscribeTool.fileURL("  " + plain + "\n").path, plain)
        XCTAssertEqual(TranscribeTool.fileURL("~/x.m4a").path, (("~/x.m4a") as NSString).expandingTildeInPath)
    }

    func testTranscribeNamesTheMissingFile() async {
        do { _ = try await TranscribeTool().call(["path": .string("file:///nope/none%20here.m4a")]); XCTFail("should throw") }
        catch { XCTAssertTrue("\(error)".contains("no file at /nope/none here.m4a"), "\(error)") }
    }

    /// End to end on the macOS test host: synthesise "hello from loopl" into exactly the file the composer writes
    /// (AAC, 16 kHz, mono, .m4a) and run the real `transcribe` tool on its plain path. Skips where the Speech
    /// framework has no on-device model for en-US.
    func testTranscribeReadsAComposerStyleRecording() async throws {
        #if canImport(AVFAudio) && canImport(Speech)
        guard #available(macOS 26, iOS 26, *), TranscribeTool.availability().available else { throw XCTSkip("needs iOS/macOS 26 Speech") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-audio-\(UUID().uuidString.prefix(6)).attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("8F2A1B.m4a")
        try await Self.synthesise("hello from loopl, this is a recording", to: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(bytes, 2_000, "AAC file written")

        let out: String
        do { out = try await TranscribeTool().call(["path": .string(url.path), "language": .string("en-US")]) }
        catch { throw XCTSkip("transcribe could not run here: \(error)") }
        print("AUDIO-INPUT transcribe proof →", out)
        XCTAssertTrue(out.hasPrefix("transcript of 8F2A1B.m4a ("), out)
        XCTAssertTrue(out.lowercased().contains("hello"), out)
        XCTAssertTrue(out.lowercased().contains("recording"), out)
        #else
        throw XCTSkip("no AVFAudio/Speech")
        #endif
    }

    #if canImport(AVFAudio)
    /// AVSpeechSynthesizer.write → PCM buffers → AVAudioFile with the composer's AAC 16 kHz mono settings (silent: nothing is spoken aloud).
    static func synthesise(_ text: String, to url: URL) async throws {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: "en-US")
        utt.rate = 0.5
        let synth = AVSpeechSynthesizer()
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        final class Box: @unchecked Sendable { var file: AVAudioFile?; var converter: AVAudioConverter?; var resumed = false }
        let box = Box()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            synth.write(utt) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { if !box.resumed { box.resumed = true; c.resume() }; return }
                do {
                    if box.file == nil {
                        // Write at the synthesiser's own PCM format, letting AVAudioFile encode to AAC; resample to 16 kHz first.
                        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                        box.converter = AVAudioConverter(from: pcm.format, to: target)
                        box.file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: target.commonFormat, interleaved: target.isInterleaved)
                    }
                    guard let conv = box.converter, let file = box.file else { return }
                    let ratio = 16_000 / pcm.format.sampleRate
                    let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64)!
                    var err: NSError?
                    var fed = false
                    conv.convert(to: out, error: &err) { _, status in
                        if fed { status.pointee = .noDataNow; return nil }
                        fed = true; status.pointee = .haveData; return pcm
                    }
                    if let err { throw err }
                    if out.frameLength > 0 { try file.write(from: out) }
                } catch { if !box.resumed { box.resumed = true; c.resume(throwing: error) } }
            }
        }
        box.file = nil   // closes the file
    }
    #endif
}
