import Testing
import LooplUI
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The arithmetic behind `looplScrollClearance()` — the geometry guard for the
/// bug where the bottom tab bar covered the last row of Settings and Models.
/// The measured truth it is built on: iOS 26.4 reserves exactly 83 pt under a
/// `TabView` pane on an iPhone 16 Pro (tab bar 49 + home indicator 34).
@Suite struct ScrollClearanceTests {
    @Test func systemThatReservesTheBarAddsAirOnly() {
        #expect(LooplDesign.scrollClearance(reservedBottom: 83, hasBottomBar: true) == LooplDesign.bottomClearance)
    }

    @Test func systemThatFloatsTheBarAddsTheBarToo() {
        // Only the home indicator reserved: the bar must be topped up.
        let c = LooplDesign.scrollClearance(reservedBottom: LooplDesign.homeIndicatorInset, hasBottomBar: true)
        #expect(c == LooplDesign.systemTabBarHeight + LooplDesign.bottomClearance)
        // …and the total clearance covers bar + indicator + air.
        #expect(LooplDesign.homeIndicatorInset + c >= LooplDesign.tabBarAllowance + LooplDesign.bottomClearance)
    }

    @Test func noBarBehindThePaneIsAirOnly() {
        // iPad split view / sheets: nothing to clear but the home indicator.
        #expect(LooplDesign.scrollClearance(reservedBottom: 0, hasBottomBar: false) == LooplDesign.bottomClearance)
        #expect(LooplDesign.scrollClearance(reservedBottom: 20, hasBottomBar: false) == LooplDesign.bottomClearance)
    }

    @Test func clearanceIsNeverNegativeAndNeverShrinksBelowTheGutter() {
        for reserved in stride(from: CGFloat(0), through: 200, by: 7) {
            for bar in [true, false] {
                let c = LooplDesign.scrollClearance(reservedBottom: reserved, hasBottomBar: bar)
                #expect(c >= LooplDesign.bottomClearance)
            }
        }
    }

    @Test func tokensAreDerivedNotMagic() {
        #expect(LooplDesign.bottomClearance == LooplDesign.gutter)
        #expect(LooplDesign.tabBarAllowance == LooplDesign.systemTabBarHeight + LooplDesign.homeIndicatorInset)
    }
}
