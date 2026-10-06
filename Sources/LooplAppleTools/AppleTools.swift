import Foundation
import Loopl

// LooplAppleTools — the iPhone's own intelligence AND hardware as loopl tools. Everything here
// runs on the device, needs no account and no download by loopl; each tool reports
// `availability` honestly (Apple Intelligence off, Simulator, older iOS) and the
// app only hands AVAILABLE tools to the model. Research + citations:
// ~/.tiny/loopl-train-20261005/apple-tools/RESEARCH.md (Apple docs, 2026-10-05).

/// Whether a tool can run on THIS device right now, and why not when it cannot.
/// Mirrors `RuntimeAvailability` for runtimes.
public struct ToolAvailability: Sendable, Hashable {
    public var available: Bool
    /// Empty when available; otherwise one short line for Settings ("Needs Apple Intelligence").
    public var reason: String
    public static let ok = ToolAvailability(available: true, reason: "")
    public static func no(_ reason: String) -> ToolAvailability { ToolAvailability(available: false, reason: reason) }
    public init(available: Bool, reason: String) { self.available = available; self.reason = reason }
}

/// A loopl tool backed by an Apple framework on the device.
public protocol AppleTool: Tool {
    /// One line for Settings: what runs on-device and what it costs the user (nothing).
    static var onDeviceCopy: String { get }
    /// Call-time check — Settings shows the reason as a chip; the Engine filters unavailable tools out.
    static func availability() -> ToolAvailability
}

/// Short reasons shared by several tools.
enum Unavailable {
    static let appleIntelligence = "Needs Apple Intelligence (iPhone 15 Pro or newer, turned on in Settings)"
    static let simulator = "Not on Simulator — runs on a real iPhone"
    static func ios(_ v: String) -> String { "Needs iOS \(v) or later" }
    static let sdk = "Framework not in this SDK"
    static let noTorch = "No flashlight on this device"
    static let noHaptics = "No Taptic Engine on this device"
    static let noUIKit = "Needs an iPhone or iPad"
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

/// Every Apple tool loopl ships, in Settings order. Names are snake_case verbs.
public enum AppleTools {
    public static var all: [any AppleTool] {
        [GenerateImageTool(), GenerateVoiceTool(), DescribeImageTool(),
         TranslateTool(), TranscribeTool(),
         FlashlightTool(), VibrateTool(), OpenAppTool()]
    }
    public static var names: [String] { all.map(\.name) }
    /// Tools whose `availability()` is OK right now — what the Engine should expose to the model.
    public static var available: [any AppleTool] { all.filter { type(of: $0).availability().available } }
    public static func availability(of name: String) -> ToolAvailability {
        guard let t = all.first(where: { $0.name == name }) else { return .no("unknown tool") }
        return type(of: t).availability()
    }
    public static func copy(of name: String) -> String {
        guard let t = all.first(where: { $0.name == name }) else { return "" }
        return type(of: t).onDeviceCopy
    }
}

// MARK: - Argument helpers

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ k: String) -> String? { if case .string(let s)? = self[k] { return s }; return nil }
    func int(_ k: String) -> Int? {
        switch self[k] { case .number(let d)?: return Int(d); case .string(let s)?: return Int(s); default: return nil }
    }
    func double(_ k: String) -> Double? {
        switch self[k] { case .number(let d)?: return d; case .string(let s)?: return Double(s); default: return nil }
    }
    func bool(_ k: String) -> Bool? {
        switch self[k] { case .bool(let b)?: return b; case .string(let s)?: return Bool(s); default: return nil }
    }
}

/// Picks the picture a tool should look at: `image_index` (0 = most recent) over the user's attachments.
func pickImage(_ images: [ImageBlock], args: [String: JSONValue]) throws -> ImageBlock {
    guard !images.isEmpty else {
        throw ToolError("no image attached — ask the user to attach a picture to their message first")
    }
    let idx = args.int("image_index") ?? 0
    let ordered = Array(images.reversed())   // most recent first
    guard idx >= 0, idx < ordered.count else { throw ToolError("image_index \(idx) out of range (\(images.count) attached)") }
    return ordered[idx]
}

extension MainActor {
    /// Run a main-actor-only read from any context: directly when already on the main
    /// thread, otherwise hop synchronously (these reads are instant property lookups).
    static func assumeIsolatedIfPossible<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
