import Foundation
import XCTest
@testable import Loopl

/// The Train screen uploads App/Resources/train/loopl_sft.py into the user's dataset and runs it on HF Jobs.
/// 1.0.3 exported MLX with mlx_lm.convert (text-only) → every model trained from the app lost its vision tower.
/// 1.1.0 (loopl-train 523fafb) exports with mlx_vlm.convert and gates the vision triad.
final class TrainingScriptBundleTests: XCTestCase {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/train/loopl_sft.py")

    func source() throws -> String { try String(contentsOf: Self.script, encoding: .utf8) }

    func testBundledScriptIsAtLeast110() throws {
        let v = try XCTUnwrap(TrainingLaunch.scriptVersion(in: try source()))
        let parts = v.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 1, 0]), "bundled loopl_sft.py \(v) < 1.1.0")
    }

    func testBundledScriptExportsVisionWithMLXVLM() throws {
        let s = try source()
        XCTAssertTrue(s.contains("\"mlx_vlm\", \"convert\""), "MLX export must use mlx_vlm.convert (keeps the vision tower)")
        XCTAssertFalse(s.contains("\"mlx_lm\", \"convert\""), "mlx_lm.convert is text-only — it drops model.visual.*")
        XCTAssertTrue(s.contains("def vision_report"), "the vision triad gate must be in the bundled script")
    }

    func testScriptArgumentsAreKnownToTheScript() throws {
        let s = try source()
        let plan = TrainingPlan(dataset: "me/loopl-app-conversations", conversations: 120, base: .b0_8, skipGGUF: true, skipMLX: true)
        for flag in plan.scriptArguments(user: "me") where flag.hasPrefix("--") {
            XCTAssertTrue(s.contains("add_argument(\"\(flag)\""), "loopl_sft.py has no \(flag)")
        }
    }
}
