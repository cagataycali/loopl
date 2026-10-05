import SwiftUI

/// loopl's design language — mirrored from tiny iOS (ios/DESIGN.md):
/// one accent (the tiny flame green #00FF88 as default), SF Symbols for
/// chrome, emoji only as content personality, 14pt cards with an accent
/// hairline at 15%, 18pt bubbles, system fonts + Dynamic Type.
enum LooplDesign {
    static let accent = Color(red: 0, green: 1, blue: 0.533)   // #00FF88
    static let iconChat = "bubble.left.and.text.bubble.right"
    static let iconModels = "square.stack.3d.down.right"
    static let iconAgent = "point.3.connected.trianglepath.dotted"
    static let iconSettings = "gearshape"
    static let iconTool = "wrench.and.screwdriver"
    static let iconDownload = "arrow.down.circle"
    static let iconLoaded = "bolt.fill"
    static let iconOffline = "airplane"
    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .soft) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

struct LooplCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(LooplDesign.accent.opacity(0.15), lineWidth: 1))
    }
}
extension View { func looplCard() -> some View { modifier(LooplCard()) } }

/// Small accent-tinted label like "MLX" / "gated" / "loaded".
struct Pill: View {
    var text: String
    var tint: Color = LooplDesign.accent
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule()).foregroundStyle(tint == LooplDesign.accent ? .primary : tint)
    }
}
