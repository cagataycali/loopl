import XCTest
@testable import Loopl
import LooplUI

/// IMPROVE-4: words small models copy and words people wait on.
final class PlainWordsTests: XCTestCase {
    /// Measured on Qwen3 0.6B: "what time is it right now?" → `current_time(timezone: "Europe/Istanbul")` — the example city in
    /// the description went straight into the call. No city example in the description; the device default is the loud part.
    func testCurrentTimeDescriptionCarriesNoExampleCity() {
        let d = CurrentTimeTool().description
        XCTAssertFalse(d.contains("Istanbul"), d)
        XCTAssertFalse(d.contains("Los_Angeles"), d)
        XCTAssertTrue(d.lowercased().contains("no arguments"), "the default call is spelled out: \(d)")
        XCTAssertTrue(d.lowercased().contains("another place"), "when to pass a zone is spelled out: \(d)")
    }

    /// With no timezone the tool answers in the device zone (the default the description promises).
    func testCurrentTimeDefaultsToDeviceZone() async throws {
        let out = try await CurrentTimeTool().call([:])
        XCTAssertTrue(out.contains(TimeZone.current.identifier) || out.contains(TimeZone.current.abbreviation() ?? "§"), out)
    }

    /// The pending row says what is happening once the wait is long (IMPROVE-4 #12).
    func testPendingRowCaptionGrowsWithTheWait() {
        XCTAssertEqual(PendingRow.caption(after: 0), "…")
        XCTAssertEqual(PendingRow.caption(after: 3.9), "…")
        XCTAssertEqual(PendingRow.caption(after: 4), "Reading your message and the tools…")
        XCTAssertEqual(PendingRow.caption(after: 20), "Still reading — a big prompt takes longer on this device.")
    }

    /// The repair message is read by someone whose model will not start, with a Repair button under it.
    /// It must say what is wrong, what the button does, and that the big download is not happening again —
    /// without the packager's vocabulary (IMPROVE-9).
    func testRepairMessageAvoidsThePackagersVocabulary() {
        let m = TokenizerFiles.repairMessage(for: "loopl 2B")
        XCTAssertTrue(m.hasPrefix("loopl 2B"), m)
        for word in ["tokenizer", "weights", "a few KB"] {
            XCTAssertFalse(m.lowercased().contains(word.lowercased()), "\(word) is not the reader's word: \(m)")
        }
        XCTAssertTrue(m.contains("Repair"), "the button is named: \(m)")
        XCTAssertTrue(m.contains("kilobytes"), "the size is spelled out so nobody fears a second big download: \(m)")
        XCTAssertTrue(m.lowercased().contains("stays on your device"), "the model is not re-downloaded: \(m)")
    }

    /// **The retired sentences, pinned so they cannot come back.** Each one was measured wrong in IMPROVE-9 and
    /// is quoted here verbatim; the scan reads the source tree next to this file (`#filePath`), the same way
    /// `CatalogFixtureParityTests` does, so it runs wherever the checkout is.
    ///
    /// Pinning *retired phrases* rather than banning *words* is deliberate: a word ban on "repo" or "Metal"
    /// would fire on comments, identifiers and the places those words are genuinely correct (the Format picker
    /// still says MLX and GGUF, because someone choosing between them needs the names). This has no false
    /// positives and still stops the exact regression.
    func testRetiredPackagerSentencesDoNotComeBack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/LooplTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let retired = [
            "tokenizer files are out of date",        // asked the reader to know what a tokenizer is
            "the repo itself needs fixing",           // asked them to fix a repository they do not own
            "instruct checkpoints only",              // jargon, and untrue: the filter is isTextGeneration
            "gated repos are hidden",
            "mlx-community conversions",
            "Pick the quant in the details",
        ]
        var offenders: [String] = []
        for dir in ["App/Sources", "Sources"] {
            let base = root.appendingPathComponent(dir)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                // Skip the lines that quote a retired sentence in order to explain why it was retired.
                let live = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                for phrase in retired where live.contains(phrase) {
                    offenders.append("\(url.lastPathComponent): “\(phrase)”")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "retired copy is back: \(offenders.joined(separator: " · "))")
    }
}
