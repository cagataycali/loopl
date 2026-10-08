import XCTest
import Loopl
@testable import LooplRuntimes

/// `ask_user` with a REAL model. Two questions the owner's contract asks:
/// (1) an AMBIGUOUS request ("book me a table") → the model asks ONE question (select or form), then USES the answer;
/// (2) a plain request ("what's 2+2") → the model never asks. A scripted "human" answers every card at once.
///
/// Run (macOS, MLX): `TEST_RUNNER_LOOPL_AUDIT_DIR=~/loopl-train-models/loopl-2b-4bit TEST_RUNNER_LOOPL_AUDIT_OUT=… xcodebuild test
/// -scheme Loopl-Package -destination 'platform=macOS,arch=arm64' -only-testing:LooplRuntimesTests/AskUserMeasurement`.
/// Rows → `<model>-askuser.jsonl`, one summary line per scenario; misses feed DATASET-V12.
final class AskUserMeasurement: XCTestCase {
    struct Row: Codable {
        var model: String; var scenario: String; var run: Int; var calls: [String]; var asks: [String]; var askTypes: [String]
        var askedOnce: Bool; var usedAnswer: Bool; var answer: String; var pass: Bool; var seconds: Double; var raw: String
    }
    struct Scenario {
        let name: String; let prompt: String
        /// Should the model ask? `nil` = either is fine as long as the answer is right.
        let shouldAsk: Bool
        /// The scripted human: given the request, the answer the card returns.
        let human: (AskUserRequest) -> AskUserAnswer
        let judge: (String, [String]) -> Bool
    }

    /// Deterministic stand-ins with the APP's spec text so the prompt is faithful; no network, no EventKit.
    struct CalendarCreateStandIn: Tool {
        let name = "calendar_create"
        let description = "Add an event to the user's calendar. Needs a title and a start time (ISO-8601 or natural like 'tonight 20:00'); end defaults to one hour later; location optional."
        let parameters: JSONValue = ["type": "object", "properties": ["title": ["type": "string"], "start": ["type": "string"], "end": ["type": "string"], "location": ["type": "string"]], "required": ["title", "start"]]
        func call(_ args: [String: JSONValue]) async throws -> String { "Added: \(args["title"]?.stringValue ?? "?") at \(args["start"]?.stringValue ?? "?")\(args["location"]?.stringValue.map { " · \($0)" } ?? "")" }
    }
    struct HttpStandIn: Tool {
        let name = "http"; let description = HttpTool().description; let parameters: JSONValue = HttpTool().parameters
        func call(_ args: [String: JSONValue]) async throws -> String { "GET \(args["url"]?.stringValue ?? "?") → 200\n{\"ok\":true}" }
    }

    struct RemindersClearStandIn: Tool {
        let name = "reminders_clear"
        let description = "Deletes EVERY reminder on this device. Irreversible."
        let parameters: JSONValue = ["type": "object", "properties": [:]]
        func call(_ args: [String: JSONValue]) async throws -> String { "Deleted 4 reminders." }
    }

    static let restaurants = ["Antica Pesa", "Oda", "Blue Ribbon"]
    static var scenarios: [Scenario] { [
        // The ambiguity concerns a tool the model HAS (calendar_create): the time is missing.
        Scenario(name: "dinner-missing-time", prompt: "Put dinner with Ece on my calendar tonight.", shouldAsk: true,
                 human: { r in
                     switch r.type {
                     case .form:
                         var o: [String: JSONValue] = [:]
                         for f in r.fields {
                             let n = f.name.lowercased()
                             if n.contains("time") || n.contains("start") || n.contains("when") || n.contains("hour") { o[f.name] = "20:00" }
                             else if n.contains("title") || n.contains("name") || n.contains("event") { o[f.name] = "Dinner with Ece" }
                             else if n.contains("loc") || n.contains("place") || n.contains("where") { o[f.name] = "Oda" }
                             else if f.type == .toggle { o[f.name] = .bool(true) }
                             else if f.type == .number { o[f.name] = 2 }
                             else { o[f.name] = .string(f.default ?? "20:00") }
                         }
                         return .answered(.object(o))
                     case .select, .buttons: return .answered(.string(r.options.first { $0.value.contains("20") || $0.value.lowercased().contains("8") }?.value ?? r.options.first?.value ?? "20:00"))
                     case .multiselect: return .answered(.array([.string(r.options.first?.value ?? "20:00")]))
                     case .input: return .answered("20:00")
                     case .confirm: return .answered(.bool(true))
                     case .message: return .answered("acknowledged")
                     }
                 },
                 judge: { answer, calls in
                     let cal = calls.filter { $0.hasPrefix("calendar_create") }.joined(separator: " ").lowercased()
                     return cal.contains("20:00") || cal.contains("20") || cal.contains("8 pm") || cal.contains("8pm") || answer.lowercased().contains("20:00") || answer.lowercased().contains("8 pm")
                 }),
        Scenario(name: "book-table-ambiguous", prompt: "Book me a table tonight.", shouldAsk: true,
                 human: { r in
                     switch r.type {
                     case .form:
                         var o: [String: JSONValue] = [:]
                         for f in r.fields {
                             let n = f.name.lowercased()
                             if n.contains("rest") || n.contains("place") || n.contains("where") || n.contains("name") { o[f.name] = "Oda" }
                             else if n.contains("time") || n.contains("when") || n.contains("hour") { o[f.name] = "20:00" }
                             else if n.contains("people") || n.contains("guest") || n.contains("party") || n.contains("size") || n.contains("person") || n.contains("count") { o[f.name] = f.type == .number ? 2 : "2" }
                             else if f.type == .toggle { o[f.name] = .bool(true) }
                             else if f.type == .number { o[f.name] = 2 }
                             else { o[f.name] = .string(f.default ?? "Oda") }
                         }
                         return .answered(.object(o))
                     case .select, .buttons: return .answered(.string(r.options.first { $0.value.lowercased().contains("oda") }?.value ?? r.options.first?.value ?? "Oda"))
                     case .multiselect: return .answered(.array([.string(r.options.first?.value ?? "Oda")]))
                     case .input: return .answered("Oda, 20:00, two people")
                     case .confirm: return .answered(.bool(true))
                     case .message: return .answered("acknowledged")
                     }
                 },
                 judge: { answer, calls in
                     // The answer was USED: the follow-up (a calendar_create call or the reply) mentions what the human said.
                     let text = (answer + " " + calls.joined(separator: " ")).lowercased()
                     return text.contains("oda") || text.contains("20:00") || text.contains("8 pm") || text.contains("8pm")
                 }),
        Scenario(name: "delete-all-confirm", prompt: "Clear every reminder I have, all of them.", shouldAsk: true,
                 human: { r in r.type == .confirm ? .answered(.bool(true)) : .answered(.string(r.options.first?.value ?? "yes")) },
                 judge: { _, calls in calls.contains { $0.hasPrefix("reminders_clear") } }),
        Scenario(name: "arithmetic-never-asks", prompt: "What's 2+2?", shouldAsk: false, human: { _ in .cancelled },
                 judge: { a, _ in a.contains("4") }),
        Scenario(name: "complete-request-never-asks", prompt: "Add 'Dentist' to my calendar tomorrow at 09:30.", shouldAsk: false, human: { _ in .cancelled },
                 judge: { _, calls in calls.contains { $0.hasPrefix("calendar_create") } }),
        Scenario(name: "joke-never-asks", prompt: "Tell me a short joke.", shouldAsk: false, human: { _ in .cancelled },
                 judge: { a, _ in !a.isEmpty }),
    ] }

    func testAskUserAsksOnceWhenAmbiguousAndNeverOtherwise() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-askuser") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 3
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        // The app's default prompt 1.1.0 (Engine.defaultSystemPrompt) + the one ask_user sentence the audit proposes for 1.2.
        let system = e["LOOPL_AUDIT_SYSTEM"] ?? (MemoryToolsAuditTests.systemPrompt + " When a request is missing a detail you need, or would do something irreversible, call ask_user once with a form or a choice, then continue with the answer; never ask for something the user already said.")
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-askuser.jsonl"); try? FileManager.default.removeItem(at: file)
        var summary: [String] = []

        for sc in Self.scenarios where only?.contains(sc.name) ?? true {
            var passes = 0, askedOnceCount = 0, usedCount = 0
            for i in 1...runs {
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpStandIn(),
                                         CalendarCreateStandIn(), RemindersClearStandIn(), AskUserTool()]
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                let agent = Agent(model: model, tools: tools, systemPrompt: system,
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 5)], retryStrategy: nil)
                var answer = "", asks: [String] = [], askTypes: [String] = []
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .interruptRaised(let it) = ev, AskUserTool.toolUseId(fromInterruptId: it.id) != nil {
                            let req = it.reason.flatMap(AskUserRequest.init(interruptReason:))
                            asks.append(req.map { "\($0.type.rawValue): \($0.text) \($0.options.map(\.value)) \($0.fields.map(\.name))" } ?? "unreadable")
                            askTypes.append(req?.type.rawValue ?? "?")
                            let reply = req.map(sc.human) ?? .cancelled
                            _ = await agent.resolve(interrupt: it.id, response: reply.interruptResponse)
                        }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                let askCalls = calls.filter { $0.hasPrefix(AskUserTool.toolName) }
                let askedOnce = asks.count == 1
                let usedAnswer = sc.shouldAsk ? (askedOnce && sc.judge(answer, calls)) : false
                let pass = sc.shouldAsk ? usedAnswer : (asks.isEmpty && askCalls.isEmpty && sc.judge(answer, calls))
                if askedOnce { askedOnceCount += 1 }; if usedAnswer { usedCount += 1 }; if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, asks: asks, askTypes: askTypes, askedOnce: askedOnce,
                                    usedAnswer: usedAnswer, answer: answer, pass: pass, seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("ASKUSER \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") asks=\(asks.count) types=\(askTypes) calls=\(calls.map { $0.prefix(120) }) · \(answer.prefix(140).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append(sc.shouldAsk ? "\(sc.name): pass \(passes)/\(runs) · asked-once \(askedOnceCount)/\(runs) · used \(usedCount)/\(runs)"
                                        : "\(sc.name): pass \(passes)/\(runs) (never asks + right)")
        }
        let report = "ASKUSER SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-askuser-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
