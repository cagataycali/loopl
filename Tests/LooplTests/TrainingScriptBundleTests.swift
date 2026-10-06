import CryptoKit
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

    /// The bundle is a COPY of loopl-train main; App/Resources/train/VERSION pins the revision + sha256 (scripts/sync-train-script.sh).
    /// This fails the moment someone edits the bundle by hand or loopl-train moves without a sync — both have happened (1.1.0 → 1.2.0 drift, 2026-10-06).
    func testBundledScriptMatchesThePinnedLooplTrainRevision() throws {
        let pin = try String(contentsOf: Self.script.deletingLastPathComponent().appendingPathComponent("VERSION"), encoding: .utf8)
        func field(_ k: String) -> String? { pin.split(separator: "\n").first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } }
        let revision = try XCTUnwrap(field("revision")); XCTAssertEqual(revision.count, 40, "loopl-train commit sha")
        let want = try XCTUnwrap(field("sha256"))
        let have = SHA256.hash(data: try Data(contentsOf: Self.script)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(have, want, "App/Resources/train/loopl_sft.py differs from the pinned loopl-train \(revision.prefix(8)) — run scripts/sync-train-script.sh (or --check)")
        XCTAssertEqual(field("script_version"), try TrainingLaunch.scriptVersion(in: source()))
    }

    func testPlanAsksForVisionUnlessMLXIsSkipped() {
        let plan = TrainingPlan(dataset: "me/d", conversations: 50, base: .b2)
        XCTAssertTrue(plan.scriptArguments(user: "me").contains("--expect-vision"), "Qwen3.5 0.8B/2B/4B all see — a text-only export must fail the job, not ship")
        let noMLX = TrainingPlan(dataset: "me/d", conversations: 50, base: .b2, skipMLX: true)
        XCTAssertFalse(noMLX.scriptArguments(user: "me").contains("--expect-vision"))
        for b in TrainingBase.allCases { XCTAssertTrue(b.hubId.hasPrefix("Qwen/Qwen3.5-"), "\(b.hubId) — only vision bases are offered") }
    }

    func testDoneLineCarriesVision() {
        var p = TrainingProgress()
        p.ingest(#"[loopl] done {"out": {"merged": "me/m", "mlx": "me/m-4bit", "gguf": null, "vision": {"visual_tensors": 153, "vision_config": true, "preprocessor_config": true}}, "eval_loss_base": 0.7, "eval_loss_tuned": 0.3, "tool_name_match": "7/9", "wall_s": 365, "script": "1.2.2"}"#)
        XCTAssertEqual(p.output?.visionTensors, 153); XCTAssertEqual(p.output?.keptVision, true)
        var q = TrainingProgress()
        q.ingest(#"[loopl] done {"out": {"merged": "me/m", "mlx": "me/m-4bit"}, "script": "1.1.0"}"#)
        XCTAssertNil(q.output?.visionTensors); XCTAssertNil(q.output?.keptVision, "an older script says nothing — the card shows nothing")
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
