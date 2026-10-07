import XCTest
@testable import LooplAppleTools
@testable import Loopl

/// Every on-device tool's Settings line, read as a SET rather than one at a time — which is how IMPROVE-8 found that
/// `translate` told a person on a real iPhone it was "not available on Simulator", `open_app` said "deeplink" and
/// `describe_image` named the Vision framework. A row in Settings is read by somebody deciding what their phone is
/// allowed to do; it is not documentation.
final class ToolWordsTests: XCTestCase {
    private func copies() -> [(String, String)] {
        AppleTools.all.map { ($0.name, type(of: $0).onDeviceCopy) }
    }

    func testNoDeveloperVocabularyInAToolRow() {
        // Each word has a reason, and each was really there: "Simulator" (translate — meaningless on a phone, and the
        // availability chip already says it where it is true), "deeplink" (open_app), "framework" (describe_image),
        // "Taptic Engine" (vibrate), "system music player" (music), "on-device" (transcribe — our word, not theirs).
        let banned = ["simulator", "deeplink", "framework", "taptic", "sdk", "api ", "on-device", "runtime", "system music"]
        for (name, copy) in copies() {
            let lower = copy.lowercased()
            for word in banned {
                XCTAssertFalse(lower.contains(word), "\(name): “\(word)” is our vocabulary, not the reader's — “\(copy)”")
            }
        }
    }

    func testEveryRowIsOneOrTwoPlainSentences() {
        for (name, copy) in copies() {
            XCTAssertFalse(copy.isEmpty, "\(name) has no Settings line")
            XCTAssertLessThanOrEqual(copy.count, 140, "\(name): \(copy.count) characters is a paragraph — “\(copy)”")
            XCTAssertTrue(copy.hasSuffix("."), "\(name): a row is a sentence — “\(copy)”")
            XCTAssertFalse(copy.contains("{") || copy.contains("}"), "\(name): braces are JSON, not words")
            XCTAssertNil(copy.range(of: "\\b[A-Z]{4,}\\b", options: .regularExpression), "\(name): SHOUTING is prompt voice")
        }
    }

    /// One phone, one name for it. Two rows said "on this device" while the rest say "your iPhone" or "the device" —
    /// and a tools module cannot hardcode either, because the app elsewhere resolves the real name
    /// (`LooplDesign.deviceName`: "iPhone" or "iPad"). Those two rows now simply do not name the device: the section's
    /// own footer already says everything runs here, so the clause was redundant as well as inconsistent.
    func testTheyAgreeOnWhatToCallThePhone() {
        for (name, copy) in copies() {
            XCTAssertFalse(copy.contains("this device"), "\(name): the app says “this iPhone” or “the device” — “\(copy)”")
        }
    }
}
