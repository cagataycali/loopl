import Foundation
import Loopl
#if canImport(Vision)
import Vision
#endif

/// `read_text` — Vision `RecognizeTextRequest` (iOS 18 Swift API): OCR on the user's
/// most recent attached picture. Works offline, on the Simulator too.
public struct ReadTextTool: AppleTool {
    public init() {}
    public let name = "read_text"
    public let description = "Read the text in a picture the user attached (OCR, on-device). Returns the recognised lines top to bottom. Use for screenshots, signs, receipts, documents."
    public let parameters: JSONValue = ToolSchema.object([
        "image_index": ToolSchema.number("Which attached picture: 0 = most recent (default)"),
        "languages": ToolSchema.string("Comma-separated BCP-47 hints like en-US,tr-TR (default: automatic)"),
    ])
    public static let onDeviceCopy = "Reads text in pictures with the Vision framework on your iPhone. Works offline."
    public static func availability() -> ToolAvailability {
        #if canImport(Vision) && canImport(ImageIO)
        return .ok
        #else
        return .no(Unavailable.sdk)
        #endif
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        throw ToolError("no image attached — ask the user to attach a picture to their message first")
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput {
        let block = try pickImage(images, args: args)
        #if canImport(Vision) && canImport(ImageIO)
        let cg = try ImageCodec.cgImage(block)
        var req = RecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        if let langs = args.string("languages")?.split(separator: ",").map({ Locale.Language(identifier: $0.trimmingCharacters(in: .whitespaces)) }), !langs.isEmpty {
            req.recognitionLanguages = langs
        } else {
            req.automaticallyDetectsLanguage = true
        }
        let observations = try await req.perform(on: cg)
        // Top-to-bottom: Vision's origin is bottom-left.
        let lines = observations
            .sorted { $0.boundingBox.cgRect.midY > $1.boundingBox.cgRect.midY }
            .compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return ToolOutput(text: "no text found in the picture (\(cg.width)×\(cg.height))") }
        return ToolOutput(text: "text in the picture (\(lines.count) lines, \(cg.width)×\(cg.height)):\n" + lines.joined(separator: "\n"))
        #else
        throw ToolError(Unavailable.sdk)
        #endif
    }
}

/// `describe_image` — Vision `ClassifyImageRequest` + `DetectFaceRectanglesRequest` +
/// `DetectBarcodesRequest` (iOS 18): what is in the picture, for text-only models.
public struct DescribeImageTool: AppleTool {
    public init() {}
    public let name = "describe_image"
    public let description = "Describe what is in a picture the user attached: top scene/object labels with confidence, number of faces, barcode/QR contents (on-device Vision, no text reading — use read_text for that)."
    public let parameters: JSONValue = ToolSchema.object([
        "image_index": ToolSchema.number("Which attached picture: 0 = most recent (default)"),
        "max_labels": ToolSchema.number("How many labels to return (default 8)"),
    ])
    public static let onDeviceCopy = "Labels scenes, objects, faces and QR codes with the Vision framework on your iPhone. Works offline."
    public static let minConfidence: Float = 0.25
    public static func availability() -> ToolAvailability {
        #if canImport(Vision) && canImport(ImageIO)
        return .ok
        #else
        return .no(Unavailable.sdk)
        #endif
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        throw ToolError("no image attached — ask the user to attach a picture to their message first")
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput {
        let block = try pickImage(images, args: args)
        #if canImport(Vision) && canImport(ImageIO)
        let cg = try ImageCodec.cgImage(block)
        let maxLabels = max(1, min(25, args.int("max_labels") ?? 8))
        var lines = ["picture: \(cg.width)×\(cg.height) \(block.format)"]
        let labels = try await ClassifyImageRequest().perform(on: cg)
            .filter { $0.confidence >= Self.minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { "\($0.identifier.replacingOccurrences(of: "_", with: " ")) \(Int($0.confidence * 100))%" }
        lines.append(labels.isEmpty ? "labels: none above \(Int(Self.minConfidence * 100))% confidence" : "labels: " + labels.joined(separator: ", "))
        let faces = try await DetectFaceRectanglesRequest().perform(on: cg)
        lines.append("faces: \(faces.count)")
        let codes = try await DetectBarcodesRequest().perform(on: cg).compactMap { o -> String? in
            guard let p = o.payloadString else { return nil }
            return "\(String(describing: o.symbology)): \(p)"
        }
        if !codes.isEmpty { lines.append("barcodes: " + codes.joined(separator: " | ")) }
        return ToolOutput(text: lines.joined(separator: "\n"))
        #else
        throw ToolError(Unavailable.sdk)
        #endif
    }
}
