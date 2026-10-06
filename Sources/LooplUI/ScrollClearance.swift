#if canImport(SwiftUI)
import SwiftUI

/// Does a bottom bar (the tab bar) sit behind this pane? Set once, by whoever
/// builds the `TabView`; `false` in a `NavigationSplitView` (iPad), where the
/// detail column has no bar under it.
public struct LooplHasBottomBarKey: EnvironmentKey {
    public static let defaultValue = false
}

public extension EnvironmentValues {
    /// `true` while the view is inside a `TabView` pane — read by `looplScrollClearance()`.
    var looplHasBottomBar: Bool {
        get { self[LooplHasBottomBarKey.self] }
        set { self[LooplHasBottomBarKey.self] = newValue }
    }
}

/// Keeps the last row of a scrollable pane clear of the tab bar and the home
/// indicator.
///
/// The system reserves a tab bar in the pane's safe area, so a `List` normally
/// stops above it — but two things break that promise:
///
/// * a floating glass tab bar draws taller than the inset it reserves, so the
///   last row slides underneath it (reported on iOS 27.0.1: Settings' "Delete
///   conversation history" and the Models list's last row);
/// * even when it fits exactly, a destructive row flush against the glass has no
///   air and is hard to hit.
///
/// So this measures what the system actually reserved below the pane and tops it
/// up to `LooplDesign.tabBarAllowance`, plus `LooplDesign.bottomClearance` of
/// air — no magic numbers, and nothing to maintain per device. The spacer is a
/// `safeAreaInset`, so the scroll indicator shortens with it and `scrollTo`
/// still lands on the real last row.
public struct LooplScrollClearance: ViewModifier {
    @Environment(\.looplHasBottomBar) private var hasBottomBar
    @State private var reserved: CGFloat = 0

    public init() {}

    #if DEBUG
    /// `--design-no-clearance` reproduces the pre-fix geometry (no top-up at all),
    /// so one build can capture the before/after pair of a pane. DEBUG only.
    private static let suppressed = CommandLine.arguments.contains("--design-no-clearance")
    #else
    private static let suppressed = false
    #endif

    public func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            // Placed in the parent's safe area: its own `safeAreaInsets.bottom`
            // is exactly what the system already reserved under the pane.
            GeometryReader { geo in
                Color.clear
                    .onAppear { reserved = geo.safeAreaInsets.bottom }
                    .onChange(of: geo.safeAreaInsets.bottom) { _, new in reserved = new }
            }
            .frame(height: Self.suppressed ? 0 : LooplDesign.scrollClearance(reservedBottom: reserved, hasBottomBar: hasBottomBar))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

public extension View {
    /// Every `List` / `Form` / `ScrollView` that fills a pane ends with this, so
    /// its last row always clears the tab bar and the home indicator.
    func looplScrollClearance() -> some View { modifier(LooplScrollClearance()) }

    /// Declares that a bottom tab bar sits behind this subtree (see
    /// `looplScrollClearance()`). Applied once, on the `TabView`.
    func looplBottomBar(_ present: Bool = true) -> some View {
        environment(\.looplHasBottomBar, present)
    }
}
#endif
