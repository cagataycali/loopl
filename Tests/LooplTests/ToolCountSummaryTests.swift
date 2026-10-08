import XCTest
import Loopl

/// Settings must promise the number of tools the agent actually gets.
///
/// The visual audit of main 75e3a279 caught **"Tools 6 of 6"** sitting directly above a section of eight
/// on-device Apple toggles that are all on: `Engine.allTools` is the six portable tools, while `activeTools`
/// is `allTools.filter(enabled) + AppleToolPrefs.shared.active`.
final class ToolCountSummaryTests: XCTestCase {
    func testAppleToolsAreCounted() {
        // A real iPhone: six core + eight Apple tools, everything on and available.
        let apple = Array(repeating: (enabled: true, available: true), count: 8)
        XCTAssertEqual(ToolCountSummary.label(core: 6, coreEnabled: 6, apple: apple), "14 of 14")
    }

    func testUnavailableToolsAreNeitherOfferedNorPromised() {
        // A simulator: generate_image / describe_image / translate cannot run, so they are not part of either number.
        let apple = [(enabled: true, available: true), (enabled: true, available: false), (enabled: true, available: false)]
        XCTAssertEqual(ToolCountSummary.label(core: 6, coreEnabled: 6, apple: apple), "7 of 7")
    }

    func testSwitchedOffToolsStayInTheDenominator() {
        let apple = [(enabled: false, available: true), (enabled: true, available: true)]
        XCTAssertEqual(ToolCountSummary.label(core: 6, coreEnabled: 4, apple: apple), "5 of 8")
    }

    /// "off" only when the model really gets nothing — an Apple tool left on is not "off".
    func testOffMeansOff() {
        XCTAssertEqual(ToolCountSummary.label(core: 6, coreEnabled: 0, apple: [(enabled: false, available: true)]), "off")
        XCTAssertEqual(ToolCountSummary.label(core: 6, coreEnabled: 0, apple: [(enabled: true, available: true)]), "1 of 7")
        XCTAssertEqual(ToolCountSummary.label(core: 0, coreEnabled: 0, apple: []), "off")
    }

    func testNonsenseInputsCannotOverCount() {
        XCTAssertEqual(ToolCountSummary.label(core: 6, coreEnabled: 99, apple: []), "6 of 6")
        XCTAssertEqual(ToolCountSummary.label(core: -1, coreEnabled: -5, apple: []), "off")
    }
}
