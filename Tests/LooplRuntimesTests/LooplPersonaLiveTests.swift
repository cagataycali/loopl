import XCTest
import Loopl
@testable import LooplRuntimes

/// Real MLX on macOS with a loopl model: proves the built-in identity (`LooplPersona.systemPrompt`) makes
/// cagataydev/loopl-* answer "who built you" the way it was trained — and records, without asserting, what it
/// says to "who is Cagatay" (the dataset lane IDENTITY-V11 owns improving that). Runs only when
/// `LOOPL_PERSONA_DIR` points at a downloaded loopl export, e.g.
///     hf download cagataydev/loopl-0.8b-4bit --local-dir ~/loopl-train-models/loopl-0.8b-4bit   (owner's token)
///     TEST_RUNNER_LOOPL_PERSONA_DIR=~/loopl-train-models/loopl-0.8b-4bit xcodebuild test -scheme Loopl-Package -destination 'platform=macOS,arch=arm64' -only-testing LooplRuntimesTests/LooplPersonaLiveTests
/// `LOOPL_PERSONA_OUT` (default /tmp/loopl-persona-probe) receives probe.json with every answer, both conditions.
final class LooplPersonaLiveTests: XCTestCase {
    struct Probe: Codable { var question: String; var persona: Bool; var answer: String; var tokens: Int; var seconds: Double }

    func env() throws -> (URL, ModelSpec, URL) {
        let e = ProcessInfo.processInfo.environment
        guard let dir = e["LOOPL_PERSONA_DIR"] else { throw XCTSkip("LOOPL_PERSONA_DIR not set") }
        guard MLXModel.availability().available else { throw XCTSkip(MLXModel.availability().reason) }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else { throw XCTSkip("no config.json at \(dir)") }
        let name = url.lastPathComponent
        // The spec the app builds for this repo: persona from the repo name, vision from the files on disk.
        let spec = ModelSpec(id: "loopl-\(name)", name: name, repo: "cagataydev/\(name)", runtime: .mlx, family: .hermes,
                             paramsB: 0.8, sizeBytes: 650_000_000, ctxNominal: 262_144, ctxUsable8GB: 8192, minRAMGB: 2, gated: true,
                             chatTemplateKwargs: ["enable_thinking": .bool(false)],
                             vision: LocalModelFiles.hasVisionTower(in: url) == true ? true : nil, persona: .loopl)
        XCTAssertTrue(spec.hasLooplPersona)
        let out = URL(fileURLWithPath: ((e["LOOPL_PERSONA_OUT"] ?? "/tmp/loopl-persona-probe") as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return (url, spec, out)
    }

    func ask(_ model: MLXModel, _ q: String, system: String) async throws -> (String, Int, Double) {
        var assembler = StreamAssembler()
        let t0 = Date()
        for try await ev in model.stream([Message.user(q)], toolSpecs: [], systemPrompt: system) { _ = assembler.feed(ev) }
        let stop = assembler.finish()
        return (stop.message.text.trimmingCharacters(in: .whitespacesAndNewlines), stop.metrics.generatedTokens, Date().timeIntervalSince(t0))
    }

    func testWhoBuiltYouWithTheBuiltInIdentity() async throws {
        let (dir, spec, out) = try env()
        let appDefault = "You are loopl, a helpful assistant running fully on this device. Use tools when they help; answer concisely."
        let withPersona = LooplPersona.combined(with: appDefault, appDefault: appDefault)
        XCTAssertEqual(withPersona, LooplPersona.systemPrompt)
        let model = MLXModel()
        var params = spec.defaultParams; params.temperature = 0      // greedy: the probe is reproducible
        try await model.load(spec, from: dir) { _ in }
        await model.updateConfig(params)
        var probes: [Probe] = []
        for (persona, system) in [(true, withPersona), (false, appDefault)] {
            for q in ["Who built you?", "What are you, and who made you?", "Do you know who Cagatay is?"] {
                let (a, n, s) = try await ask(model, q, system: system)
                probes.append(Probe(question: q, persona: persona, answer: a, tokens: n, seconds: s))
                print("PERSONA=\(persona) Q: \(q)\nA: \(a)\n")
            }
        }
        try JSONEncoder().encode(probes).write(to: out.appendingPathComponent("probe.json"))
        // The claim: with the identity in front, the model names its builder. (Two phrasings, either suffices per question.)
        let built = probes.filter { $0.persona && $0.question != "Do you know who Cagatay is?" }
        XCTAssertEqual(built.count, 2)
        for p in built {
            XCTAssertTrue(p.answer.lowercased().contains("cagatay"), "with the persona, '\(p.question)' must name Cagatay Cali — got: \(p.answer)")
            XCTAssertFalse(p.answer.lowercased().contains("google") || p.answer.lowercased().contains("alibaba"), "must not claim another builder: \(p.answer)")
        }
        await model.unload()
    }
}
