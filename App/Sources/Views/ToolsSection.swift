import SwiftUI
import Loopl
import LooplUI
import LooplRuntimes
import LooplAppleTools

/// Settings › Tools — ONE collapsible section for every tool the model can be offered, portable and on-device alike,
/// grouped by what the model actually gets (On / Off). Each row: toggle, one line of copy, "on/off by default", the
/// reason when this device cannot run it (greyed, toggle disabled), and "Asks before …" where an approval card applies.
/// Nothing tool-related lives anywhere else in Settings (owner, 2026-10-06). `ToolListing` holds the data + grouping.
struct ToolsSection: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var prefs = AppleToolPrefs.shared
    @AppStorage("loopl.settings.toolsExpanded") private var expanded = false

    private var listing: ToolListing {
        let runtime = engine.loadedModel?.runtime
        let here = Set(engine.mountedNow)
        let core = engine.allTools.map { t in
            ToolListing.Row(name: t.name, copy: ToolListing.coreCopy[t.name] ?? t.description, defaultOn: true, enabled: settings.enabledTools.contains(t.name),
                            mountedHere: here.contains(t.name))
        }
        let manage = ToolListing.Row(name: ManageToolsTool.toolName, copy: ToolListing.coreCopy[ManageToolsTool.toolName] ?? "", defaultOn: true, enabled: true,
                                     mountedHere: true, pinned: true)
        let apple = AppleTools.all.map { t -> ToolListing.Row in
            var a = type(of: t).availability()
            if runtime != nil, t.redundantWithRuntime == runtime, a.available {
                a = .no("Not offered to \(runtime?.label ?? "this model") — it is \(runtime?.label ?? "this model"). Other models get it.")
            }
            return ToolListing.Row(name: t.name, copy: type(of: t).onDeviceCopy, defaultOn: type(of: t).defaultOn, available: a.available, reason: a.reason,
                                   enabled: prefs.enabled.contains(t.name), mountedHere: here.contains(t.name))
        }
        return ToolListing(core + [manage] + apple)
    }

    var body: some View {
        let listing = self.listing
        DisclosureGroup(isExpanded: $expanded) {
            if let note = listing.conversationNote {
                Label(note, systemImage: "wrench.adjustable").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore).accessibilityLabel(note)
                    .accessibilityIdentifier("settings-tools-conversation-note")
            }
            group("On", listing.on, empty: "Nothing — the model answers from what it knows.")
            group("Off", listing.off, empty: "Everything is on.")
        } label: {
            LabeledContent {
                Text(listing.summary).foregroundStyle(.secondary).accessibilityIdentifier("settings-tools-summary")
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }   // a List row's DisclosureGroup ignores XCUITest taps on its own id
            .accessibilityIdentifier("settings-tools")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "expanded" : "collapsed")
        }
        .tint(LooplDesign.accent)
    }

    /// Footer for the section that holds the disclosure — one sentence collapsed, the rules when open.
    static func footer(expanded: Bool) -> String {
        expanded
        ? "The model only sees the tools that are on. Fewer tools help a small model, so the everyday set is on and the rest wait here — the model can still switch one on for a single conversation when it needs it. Everything runs on this \(LooplDesign.deviceName); a tool that needs an iOS permission asks for it the first time it runs. Settings › Network › Ask before decides when you are asked first."
        : "It sees only the tools that are on (it can switch one on for a conversation). Tap Tools to choose."
    }

    @ViewBuilder private func group(_ title: String, _ rows: [ToolListing.Row], empty: String) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            Spacer()
            Text("\(rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
        .accessibilityIdentifier("settings-tools-group-\(title.lowercased())")
        .accessibilityElement(children: .combine)
        if rows.isEmpty {
            Text(empty).font(.footnote).foregroundStyle(.tertiary)
        }
        ForEach(rows) { row in
            ToolToggleRow(row: row, isOn: binding(row.name)).disabled(!row.available || row.pinned)
            if row.name == OpenAppTool().name, row.offered {
                NavigationLink {
                    OpenAppAllowlistEditor()
                } label: {
                    LabeledContent("Open without asking", value: allowlistSummary).font(.subheadline)
                }
                .accessibilityIdentifier("openAppAllowlist")
            }
            if row.name == LocationTool().name, row.offered {
                Toggle(isOn: $prefs.preciseLocation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Exact position").font(.subheadline)
                        Text(prefs.preciseLocation ? "The model gets your position within metres." : "The model gets your city and coordinates rounded to about 1 km.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(LooplDesign.accent)
                .accessibilityIdentifier("locationPrecise")
            }
        }
    }

    private func binding(_ name: String) -> Binding<Bool> {
        if name == ManageToolsTool.toolName { return .constant(true) }
        if engine.allTools.contains(where: { $0.name == name }) {
            return Binding(get: { settings.enabledTools.contains(name) },
                           set: { on in if on { settings.enabledTools.insert(name) } else { settings.enabledTools.remove(name) }; engine.settingsToggled(name, on: on) })
        }
        return Binding(get: { prefs.enabled.contains(name) },
                       set: { on in if on { prefs.enabled.insert(name) } else { prefs.enabled.remove(name) }; engine.settingsToggled(name, on: on) })
    }

    private var allowlistSummary: String {
        let n = prefs.openAppSchemes.subtracting(["http"]).count
        return n == 0 ? "always ask" : "\(n) scheme\(n == 1 ? "" : "s")"
    }
}

/// One tool: toggle · `name` · copy · tags (default, asks first) · reason when the device cannot run it.
struct ToolToggleRow: View {
    let row: ToolListing.Row
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.body.monospaced())
                    if !row.available {
                        Text(ToolToggleRow.chip(row.reason)).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
                            .accessibilityLabel("unavailable: \(row.reason)")
                    }
                }
                Text(row.available ? row.copy : row.reason).font(.caption).foregroundStyle(.secondary)
                // "on by default · mounted for this conversation" on one line; the approval note gets its OWN line —
                // in one HStack SwiftUI left it whatever width the tag did not use, so "Asks before POST, PUT, PATCH
                // or DELETE — reads go through." wrapped into a ragged ~150 pt column on the 16 Pro as well as the SE.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(row.defaultTag).accessibilityIdentifier("tool.\(row.name).default")
                        if let tag = row.conversationTag {
                            Text("·").accessibilityHidden(true)
                            Text(tag).foregroundStyle(LooplDesign.accent).accessibilityIdentifier("tool.\(row.name).conversation")
                        }
                    }
                    if let ask = row.asksFirst {
                        Label(ask, systemImage: "hand.raised").labelStyle(.titleOnly)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("tool.\(row.name).asksFirst")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .tint(LooplDesign.accent)
        .accessibilityIdentifier("tool.\(row.name)")
    }

    static func chip(_ reason: String) -> String {
        if reason.contains("Apple Intelligence") { return "Apple Intelligence" }
        if reason.hasPrefix("Not on Simulator") { return "Simulator" }
        if reason.hasPrefix("Not offered") { return "not offered" }
        if reason.hasPrefix("No ") { return "not on this device" }
        if reason.hasPrefix("Needs iOS") { return String(reason.dropFirst(6)).components(separatedBy: " or").first.map { "iOS \($0)".replacingOccurrences(of: "iOS iOS", with: "iOS") } ?? "unavailable" }
        return "unavailable"
    }
}
