import Foundation
import Loopl
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// `vibrate` — the Taptic Engine. Named patterns map to the system feedback generators
/// (tap/double → impact, success/warning/error → notification) and to CoreHaptics for
/// the ones UIKit has no name for (heartbeat, long). Runs on the main actor — UIKit's
/// feedback generators require it. Simulator and most iPads have no Taptic Engine.
public struct VibrateTool: AppleTool {
    public init() {}
    public let name = "vibrate"
    public let description = "Play a vibration (haptic) pattern on the iPhone: tap, double, success, warning, error, heartbeat or long. Use only when the user asks to vibrate, buzz or give haptic feedback. Returns the pattern played."
    public let parameters: JSONValue = ToolSchema.object([
        "pattern": ["type": "string", "enum": .array(VibrateTool.patterns.map(JSONValue.string)), "description": "Which pattern to play"],
        "intensity": ToolSchema.number("Strength 0–1 (default 1)"),
    ], required: ["pattern"])
    public static let onDeviceCopy = "Buzzes in one of a few patterns. Nothing else happens."
    public static let patterns = ["tap", "double", "success", "warning", "error", "heartbeat", "long"]

    public struct Request: Sendable, Hashable {
        public var pattern: String
        public var intensity: Float
        public init(pattern: String, intensity: Float) { self.pattern = pattern; self.intensity = intensity }
    }

    public static func parse(_ args: [String: JSONValue]) throws -> Request {
        guard let p = args.string("pattern")?.lowercased(), patterns.contains(p) else {
            throw ToolError("pattern must be one of \(patterns.joined(separator: ", "))")
        }
        let i = Float(args.double("intensity") ?? 1)
        guard i.isFinite, i >= 0, i <= 1 else { throw ToolError("intensity must be between 0 and 1") }
        return Request(pattern: p, intensity: max(i, 0.05))
    }

    public static func availability() -> ToolAvailability {
        if Unavailable.isSimulator { return .no(Unavailable.simulator) }
        #if canImport(CoreHaptics) && canImport(UIKit)
        return CHHapticEngine.capabilitiesForHardware().supportsHaptics ? .ok : .no(Unavailable.noHaptics)
        #else
        return .no(Unavailable.noUIKit)
        #endif
    }

    /// Roughly how long each pattern plays — the tool waits this long so the engine is not torn down mid-buzz.
    public static func duration(of pattern: String) -> TimeInterval {
        switch pattern {
        case "double": 0.25
        case "heartbeat": 1.1
        case "long": 0.7
        default: 0.15
        }
    }

    /// Phase 7: "Vibrate again" re-runs the same pattern at the same intensity.
    public static func control(_ r: Request) -> ToolControl {
        .button(label: "Vibrate again", action: ControlAction(tool: "vibrate", args: ["pattern": .string(r.pattern), "intensity": .number(Double(r.intensity))]))
    }

    public func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }

    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let r = try Self.parse(args)
        let a = Self.availability()
        guard a.available else { throw ToolError("vibrate is not available here: \(a.reason)") }
        #if canImport(CoreHaptics) && canImport(UIKit)
        try await Self.play(r)
        return ToolOutput(text: "vibrated: \(r.pattern) (intensity \(String(format: "%.2f", r.intensity)))", control: Self.control(r))
        #else
        throw ToolError(Unavailable.noUIKit)
        #endif
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }

    #if canImport(CoreHaptics) && canImport(UIKit)
    @MainActor
    static func play(_ r: Request) async throws {
        switch r.pattern {
        case "tap":
            let g = UIImpactFeedbackGenerator(style: .medium); g.prepare()
            g.impactOccurred(intensity: CGFloat(r.intensity))
        case "double":
            let g = UIImpactFeedbackGenerator(style: .rigid); g.prepare()
            g.impactOccurred(intensity: CGFloat(r.intensity))
            try await Task.sleep(for: .milliseconds(120))
            g.impactOccurred(intensity: CGFloat(r.intensity))
        case "success", "warning", "error":
            let g = UINotificationFeedbackGenerator(); g.prepare()
            let kind: UINotificationFeedbackGenerator.FeedbackType = switch r.pattern { case "success": .success; case "warning": .warning; default: .error }
            g.notificationOccurred(kind)
        default:
            try await playPattern(r)
        }
        try await Task.sleep(for: .seconds(duration(of: r.pattern)))
    }

    /// CoreHaptics for the shapes UIKit cannot name. Each event carries the requested intensity.
    @MainActor
    private static func playPattern(_ r: Request) async throws {
        let i = CHHapticEventParameter(parameterID: .hapticIntensity, value: r.intensity)
        let sharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        let events: [CHHapticEvent] = switch r.pattern {
        case "heartbeat":
            // lub-dub, twice
            [0, 0.18, 0.7, 0.88].map { CHHapticEvent(eventType: .hapticTransient, parameters: [i, sharp], relativeTime: $0) }
        default:   // long
            [CHHapticEvent(eventType: .hapticContinuous, parameters: [i, CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)], relativeTime: 0, duration: 0.6)]
        }
        let engine = try CHHapticEngine()
        try await engine.start()
        let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
        try player.start(atTime: CHHapticTimeImmediate)
        try await Task.sleep(for: .seconds(duration(of: r.pattern)))
        try? await engine.stop()
    }
    #endif
}
