import XCTest
import Foundation
import Synchronization
@testable import Loopl
@testable import LooplRuntimes

/// The owner's acceptance question for the no-RepeatBreaker decision: when a tool call FAILS and
/// the model truly sees the error, does Qwen3.5-0.8B change its arguments (or answer honestly) on
/// the next cycle — or does it repeat the identical call?
///
/// Real `Agent` + real `MLXModel` on macOS (Metal). Runs only with `LOOPL_MEASURE_DIR` pointing at
/// a local MLX checkpoint (e.g. ~/loopl-train-models/Qwen3.5-0.8B-4bit); writes one JSON line per
/// ask to `LOOPL_MEASURE_OUT` (default /tmp/tool-errors-measure.jsonl). Skips everywhere else.
///
/// BEFORE = what the model used to read: the error text with no marker (no template renders
/// `status`, so stripping the marker reproduces the old prompt byte for byte; RepeatBreaker never
/// touched errored calls, so its absence changes nothing here). AFTER = `promptContent` as shipped.
final class ToolErrorRecoveryMeasurement: XCTestCase {

    /// A `http` tool with HttpTool's real schema/description whose FIRST call fails with the exact
    /// validation complaint the owner saw (or an unreachable-host error), whatever the arguments;
    /// every later call succeeds. Records every call's canonical input.
    final class FailOnceHttp: Tool, @unchecked Sendable {
        enum Failure: String { case validation, unreachable, notfound }
        let name = "http"
        let description = HttpTool().description
        let parameters: JSONValue = HttpTool().parameters
        let failure: Failure
        private let state = Mutex<[[String: JSONValue]]>([])
        init(_ failure: Failure) { self.failure = failure }
        var inputs: [[String: JSONValue]] { state.withLock { $0 } }
        func call(_ args: [String: JSONValue]) async throws -> String {
            let n = state.withLock { $0.append(args); return $0.count }
            if n == 1 {
                switch failure {
                case .validation:
                    throw ToolError("missing required parameter 'url'. Call it with arguments like {\"url\": \"https://example.com\"}.\n" + ToolResult.retryHint)
                case .unreachable:
                    let host = args["url"]?.stringValue ?? "the host"
                    throw ToolError("could not connect to \(host): the host is unreachable (DNS lookup failed). Check the URL or try a different host.")
                case .notfound:
                    let url = args["url"]?.stringValue ?? "that URL"
                    throw ToolError("HTTP 404 Not Found for \(url): the page does not exist. Try a different path or answer without it.")
                }
            }
            return "{\"status\": 200, \"contentType\": \"text/html\", \"body\": \"<html><title>Example Domain</title><p>This domain is for use in illustrative examples.</p></html>\"}"
        }
    }

    /// BEFORE: hands the runtime the same conversation with every error result demoted to a plain
    /// success-looking result (content unchanged) — exactly what the model read before this PR.
    actor MarkerStripper: Model {
        let inner: MLXModel
        init(_ inner: MLXModel) { self.inner = inner }
        nonisolated var kind: RuntimeKind { .mlx }
        var loadedModelId: String? = nil
        var params = GenerationParams()
        var contextWindow: Int = 8192
        func sync() async { loadedModelId = await inner.loadedModelId; params = await inner.params; contextWindow = await inner.contextWindow }
        func updateConfig(_ params: GenerationParams) { self.params = params; Task { await inner.updateConfig(params) } }
        func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws { try await inner.load(spec, from: directory, progress: progress); await sync() }
        func unload() async { await inner.unload(); loadedModelId = nil }
        nonisolated static func availability() -> RuntimeAvailability { MLXModel.availability() }
        nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
            let demoted = messages.map { m -> Message in
                guard m.role == .user, m.hasToolResult else { return m }
                return .toolResults(m.toolResults.map { r in
                    ToolResult(toolUseId: r.toolUseId, name: r.name, status: .success, content: r.content, durationMs: r.durationMs)
                })
            }
            return inner.stream(demoted, toolSpecs: toolSpecs, systemPrompt: systemPrompt)
        }
    }

    struct Row: Codable {
        var condition: String, failure: String, ask: String
        var cycles: Int, calls: Int
        var firstInput: String, secondInput: String?
        var outcome: String   // identical_retry | changed_args | answered_honestly | no_call_first | other
        var finalText: String
        var seconds: Double
        var trace: [String]   // per cycle: stopReason + tool uses the model asked for + first 120 chars of its text
        var stopReason: String
    }

    /// Short imperative asks of the kind the HTTP-ARGS lane measured to trigger an `http` call
    /// 5/5 on this model (long polite phrasings made the 0.8B refuse "I can't access URLs").
    static let asks: [String] = [
        "fetch https://loopl.dev",
        "what does https://httpbin.org/get return?",
        "get https://example.com and tell me the title",
        "download https://loopl.dev/sitemap.xml and tell me how many urls it has",
        "check if https://github.com/cagataycali/loopl is up",
        "call https://api.github.com/repos/cagataycali/loopl",
        "fetch https://example.org",
        "GET https://httpbin.org/status/200",
        "fetch https://strandsagents.com and summarise it",
        "read https://loopl.dev/sdk/",
        "get the headers of https://example.com with a HEAD request",
        "fetch https://news.ycombinator.com",
    ]

    func testMeasureRecoveryAfterAFailedHttpCall() async throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOPL_MEASURE_DIR"] else { throw XCTSkip("LOOPL_MEASURE_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let out = ProcessInfo.processInfo.environment["LOOPL_MEASURE_OUT"] ?? "/tmp/tool-errors-measure.jsonl"
        let conditions = (ProcessInfo.processInfo.environment["LOOPL_MEASURE_CONDITIONS"] ?? "before,after").split(separator: ",").map(String.init)
        let failures: [FailOnceHttp.Failure] = (ProcessInfo.processInfo.environment["LOOPL_MEASURE_FAILURES"] ?? "validation,unreachable")
            .split(separator: ",").compactMap { FailOnceHttp.Failure(rawValue: String($0)) }
        let limit = Int(ProcessInfo.processInfo.environment["LOOPL_MEASURE_N"] ?? "") ?? Self.asks.count
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: out))

        let url = URL(fileURLWithPath: dir)
        let name = url.lastPathComponent
        let spec = ModelSpec(id: "hub:mlx-community/\(name.lowercased())", name: name, repo: "mlx-community/\(name)", runtime: .mlx, family: .hermes,
                             paramsB: 0.8, sizeBytes: 650_000_000, ctxNominal: 32768, ctxUsable8GB: 8192, minRAMGB: 2,
                             chatTemplateKwargs: ["enable_thinking": .bool(false)], vision: name.contains("3.5"))
        let mlx = MLXModel()
        try await mlx.load(spec, from: url) { _ in }
        // The app's default sampling (0.6 / 0.95); the seed is fixed per ask so each condition starts
        // from the same draw. Greedy made the 0.8B refuse most asks outright.
        var params = GenerationParams(temperature: 0.6, topP: 0.95, maxTokens: 400, contextLength: 8192)
        let encoder = JSONEncoder()

        var tally: [String: [String: Int]] = [:]
        for failure in failures {
            for condition in conditions {
                for ask in Self.asks.prefix(limit) {
                    let tool = FailOnceHttp(failure)
                    params.seed = UInt64(truncatingIfNeeded: abs(ask.hashValue)) % 100_000 + 7
                    await mlx.updateConfig(params)
                    let stripper = MarkerStripper(mlx); await stripper.sync()
                    let model: any Model = condition == "before" ? stripper : mlx
                    let agent = Agent(model: model, tools: [tool, CalculatorTool(), CurrentTimeTool()],
                                      systemPrompt: "You are loopl, a helpful assistant running fully on this iPhone. Use tools when they help; answer concisely.",
                                      retryStrategy: nil)
                    let t0 = Date()
                    var cycles = 0
                    var finalText = ""
                    var threw: String? = nil
                    var trace: [String] = []
                    var stopReason = ""
                    do {
                        for try await ev in agent.stream(ask) {
                            if case .modelMessage(let m) = ev {
                                cycles += 1
                                trace.append("asst: uses=\(m.toolUses.map { "\($0.name)\(JSONValue.object($0.input).compact)" }) text=\(m.text.prefix(120).replacingOccurrences(of: "\n", with: "⏎"))")
                            }
                            if case .toolResult(let r) = ev { trace.append("result[\(r.status)]: \(r.promptContent.prefix(120).replacingOccurrences(of: "\n", with: "⏎"))") }
                            if case .forceStop(let why) = ev { trace.append("forceStop: \(why)") }
                            if case .result(let r) = ev { finalText = r.text; stopReason = "\(r.stopReason)" }
                            if cycles >= 4 { break }  // the measurement needs cycle 2 only; cap the spend, not the SDK
                        }
                    } catch { threw = "\(error)"; trace.append("threw: \(threw!)") }
                    let inputs = tool.inputs
                    let first = inputs.first.map { JSONValue.object($0).compact } ?? ""
                    let second = inputs.count > 1 ? JSONValue.object(inputs[1]).compact : nil
                    let outcome: String
                    if inputs.isEmpty { outcome = "no_call_first" }
                    else if inputs.count == 1 { outcome = finalText.isEmpty ? (threw == nil ? "other" : "error:\(threw!.prefix(60))") : "answered_honestly" }
                    else if second == first { outcome = "identical_retry" }
                    else { outcome = "changed_args" }
                    let row = Row(condition: condition, failure: failure.rawValue, ask: ask,
                                  cycles: cycles, calls: inputs.count, firstInput: first, secondInput: second, outcome: outcome,
                                  finalText: String(finalText.prefix(300)), seconds: Date().timeIntervalSince(t0), trace: trace, stopReason: stopReason)
                    let line = try encoder.encode(row)
                    handle.write(line); handle.write("\n".data(using: .utf8)!)
                    print("MEASURE \(condition)/\(row.failure): \(outcome) · \(inputs.count) calls · \(cycles) cycles · \(String(format: "%.1f", row.seconds)) s — \(ask)")
                    tally[condition + "/" + row.failure, default: [:]][outcome, default: 0] += 1
                }
            }
        }
        try handle.close()
        print("MEASURE TALLY: \(tally)")
        await mlx.unload()
    }
}
