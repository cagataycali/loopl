import SwiftUI
import Loopl

// Pictures in the transcript: a row of rounded thumbnails under a turn, and a
// full-screen viewer the thumbnail zooms into (matchedGeometryEffect; iOS 18
// zoom navigation transition where available). Reduce Motion → plain fades.

/// Decoded `UIImage`/`NSImage` cache keyed by the bytes' hash — decoding a 1 MB JPEG per layout pass would stutter.
@MainActor
final class ImageBlockDecoder {
    static let shared = ImageBlockDecoder()
    private var cache: [Int: PlatformImage] = [:]
    func image(for block: ImageBlock) -> PlatformImage? {
        let key = block.data.hashValue
        if let hit = cache[key] { return hit }
        guard let img = PlatformImage(data: block.data) else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = img
        return img
    }
}

// `PlatformImage` + `Image(platformImage:)` live in ToolImages.swift (shared with ToolCallCard).
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One picture, fitted into a rounded tile. Tapping opens `ImageViewer` (zoom).
public struct ImageTile: View {
    public var block: ImageBlock
    public var maxHeight: CGFloat
    public var namespace: Namespace.ID?
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ block: ImageBlock, maxHeight: CGFloat = 220, namespace: Namespace.ID? = nil) {
        self.block = block; self.maxHeight = maxHeight; self.namespace = namespace
    }

    private var aspect: CGFloat {
        if let w = block.width, let h = block.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        if let img = ImageBlockDecoder.shared.image(for: block), img.size.height > 0 { return img.size.width / img.size.height }
        return 4 / 3
    }

    public var body: some View {
        Button {
            LooplDesign.haptic()
            open = true
        } label: {
            Group {
                if let img = ImageBlockDecoder.shared.image(for: block) {
                    Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(Color(.secondarySystemFill))
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
            }
            // Fit INSIDE the column: height-first sizing (`frame(height:)` then aspect) made a 1.6:1 picture 352 pt wide
            // on a 335 pt SE column — the LazyVStack used to swallow the overrun, the plain VStack (#117) reported it and
            // the whole chat shifted 8.5 pt left (UX-GEOM caught it). Width ≤ the proposal, height ≤ maxHeight.
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: min(maxHeight, 320))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(block.alt ?? "Image")
        .accessibilityAddTraits(.isImage)
        .modifier(ZoomSource(id: block.data.hashValue, namespace: namespace))
        .modifier(ViewerPresenter(open: $open) {
            ImageViewer(block: block, namespace: namespace)
                .modifier(ZoomDestination(id: block.data.hashValue, namespace: namespace, reduceMotion: reduceMotion))
        })
    }
}

/// A row of tiles under a turn — horizontally scrollable when it does not fit.
public struct ImageStrip: View {
    public var images: [ImageBlock]
    public var maxHeight: CGFloat
    @Namespace private var zoom
    public init(_ images: [ImageBlock], maxHeight: CGFloat = 220) { self.images = images; self.maxHeight = maxHeight }
    public var body: some View {
        if images.count == 1, let one = images.first {
            ImageTile(one, maxHeight: maxHeight, namespace: zoom)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, b in
                        ImageTile(b, maxHeight: min(maxHeight, 160), namespace: zoom)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

/// Full-screen viewer: pinch to zoom, double-tap to toggle, drag down to dismiss (interruptible),
/// the picture's `alt` as a caption. Reduce Motion: no rubber-band offset, plain fade.
public struct ImageViewer: View {
    public var block: ImageBlock
    public var namespace: Namespace.ID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var drag: CGSize = .zero
    @State private var showChrome = true

    public init(block: ImageBlock, namespace: Namespace.ID? = nil) { self.block = block; self.namespace = namespace }

    private var dismissProgress: CGFloat { min(1, abs(drag.height) / 240) }

    public var body: some View {
        ZStack {
            Color.black.opacity(Double(1 - dismissProgress * 0.6)).ignoresSafeArea()
            if let img = ImageBlockDecoder.shared.image(for: block) {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fit)
                    .scaleEffect(scale * (1 - dismissProgress * 0.15))
                    .offset(reduceMotion ? .zero : drag)
                    .gesture(magnify)
                    .simultaneousGesture(scale <= 1.01 ? pan : nil)
                    .onTapGesture(count: 2) {
                        LooplDesign.haptic()
                        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { scale = scale > 1 ? 1 : 2.5; lastScale = scale }
                    }
                    .onTapGesture { withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.value, reduceMotion)) { showChrome.toggle() } }
                    .accessibilityLabel(block.alt ?? "Image")
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.callout.weight(.semibold)).padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain).padding(16)
                    .accessibilityLabel("Close")
                }
                Spacer()
                if let alt = block.alt, !alt.isEmpty {
                    Text(alt).font(.footnote).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center)
                        .padding(.horizontal, 20).padding(.bottom, 24)
                }
            }
            .opacity(showChrome ? 1 : 0)
        }
        #if os(iOS)
        .statusBarHidden(!showChrome)
        #endif
        .preferredColorScheme(.dark)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in scale = max(1, min(6, lastScale * v.magnification)) }
            .onEnded { _ in
                lastScale = scale
                if scale < 1.05 { withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { scale = 1; lastScale = 1 } }
            }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.interactive, reduceMotion)) { drag = v.translation }
            }
            .onEnded { v in
                let dy = v.translation.height, vy = v.predictedEndTranslation.height - dy
                if abs(dy) > LooplDesign.Motion.dismissDistance * 2 || abs(vy) > LooplDesign.Motion.dismissVelocity {
                    dismiss()
                } else {
                    withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { drag = .zero }
                }
            }
    }
}

/// Full-screen on iOS, a sheet on macOS (no fullScreenCover there).
private struct ViewerPresenter<V: View>: ViewModifier {
    @Binding var open: Bool
    @ViewBuilder var viewer: () -> V
    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $open, content: viewer)
        #else
        content.sheet(isPresented: $open, content: viewer)
        #endif
    }
}

// MARK: - zoom transition plumbing (iOS 18+; no-op elsewhere)

private struct ZoomSource: ViewModifier {
    var id: Int
    var namespace: Namespace.ID?
    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace { content.matchedTransitionSource(id: id, in: namespace) } else { content }
        #else
        content
        #endif
    }
}

private struct ZoomDestination: ViewModifier {
    var id: Int
    var namespace: Namespace.ID?
    var reduceMotion: Bool
    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace, !reduceMotion { content.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { content }
        #else
        content
        #endif
    }
}

// MARK: - Composer attachment chips

/// Thumbnail chips above the composer field: tap ✕ to remove. Insert/remove animate with the Motion tokens.
public struct AttachmentChips: View {
    @Binding public var images: [ImageBlock]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(images: Binding<[ImageBlock]>) { _images = images }
    public var body: some View {
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.element) { idx, b in
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let img = ImageBlockDecoder.shared.image(for: b) {
                                    Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
                                } else { Color(.secondarySystemFill) }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Button {
                                LooplDesign.haptic()
                                withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { images.remove(at: idx) }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).padding(5)
                                    .background(Color.black.opacity(0.7), in: Circle()).foregroundStyle(.white)
                            }
                            .buttonStyle(.plain).padding(4)
                            .accessibilityLabel("Remove image")
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: images.count)
            .accessibilityLabel("\(images.count) attached image\(images.count == 1 ? "" : "s")")
        }
    }
}
