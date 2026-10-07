import XCTest
import Loopl

/// IMPROVE-3 audit #8: "Qwen3-0.6B (4-bit)" in the chat title — the build suffix is for the catalog, not the title bar.
final class ModelSpecDisplayNameTests: XCTestCase {
    private func spec(_ name: String) -> ModelSpec {
        ModelSpec(id: "x", name: name, repo: "a/b", runtime: .mlx, family: .hermes, paramsB: 1, sizeBytes: 1, ctxNominal: 4096, ctxUsable8GB: 4096, minRAMGB: 2)
    }
    func testBuildSuffixIsDropped() {
        XCTAssertEqual(spec("Qwen3-0.6B (4-bit)").displayName, "Qwen3-0.6B")
        XCTAssertEqual(spec("Llama 3.2 1B (8-bit)").displayName, "Llama 3.2 1B")
        XCTAssertEqual(spec("Phi-4 mini (Q4_K_M)").displayName, "Phi-4 mini")
        XCTAssertEqual(spec("loopl 2B").displayName, "loopl 2B")
        XCTAssertEqual(spec("Apple Intelligence (on-device)").displayName, "Apple Intelligence (on-device)")
        XCTAssertEqual(spec("(4-bit)").displayName, "(4-bit)", "never empty")
    }
}
