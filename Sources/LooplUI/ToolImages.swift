import SwiftUI
import Loopl

/// Pictures a tool produced (`ToolResult.images`), shown under the tool row even
/// when the details are folded: a generated image IS the result. Tap → full screen
/// with the iOS 18 zoom transition; Reduce Motion gets a plain fade.
public struct ToolImagesView: View {
    public var images: [ImageBlock]
    @State private var shown: ImageBlock?
    @State private var appeared = false
    @Namespace private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(_ images: [ImageBlock]) { self.images = images }

    public var body: some View {
        if !images.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, block in
                    thumb(block)
                        .matchedTransitionSource(id: i, in: zoom)
                        .onTapGesture { shown = block }
                        .accessibilityLabel(block.alt ?? "generated image")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("opens full screen")
                }
            }
            .padding(.leading, 24)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.96, anchor: .topLeading)
            .onAppear { withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { appeared = true } }
            .looplLightbox(item: $shown) { block in
                ImageLightbox(block: block)
                    .looplZoom(id: images.firstIndex(of: block) ?? 0, in: zoom, reduceMotion: reduceMotion)
            }
        }
    }

    @ViewBuilder private func thumb(_ block: ImageBlock) -> some View {
        if let ui = block.platformImage {
            Image(platformImage: ui)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: 240, maxHeight: 240)
                .aspectRatio(block.aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LooplDesign.secondaryBackground)
                .frame(width: 160, height: 120)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }
}

/// Full-screen viewer: pinch to zoom, drag down to dismiss (interruptible spring), share.
struct ImageLightbox: View {
    var block: ImageBlock
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var drag: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(1 - min(0.6, abs(drag.height) / 600))
            if let ui = block.platformImage {
                Image(platformImage: ui).resizable().aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(drag)
                    .gesture(MagnifyGesture().onChanged { scale = max(1, min(4, $0.magnification)) }
                        .onEnded { _ in withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { scale = max(1, min(3, scale)) } })
                    .simultaneousGesture(DragGesture().onChanged { drag = $0.translation }
                        .onEnded { v in
                            if abs(v.translation.height) > LooplDesign.Motion.dismissDistance * 3 || abs(v.predictedEndTranslation.height - v.translation.height) > LooplDesign.Motion.dismissVelocity { dismiss() }
                            else { withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.interactive, reduceMotion)) { drag = .zero } }
                        })
                    .accessibilityLabel(block.alt ?? "image")
            }
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).padding(10) }
                        .background(.ultraThinMaterial, in: Circle()).accessibilityLabel("close")
                    Spacer()
                    if let url = block.temporaryFileURL() {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).padding(10) }
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                Spacer()
                if let alt = block.alt {
                    Text(alt).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden()
        #endif
    }
}

extension View {
    @ViewBuilder func looplZoom(id: Int, in ns: Namespace.ID, reduceMotion: Bool) -> some View {
        #if os(iOS)
        if reduceMotion { self } else { self.navigationTransition(.zoom(sourceID: id, in: ns)) }
        #else
        self
        #endif
    }
    /// Full screen on iOS; a sheet on the Mac (fullScreenCover does not exist there).
    @ViewBuilder func looplLightbox<Item: Identifiable, C: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }
}

// MARK: - Platform image plumbing

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension ImageBlock: Identifiable {
    public var id: Int { hashValue }
    var platformImage: PlatformImage? { PlatformImage(data: data) }
    var aspect: CGFloat? {
        if let width, let height, height > 0 { return CGFloat(width) / CGFloat(height) }
        return nil
    }
    /// A tmp copy for ShareLink / drag-out (JPEG or PNG per `format`).
    func temporaryFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopl-\(abs(hashValue)).\(format == "jpeg" ? "jpg" : format)")
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
        return url
    }
}
