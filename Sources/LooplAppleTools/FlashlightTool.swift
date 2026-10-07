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
    public static let onDeviceCopy = "Turns the flashlight on and off. No camera access, nothing recorded."
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
        if TorchStore.isFixture { return .ok }
        if Unavailable.isSimulator { return .no(Unavailable.simulator) }
        #if canImport(AVFoundation) && os(iOS)
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { return .no(Unavailable.noTorch) }
        return .ok
        #else
        return .no(Unavailable.noTorch)
        #endif
    }

    /// The control under the result (Phase 7): on → "Turn off" (runs `{state: off}`), off → "Turn on" (runs `{state: on}`,
    /// full brightness — the LED reports level 0 once off, so there is no "same level" to keep). The TOOL attaches it —
    /// the model never emits controls.
    public static func control(on: Bool, level: Float) -> ToolControl {
        .toggle(label: on ? "Turn off" : "Turn on", on: on, action: ControlAction(tool: "flashlight", args: ["state": .string(on ? "off" : "on")]))
    }

    /// The text the model reads.
    public static func render(on: Bool, level: Float) -> String {
        on ? "flashlight: on (level \(String(format: "%.2f", level)))" : "flashlight: off"
    }

    public func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }

    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let r = try Self.parse(args)
        let a = Self.availability()
        guard a.available else { throw ToolError("flashlight is not available here: \(a.reason)") }
        let torch = TorchStore.current
        let wantOn: Bool = switch r.state { case "on": true; case "off": false; default: try !torch.isOn() }
        let state = try torch.set(on: wantOn, level: r.level)
        return ToolOutput(text: Self.render(on: state.on, level: state.level), control: Self.control(on: state.on, level: state.level))
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}

/// The torch behind `flashlight`: `SystemTorch` (AVCaptureDevice) on an iPhone, `FixtureTorch` in tests and design
/// fixtures — the seam that lets a Simulator prove "tap Turn off → flashlight: off" (Phase 7).
public protocol TorchSource: Sendable {
    func isOn() throws -> Bool
    /// Sets the LED and returns the state it actually ended in.
    func set(on: Bool, level: Float) throws -> (on: Bool, level: Float)
}

public final class FixtureTorch: TorchSource, @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var level: Float = 1
    public private(set) var calls: [(on: Bool, level: Float)] = []
    public init(on: Bool = false) { self.on = on }
    public func isOn() throws -> Bool { lock.lock(); defer { lock.unlock() }; return on }
    public func set(on: Bool, level: Float) throws -> (on: Bool, level: Float) {
        lock.lock(); defer { lock.unlock() }
        self.on = on; if on { self.level = level }
        calls.append((on, level))
        return (on, on ? self.level : 0)
    }
}

public enum TorchStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: (any TorchSource)?
    /// Tests / fixtures install a `FixtureTorch`; `nil` restores the hardware.
    public static func use(_ source: (any TorchSource)?) { lock.lock(); override = source; lock.unlock() }
    public static var isFixture: Bool { lock.lock(); defer { lock.unlock() }; return override != nil }
    static var current: any TorchSource {
        lock.lock(); defer { lock.unlock() }
        if let o = override { return o }
        return SystemTorch()
    }
}

struct SystemTorch: TorchSource {
    func isOn() throws -> Bool {
        #if canImport(AVFoundation) && os(iOS)
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { throw ToolError(Unavailable.noTorch) }
        return d.torchMode == .on
        #else
        throw ToolError(Unavailable.noTorch)
        #endif
    }
    func set(on: Bool, level: Float) throws -> (on: Bool, level: Float) {
        #if canImport(AVFoundation) && os(iOS)
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { throw ToolError(Unavailable.noTorch) }
        guard d.isTorchAvailable else { throw ToolError("flashlight is unavailable right now (overheated or in use by the camera)") }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        if on {
            try d.setTorchModeOn(level: min(level, AVCaptureDevice.maxAvailableTorchLevel))
        } else {
            d.torchMode = .off
        }
        return (d.torchMode == .on, d.torchLevel)
        #else
        throw ToolError(Unavailable.noTorch)
        #endif
    }
}
