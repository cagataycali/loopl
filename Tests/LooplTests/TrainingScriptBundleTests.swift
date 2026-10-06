import Foundation
import XCTest
@testable import Loopl

/// The Train screen uploads App/Resources/train/loopl_sft.py into the user's dataset and runs it on HF Jobs.
/// 1.0.3 exported MLX with mlx_lm.convert (text-only) → every model trained from the app lost its vision tower.
/// 1.1.0 (loopl-train 523fafb) exports with mlx_vlm.convert and gates the vision triad.
/// 1.2.0 (loopl-train 0bfd3d7) adds continual tuning (`--base <tuned model>`), `--epochs auto`, `--stitch`; 1.2.1 `--expect-vision`; 1.2.2 stitch splits a day into (1.2.3: one eval_history entry per epoch)
/// several budget-sized samples — this file must stay byte-identical to loopl-train main.
final class TrainingScriptBundleTests: XCTestCase {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/train/loopl_sft.py")

    func source() throws -> String { try String(contentsOf: Self.script, encoding: .utf8) }

    func testBundledScriptIsAtLeast120() throws {
        let v = try XCTUnwrap(TrainingLaunch.scriptVersion(in: try source()))
        let parts = v.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 2, 0]), "bundled loopl_sft.py \(v) < 1.2.0 (continual --base, --epochs auto, --stitch)")
    }

    func testBundledScriptExportsVisionWithMLXVLM() throws {
        let s = try source()
        XCTAssertTrue(s.contains("\"mlx_vlm\", \"convert\""), "MLX export must use mlx_vlm.convert (keeps the vision tower)")
        XCTAssertFalse(s.contains("\"mlx_lm\", \"convert\""), "mlx_lm.convert is text-only — it drops model.visual.*")
        XCTAssertTrue(s.contains("def vision_report"), "the vision triad gate must be in the bundled script")
    }

    func testScriptArgumentsAreKnownToTheScript() throws {
        let s = try source()
        let tuned = TrainingTunedBase(repo: "me/loopl-app-sim-4bit", bf16Repo: "me/loopl-app-sim", round: 1, size: .b0_8)
        var plan = TrainingPlan(dataset: "me/loopl-app-conversations", conversations: 120, base: .b0_8, tunedBase: tuned, stitch: .day, skipGGUF: true, skipMLX: true)
        plan.includeAllShards = false
        for flag in plan.scriptArguments(user: "me") where flag.hasPrefix("--") {
            XCTAssertTrue(s.contains("add_argument(\"\(flag)\""), "loopl_sft.py has no \(flag)")
        }
        XCTAssertTrue(s.contains("choices=[\"none\", \"day\", \"topic\"]"), "--stitch choices")
        XCTAssertTrue(s.contains("[loopl] epoch=") || s.contains("epoch={round(state.epoch):d}"), "per-epoch lines the chart reads")
        XCTAssertTrue(s.contains("def resolve_base"), "continual base resolution")
    }
}
