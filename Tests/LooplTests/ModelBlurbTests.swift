import XCTest
import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// the Models › loopl models rows read the Hub's curator note ("MLX 4-bit, 297 vision tensors, quiz 158 vs base 83").
final class ModelBlurbTests: XCTestCase {
    func testHubNoteBecomesOnePlainSentence() {
        let note = "loopl 4B v1.1 — MLX 4-bit, vision: what the loopl app downloads (3.03 GB, 297 vision tensors). quiz 158 vs base 83 · tools 9/9·9/9 · identity w/o prompt 11/13."
        let p = ModelBlurb.plain(note: note)
        XCTAssertEqual(p, "loopl 4B v1.1 — what the loopl app downloads.")
        for bad in ["MLX", "4-bit", "tensors", "quiz", "9/9"] { XCTAssertFalse(p.contains(bad), p) }
        XCTAssertEqual(ModelBlurb.plain(note: "A friendly note. With a second sentence."), "A friendly note.")
        XCTAssertEqual(ModelBlurb.plain(note: "No period at all"), "No period at all")
    }
    func testShippedPicksHaveHandWrittenBlurbs() {
        for id in ["loopl-0.8b-4bit", "loopl-2b-4bit", "loopl-4b-4bit"] {
            let spec = ModelSpec(id: id, name: id, repo: "cagataydev/\(id)", runtime: .mlx, family: .hermes, paramsB: 1, sizeBytes: 1, ctxNominal: 4096, ctxUsable8GB: 4096, minRAMGB: 2)
            let b = ModelBlurb.known(spec)
            XCTAssertNotNil(b, id); XCTAssertFalse(b?.contains("MLX") == true, id)
        }
    }
}
#endif
