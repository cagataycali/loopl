import Foundation
import Loopl
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// `detect_language` — NaturalLanguage `NLLanguageRecognizer` (iOS 12). Offline, instant.
public struct DetectLanguageTool: AppleTool {
    public init() {}
    public let name = "detect_language"
    public let description = "Detect the language of a text (on-device). Returns the BCP-47 code and the top alternatives with probabilities."
    public let parameters: JSONValue = ToolSchema.object(["text": ToolSchema.string("The text to inspect")], required: ["text"])
    public static let onDeviceCopy = "Identifies the language of text with the Natural Language framework. Instant, offline."
    public static func availability() -> ToolAvailability {
        #if canImport(NaturalLanguage)
        return .ok
        #else
        return .no(Unavailable.sdk)
        #endif
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        guard let text = args.string("text"), !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError("text is required") }
        #if canImport(NaturalLanguage)
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage else { return "language: undetermined" }
        let alts = r.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \(Int($0.value * 100))%" }
        return "language: \(lang.rawValue)\nalternatives: \(alts.joined(separator: ", "))"
        #else
        throw ToolError(Unavailable.sdk)
        #endif
    }
}
