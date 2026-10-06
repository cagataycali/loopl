import Foundation
import Loopl
#if canImport(AVFoundation)
import AVFoundation
#endif

/// `flashlight` — the camera torch through `AVCaptureDevice` (no camera permission is
/// needed for the torch). On, off or toggle, optionally at a brightness level; reports
/// the state the LED actually ended in. Simulator and torch-less iPads say so honestly.
public struct FlashlightTool: AppleTool {
    public init() {}
    public let name = "flashlight"
    public let description = "Turn the iPhone's flashlight (torch LED) on or off, or toggle it, optionally at a brightness level 0–1. Use only when the user explicitly asks for the flashlight or torch. Returns the resulting state."
    public let parameters: JSONValue = ToolSchema.object([
        "state": ["type": "string", "enum": ["on", "off", "toggle"], "description": "on, off or toggle"],
        "level": ToolSchema.number("Brightness 0–1 when turning on (default 1 = full)"),
    ], required: ["state"])
    public static let onDeviceCopy = "Switches the camera LED on and off. No camera access, nothing recorded."
    public static let states = ["on", "off", "toggle"]

    /// Parsed input, shared by `call` and the tests.
    public struct Request: Sendable, Hashable {
        public var state: String
        /// 0 < level ≤ 1; `AVCaptureDevice` rejects 0 and anything above the maximum.
        public var level: Float
    }

    public static func parse(_ args: [String: JSONValue]) throws -> Request {
        guard let state = args.string("state")?.lowercased(), states.contains(state) else {
            throw ToolError("state must be one of \(states.joined(separator: ", "))")
        }
        var level = Float(args.double("level") ?? 1)
        guard level.isFinite, level >= 0, level <= 1 else { throw ToolError("level must be between 0 and 1") }
        if level == 0 { level = 0.01 }   // the torch has no "on at zero"; the smallest glow instead
        return Request(state: state, level: level)
    }

    public static func availability() -> ToolAvailability {
        if Unavailable.isSimulator { return .no(Unavailable.simulator) }
        #if canImport(AVFoundation) && os(iOS)
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { return .no(Unavailable.noTorch) }
        return .ok
        #else
        return .no(Unavailable.noTorch)
        #endif
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let r = try Self.parse(args)
        let a = Self.availability()
        guard a.available else { throw ToolError("flashlight is not available here: \(a.reason)") }
        #if canImport(AVFoundation) && os(iOS)
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { throw ToolError(Unavailable.noTorch) }
        guard d.isTorchAvailable else { throw ToolError("flashlight is unavailable right now (overheated or in use by the camera)") }
        let wantOn: Bool = switch r.state { case "on": true; case "off": false; default: d.torchMode != .on }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        if wantOn {
            try d.setTorchModeOn(level: min(r.level, AVCaptureDevice.maxAvailableTorchLevel))
        } else {
            d.torchMode = .off
        }
        let on = d.torchMode == .on
        return on ? "flashlight: on (level \(String(format: "%.2f", d.torchLevel)))" : "flashlight: off"
        #else
        throw ToolError(Unavailable.noTorch)
        #endif
    }
}
