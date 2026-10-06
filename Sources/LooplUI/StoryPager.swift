import SwiftUI

/// Horizontal pages that follow the finger and settle with velocity — interruptible at any point
/// (a drag mid-settle picks the page up where it is, no waiting for the animation to end).
///
/// `TabView(.page)` cannot do that: it owns the gesture and animates at its own pace. This is a
/// plain `HStack` offset by `-index * width + drag`, so the settle is one spring on `index` and the
/// finger is always the source of truth while it is down. Under Reduce Motion the finger still
/// drags (user-driven motion is fine) but programmatic page changes crossfade instead of sliding.
///
/// Used by the first-run story in the app; generic enough for any carousel of full-width pages.
public struct StoryPager<Page: View>: View {
    @Binding public var index: Int
    public var count: Int
    public var onSettle: ((Int) -> Void)?
    @ViewBuilder public var page: (Int) -> Page

    @GestureState private var drag: CGFloat = 0
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    public init(index: Binding<Int>, count: Int, onSettle: ((Int) -> Void)? = nil, @ViewBuilder page: @escaping (Int) -> Page) {
        _index = index; self.count = count; self.onSettle = onSettle; self.page = page
    }

    public var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            let rtl: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
            // Past the ends the offset is rubber-banded (a third of the overshoot) so the edge is felt, not hit.
            let raw = drag
            let clamped: CGFloat = {
                if index == 0, raw * rtl > 0 { return raw / 3 }
                if index == count - 1, raw * rtl < 0 { return raw / 3 }
                return raw
            }()
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    page(i)
                        .frame(width: w, height: g.size.height)
                        .opacity(reduceMotion ? (i == index ? 1 : 0) : 1)
                        .accessibilityHidden(i != index)
                }
            }
            .frame(width: w * CGFloat(count), alignment: .leading)
            .offset(x: -CGFloat(index) * w * rtl + clamped)
            .animation(dragging ? nil : settleAnimation, value: index)
            .animation(dragging ? nil : settleAnimation, value: clamped)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .updating($drag) { v, s, _ in s = v.translation.width }
                    .onChanged { _ in if !dragging { dragging = true } }
                    .onEnded { v in
                        dragging = false
                        let predicted = v.predictedEndTranslation.width * rtl
                        let moved = v.translation.width * rtl
                        var target = index
                        // Either a real distance (a third of the width) or a flick (the projection crosses half a page).
                        if moved < -w / 3 || predicted < -w / 2 { target = min(count - 1, index + 1) }
                        else if moved > w / 3 || predicted > w / 2 { target = max(0, index - 1) }
                        withAnimation(settleAnimation) { index = target }
                        onSettle?(target)
                    }
            )
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            // VoiceOver swipe up/down steps through the pages.
            switch direction {
            case .increment: if index < count - 1 { withAnimation(settleAnimation) { index += 1 }; onSettle?(index) }
            case .decrement: if index > 0 { withAnimation(settleAnimation) { index -= 1 }; onSettle?(index) }
            @unknown default: break
            }
        }
    }

    private var settleAnimation: Animation {
        reduceMotion ? LooplDesign.Motion.crossfade : LooplDesign.Motion.interactive
    }
}

/// Page indicator: the current page is a wide capsule, the rest are dots — all one shape so the width
/// change animates instead of swapping views.
public struct PageDots: View {
    public var count: Int
    public var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(count: Int, index: Int) { self.count = count; self.index = index }
    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? AnyShapeStyle(LooplDesign.flame) : AnyShapeStyle(LooplDesign.tertiaryFill))
                    .frame(width: i == index ? 22 : 6, height: 6)
            }
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: index)
        .accessibilityElement()
        .accessibilityLabel("Page \(index + 1) of \(count)")
    }
}

#Preview("StoryPager") {
    struct Demo: View {
        @State var i = 0
        var body: some View {
            VStack {
                StoryPager(index: $i, count: 3) { n in
                    RoundedRectangle(cornerRadius: 24).fill([Color.orange, .pink, .teal][n].opacity(0.4)).padding()
                        .overlay(Text("Page \(n + 1)").font(.largeTitle))
                }
                PageDots(count: 3, index: i)
            }
        }
    }
    return Demo()
}
