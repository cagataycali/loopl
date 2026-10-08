import SwiftUI
import Loopl
#if canImport(MapKit)
import MapKit
#endif

// Controls: a tool result may carry a typed `ToolControl`; the tool row draws it live under the row and a tap
// runs the SAME tool with the given args through the host's normal dispatch (`ToolControlHandler`). The view never calls a
// tool itself and never hides anything: the row still shows the arguments and the result text; the control is a shortcut.

/// How a tap reaches the host: `(toolUseId of the row, the action)`. The host (loopl's Engine) runs it through the
/// agent — hooks, approval policy, registry — and feeds the fresh result back into the SAME row
/// (`Transcript.applyControlResult`). `nil` in the environment = controls are shown but disabled (no model loaded,
/// a turn is running, a static capture).
public struct ToolControlHandler: Sendable {
    public var run: @Sendable @MainActor (String, ControlAction) -> Void
    public init(_ run: @Sendable @MainActor @escaping (String, ControlAction) -> Void) { self.run = run }
}

public extension EnvironmentValues {
    /// The host's dispatcher for control taps (see `ToolControlHandler`).
    @Entry var looplControlHandler: ToolControlHandler? = nil
    /// Tool-use ids whose control tap is in flight — the control dims and shows the thin sweep until the result lands.
    @Entry var looplControlBusy: Set<String> = []
}

/// Draws one `ToolControl` for the row `toolUseId`. Compact, one line where it can be; everything is a real `Button`
/// (VoiceOver reads the state: "Turn off, currently on") with stable identifiers for UI tests (`control-*`).
public struct ToolControlView: View {
    public var control: ToolControl
    public var toolUseId: String
    /// How many times this row's control was tapped (the result shown is the latest one) — a quiet caption when > 0.
    public var taps: Int
    @Environment(\.looplControlHandler) private var handler
    @Environment(\.looplControlBusy) private var busySet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    public init(control: ToolControl, toolUseId: String, taps: Int = 0) { self.control = control; self.toolUseId = toolUseId; self.taps = taps }

    private var busy: Bool { busySet.contains(toolUseId) }
    private var enabled: Bool { handler != nil && !busy }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch control {
            case .toggle(let label, let on, let action): toggle(label, on: on, action)
            case .button(let label, let action): button(label, action)
            case .player(let p): PlayerControl(player: p, enabled: enabled) { run($0) }
            case .mapPin(let lat, let lon, let label): MapPinControl(lat: lat, lon: lon, label: label)
            case .timer(let until, let label): TimerControl(until: until, label: label)
            case .link(let label, let url): link(label, url)
            }
            if busy {
                IndeterminateBar().transition(.opacity)
                    .accessibilityLabel("running")
            } else if taps > 0 {
                Text(taps == 1 ? "updated by your tap" : "updated by your taps (\(taps))")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("control-taps")
            }
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-control-\(control.typeName)")
    }

    private func run(_ action: ControlAction) { handler?.run(toolUseId, action) }

    // MARK: pieces

    private func toggle(_ label: String, on: Bool, _ action: ControlAction) -> some View {
        Button { run(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(on ? LooplDesign.accent : Color.secondary)
                    .accessibilityHidden(true)
                Text(label)
            }
        }
        .buttonStyle(ControlChipStyle())
        .disabled(!enabled)
        .accessibilityLabel("\(label), currently \(on ? "on" : "off")")
        .accessibilityHint("runs the \(action.tool) tool")
        .accessibilityIdentifier("control-toggle")
    }

    private func button(_ label: String, _ action: ControlAction) -> some View {
        Button { run(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise").accessibilityHidden(true)
                Text(label)
            }
        }
        .buttonStyle(ControlChipStyle())
        .disabled(!enabled)
        .accessibilityHint("runs the \(action.tool) tool again")
        .accessibilityIdentifier("control-button")
    }

    private func link(_ label: String, _ url: String) -> some View {
        Button {
            if let u = URL(string: url) { openURL(u) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app").accessibilityHidden(true)
                Text(label)
            }
        }
        .buttonStyle(ControlChipStyle())
        .disabled(URL(string: url) == nil)
        .accessibilityHint("opens another app")
        .accessibilityIdentifier("control-link")
    }
}

/// The chip every control button wears: capsule, secondary fill, 40 pt tall like the composer's controls (never
/// smaller than 44 pt wide), accent text. Pressed → dims.
struct ControlChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? LooplDesign.accent : Color.secondary)
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: LooplDesign.controlSide)
            .background(LooplDesign.controlFill, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// Mini player: title · subtitle, previous / play-pause / next, and a volume slider when the level is known.
/// Every button is a `ControlAction` on the player's tool (`music`), using that tool's own `action` enum.
struct PlayerControl: View {
    var player: ToolControl.Player
    var enabled: Bool
    var run: (ControlAction) -> Void
    @State private var volume: Double = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.title).font(.callout.weight(.medium)).lineLimit(1)
                    if let s = player.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("control-player-title")
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                HStack(spacing: 4) {
                    transport("backward.fill", "Previous song", "control-previous", ["action": .string("previous")])
                    transport(player.playing ? "pause.fill" : "play.fill", player.playing ? "Pause" : "Play", "control-play-pause",
                              ["action": .string(player.playing ? "pause" : "play")])
                    transport("forward.fill", "Next song", "control-next", ["action": .string("next")])
                }
            }
            if let v = player.volume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $volume, in: 0...100, step: 1) { editing in
                        if !editing { run(ControlAction(tool: player.tool, args: ["action": .string("volume"), "level": .number(volume.rounded())])) }
                    }
                    .tint(LooplDesign.accent)
                    .disabled(!enabled)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(volume)) percent")
                    .accessibilityIdentifier("control-volume")
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .onAppear { volume = Double(v) }
                .onChange(of: v) { _, new in volume = Double(new) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LooplDesign.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // A container, so the buttons keep their OWN identifiers (an identifier on a plain stack propagates to every child).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("control-player")
    }

    private func transport(_ symbol: String, _ label: String, _ id: String, _ args: [String: JSONValue]) -> some View {
        Button { run(ControlAction(tool: player.tool, args: args)) } label: {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .frame(width: LooplDesign.controlSide, height: LooplDesign.controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A pin on a small, non-interactive map. Tap → Apple Maps at the pin. Falls back to a labelled coordinate line where
/// MapKit is not available (the text result above already carries the coordinates — nothing is lost).
struct MapPinControl: View {
    var lat: Double
    var lon: Double
    var label: String?
    @Environment(\.looplStaticRender) private var staticRender

    var body: some View {
        #if canImport(MapKit)
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        Button { open(coord) } label: {
            ZStack(alignment: .bottomLeading) {
                if staticRender {
                    // Static captures (share image) cannot wait for tiles: a flat placeholder with the pin.
                    Rectangle().fill(LooplDesign.controlFill)
                    Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(LooplDesign.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))),
                        interactionModes: []) {
                        Marker(label ?? "Here", coordinate: coord).tint(LooplDesign.accent)
                    }
                    .allowsHitTesting(false)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app").font(.caption2)
                    Text("Open in Maps").font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map: \(label ?? "your location"), \(lat), \(lon)")
        .accessibilityHint("opens in Maps")
        .accessibilityIdentifier("control-map")
        #else
        Text("\(label ?? "location") · \(lat), \(lon)").font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("control-map")
        #endif
    }

    #if canImport(MapKit)
    private func open(_ c: CLLocationCoordinate2D) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = label ?? "Location"
        item.openInMaps()
    }
    #endif
}

/// Counts down to `until` once a second; past it, says "done". Reduce Motion is irrelevant (text only).
struct TimerControl: View {
    var until: Date
    var label: String?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let remaining = until.timeIntervalSince(ctx.date)
            HStack(spacing: 8) {
                Image(systemName: remaining > 0 ? "timer" : "checkmark.circle").foregroundStyle(LooplDesign.accent).accessibilityHidden(true)
                if let label { Text(label).font(.callout) }
                Text(remaining > 0 ? Self.format(remaining) : "done")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label ?? "timer"): \(remaining > 0 ? Self.format(remaining) + " left" : "done")")
        }
        .padding(.horizontal, 14).frame(minHeight: LooplDesign.controlSide)
        .background(LooplDesign.controlFill, in: Capsule())
        .accessibilityIdentifier("control-timer")
    }
    static func format(_ s: TimeInterval) -> String {
        let t = Int(s.rounded(.up))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

#Preview("Controls") {
    VStack(alignment: .leading, spacing: 16) {
        ToolControlView(control: .toggle(label: "Turn off", on: true, action: ControlAction(tool: "flashlight", args: ["state": .string("off")])), toolUseId: "a")
        ToolControlView(control: .button(label: "Vibrate again", action: ControlAction(tool: "vibrate", args: ["pattern": .string("double")])), toolUseId: "b", taps: 1)
        ToolControlView(control: .player(.init(title: "Teardrop", subtitle: "Massive Attack · Mezzanine", playing: true, volume: 40)), toolUseId: "c")
        ToolControlView(control: .mapPin(lat: 40.744, lon: -74.0324, label: "Hoboken"), toolUseId: "d")
        ToolControlView(control: .timer(until: Date().addingTimeInterval(95), label: "Tea"), toolUseId: "e")
        ToolControlView(control: .link(label: "Open in Calendar", url: "calshow:"), toolUseId: "f")
    }
    .padding()
    .environment(\.looplControlHandler, ToolControlHandler { _, _ in })
}
