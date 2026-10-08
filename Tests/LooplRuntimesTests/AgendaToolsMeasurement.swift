import XCTest
import Loopl
import LooplAppleTools
@testable import LooplRuntimes

/// calendar_events / calendar_create / reminders_due / reminders_create with a REAL model and the fixture store
/// same recipe as ClipboardShapeMeasurement — app prompt, 6 SDK tools + every available Apple
/// tool (the four agenda tools switched on), temp as the phone uses it, `ApprovalPolicy(.mutating)`. Pass = right
/// tool called, `success`, creates approved through the card and landed in the store, answer uses the result.
/// `LOOPL_AUDIT_DIR=<model dir> LOOPL_AUDIT_OUT=… LOOPL_AUDIT_RUNS=3 … -only-testing:LooplRuntimesTests/AgendaToolsMeasurement`
final class AgendaToolsMeasurement: XCTestCase {
    struct Row: Codable { var model: String; var scenario: String; var run: Int; var calls: [String]; var results: [String]; var status: String; var approved: Int; var answer: String; var pass: Bool; var seconds: Double; var raw: String }
    struct Scenario { let name: String; let tool: String; let prompt: String; let needsApproval: Bool; let judge: (String, FixtureEventSource) -> Bool }

    static func fixture() -> FixtureEventSource {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: cal.date(byAdding: .day, value: d, to: today)!)! }
        return FixtureEventSource(events: [
            AgendaItem(title: "Standup", start: at(0, 9, 30), end: at(0, 9, 45), calendar: "Work"),
            AgendaItem(title: "Dentist", start: at(0, 15), end: at(0, 16), calendar: "Home", location: "Hoboken"),
            AgendaItem(title: "Flight to Istanbul", start: at(1, 19, 10), end: at(1, 23), calendar: "Home"),
        ], reminders: [
            AgendaItem(title: "Buy edamame", start: at(0, 18), calendar: "Reminders"),
            AgendaItem(title: "Send the invoice", start: at(0, 11), calendar: "Reminders"),
        ])
    }

    static var scenarios: [Scenario] { [
        Scenario(name: "events-today", tool: "calendar_events", prompt: "What's on my calendar today?", needsApproval: false) { a, _ in a.lowercased().contains("dentist") || a.lowercased().contains("standup") },
        Scenario(name: "events-tomorrow", tool: "calendar_events", prompt: "Do I have anything tomorrow evening?", needsApproval: false) { a, _ in a.lowercased().contains("istanbul") || a.lowercased().contains("flight") },
        Scenario(name: "create-event", tool: "calendar_create", prompt: "Add lunch with Ali tomorrow at 12:30 to my calendar.", needsApproval: true) { _, s in
            s.created.contains { $0.title.lowercased().contains("lunch") && $0.start.map { Calendar.current.component(.hour, from: $0) == 12 && Calendar.current.isDateInTomorrow($0) } == true } },
        Scenario(name: "reminders-today", tool: "reminders_due", prompt: "What do I still have to do today?", needsApproval: false) { a, _ in a.lowercased().contains("edamame") || a.lowercased().contains("invoice") },
        Scenario(name: "create-reminder", tool: "reminders_create", prompt: "Remind me to water the plants tomorrow morning at 8.", needsApproval: true) { _, s in
            s.created.contains { $0.title.lowercased().contains("plant") } },
    ] }

    func testAgendaTools() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-agenda") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-agenda.jsonl"); try? FileManager.default.removeItem(at: file)
        defer { AgendaStore.use(nil) }
        var summary: [String] = []

        for sc in Self.scenarios where only?.contains(sc.name) ?? true {
            var passes = 0
            for i in 1...runs {
                let store = Self.fixture(); AgendaStore.use(store)
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                // Everything the app offers with the four agenda tools switched ON (they are off by default in Settings).
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()]
                    + AppleTools.available.map { $0 as any Tool }
                let agent = Agent(model: model, tools: tools, systemPrompt: MemoryToolsAuditTests.systemPrompt,
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 5)], retryStrategy: nil)
                var answer = "", approved = 0, status = "none"
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { if await agent.resolve(approval: req.id, .approve) { approved += 1 } }
                        if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name == sc.tool }) { status = r.status.rawValue }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)"; status = "error" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                let called = calls.contains { $0.hasPrefix(sc.tool + " ") || $0 == sc.tool }
                let pass = called && status == "success" && sc.judge(answer, store) && (!sc.needsApproval || approved >= 1)
                if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, results: cycles.flatMap(\.results), status: status, approved: approved,
                                    answer: answer, pass: pass, seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("AGENDA \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") called=\(called) status=\(status) approved=\(approved) calls=\(calls) · \(answer.prefix(110).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append("\(sc.name): \(passes)/\(runs)")
        }
        let report = "AGENDA SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-agenda-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
