import XCTest
import Loopl
import LooplAppleTools
@testable import LooplRuntimes
#if canImport(AVFAudio)
import AVFAudio
#endif

/// Every app tool, end to end, with a REAL model (owner 2026-10-06 15:2xZ: "make sure our tools work end to end"):
/// the app's default prompt, the app's full tool list, one natural request per tool → the model must pick the tool,
/// the tool must run (status success) and the answer must use the result. The approval path is exercised on `http`
/// with `ApprovalPolicy(mode: .always)`: the request is raised as an interrupt and approved from the test, like the card.
/// Tools whose `availability()` says no on this host are recorded as `unavailable(<reason>)` — the matrix in
/// identity-out-tools/TOOLS-E2E.md carries them as device-proof requests. Runs with `LOOPL_AUDIT_DIR`; writes
/// `LOOPL_AUDIT_OUT/<model>-tools.jsonl` + `-tools-summary.txt`.
final class ToolsE2ETests: XCTestCase {
    struct Row: Codable { var model: String; var tool: String; var run: Int; var called: Bool; var status: String; var answer: String; var outcome: String; var pass: Bool; var seconds: Double; var calls: [String]; var results: [String]; var raw: String }

    struct Case {
        let tool: String
        let prompt: String
        var images: [ImageBlock] = []
        var approval: ApprovalPolicy.Mode = .never
        var setup: () async throws -> Void = {}
        let judge: (String) -> Bool   // final answer
    }

    static let img: ImageBlock? = {
        guard let url = Bundle.module.url(forResource: "vision-test", withExtension: "png", subdirectory: "Fixtures"), let d = try? Data(contentsOf: url) else { return nil }
        return ImageBlock(data: d, mime: "image/png", width: 640, height: 400, alt: nil)
    }()
    static let m4a = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-tools-e2e-recording.m4a")

    static var cases: [Case] { [
        Case(tool: "current_time", prompt: "What time is it in Tokyo right now?") { $0.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil },
        Case(tool: "calculator", prompt: "What is 23*47?") { $0.contains("1081") || $0.contains("1,081") },
        Case(tool: "device_info", prompt: "How is my battery doing?") { $0.lowercased().contains("81") || $0.lowercased().contains("battery") },
        Case(tool: "remember", prompt: "Remember that my name is Çağatay.") { _ in !NotesStore.all().isEmpty },
        Case(tool: "recall", prompt: "What is my name?", setup: { NotesStore.save(["name": "Çağatay"]) }) { $0.lowercased().folding(options: .diacriticInsensitive, locale: nil).contains("cagatay") },
        Case(tool: "http", prompt: "Fetch https://httpbin.org/uuid and tell me the uuid it returns.", approval: .always) { $0.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}"#, options: .regularExpression) != nil },
        Case(tool: "generate_voice", prompt: "Say \"hello from loopl\" out loud.") { !$0.isEmpty },
        Case(tool: "describe_image", prompt: "Use describe_image on the attached picture and tell me the labels it finds.", images: img.map { [$0] } ?? []) { !$0.isEmpty },
        Case(tool: "translate", prompt: "Translate \"good morning\" into Turkish.") { $0.lowercased().contains("günaydın") || $0.lowercased().contains("gunaydin") },
        Case(tool: "transcribe", prompt: "[audio attached: \(m4a.path) (3 s) — call transcribe with this path to hear it]\nWhat did I say in the recording?",
             setup: { try await synthesise("hello from loopl this is a recording", to: m4a) }) { $0.lowercased().contains("hello") || $0.lowercased().contains("recording") },
        Case(tool: "generate_image", prompt: "Generate a picture of a red bicycle.") { !$0.isEmpty },
        Case(tool: "flashlight", prompt: "Turn on the flashlight.") { !$0.isEmpty },
        Case(tool: "vibrate", prompt: "Vibrate the phone twice.") { !$0.isEmpty },
        Case(tool: "open_app", prompt: "Open https://loopl.dev in the browser.", approval: .always) { !$0.isEmpty },
    ] }

    func testEveryAppToolEndToEnd() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-tools-e2e") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 1
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-tools.jsonl"); try? FileManager.default.removeItem(at: file)
        var summary: [String] = []

        for c in Self.cases where only?.contains(c.tool) ?? true {
            // Availability on this host decides offered-or-not exactly as Engine.activeTools does (AppleToolPrefs.active).
            if AppleTools.names.contains(c.tool), !AppleTools.availability(of: c.tool).available {
                let why = AppleTools.availability(of: c.tool).reason
                let row = Row(model: name, tool: c.tool, run: 0, called: false, status: "unavailable", answer: "", outcome: "unavailable(\(why))", pass: false, seconds: 0, calls: [], results: [], raw: "")
                try Self.append(row, to: file); summary.append("\(c.tool): unavailable here — \(why)"); print("TOOLS-E2E \(name) \(c.tool): UNAVAILABLE — \(why)"); continue
            }
            var passes = 0
            for i in 1...runs {
                NotesStore.save([:]); try await c.setup()
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()]
                    + AppleTools.available.map { $0 as any Tool }
                let agent = Agent(model: model, tools: tools, systemPrompt: MemoryToolsAuditTests.systemPrompt,
                                  hooks: [ApprovalPolicy(mode: c.approval), ToolCallAuditTests.CycleCap(maxCycles: 5)], retryStrategy: nil)
                var answer = "", approved = 0, status = "none"
                let t0 = Date()
                do {
                    let input: Agent.Input = c.images.isEmpty ? .text(c.prompt) : .messages([Message(role: .user, content: [.text(c.prompt)] + c.images.map { .image($0) })])
                    for try await ev in agent.stream(input) {
                        rec.event(ev)
                        // Exactly what Engine.resolve(_:_:) does when the user taps Approve on the card.
                        if case .approvalRequested(let req) = ev { if await agent.resolve(approval: req.id, .approve) { approved += 1 } }
                        if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name == c.tool }) { status = r.status.rawValue }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)"; status = "error" }
                let cycles = rec.cycles()
                let calls = cycles.flatMap(\.calls)
                let called = calls.contains { $0.hasPrefix(c.tool + " ") || $0 == c.tool }
                let needsApproval = c.approval == .always
                let pass = called && status == "success" && c.judge(answer) && (!needsApproval || approved >= 1)
                let outcome = "called=\(called) status=\(status)\(needsApproval ? " approved=\(approved)" : "") answer=\(c.judge(answer))"
                if pass { passes += 1 }
                try Self.append(Row(model: name, tool: c.tool, run: i, called: called, status: status, answer: answer, outcome: outcome, pass: pass,
                                    seconds: Date().timeIntervalSince(t0), calls: calls, results: cycles.flatMap(\.results), raw: cycles.first?.raw ?? ""), to: file)
                print("TOOLS-E2E \(name) \(c.tool) run \(i): \(pass ? "PASS" : "FAIL") — \(outcome) · \(answer.prefix(90).replacingOccurrences(of: "\n", with: " ")) · results=\(cycles.flatMap(\.results).map { $0.prefix(100) })")
            }
            summary.append("\(c.tool): \(passes)/\(runs)")
        }
        let report = "TOOLS-E2E SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-tools-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }

    /// Same recipe as AudioInputTests: AVSpeechSynthesizer.write → 16 kHz mono AAC m4a (silent).
    static func synthesise(_ text: String, to url: URL) async throws {
        #if canImport(AVFAudio)
        if FileManager.default.fileExists(atPath: url.path) { return }
        let utt = AVSpeechUtterance(string: text); utt.voice = AVSpeechSynthesisVoice(language: "en-US"); utt.rate = 0.5
        let synth = AVSpeechSynthesizer()
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        final class Box: @unchecked Sendable { var file: AVAudioFile?; var converter: AVAudioConverter?; var resumed = false }
        let box = Box()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            synth.write(utt) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { if !box.resumed { box.resumed = true; cont.resume() }; return }
                do {
                    if box.file == nil {
                        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                        box.converter = AVAudioConverter(from: pcm.format, to: target)
                        box.file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: target.commonFormat, interleaved: target.isInterleaved)
                    }
                    guard let conv = box.converter, let file = box.file else { return }
                    let ratio = 16_000 / pcm.format.sampleRate
                    let outBuf = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64)!
                    var err: NSError?; var fed = false
                    conv.convert(to: outBuf, error: &err) { _, st in if fed { st.pointee = .noDataNow; return nil }; fed = true; st.pointee = .haveData; return pcm }
                    if let err { throw err }
                    if outBuf.frameLength > 0 { try file.write(from: outBuf) }
                } catch { if !box.resumed { box.resumed = true; cont.resume(throwing: error) } }
            }
        }
        box.file = nil
        #else
        throw XCTSkip("no AVFAudio")
        #endif
    }
}
