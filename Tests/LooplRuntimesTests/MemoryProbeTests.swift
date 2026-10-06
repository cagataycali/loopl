import XCTest
import Loopl
import LooplAppleTools
@testable import LooplRuntimes

/// Controlled probe behind MemoryToolsAuditTests: does the model call `remember` on "Remember that my name is Çağatay."?
/// Varies the two levers the app controls — tool-set size (6 SDK tools vs the full 14 with Apple tools) and sampling
/// (model-card 0.7/0.8 vs greedy) — N runs each. LOOPL_AUDIT_DIR as in the audit; writes `<out>/<model>-probe.json`.
final class MemoryProbeTests: XCTestCase {
    struct Cell: Codable { var system: String; var tools: Int; var temperature: Float; var remember: Int; var recallFresh: Int; var runs: Int; var raws: [String]; var rawsFresh: [String]; var callsFresh: [[String]] = []; var calls: [[String]] = [] }

    func testRememberRateByToolCountAndTemperature() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 0.8, sizeBytes: 650_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2, chatTemplateKwargs: ["enable_thinking": .bool(false)])
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-memory-audit") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 6
        // LOOPL_PROBE_SYSTEM overrides the system prompt (to measure a candidate app default); recorded in the JSON.
        let system = e["LOOPL_PROBE_SYSTEM"] ?? MemoryToolsAuditTests.systemPrompt
        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        let sdk: [any Tool] = [CurrentTimeTool(), CalculatorTool(), MemoryToolsAuditTests.DeviceInfoStandIn(), RememberTool(), RecallTool(), HttpTool()]
        let full = MemoryToolsAuditTests.appTools
        var cells: [Cell] = []
        for tools in [sdk, full] {
            for temp in [Float(0.7), Float(0)] {
                var p = spec.defaultParams; p.temperature = temp; if temp == 0 { p.topP = 1 }
                await model.updateConfig(p)
                var cell = Cell(system: system, tools: tools.count, temperature: temp, remember: 0, recallFresh: 0, runs: runs, raws: [], rawsFresh: [])
                for _ in 1...runs {
                    NotesStore.save([:])
                    let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                    let a = Agent(model: model, tools: tools, systemPrompt: system,
                                  hooks: [ApprovalPolicy(mode: .never), ToolCallAuditTests.CycleCap(maxCycles: 4)], retryStrategy: nil)
                    for try await ev in a.stream("Remember that my name is Çağatay.") { rec.event(ev) }
                    let c = rec.cycles()
                    if c.flatMap(\.calls).contains(where: { $0.hasPrefix("remember") }) { cell.remember += 1 }
                    cell.raws.append(c.first?.raw.prefix(120).description ?? ""); cell.calls.append(c.flatMap(\.calls))
                    // fresh conversation, notes present: does it recall?
                    NotesStore.save(["name": "Çağatay"])
                    let rec2 = ToolCallAuditTests.Recorder(); await model.setTrace { rec2.trace($0) }
                    let b = Agent(model: model, tools: tools, systemPrompt: system,
                                  hooks: [ApprovalPolicy(mode: .never), ToolCallAuditTests.CycleCap(maxCycles: 4)], retryStrategy: nil)
                    for try await ev in b.stream("What is my name?") { rec2.event(ev) }
                    let c2 = rec2.cycles()
                    if c2.flatMap(\.calls).contains(where: { $0.hasPrefix("recall") }) { cell.recallFresh += 1 }
                    cell.rawsFresh.append(c2.first?.raw.prefix(120).description ?? ""); cell.callsFresh.append(c2.flatMap(\.calls))
                }
                print("PROBE \(name) tools=\(cell.tools) temp=\(temp): remember \(cell.remember)/\(runs) · recall(fresh) \(cell.recallFresh)/\(runs)")
                cells.append(cell)
            }
        }
        try JSONEncoder().encode(cells).write(to: out.appendingPathComponent("\(name)-probe\(e["LOOPL_PROBE_TAG"] ?? "").json"))
    }
}
