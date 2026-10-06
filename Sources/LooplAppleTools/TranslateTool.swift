import Foundation
import Loopl
#if canImport(Translation)
import Translation
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// `translate` — Translation framework. The class is iOS 18, but creating a session WITHOUT a
/// SwiftUI `.translationTask` — `TranslationSession(installedSource:target:)` — is iOS 26.0
/// per the 26.4 SDK interface (the docs page shows the class's 18.0). So: iOS 26+.
/// Uses the language packs already installed on the device (Settings › Translate ›
/// Downloaded Languages). Not supported on the Simulator (Apple sample code note).
public struct TranslateTool: AppleTool {
    public init() {}
    public let name = "translate"
    public let description = "Translate text with the iPhone's offline Translate languages. Give the target language (BCP-47 like 'tr', 'de', 'en'); the source is detected unless given. Fails clearly if the pack is not downloaded."
    public let parameters: JSONValue = ToolSchema.object([
        "text": ToolSchema.string("Text to translate (≤ 4000 characters)"),
        "to": ToolSchema.string("Target language code, e.g. 'tr', 'de', 'en-US'"),
        "from": ToolSchema.string("Source language code (default: detected)"),
    ], required: ["text", "to"])
    public static let onDeviceCopy = "Translates with the language packs downloaded in Apple Translate. Offline; not available on Simulator."
    public static func availability() -> ToolAvailability {
        #if canImport(Translation)
        if #available(iOS 26, macOS 26, *) {
            if Unavailable.isSimulator { return .no(Unavailable.simulator) }
            return .ok
        }
        return .no(Unavailable.ios("26"))
        #else
        return .no(Unavailable.sdk)
        #endif
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        guard let text = args.string("text"), !text.isEmpty else { throw ToolError("text is required") }
        guard text.count <= 4000 else { throw ToolError("text is too long (\(text.count) > 4000 characters)") }
        guard let to = args.string("to"), !to.isEmpty else { throw ToolError("to (target language) is required") }
        let a = Self.availability()
        guard a.available else { throw ToolError("translate is not available here: \(a.reason)") }
        #if canImport(Translation)
        guard #available(iOS 26, macOS 26, *) else { throw ToolError(Unavailable.ios("26")) }
        let target = Locale.Language(identifier: to)
        let source: Locale.Language? = args.string("from").map { Locale.Language(identifier: $0) }
        let availability = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let source { status = await availability.status(from: source, to: target) }
        else { status = try await availability.status(for: text, to: target) }
        switch status {
        case .installed: break
        case .supported:
            throw ToolError("the \(to) language pack is supported but not downloaded — ask the user to download it in Settings › Apps › Translate › Downloaded Languages (or Translate app)")
        case .unsupported:
            throw ToolError("translation to \(to) is not supported on this device")
        @unknown default:
            throw ToolError("translation availability unknown")
        }
        let resolvedSource: Locale.Language
        if let source { resolvedSource = source } else {
            // Session init wants a concrete installed source; detect it the same way the availability check did.
            let r = NLLanguageRecognizer(); r.processString(text)
            guard let code = r.dominantLanguage?.rawValue else { throw ToolError("could not detect the source language — pass `from`") }
            resolvedSource = Locale.Language(identifier: code)
        }
        let session = TranslationSession(installedSource: resolvedSource, target: target)
        let response = try await session.translate(text)
        return "translated (\(response.sourceLanguage.minimalIdentifier) → \(response.targetLanguage.minimalIdentifier)):\n\(response.targetText)"
        #else
        throw ToolError(Unavailable.sdk)
        #endif
    }
}
