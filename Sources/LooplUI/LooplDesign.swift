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
    /// The one spring every entering row uses.
    public static let spring: Animation = .spring(response: 0.42, dampingFraction: 0.82)

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
