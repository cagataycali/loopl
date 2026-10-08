import XCTest
import Loopl
import LooplAppleTools
@testable import LooplRuntimes

/// Which clipboard schema can a small model actually call? (2026-10-06) Shape A is one tool,
/// `clipboard{action: read|write, text}`; shape B is `clipboard_read{}` + `clipboard_write{text}`. Same app
/// prompt, same six SDK tools + the available Apple tools, one natural request per scenario, N runs each,
/// temperature as the phone uses it. Pass = the right clipboard tool was called with the right action, the tool ran
/// (`success`), the write went through the approval card, and the answer used the result.
/// `LOOPL_AUDIT_DIR=<model dir> LOOPL_AUDIT_OUT=… LOOPL_AUDIT_RUNS=3 xcodebuild test -scheme Loopl-Package
/// -destination 'platform=macOS,arch=arm64' -only-testing:LooplRuntimesTests/ClipboardShapeMeasurement`
/// → `<model>-clipboard.jsonl` + `-clipboard-summary.txt`.
final class ClipboardShapeMeasurement: XCTestCase {
    struct Row: Codable { var model: String; var shape: String; var scenario: String; var run: Int; var calls: [String]; var results: [String]; var status: String; var approved: Int; var answer: String; var pass: Bool; var seconds: Double; var raw: String }

    struct Scenario {
        let name: String
        let prompt: String
        let setup: () -> Void
        /// Which call counts as the right one, per shape ("A" / "B").
        let wantCall: (String, String) -> Bool
        let needsApproval: Bool
        let judge: (String) -> Bool
    }

    static var scenarios: [Scenario] { [
        Scenario(name: "read-text", prompt: "What did I just copy? Read my clipboard and tell me.",
                 setup: { Clipboard.write("Meet at the harbour at 7, bring the blue folder") },
                 wantCall: { shape, call in shape == "A" ? call.hasPrefix("clipboard ") && call.contains("read") : call.hasPrefix("clipboard_read") },
                 needsApproval: false) { $0.lowercased().contains("harbour") || $0.contains("7") },
        Scenario(name: "paste-translate", prompt: "Paste what I copied and translate it into Turkish.",
                 setup: { Clipboard.write("good morning") },
                 wantCall: { shape, call in shape == "A" ? call.hasPrefix("clipboard ") && call.contains("read") : call.hasPrefix("clipboard_read") },
                 needsApproval: false) { $0.lowercased().contains("günaydın") || $0.lowercased().contains("gunaydin") || $0.lowercased().contains("good morning") },
        Scenario(name: "write", prompt: "Copy the phrase \"hello from loopl\" to my clipboard.",
                 setup: { Clipboard.write("stale") },
                 wantCall: { shape, call in shape == "A" ? call.hasPrefix("clipboard ") && call.contains("write") : call.hasPrefix("clipboard_write") },
                 needsApproval: true) { _ in Clipboard.readText() == "hello from loopl" },
    ] }

    func testClipboardShapes() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        guard Clipboard.isAvailable else { throw XCTSkip("no pasteboard on this host") }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-clipboard") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let shapes = (e["LOOPL_AUDIT_SHAPES"] ?? "A,B").split(separator: ",").map(String.init)
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-clipboard.jsonl"); try? FileManager.default.removeItem(at: file)
        let before = Clipboard.readText()
        defer { if let b = before { Clipboard.write(b) } }
        var summary: [String] = []

        for shape in shapes {
            var shapeTotal = 0, shapePass = 0
            for sc in Self.scenarios {
                var passes = 0
                for i in 1...runs {
                    sc.setup()
                    let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                    // The app's list minus every clipboard tool, plus the shape under test.
                    let apple = AppleTools.available.filter { !$0.name.hasPrefix("clipboard") }.map { $0 as any Tool }
                    let clip: [any Tool] = shape == "A" ? [ClipboardTool()] : [ClipboardReadTool(), ClipboardWriteTool()]
                    let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()] + apple + clip
                    let agent = Agent(model: model, tools: tools, systemPrompt: MemoryToolsAuditTests.systemPrompt,
                                      hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 5)], retryStrategy: nil)
                    var answer = "", approved = 0, status = "none"
                    let t0 = Date()
                    do {
                        for try await ev in agent.stream(.text(sc.prompt)) {
                            rec.event(ev)
                            if case .approvalRequested(let req) = ev { if await agent.resolve(approval: req.id, .approve) { approved += 1 } }
                            if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name.hasPrefix("clipboard") }) { status = r.status.rawValue }
                            if case .result(let r) = ev { answer = r.message.text }
                        }
                    } catch { answer = "ERROR \(error)"; status = "error" }
                    let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                    let called = calls.contains { sc.wantCall(shape, $0) }
                    let pass = called && status == "success" && sc.judge(answer) && (!sc.needsApproval || approved >= 1)
                    if pass { passes += 1 }
                    try Self.append(Row(model: name, shape: shape, scenario: sc.name, run: i, calls: calls, results: cycles.flatMap(\.results), status: status,
                                        approved: approved, answer: answer, pass: pass, seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                    print("CLIPBOARD \(name) shape \(shape) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") called=\(called) status=\(status) approved=\(approved) calls=\(calls) · \(answer.prefix(100).replacingOccurrences(of: "\n", with: " "))")
                }
                shapeTotal += runs; shapePass += passes
                summary.append("\(shape)/\(sc.name): \(passes)/\(runs)")
            }
            summary.append("\(shape) TOTAL \(shapePass)/\(shapeTotal)")
        }
        let report = "CLIPBOARD SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-clipboard-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
