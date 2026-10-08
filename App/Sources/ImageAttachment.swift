import SwiftUI
import Loopl
#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Turns what the user picked (Photos, camera, pasteboard) into an `ImageBlock` the model can take:
/// orientation baked in, longest edge ≤ 1024 px, JPEG 0.85 (PNG kept when the source has alpha and is small).
/// A 12 MP HEIC becomes ~200 KB — the transcript stays light and the vision tower gets exactly what it would
/// downscale to anyway (Qwen-VL budgets ≤ 1280 tokens ≈ 1 MP).
enum ImageAttachment {
    static let maxEdge: CGFloat = 1024

    static func block(from data: Data) -> ImageBlock? {
        guard let ui = UIImage(data: data) else { return nil }
        return block(from: ui, original: data)
    }

    static func block(from ui: UIImage, original: Data? = nil) -> ImageBlock? {
        let fixed = ui.normalizedOrientation()
        let scaled = fixed.downscaled(maxEdge: maxEdge)
        let hasAlpha = scaled.cgImage.map { $0.alphaInfo != .none && $0.alphaInfo != .noneSkipLast && $0.alphaInfo != .noneSkipFirst } ?? false
        let w = Int(scaled.size.width * scaled.scale), h = Int(scaled.size.height * scaled.scale)
        if hasAlpha, let png = scaled.pngData(), png.count < 2_000_000 {
            return ImageBlock(data: png, mime: "image/png", width: w, height: h)
        }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        return ImageBlock(data: jpeg, mime: "image/jpeg", width: w, height: h)
    }

    static var pasteboardHasImage: Bool { UIPasteboard.general.hasImages }

    static func fromPasteboard() -> ImageBlock? {
        guard let ui = UIPasteboard.general.image else { return nil }
        return block(from: ui)
    }
}

extension UIImage {
    /// Redraws so EXIF orientation is applied (the model sees the picture the way the user does).
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Longest edge ≤ `maxEdge` pixels (scale 1). Returns self when already small enough.
    func downscaled(maxEdge: CGFloat) -> UIImage {
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let longest = max(px.width, px.height)
        guard longest > maxEdge, longest > 0 else {
            if scale == 1 { return self }
            let f = UIGraphicsImageRendererFormat.default(); f.scale = 1
            return UIGraphicsImageRenderer(size: px, format: f).image { _ in draw(in: CGRect(origin: .zero, size: px)) }
        }
        let k = maxEdge / longest
        let target = CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
        let f = UIGraphicsImageRendererFormat.default(); f.scale = 1
        return UIGraphicsImageRenderer(size: target, format: f).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// The system camera, as a SwiftUI view. Hands back JPEG bytes (or nil on cancel).
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.cameraCaptureMode = .photo
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let ui = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            parent.onPick(ui?.normalizedOrientation().jpegData(compressionQuality: 0.9))
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onPick(nil)
            parent.dismiss()
        }
    }
}
#endif
