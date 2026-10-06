import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// loopl's design language — the tiny iOS rules (ios/DESIGN.md) with the
/// loopl flame palette: one accent (flame orange), amber as its warm end,
/// SF Symbols for chrome, system fonts + Dynamic Type everywhere, motion
/// only where it means something (and never under Reduce Motion).
public enum LooplDesign {
    /// Flame orange — the brand accent and the icon's head.
    public static let accent = Color(red: 1.0, green: 0.478, blue: 0.133)   // #FF7A22
    /// Amber — the warm end of the flame gradient.
    public static let amber = Color(red: 1.0, green: 0.761, blue: 0.267)    // #FFC244
    /// Near-black canvas for the dark mark.
    public static let ink = Color(red: 0.055, green: 0.055, blue: 0.067)    // #0E0E11
    /// Cream canvas for the light mark.
    public static let cream = Color(red: 0.984, green: 0.961, blue: 0.914)  // #FBF5E9
    public static var flame: LinearGradient {
        LinearGradient(colors: [accent, amber], startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    public static let iconChat = "text.bubble"
    public static let iconModels = "square.stack.3d.down.right"
    public static let iconAgent = "point.3.connected.trianglepath.dotted"
    public static let iconSettings = "gearshape"
    public static let iconTool = "wrench.and.screwdriver"
    public static let iconDownload = "arrow.down.circle"
    public static let iconLoaded = "bolt.fill"
    public static let iconOffline = "airplane"
    public static let iconWarning = "exclamationmark.triangle"
    public static let iconHistory = "clock.arrow.circlepath"

    /// Horizontal padding of the document column (brief: 20 pt).
    public static let gutter: CGFloat = 20
    /// Air between the LAST row of a scrollable pane and whatever sits under it
    /// (tab bar, home indicator, window edge) — one gutter, so a destructive row
    /// is never flush against the glass. See `looplScrollClearance()`.
    public static let bottomClearance: CGFloat = gutter
    /// A standard iOS tab bar, from Apple's platform metrics.
    public static let systemTabBarHeight: CGFloat = 49
    /// The tallest home-indicator safe-area inset on a Face ID device.
    public static let homeIndicatorInset: CGFloat = 34
    /// What a bottom tab bar needs below a pane when the system has NOT reserved
    /// it: the bar plus the home indicator it floats above. Measured: this is
    /// *exactly* the inset iOS 26.4 reserves under a `TabView` pane on an
    /// iPhone 16 Pro (83 pt), so a system that reserves the bar tops up by
    /// nothing, and one that floats it over the content tops up by the bar.
    public static let tabBarAllowance: CGFloat = systemTabBarHeight + homeIndicatorInset
    /// Extra bottom scroll clearance for a pane: whatever the tab bar still needs
    /// on top of the inset the system already reserved, plus `bottomClearance`.
    /// `reservedBottom` is measured at run time (the safe area left below the
    /// pane), so a system that reserves the bar in full adds nothing but air, and
    /// one that floats the bar over the content adds the bar too.
    public static func scrollClearance(reservedBottom: CGFloat, hasBottomBar: Bool) -> CGFloat {
        (hasBottomBar ? max(0, tabBarAllowance - reservedBottom) : 0) + bottomClearance
    }

    /// The one spring every entering row uses (= `Motion.spring`).
    public static let spring: Animation = Motion.spring

    /// Every duration and spring in loopl, in one place (mirror of docs/DESIGN.md "Motion").
    /// Views never write a duration inline; under Reduce Motion they pass each of
    /// these through `reduced(_:_:)`, which turns them into nil (no motion) or a plain cross-fade.
    public enum Motion {
        /// Entering rows, expanding cards, layout changes.
        public static let spring: Animation = .spring(response: 0.42, dampingFraction: 0.82)
        /// Small chrome: toggles, chevrons, send/stop swap.
        public static let snappy: Animation = .spring(response: 0.28, dampingFraction: 0.86)
        /// Finger-driven: composer drag, sheet drag — retargets without a hitch.
        public static let interactive: Animation = .interactiveSpring(response: 0.3, dampingFraction: 0.86, blendDuration: 0.2)
        /// A streamed chunk fading in (~180 ms, critically damped so it never overshoots).
        public static let chunk: Animation = .spring(duration: 0.18, bounce: 0)
        /// Numbers and short labels changing in place.
        public static let value: Animation = .easeInOut(duration: 0.2)
        /// Opacity-only fade — the one animation still allowed under Reduce Motion.
        public static let crossfade: Animation = .easeInOut(duration: 0.22)
        /// Breathing of the mark / caret while something is in flight.
        public static let pulse: Animation = .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
        /// Indeterminate progress sweep.
        public static let sweep: Animation = .linear(duration: 1.4).repeatForever(autoreverses: false)
        /// The mark drawing itself once at launch.
        public static let draw: Animation = .easeInOut(duration: 0.7)
        public static let drawSeconds: Double = 0.7
        /// Wait for the system's launch cross-fade to finish, so the stroke is seen being drawn.
        public static let drawDelay: Double = 0.3
        /// Minimum spacing between two haptics.
        public static let hapticGap: TimeInterval = 0.25
        /// Composer: how far the finger must travel / how fast to count as "dismiss the keyboard".
        public static let dismissDistance: CGFloat = 36
        public static let dismissVelocity: CGFloat = 600

        /// `a` normally; nil under Reduce Motion (the change applies instantly).
        public static func reduced(_ a: Animation, _ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : a }
        /// `a` normally; an opacity-only cross-fade under Reduce Motion.
        public static func faded(_ a: Animation, _ reduceMotion: Bool) -> Animation { reduceMotion ? crossfade : a }
    }

    @MainActor public static func haptic(_ strength: Int = 0) {
        #if canImport(UIKit) && !os(watchOS)
        UIImpactFeedbackGenerator(style: strength > 0 ? .medium : .soft).impactOccurred()
        #endif
    }
    /// Sensory feedback for "it finished" moments (tool done, model loaded).
    @MainActor public static func success() {
        #if canImport(UIKit) && !os(watchOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
    @MainActor public static func failure() {
        #if canImport(UIKit) && !os(watchOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    static var secondaryBackground: Color {
        #if canImport(UIKit)
        Color(UIColor.secondarySystemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    static var tertiaryFill: Color {
        #if canImport(UIKit)
        Color(UIColor.tertiarySystemFill)
        #else
        Color.gray.opacity(0.2)
        #endif
    }
}

struct LooplCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(LooplDesign.accent.opacity(0.15), lineWidth: 1))
    }
}
public extension View { func looplCard() -> some View { modifier(LooplCard()) } }

/// Small accent-tinted label like "MLX" / "loaded".
public struct Pill: View {
    public var text: String
    public var tint: Color
    public init(_ text: String, tint: Color = LooplDesign.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule()).foregroundStyle(tint)
    }
}


// MARK: - Haptics

/// What the app wants the hand to feel. Mapped to `SensoryFeedback` in `HapticBus`.
public enum HapticEvent: Hashable, Sendable {
    case send, toolStart, toolFinish, modelLoaded, downloadFinished, error, tap, approvalNeeded
    var feedback: SensoryFeedback {
        switch self {
        case .approvalNeeded: .warning
        case .send: .impact(flexibility: .soft)
        case .toolStart: .selection
        case .toolFinish: .impact(weight: .light)
        case .modelLoaded, .downloadFinished: .success
        case .error: .error
        case .tap: .impact(flexibility: .soft)
        }
    }
}

/// One haptic channel for the whole app: anything may `emit`, the root view plays it with
/// `.sensoryFeedback`, and two events closer than `Motion.hapticGap` collapse into one
/// (the later wins, so a tool-finish arriving right after a tool-start is still felt).
@MainActor @Observable public final class HapticBus {
    public private(set) var seq = 0
    public private(set) var last: HapticEvent?
    private var lastAt: TimeInterval = 0
    private var pending: Task<Void, Never>?
    public init() {}

    public func emit(_ e: HapticEvent) {
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastAt >= LooplDesign.Motion.hapticGap {
            pending?.cancel(); pending = nil
            fire(e, at: now)
        } else {
            // Too soon: queue it for the end of the gap, replacing whatever was queued.
            pending?.cancel()
            let wait = LooplDesign.Motion.hapticGap - (now - lastAt)
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.fire(e, at: Date().timeIntervalSinceReferenceDate)
            }
        }
    }
    private func fire(_ e: HapticEvent, at t: TimeInterval) { lastAt = t; last = e; seq &+= 1 }
}

private struct HapticPlayer: ViewModifier {
    var bus: HapticBus
    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: bus.seq) { _, _ in bus.last?.feedback }
    }
}
public extension View {
    /// Plays every `HapticBus.emit` through `.sensoryFeedback`. Attach once, at the root.
    func looplHaptics(_ bus: HapticBus) -> some View { modifier(HapticPlayer(bus: bus)) }
}

// MARK: - Indeterminate progress (never a spinner)

/// A 2 pt track with a short accent segment sweeping left→right; under Reduce Motion a
/// still, half-tinted track. Replaces `ProgressView()` wherever a thing is in flight.
public struct IndeterminateBar: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public var body: some View {
        GeometryReader { g in
            let w = g.size.width, seg = max(24, w * 0.3)
            ZStack(alignment: .leading) {
                Capsule().fill(LooplDesign.tertiaryFill)
                if reduceMotion {
                    Capsule().fill(LooplDesign.accent.opacity(0.5))
                } else {
                    Capsule().fill(LooplDesign.accent).frame(width: seg)
                        .offset(x: on ? w : -seg)
                        .animation(LooplDesign.Motion.sweep, value: on)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 2)
        .onAppear { on = true }
        .accessibilityLabel("in progress")
    }
}

/// The mark breathing (opacity 1 ↔ 0.45) while something is in flight; still under Reduce Motion.
public struct PulsingMark: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public var body: some View {
        LooplMark()
            .opacity(on && !reduceMotion ? 0.45 : 1)
            .animation(reduceMotion ? nil : LooplDesign.Motion.pulse, value: on)
            .onAppear { on = true }
            .accessibilityLabel("in progress")
    }
}
