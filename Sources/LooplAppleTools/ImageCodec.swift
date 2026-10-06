import Foundation
import Loopl
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// CGImage ⇄ `ImageBlock` with ImageIO only (no UIKit), so the same code runs
/// on iOS, the Simulator and the Mac that executes `swift test`.
public enum ImageCodec {
    /// Decode an attachment to a CGImage (any format ImageIO reads: PNG/JPEG/HEIC/WebP/GIF).
    public static func cgImage(_ block: ImageBlock) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(block.data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ToolError("could not decode the attached image (\(block.mime), \(block.byteCount) bytes)")
        }
        return img
    }

    /// JPEG ≤ `maxSide` px on the long edge → `ImageBlock` with width/height/alt set.
    /// Downscales through a CGContext (ImagePlayground returns 1024² or larger).
    public static func jpeg(_ image: CGImage, maxSide: Int = 1024, quality: Double = 0.85, alt: String? = nil) throws -> ImageBlock {
        let w = image.width, h = image.height
        let side = max(w, h)
        var out = image
        if side > maxSide {
            let scale = Double(maxSide) / Double(side)
            let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
            if let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
                if let scaled = ctx.makeImage() { out = scaled }
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ToolError("could not create a JPEG encoder")
        }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), data.length > 0 else { throw ToolError("JPEG encoding failed") }
        return ImageBlock(data: data as Data, mime: "image/jpeg", width: out.width, height: out.height, alt: alt)
    }

    /// A flat test image (solid colour with a contrasting block) — fixtures for tests and self-tests.
    public static func testImage(width: Int = 256, height: Int = 160) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.97, green: 0.95, blue: 0.92, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.72, green: 0.26, blue: 0.04, alpha: 1)); ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return ctx.makeImage()
    }
}
#endif
