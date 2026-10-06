import XCTest
import Loopl

/// The built-in loopl identity (`LooplPersona`): the exact system turn of every loopl-train sample, applied ahead of
/// the app prompt for loopl's own models — and only for them.
final class LooplPersonaTests: XCTestCase {
    func testPromptIsTheTrainingSystemTurn() {
        let p = LooplPersona.systemPrompt
        XCTAssertTrue(p.hasPrefix("You are loopl, an on-device agent runtime built by Cagatay Cali (@cagataycali)."))
        XCTAssertTrue(p.contains("- Name: loopl. Builder: Cagatay Cali. You are a post-trained Qwen3.5 model"))
        XCTAssertTrue(p.hasSuffix("No preamble, no disclaimers about being an AI unless asked."))
        XCTAssertFalse(p.hasPrefix("<!--"), "the loopl.md HTML comment header is not part of the prompt")
        XCTAssertEqual(LooplPersona.version, "1.0.0")
        XCTAssertEqual(LooplPersona.revision.count, 40)
        // Paid on every turn of an 8k phone context (v1.0.0 = 2,538 chars ≈ 600 tokens): a growth guard, bump with loopl.md.
        XCTAssertLessThan(p.count, 3000, "prompt grew past the training budget: \(p.count) chars")
    }

    func testAppliesToCagataysExportsAndLooplTaggedRepos() {
        XCTAssertTrue(LooplPersona.applies(repo: "cagataydev/loopl-4b-4bit", tags: []))
        XCTAssertTrue(LooplPersona.applies(repo: "cagataydev/loopl-0.8b-GGUF", tags: []))
        XCTAssertTrue(LooplPersona.applies(repo: "CagatayDev/LOOPL-2b", tags: []))
        XCTAssertTrue(LooplPersona.applies(repo: "someone/my-tuned-model", tags: ["mlx", "loopl"]), "Train your own pushes the `loopl` tag")
        XCTAssertFalse(LooplPersona.applies(repo: "cagataydev/gr00t-wholettheducksout", tags: ["lerobot"]))
        XCTAssertFalse(LooplPersona.applies(repo: "mlx-community/Qwen3.5-0.8B-4bit", tags: ["mlx", "qwen3_5"]))
        XCTAssertFalse(LooplPersona.applies(repo: "someone/loopl-fan-model", tags: []), "the name alone is not the tag")
    }

    func testCombinedPutsTheIdentityFirstAndSkipsTheAppDefault() {
        let def = "You are loopl, a helpful assistant running fully on this device. Use tools when they help; answer concisely."
        XCTAssertEqual(LooplPersona.combined(with: def, appDefault: def), LooplPersona.systemPrompt, "the default adds nothing the identity does not say")
        XCTAssertEqual(LooplPersona.combined(with: "  \n", appDefault: def), LooplPersona.systemPrompt)
        XCTAssertEqual(LooplPersona.combined(with: nil), LooplPersona.systemPrompt)
        let custom = "Always answer in Turkish."
        let c = LooplPersona.combined(with: custom, appDefault: def)
        XCTAssertTrue(c.hasPrefix(LooplPersona.systemPrompt))
        XCTAssertTrue(c.hasSuffix("\n\n" + custom), "the user's own prompt still applies, after the identity")
    }
}
