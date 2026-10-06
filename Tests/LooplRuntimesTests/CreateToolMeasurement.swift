import XCTest
import Loopl
@testable import LooplRuntimes

/// Agent-written tools with a REAL model (Phase 6 lane D): does loopl-2b, asked for a capability it lacks, WRITE the tool
/// (Swift on this Mac), load it with `manage_tools create`, and then CALL it on its next step? Skips without
/// `LOOPL_AUDIT_DIR` (a local MLX checkpoint). Evidence: JSONL + summary in `LOOPL_AUDIT_OUT` (default /tmp/loopl-create-tool).
///
///   TEST_RUNNER_LOOPL_AUDIT_DIR=~/loopl-train-models/loopl-2b-4bit xcodebuild test -scheme Loopl-Package \
///     -destination 'platform=macOS,arch=arm64' -only-testing:LooplRuntimesTests/CreateToolMeasurement
final class CreateToolMeasurement: XCTestCase {
    struct Row: Codable {
        var model: String; var scenario: String; var run: Int; var calls: [String]; var created: [String]; var language: String
        var usedCreated: Bool; var offeredAfterCreate: Bool?; var answer: String; var pass: Bool; var seconds: Double; var raw: [String]
    }
    struct Scenario { let name: String; let prompt: String; let toolName: String; let judge: (String) -> Bool }

    static var scenarios: [Scenario] { [
        Scenario(name: "reverse", prompt: "I need a tool that reverses a string. Create it, then use it to reverse the word loopl.", toolName: "reverse_string") { $0.lowercased().contains("lpool") },
        Scenario(name: "vowels", prompt: "Make yourself a tool that counts the vowels in a text, then tell me how many vowels are in 'on-device agents'.", toolName: "count_vowels") { $0.contains("6") },
    ] }

    /// The directive SUPERVISOR-7 puts in app-default.md, appended to today's default prompt.
    static let directive = " If you lack a tool for what the user asked, write one: call manage_tools with action create — on a Mac write Swift (struct X: Tool, shape in the tool's description), on an iPhone or iPad write JavaScript (a global tool object) — and it is available on your next step. If the compiler reports an error, fix the code and create again."

    func testModelWritesAndUsesATool() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_AUDIT_DIR"] else { throw XCTSkip("LOOPL_AUDIT_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath); let name = url.lastPathComponent
        let vision = FileManager.default.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path)
        let spec = ModelSpec(id: "hub:\(name.lowercased())", name: name, repo: name, runtime: .mlx, family: .hermes, paramsB: 2, sizeBytes: 1_700_000_000,
                             ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 4, chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: vision)
        let out = URL(fileURLWithPath: ((e["LOOPL_AUDIT_OUT"] ?? "/tmp/loopl-create-tool") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(e["LOOPL_AUDIT_RUNS"] ?? "") ?? 2
        let only = e["LOOPL_AUDIT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let language = e["LOOPL_AUDIT_LANGUAGE"] ?? "swift"   // the device decides; "javascript" forces the iPhone path on this Mac

        let model = MLXModel()
        try await model.load(spec, from: url) { _ in }
        defer { Task { await model.unload() } }
        let file = out.appendingPathComponent("\(name)-create-tool-\(language).jsonl"); try? FileManager.default.removeItem(at: file)
        var summary: [String] = []

        for sc in Self.scenarios where only?.contains(sc.name) ?? true {
            var passes = 0
            for i in 1...runs {
                // A fresh store per run: the tool must be WRITTEN this run, not found from the last one.
                let storeDir = out.appendingPathComponent("store-\(sc.name)-\(i)", isDirectory: true); try? FileManager.default.removeItem(at: storeDir)
                let store = DynamicToolStore(directory: storeDir)
                await store.setReserved(["current_time", "calculator", "remember", "recall", "manage_tools"])
                var manage = ManageToolsFallbackTool(store: store)
                if language == "javascript" { manage = ManageToolsFallbackTool(store: store, language: .javascript) }
                let base: [any Tool] = [CurrentTimeTool(), CalculatorTool(), RememberTool(), RecallTool(), manage]
                let agent = Agent(model: model, tools: base, systemPrompt: MemoryToolsAuditTests.systemPrompt + Self.directive,
                                  hooks: [ToolCallAuditTests.CycleCap(maxCycles: 6)], retryStrategy: nil)
                // The seam the Engine wires: a created tool is offered on the model's NEXT call of this same turn.
                await store.onChange { tools in await agent.setTools(base + tools) }
                let rec = ToolCallAuditTests.Recorder(); await model.setTrace { rec.trace($0) }
                var answer = ""
                let t0 = Date()
                do {
                    for try await ev in agent.stream(.text(sc.prompt)) {
                        rec.event(ev)
                        if case .approvalRequested(let req) = ev { _ = await agent.resolve(approval: req.id, .approve) }
                        if case .result(let r) = ev { answer = r.message.text }
                    }
                } catch { answer = "ERROR \(error)" }
                let cycles = rec.cycles(); let calls = cycles.flatMap(\.calls)
                let created = await store.records
                let live = created.filter(\.status.isActive).map(\.name)
                let usedCreated = calls.contains { c in live.contains { c == $0 || c.hasPrefix($0 + " ") } }
                // Was the created tool in the model's tool list on the cycle AFTER the successful create? (the whole point)
                var offeredAfterCreate: Bool? = nil
                if let first = live.first, let idx = cycles.firstIndex(where: { $0.results.contains { $0.contains("✅ \(first)") } }), idx + 1 < cycles.count {
                    offeredAfterCreate = cycles[idx + 1].prompt.contains("\"name\": \"\(first)\"")
                }
                let pass = !live.isEmpty && usedCreated && sc.judge(answer)
                if pass { passes += 1 }
                try Self.append(Row(model: name, scenario: sc.name, run: i, calls: calls, created: created.map { "\($0.name) [\($0.language.rawValue) \($0.status.label)]" },
                                    language: language, usedCreated: usedCreated, offeredAfterCreate: offeredAfterCreate, answer: answer, pass: pass,
                                    seconds: Date().timeIntervalSince(t0), raw: cycles.map(\.raw)), to: file)
                // Keep the model's source beside the evidence.
                if let first = live.first, let src = await store.source(of: first) {
                    let ext = created.first { $0.name == first }?.language.fileExtension ?? "txt"
                    try? src.write(to: out.appendingPathComponent("\(name)-\(sc.name)-\(i)-\(first).\(ext)"), atomically: true, encoding: .utf8)
                }
                print("CREATE-TOOL \(name) \(sc.name) run \(i): \(pass ? "PASS" : "FAIL") created=\(created.map(\.name)) live=\(live) usedCreated=\(usedCreated) offeredAfter=\(offeredAfterCreate.map { "\($0)" } ?? "n/a") calls=\(calls.map { $0.prefix(90) }) · \(answer.prefix(120).replacingOccurrences(of: "\n", with: " "))")
            }
            summary.append("\(sc.name): \(passes)/\(runs)")
        }
        let report = "CREATE-TOOL SUMMARY \(name) [\(language)]: " + summary.joined(separator: " · ")
        print(report)
        try (report + "\n").write(to: out.appendingPathComponent("\(name)-create-tool-\(language)-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func append(_ row: Row, to file: URL) throws {
        let data = try JSONEncoder().encode(row) + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) { try h.seekToEnd(); try h.write(contentsOf: data); try h.close() } else { try data.write(to: file) }
    }
}
