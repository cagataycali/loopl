import Foundation
import XCTest
@testable import Loopl

/// LIVE (LOOPL_HF_LIVE=1 + HF_TOKEN): the Train screen's "Continue a model" list from the owner's real Hub account —
/// loopl-app-sim-4bit (lane D's app-trained model) must resolve to its bf16 twin cagataydev/loopl-app-sim.
final class TrainingTunedBaseLiveTests: XCTestCase {
    func testMineResolvesToBF16Twins() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LOOPL_HF_LIVE"] == "1", "set LOOPL_HF_LIVE=1 and HF_TOKEN")
        let token = env["HF_TOKEN"]
        let hub = HubCatalog(token: { token })
        let runnable = try await hub.mine(author: "cagataydev").map(\.id)
        let owned = try await hub.owned(author: "cagataydev")
        print("LIVE mine:", runnable.count, "owned:", owned.count, "runnable sample:", runnable.filter { $0.contains("app-sim") })
        let bases = TrainingTunedBase.fromOwned(runnable: runnable, owned: owned)
        for b in bases { print("LIVE base:", b.repo, "→", b.bf16Repo ?? "nil", "round", b.round, b.size.rawValue) }
        let sim = try XCTUnwrap(bases.first { $0.name == "loopl-app-sim" }, "loopl-app-sim not among the bases")
        XCTAssertEqual(sim.repo, "cagataydev/loopl-app-sim-4bit", "the MLX row is the face of the base even though Mine lists the GGUF first")
        XCTAssertEqual(sim.bf16Repo, "cagataydev/loopl-app-sim")
        XCTAssertTrue(sim.isTrainable)
    }
}
