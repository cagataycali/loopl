import XCTest
@testable import LooplUI

/// the glyph inside a round composer control is sized from the CIRCLE, never from the text size.
/// The circle caps at `controlSideMax`; a `.font(.callout)` glyph does not cap, so at an accessibility text size
/// `stop.fill` outgrew its 44 pt circle — in dark mode Stop read as a black square on black, and Send lost the
/// orange disc that distinguishes enabled from disabled. These numbers are the contract.
final class ControlGlyphTests: XCTestCase {
    /// At the default side the glyph is exactly 16 pt — `.callout` — so the everyday composer is unchanged.
    func testDefaultSideKeepsTheCalloutSize() {
        XCTAssertEqual(LooplDesign.controlGlyph(LooplDesign.controlSide), 16, accuracy: 0.01)
    }

    /// At the largest circle the glyph still fits inside it with room for the stroke.
    func testGlyphAlwaysFitsItsCircle() {
        for side in stride(from: 24.0, through: LooplDesign.controlSideMax, by: 1) {
            let g = LooplDesign.controlGlyph(side)
            XCTAssertLessThan(g, side * 0.5, "a \(g) pt glyph in a \(side) pt circle leaves no margin")
            XCTAssertGreaterThan(g, 8, "a \(g) pt glyph is unreadable")
        }
    }

    /// The cap is the point: growing text may not grow the glyph past the capped circle.
    func testTheCapBindsTheGlyphToo() {
        XCTAssertEqual(LooplDesign.controlGlyph(min(96, LooplDesign.controlSideMax)),
                       LooplDesign.controlGlyph(LooplDesign.controlSideMax),
                       "a huge text size must land on the capped side, not on 96 pt")
        XCTAssertLessThanOrEqual(LooplDesign.controlGlyph(LooplDesign.controlSideMax), 18)
    }
}
