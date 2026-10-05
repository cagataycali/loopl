import SwiftUI

/// The loopl mark: an open loop (ouroboros stroke) whose head is the tiny
/// flame. One filled vector path in a unit square — scale it with `.frame`.
/// The same geometry lives in App/Resources/brand/loopl-mark.svg (the icon).
public struct LooplMarkShape: Shape {
    /// Ring thickness as a fraction of the side (0.11 = the icon's weight).
    public var weight: CGFloat = 0.115
    public init(weight: CGFloat = 0.115) { self.weight = weight }

    public func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

        let c = CGPoint(x: 0.5, y: 0.54)
        let r: CGFloat = 0.32
        let w = weight
        // Loop runs from the tapered tail (20°) around to the head (300°); the gap sits top-right.
        let tail = Angle.degrees(28), head = Angle.degrees(300)
        var p = Path()
        // Band: outer arc tail→head, round over to the inner arc, inner arc head→tail, round tail cap.
        p.addArc(center: pt(c.x, c.y), radius: (r + w / 2) * s, startAngle: tail, endAngle: head, clockwise: false)
        p.addArc(center: pt(c.x + r * CGFloat(cos(head.radians)), c.y + r * CGFloat(sin(head.radians))), radius: w / 2 * s,
                 startAngle: head, endAngle: head + .degrees(180), clockwise: false)
        p.addArc(center: pt(c.x, c.y), radius: (r - w / 2) * s, startAngle: head, endAngle: tail, clockwise: true)
        p.addArc(center: pt(c.x + r * CGFloat(cos(tail.radians)), c.y + r * CGFloat(sin(tail.radians))), radius: w / 2 * s,
                 startAngle: tail + .degrees(180), endAngle: tail + .degrees(360), clockwise: false)
        p.closeSubpath()

        // Flame head: a teardrop leaning into the gap, its base centred on the head of the loop.
        let hx = c.x + r * CGFloat(cos(head.radians)), hy = c.y + r * CGFloat(sin(head.radians))
        let fw = w * 2.2, fh = w * 3.3
        var f = Path()
        f.move(to: CGPoint(x: 0.66, y: 0))                                  // tip, leaning right
        f.addCurve(to: CGPoint(x: 1, y: 0.64), control1: CGPoint(x: 0.86, y: 0.22), control2: CGPoint(x: 1, y: 0.44))
        f.addCurve(to: CGPoint(x: 0.5, y: 1), control1: CGPoint(x: 1, y: 0.86), control2: CGPoint(x: 0.78, y: 1))
        f.addCurve(to: CGPoint(x: 0, y: 0.64), control1: CGPoint(x: 0.22, y: 1), control2: CGPoint(x: 0, y: 0.86))
        f.addCurve(to: CGPoint(x: 0.66, y: 0), control1: CGPoint(x: 0, y: 0.34), control2: CGPoint(x: 0.42, y: 0.3))
        f.closeSubpath()
        let flameRect = CGRect(x: ox + (hx - fw / 2) * s, y: oy + (hy - fh * 0.7) * s, width: fw * s, height: fh * s)
        let t = CGAffineTransform(translationX: flameRect.minX, y: flameRect.minY)
            .scaledBy(x: flameRect.width, y: flameRect.height)
        let rot = CGAffineTransform(translationX: flameRect.midX, y: flameRect.midY).rotated(by: .pi / 180 * -6)
            .translatedBy(x: -flameRect.midX, y: -flameRect.midY)
        p.addPath(f.applying(t).applying(rot))
        return p
    }
}

/// The mark filled with the flame gradient; `tone` picks the canvas it sits on.
public struct LooplMark: View {
    public enum Tone { case plain, dark, light }
    public var tone: Tone
    public init(tone: Tone = .plain) { self.tone = tone }

    public var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            ZStack {
                if tone != .plain {
                    RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                        .fill(tone == .dark ? LooplDesign.ink : LooplDesign.cream)
                }
                LooplMarkShape().fill(LooplDesign.flame).padding(tone == .plain ? 0 : side * 0.12)
            }
            .frame(width: side, height: side)
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("loopl")
        .accessibilityAddTraits(.isImage)
    }
}

#Preview("LooplMark") {
    HStack(spacing: 24) {
        LooplMark().frame(width: 96)
        LooplMark(tone: .dark).frame(width: 96)
        LooplMark(tone: .light).frame(width: 96)
    }.padding()
}
