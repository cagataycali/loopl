import Foundation
import Loopl
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `apple_intelligence` — Foundation Models (iOS 26, Apple Intelligence): the ~3B system
/// model with guided generation (`@Generable`). One tool, three tasks, so a small loopl
/// model can delegate summarising / extracting / tagging to Apple's model and get JSON back.
public struct AppleIntelligenceTool: AppleTool {
    public init() {}
    public let name = "apple_intelligence"
    public let description = "Ask Apple's on-device model to summarize text (3 bullet points + one-line summary), extract structured facts (people, places, dates, amounts, action items) or tag it (topics, sentiment). Returns JSON. Text ≤ 8000 characters."
    public let parameters: JSONValue = ToolSchema.object([
        "task": ["type": "string", "enum": ["summarize", "extract", "tag"], "description": "What to do"],
        "text": ToolSchema.string("The text to work on"),
    ], required: ["task", "text"])
    public static let onDeviceCopy = "Summarises, extracts and tags with Apple's on-device Foundation Model. Needs Apple Intelligence; nothing leaves the device."
    public static let tasks = ["summarize", "extract", "tag"]
    public static let maxChars = 8000

    public static func availability() -> ToolAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ok
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .no("Apple Intelligence is turned off in Settings")
                case .deviceNotEligible: return .no(Unavailable.appleIntelligence)
                case .modelNotReady: return .no("Apple Intelligence model is still downloading")
                @unknown default: return .no("Apple Intelligence unavailable")
                }
            @unknown default: return .no("Apple Intelligence unavailable")
            }
        }
        return .no(Unavailable.ios("26"))
        #else
        return .no(Unavailable.sdk)
        #endif
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        guard let task = args.string("task"), Self.tasks.contains(task) else { throw ToolError("task must be one of \(Self.tasks.joined(separator: ", "))") }
        guard let text = args.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw ToolError("text is required") }
        guard text.count <= Self.maxChars else { throw ToolError("text is \(text.count) characters; keep it under \(Self.maxChars)") }
        let a = Self.availability()
        guard a.available else { throw ToolError("apple_intelligence is not available here: \(a.reason)") }
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { throw ToolError(Unavailable.ios("26")) }
        let session = LanguageModelSession(instructions: "You are a precise assistant inside an iPhone app. Work only from the text you are given; never invent facts. Keep every field short.")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch task {
        case "summarize":
            let r = try await session.respond(to: "Summarize this text.\n\n\(text)", generating: Summary.self)
            return String(decoding: try enc.encode(r.content), as: UTF8.self)
        case "extract":
            let r = try await session.respond(to: "Extract the facts from this text.\n\n\(text)", generating: Extraction.self)
            return String(decoding: try enc.encode(r.content), as: UTF8.self)
        default:
            let r = try await session.respond(to: "Tag this text.\n\n\(text)", generating: Tags.self)
            return String(decoding: try enc.encode(r.content), as: UTF8.self)
        }
        #else
        throw ToolError(Unavailable.sdk)
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable(description: "A short summary of a text")
struct Summary: Codable {
    @Guide(description: "One sentence, ≤ 25 words") var oneLine: String
    @Guide(description: "Three key points, each ≤ 15 words", .count(3)) var bullets: [String]
}

@available(iOS 26, macOS 26, *)
@Generable(description: "Facts extracted from a text")
struct Extraction: Codable {
    @Guide(description: "People mentioned") var people: [String]
    @Guide(description: "Places mentioned") var places: [String]
    @Guide(description: "Dates or times, as written") var dates: [String]
    @Guide(description: "Amounts of money or quantities, as written") var amounts: [String]
    @Guide(description: "Action items or requests, ≤ 12 words each") var actionItems: [String]
}

@available(iOS 26, macOS 26, *)
@Generable(description: "Topic tags and sentiment of a text")
struct Tags: Codable {
    @Guide(description: "1–5 lowercase topic tags", .count(5)) var topics: [String]
    @Guide(description: "positive, neutral or negative", .anyOf(["positive", "neutral", "negative"])) var sentiment: String
    @Guide(description: "The text's language as a BCP-47 code") var language: String
}
#endif
