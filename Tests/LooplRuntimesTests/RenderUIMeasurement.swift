import XCTest
import Loopl
@testable import LooplRuntimes

/// `render_ui` with a REAL model (Phase 7, lane A): does a small model, given the app's tool set and the prompt the
/// app really sends, answer "chart my steps", "show three cafés on a map", "diagram the login flow" with ONE valid
/// `render_ui` call of the right kind — and then one sentence that does not re-list the numbers?
/// Judge = `RenderSpec(args:)` on the call the model made (the same parser the app uses), then kind + content checks.
/// Run: TEST_RUNNER_LOOPL_AUDIT_DIR=~/loopl-train-models/loopl-2b-4bit xcodebuild test -scheme Loopl-Package -destination 'platform=macOS'
///      -only-testing:LooplRuntimesTests/RenderUIMeasurement  (LOOPL_AUDIT_RUNS=3, LOOPL_AUDIT_OUT=/tmp/loopl-render)
final class RenderUIMeasurement: XCTestCase {
    struct Row: Codable { var model: String; var scenario: String; var run: Int; var calls: [String]; var kinds: [String]; var issues: [String]; var status: String; var answer: String; var pass: Bool; var why: String; var seconds: Double; var raw: String }
    struct Scenario { let name: String; let prompt: String; let judge: (RenderSpec, String) -> String? }   // nil = pass, else why it failed

    static var scenarios: [Scenario] { [
        Scenario(name: "chart-steps", prompt: "Chart my steps this week: Mon 4k, Tue 6.2k, Wed 7.1k, Thu 3.8k, Fri 9.4k, Sat 12.1k, Sun 5.6k.") { spec, answer in
            guard let c = spec.components.first(where: { if case .chart = $0 { return true }; return false }), case .chart(_, _, let series) = c else { return "no chart component (\(spec.components.map(\.kindName)))" }
            let pts = series.flatMap(\.points)
            guard pts.count == 7 else { return "chart has \(pts.count) points, not 7" }
            guard let sat = pts.first(where: { $0.label.lowercased().hasPrefix("sat") }), abs(sat.value - 12100) < 1 else { return "Sat is not 12100: \(pts.map { "\($0.label)=\($0.value)" })" }
            if answer.contains("4000") && answer.contains("6200") && answer.contains("7100") { return "answer repeats the numbers" }
            return nil
        },
        Scenario(name: "map-cafes", prompt: "Show these 3 cafés on a map: bwè kafe (40.7447, -74.0323), Black Rail Coffee (40.7398, -74.0300), Hidden Grounds (40.7480, -74.0290).") { spec, _ in
            guard let c = spec.components.first(where: { if case .map = $0 { return true }; return false }), case .map(_, let pins, _) = c else { return "no map component (\(spec.components.map(\.kindName)))" }
            guard pins.count == 3 else { return "map has \(pins.count) pins, not 3" }
            guard pins.allSatisfy({ (40.73...40.75).contains($0.lat) && (-74.04 ... -74.02).contains($0.lon) }) else { return "coordinates off: \(pins.map { "\($0.lat),\($0.lon)" })" }
            guard pins.filter({ $0.label?.isEmpty == false }).count == 3 else { return "pins unlabeled" }
            return nil
        },
        Scenario(name: "diagram-login", prompt: "Diagram the login flow: open the app, enter email and password, verify, then home — a wrong password shows an error and goes back to the form.") { spec, _ in
            guard let c = spec.components.first(where: { if case .diagram = $0 { return true }; return false }), case .diagram(_, let nodes, let edges) = c else { return "no diagram component (\(spec.components.map(\.kindName)))" }
            guard nodes.count >= 4, nodes.count <= 10 else { return "\(nodes.count) nodes" }
            guard edges.count >= 3 else { return "only \(edges.count) edges" }
            let ids = Set(nodes.map(\.id))
            guard edges.allSatisfy({ ids.contains($0.from) && ids.contains($0.to) }) else { return "edge names an unknown node" }
            return nil
        },
    ] }

    func testRenderUI() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-render") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 3
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        UserDefaults.standard.set(false, forKey: NetworkPolicy.offlineKey)
        let file = out.appendingPathComponent("\(name)-render.jsonl"); try? FileManager.default.removeItem(at: file)
        var summary: [String] = []

        for sc in Self.scenarios where only?.contains(sc.name) ?? true {
            var passes = 0
            for i in 1...runs {
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                // The app's portable set as a fresh install offers it (render_ui is on by default) — no Apple tools: the
                // question is whether the model reaches for render_ui at all with the full prompt + 8 other tools around it.
                let tools: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool(), ManageMessagesTool(), RenderUITool()]
                let agent = Agent(model: model, tools: tools, systemPrompt: MemoryToolsAuditTests.systemPrompt,
                                  hooks: [ApprovalPolicy(mode: .mutating), ToolCallAuditTests.CycleCap(maxCycles: 4)], retryStrategy: nil)
                var answer = "", status = "none"
                var specs: [RenderSpec] = []
                var inputs: [[String: JSONValue]] = []
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .toolStarted(let use) = ev, use.name == RenderUITool.toolName { inputs.append(use.input) }
                        if case .toolResultMessage(let m) = ev, let r = m.toolResults.first(where: { $0.name == RenderUITool.toolName }) { status = r.status.rawValue }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)"; status = "error" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                for input in inputs { if let s = try? RenderSpec(args: input) { specs.append(s) } }
                let kinds = specs.flatMap { $0.components.map(\.kindName) }
                let issues = specs.flatMap(\.issues)
                var why: String? = nil
                if inputs.isEmpty { why = "render_ui not called (\(calls.map { $0.prefix(60) }))" }
                else if specs.isEmpty { why = "render_ui called but the spec did not parse" }
                else if status != "success" { why = "status \(status)" }
                else if inputs.count > 1 { why = "render_ui called \(inputs.count) times" }
                else { why = sc.judge(specs[0], answer) }
                let pass = why == nil
                if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, kinds: kinds, issues: issues, status: status, answer: answer, pass: pass,
                                    why: why ?? "", seconds: Date().timeIntervalSince(t0), raw: cycles.first?.raw ?? ""), to: file)
                print("RENDER \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") \(why ?? "") kinds=\(kinds) issues=\(issues) · \(answer.prefix(140).replacingOccurrences(of: "\n", with: " "))")
                if let raw = cycles.first?.raw { print("RENDER RAW \(name) \(sc.name) run \(i): \(raw.prefix(900).replacingOccurrences(of: "\n", with: " "))") }
            }
            summary.append("\(sc.name): \(passes)/\(runs)")
        }
        let report = "RENDER SUMMARY \(name): " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-render-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let h = try FileHandle(forWritingTo: ToolCallAuditTests.ensure(file)); try h.seekToEnd()
        try h.write(contentsOf: try JSONEncoder().encode(row) + Data("\n".utf8)); try h.close()
    }
}
