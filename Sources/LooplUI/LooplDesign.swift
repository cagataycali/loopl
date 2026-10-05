import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// loopl's design language — mirrored from tiny iOS (ios/DESIGN.md):
/// one accent (the tiny flame green #00FF88 by default), SF Symbols for
/// chrome, emoji only as content personality, 14pt cards with an accent
/// hairline at 15%, 18pt bubbles, system fonts + Dynamic Type.
public enum LooplDesign {
    public static let accent = Color(red: 0, green: 1, blue: 0.533)   // #00FF88
    public static let iconChat = "bubble.left.and.text.bubble.right"
    public static let iconModels = "square.stack.3d.down.right"
    public static let iconAgent = "point.3.connected.trianglepath.dotted"
    public static let iconSettings = "gearshape"
    public static let iconTool = "wrench.and.screwdriver"
    public static let iconDownload = "arrow.down.circle"
    public static let iconLoaded = "bolt.fill"
    public static let iconOffline = "airplane"
    public static let iconWarning = "exclamationmark.triangle"
    @MainActor public static func haptic(_ strength: Int = 0) {
        #if canImport(UIKit) && !os(watchOS)
        UIImpactFeedbackGenerator(style: strength > 0 ? .medium : .soft).impactOccurred()
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

/// Small accent-tinted label like "MLX" / "gated" / "loaded".
public struct Pill: View {
    public var text: String
    public var tint: Color
    public init(_ text: String, tint: Color = LooplDesign.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule()).foregroundStyle(tint == LooplDesign.accent ? .primary : tint)
    }
}
