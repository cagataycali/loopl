import XCTest
@testable import Loopl

/// a Hugging Face status code that is not 401/403 used to reach the user raw —
/// "HTTP 429 for model.safetensors" under a half-finished download, "Hugging Face answered HTTP 503 for
/// /api/models/…" in Browse. A person cannot tell from that whether to wait, retry, or stop trying.
final class HubStatusTests: XCTestCase {
    private let codes = [400, 404, 408, 416, 429, 500, 502, 503, 504, 418]

    /// No sentence a person reads may OPEN with a status code or the word HTTP.
    func testEverySentenceLeadsWithWords() {
        for code in codes {
            for downloading in [true, false] {
                let s = HubStatus.sentence(code, path: "weights/model.safetensors", downloading: downloading)
                XCTAssertFalse(s.hasPrefix("HTTP"), "\(code): \(s)")
                XCTAssertFalse(s.hasPrefix("\(code)"), "\(code): \(s)")
                XCTAssertTrue(s.contains("Hugging Face") || s.contains("download"), "\(code): \(s)")
                XCTAssertTrue(s.hasSuffix(".") || s.hasSuffix(")"), "a whole sentence: \(s)")
            }
        }
    }

    /// A rate limit and an outage are the two worth waiting out — and on a download the part already fetched
    /// survives in the `.part` sidecar, so the sentence may promise it.
    func testWaitableFailuresSayToWaitAndThatProgressIsKept() {
        for code in [429, 500, 502, 503, 504, 408] {
            let down = HubStatus.sentence(code, downloading: true)
            XCTAssertTrue(down.contains("try again"), "\(code): \(down)")
            XCTAssertTrue(down.contains("Your progress is kept"), "\(code) must say the bytes survive: \(down)")
            // It is drawn in red, unwrapped, beside a Retry button: two lines on a 375 pt screen, not three.
            XCTAssertLessThanOrEqual(down.count, 110, "too long for the Models row: \(down.count) chars — \(down)")
            XCTAssertFalse(HubStatus.sentence(code, downloading: false).contains("kept"),
                           "browsing has nothing to keep: \(code)")
        }
        XCTAssertTrue(HubStatus.sentence(429, downloading: true).contains("limiting requests"))
        XCTAssertTrue(HubStatus.sentence(429, downloading: true).contains("429"), "the code stays, after the words")
    }

    /// A 404 names the file that went missing — the whole path is noise in a sentence.
    func testNotFoundNamesTheFileNotThePath() {
        let s = HubStatus.sentence(404, path: "weights/model-00001-of-00002.safetensors", downloading: true)
        XCTAssertTrue(s.contains("model-00001-of-00002.safetensors"), s)
        XCTAssertFalse(s.contains("weights/"), "no directory noise: \(s)")
        XCTAssertTrue(HubStatus.sentence(404, path: "", downloading: false).contains("Not found"))
    }

    /// The two error types a user meets most carry the same wording through their `errorDescription`.
    func testTheErrorTypesUseIt() {
        let dl = HFDownloader.DLError.http(429, "weights/model.safetensors").errorDescription ?? ""
        XCTAssertTrue(dl.contains("limiting requests") && dl.contains("kept"), dl)
        let hub = HubCatalog.HubError.http(503, "/api/models/cagataydev/loopl-2b-4bit").errorDescription ?? ""
        XCTAssertTrue(hub.contains("having trouble"), hub)
        XCTAssertFalse(hub.contains("answered HTTP"), hub)
    }

    /// 416 (the server would not resume) is actionable, and it says the one thing that fixes it.
    func testRangeMismatchSaysWhatFixesIt() {
        let s = HubStatus.sentence(416, path: "config.json", downloading: true)
        XCTAssertTrue(s.contains("again"), s)
        XCTAssertFalse(s.lowercased().contains("range mismatch"), "no protocol words: \(s)")
    }
}
