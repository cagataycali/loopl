import Foundation
import Loopl
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// `generate_image` — Image Playground's on-device model (ImagePlayground framework,
/// iOS 18.4+, Apple Intelligence hardware). Programmatic `ImageCreator` is deprecated in
/// iOS 27 in favour of the system sheet; it still runs there, and the app offers the
/// sheet when creation fails. Output: one JPEG ≤ 1024 px as `ToolResult.images`.
public struct GenerateImageTool: AppleTool {
    public init() {}
    public let name = "generate_image"
    public let description = "Generate a picture on this device from a short description (Image Playground). Styles: animation (default), illustration, sketch. The image is shown to the user; you get a one-line summary."
    public let parameters: JSONValue = ToolSchema.object([
        "prompt": ToolSchema.string("What to draw — concrete visual concepts work best, e.g. 'a black smart ring on a slate tile'"),
        "style": ["type": "string", "enum": ["animation", "illustration", "sketch"], "description": "Rendering style (default animation)"],
    ], required: ["prompt"])
    public static let onDeviceCopy = "Draws with the Image Playground model on your iPhone. Nothing leaves the device."
    public static let styles = ["animation", "illustration", "sketch"]

    public static func availability() -> ToolAvailability {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, macOS 15.4, *) {
            if Unavailable.isSimulator { return .no(Unavailable.simulator) }
            let ok = MainActor.assumeIsolatedIfPossible { ImagePlaygroundViewController.isAvailable }
            return ok ? .ok : .no(Unavailable.appleIntelligence)
        }
        return .no(Unavailable.ios("18.4"))
        #else
        return .no(Unavailable.sdk)
        #endif
    }

    public func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }

    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        guard let prompt = args.string("prompt")?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw ToolError("prompt is required")
        }
        let style = args.string("style") ?? "animation"
        guard Self.styles.contains(style) else { throw ToolError("style must be one of \(Self.styles.joined(separator: ", "))") }
        let a = Self.availability()
        guard a.available else { throw ToolError("generate_image is not available here: \(a.reason)") }
        #if canImport(ImagePlayground) && canImport(ImageIO)
        guard #available(iOS 18.4, macOS 15.4, *) else { throw ToolError(Unavailable.ios("18.4")) }
        let t0 = Date()
        do {
            let creator = try await ImageCreator()
            let chosen: ImagePlaygroundStyle = switch style {
            case "illustration": .illustration
            case "sketch": .sketch
            default: .animation
            }
            for try await created in creator.images(for: [.text(prompt)], style: chosen, limit: 1) {
                let block = try ImageCodec.jpeg(created.cgImage, maxSide: 1024, alt: "\(style) of: \(prompt)")
                let secs = Date().timeIntervalSince(t0)
                let text = "generated 1 image (\(style), \(block.width ?? 0)×\(block.height ?? 0), \(String(format: "%.1f", secs)) s) for: \(prompt). The user can see it; describe it only if asked."
                return ToolOutput(text: text, images: [block])
            }
            throw ToolError("the on-device model returned no image for this prompt — try more concrete visual concepts")
        } catch let e as ImageCreator.Error {
            switch e {
            case .notSupported, .unavailable: throw ToolError(Unavailable.appleIntelligence)
            case .unsupportedLanguage: throw ToolError("Image Playground does not support the prompt's language on this device")
            case .backgroundCreationForbidden: throw ToolError("image generation only works while loopl is in the foreground")
            case .creationCancelled: throw ToolError("image generation was cancelled")
            default: throw ToolError("image generation failed: \(e.localizedDescription)")
            }
        }
        #else
        throw ToolError(Unavailable.sdk)
        #endif
    }
}
