import XCTest
import Loopl

/// The size a Hub row promises must be the size the download delivers.
///
/// Models › Mine labelled `cagataydev/loopl-0.8b-4bit` **479.8 MB** while the Hub's own file list says
/// **625.2 MB** — because the listing only carries `safetensors.total` and the old estimate multiplied
/// EVERY parameter by `bits/8 × 1.125`. `mlx_vlm` leaves the vision tower in bf16, so a quantised
/// vision export is 16-33 % bigger than that; an 8-bit repo is ~6 % smaller (no 1.125 to pay).
///
/// Fixture `mine-sizes-dtype.json` = real `GET /api/models/<repo>?blobs=true` rows saved 2026-10-06,
/// trimmed to the fields a LISTING returns (`config`, `safetensors`, `siblings[].rfilename` — no sizes),
/// so the parser has exactly what Mine has. `realBytes` below is the sum of `siblings[].size` of the
/// `.safetensors` files from the same responses, i.e. the bytes the downloader will actually fetch.
final class HubSizeTests: XCTestCase {
    /// Hub truth, 2026-10-06 (sum of `.safetensors` blob sizes).
    static let realBytes: [String: Int64] = [
        "cagataydev/loopl-0.8b-4bit": 625_228_929,
        "cagataydev/loopl-2b-4bit": 1_722_271_227,
        "cagataydev/loopl-4b-4bit": 3_034_299_183,
        "mlx-community/Qwen3-VL-2B-Instruct-4bit": 1_782_040_921,
        "mlx-community/Qwen3-8B-8bit": 8_703_048_996,
        "cagataydev/loopl-0.8b": 1_706_030_528,
    ]

    func fixture(_ name: String) throws -> Data {
        var url: URL?
        #if SWIFT_PACKAGE
        for sub in ["Fixtures/hub", "hub", nil] { if url == nil { url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: sub) } }
        #endif
        if url == nil {
            for sub in ["Fixtures/hub", "hub", nil] where url == nil {
                url = Bundle.allBundles.compactMap { $0.url(forResource: name, withExtension: "json", subdirectory: sub) }.first
            }
        }
        return try Data(contentsOf: XCTUnwrap(url, "fixture \(name) missing"))
    }

    /// Every row of the real listing lands within 0.1 % of the real download size.
    func testMineRowsCarryTheRealSize() throws {
        let hits = try HubCatalog.parseMine(fixture("mine-sizes-dtype"))
        // The bf16 transformers checkpoint (`cagataydev/loopl-0.8b`) is correctly dropped — loopl runs MLX/GGUF only.
        XCTAssertEqual(hits.count, 5)
        XCTAssertFalse(hits.contains { $0.id == "cagataydev/loopl-0.8b" })
        for hit in hits {
            let real = try XCTUnwrap(Self.realBytes[hit.id], "unexpected row \(hit.id)")
            let got = try XCTUnwrap(hit.sizeBytes, "\(hit.id) has no size")
            let off = abs(Double(got) - Double(real)) / Double(real)
            XCTAssertLessThan(off, 0.001, "\(hit.id): \(ByteSize.label(got)) vs real \(ByteSize.label(real)) (\(String(format: "%+.1f", off * 100)) %)")
        }
    }

    /// The bug as a number: the old all-parameters-quantised estimate is 15-33 % low on a vision export.
    func testOldEstimateWasLowOnVisionExports() {
        // loopl-0.8b-4bit: 852,985,920 params total of which 101,091,392 stay bf16 (the tower).
        let old = HubCatalog.estimateMLXBytes(params: 852_985_920, bits: 4)
        let new = HubCatalog.mlxBytes(parameters: ["U32": 751_894_528, "BF16": 101_091_392], bits: 4)
        let real = Self.realBytes["cagataydev/loopl-0.8b-4bit"]!
        XCTAssertLessThan(Double(old) / Double(real), 0.78)              // 479.8 MB — what Mine used to show
        XCTAssertEqual(Double(new), Double(real), accuracy: Double(real) * 0.001)
        // The label, not a hard-coded string: `ByteCountFormatter` follows the device REGION, so an assertion on
        // "625.1 MB" fails on a phone set to Turkey ("625,1 MB") — the product is right, the test was wrong
        // (2 of 605 tests went red just by running the suite on a tr_TR simulator).
        // The number, then its shape — never a hard-coded separator: the line above already pins `new` to the real
        // size within 0.1 %, so all the label has to prove is that a person reads "625 … MB" and not "479.8 MB".
        let shown = ByteSize.label(new)
        XCTAssertTrue(shown.hasPrefix("625") && shown.hasSuffix(" MB"), shown)
    }

    /// A repo with nothing quantised: U32 then really is a 4-byte tensor, and bf16 weights cost 2 bytes.
    func testUnquantisedRepoUsesDtypeSizes() {
        XCTAssertEqual(HubCatalog.mlxBytes(parameters: ["BF16": 852_985_920], bits: nil), 1_705_971_840)
        XCTAssertEqual(HubCatalog.mlxBytes(parameters: ["U32": 1_000, "F32": 10], bits: nil), 4_040)
        XCTAssertEqual(HubCatalog.mlxBytes(parameters: ["U32": 1_000, "F32": 10], bits: 16), 4_040)
    }

    /// group_size from config.json changes the scale/bias overhead (64 is the MLX default).
    func testGroupSizeChangesTheOverhead() {
        let g64 = HubCatalog.mlxBytes(parameters: ["U32": 1_000_000], bits: 4)
        let g32 = HubCatalog.mlxBytes(parameters: ["U32": 1_000_000], bits: 4, groupSize: 32)
        XCTAssertEqual(g64, 562_500)      // 0.5 + 4/64 bytes per parameter
        XCTAssertEqual(g32, 625_000)      // 0.5 + 4/32
        XCTAssertGreaterThan(g32, g64)
    }

    /// No `safetensors.parameters` (older cached rows, GGUF-only metadata) → the old estimate still answers.
    func testFallsBackWhenTheHubSendsNoBreakdown() throws {
        let row: [[String: Any]] = [[
            "id": "mlx-community/Tiny-1B-4bit",
            "tags": ["mlx"],
            "config": ["model_type": "llama", "quantization_config": ["bits": 4]],
            "safetensors": ["total": 1_000_000_000],
        ]]
        let hits = try HubCatalog.parseMine(JSONSerialization.data(withJSONObject: row))
        XCTAssertEqual(hits.first?.sizeBytes, HubCatalog.estimateMLXBytes(params: 1_000_000_000, bits: 4))
    }
}
