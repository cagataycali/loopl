import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// IMPROVE-6 lens 1, found with a REAL Hugging Face 429 injected by a local stand-in
/// (`improve-6/tools/hubproxy.py` through the DEBUG-only `LOOPL_HUB_HOST` seam):
/// the Models row said it well — two lines of red beside **Retry**, model name and size one line above —
/// and the chat screen said the same sentence with no subject at all:
///
///     ⚠︎ Hugging Face is limiting requests right now — wait a minute and try again (429).
///       Your progress is kept.                                    [Try again]
///     …
///       No model is running yet.
///
/// Whose progress? Of what? The downloader's sentence is about the TRANSFER and never names the file or
/// the model, which is right inside a row that names it and wrong on a screen where the banner stands alone.
final class DownloadFailureSubjectTests: XCTestCase {
    private var spec: ModelSpec {
        ModelSpec(id: "qwen3-0.6b-4bit", name: "Qwen3-0.6B", repo: "mlx-community/Qwen3-0.6B-4bit",
                  runtime: .mlx, family: .hermes, paramsB: 0.6, sizeBytes: 335 << 20,
                  ctxNominal: 32_768, ctxUsable8GB: 8192, minRAMGB: 1)
    }

    func testTheModelIsNamedAndTheWordDownloadAppears() {
        let line = Engine.downloadFailed(spec, HubStatus.sentence(429, path: "model.safetensors", downloading: true))
        XCTAssertTrue(line.hasPrefix("Qwen3-0.6B didn't finish downloading."), line)
        XCTAssertTrue(line.contains("429"), "the code stays, after the words")
        XCTAssertTrue(line.contains("Your progress is kept"), "and the reassurance now has a subject")
    }

    func testAMessageThatAlreadyNamesTheModelIsNotPrefixedTwice() {
        let already = "Qwen3-0.6B needs 4.1 GB of free memory; this iPhone has 3.2 GB right now."
        XCTAssertEqual(Engine.downloadFailed(spec, already), already)
    }

    func testPunctuationIsNotDoubledAndAnEmptyMessageStillSaysSomething() {
        XCTAssertEqual(Engine.downloadFailed(spec, "the connection dropped"),
                       "Qwen3-0.6B didn't finish downloading. the connection dropped.")
        XCTAssertEqual(Engine.downloadFailed(spec, "the connection dropped."),
                       "Qwen3-0.6B didn't finish downloading. the connection dropped.")
        XCTAssertEqual(Engine.downloadFailed(spec, "  "), "Qwen3-0.6B didn't finish downloading.")
    }

    /// The sentence lands in a `Label` that wraps, so length is not fatal here the way it was in the Models
    /// row (#176) — but a banner is read at a glance. Two lines on a 375 pt screen at `.footnote` is ~150
    /// characters; the 429 case is the longest one the downloader produces.
    func testTheLongestRealCaseStillReadsInTwoLines() {
        let line = Engine.downloadFailed(spec, HubStatus.sentence(429, path: "model.safetensors", downloading: true))
        XCTAssertLessThanOrEqual(line.count, 150, "banner line got long: \(line.count) chars — \(line)")
    }
}
#endif
