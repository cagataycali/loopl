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

    /// One phone, one name for it — and a tools module does not get to know WHICH phone it is.
    /// #200 banned "this device" from these rows for exactly that stated reason ("a tools module cannot
    /// hardcode either, because the app elsewhere resolves the real name") and then enforced only half of
    /// it: six rows went on saying "iPhone", which on an iPad is simply untrue, while the section footer
    /// one file over still said the banned "this device". The footer CAN resolve it (`ToolsSection` imports
    /// LooplUI) and now does; a row cannot, so a row names no device at all.
    /// In five of the six the name was redundant with the reassurance in the SAME sentence — "Works
    /// offline", "Nothing leaves the device" — which is why deleting it made every one of them shorter.
    func testNoRowClaimsToKnowWhichDeviceYouAreHolding() {
        for (name, copy) in copies() {
            let lower = copy.lowercased()
            for claim in ["iphone", "ipad", "this device"] {
                XCTAssertFalse(lower.contains(claim),
                               "\(name): a tool row cannot know which device this is — Settings › Tools' own footer resolves it — “\(copy)”")
            }
        }
    }
}
