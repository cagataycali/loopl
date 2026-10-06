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
        let core = engine.allTools.map { t in
            ToolListing.Row(name: t.name, copy: ToolListing.coreCopy[t.name] ?? t.description, defaultOn: true, enabled: settings.enabledTools.contains(t.name))
        }
        let apple = AppleTools.all.map { t -> ToolListing.Row in
            var a = type(of: t).availability()
            if runtime != nil, t.redundantWithRuntime == runtime, a.available {
                a = .no("Not offered to \(runtime?.label ?? "this model") — it is \(runtime?.label ?? "this model"). Other models get it.")
            }
            return ToolListing.Row(name: t.name, copy: type(of: t).onDeviceCopy, defaultOn: type(of: t).defaultOn, available: a.available, reason: a.reason,
                                   enabled: prefs.enabled.contains(t.name))
        }
        return ToolListing(core + apple)
    }

    var body: some View {
        let listing = self.listing
        DisclosureGroup(isExpanded: $expanded) {
            group("On", listing.on, empty: "Nothing — the model answers from what it knows.")
            group("Off", listing.off, empty: "Everything is on.")
            createdGroup
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
        ? "The model only sees the tools under On. Fewer tools help small models — the everyday set is on by default, the rest wait here. Everything runs on this device; on-device tools ask for their iOS permission the first time they run, never at install. Settings › Network › Ask before decides when an approval card is shown."
        : "The model only sees the tools that are on. Tap Tools to see every one and switch them on or off."
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
            ToolToggleRow(row: row, isOn: binding(row.name)).disabled(!row.available)
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

    /// Tools the model wrote itself (`manage_tools create`): name, language, status, one line of its description; tap for
    /// the source, swipe (or the row's Delete) to remove it — the model loses it on its next call.
    @ViewBuilder private var createdGroup: some View {
        let created = engine.createdTools
        HStack {
            Text("CREATED BY THE AGENT").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            Spacer()
            Text("\(created.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
        .accessibilityIdentifier("settings-tools-group-created")
        .accessibilityElement(children: .combine)
        if created.isEmpty {
            Text(CreatedToolRow.emptyCopy).font(.footnote).foregroundStyle(.tertiary).accessibilityIdentifier("settings-tools-created-empty")
        }
        ForEach(created) { record in
            NavigationLink {
                CreatedToolSourceView(record: record, engine: engine)
            } label: {
                CreatedToolRow(record: record)
            }
            .accessibilityIdentifier("createdTool.\(record.name)")
            .swipeActions(edge: .trailing) {
                Button("Delete", role: .destructive) { Task { await engine.deleteCreatedTool(record.name) } }
            }
        }
    }

    private func binding(_ name: String) -> Binding<Bool> {
        if engine.allTools.contains(where: { $0.name == name }) {
            return Binding(get: { settings.enabledTools.contains(name) },
                           set: { on in if on { settings.enabledTools.insert(name) } else { settings.enabledTools.remove(name) } })
        }
        return Binding(get: { prefs.enabled.contains(name) },
                       set: { on in if on { prefs.enabled.insert(name) } else { prefs.enabled.remove(name) } })
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
                HStack(spacing: 8) {
                    Text(row.defaultTag).accessibilityIdentifier("tool.\(row.name).default")
                    if let ask = row.asksFirst {
                        Text("·").accessibilityHidden(true)
                        Label(ask, systemImage: "hand.raised").labelStyle(.titleOnly).accessibilityIdentifier("tool.\(row.name).asksFirst")
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

/// One agent-written tool in Settings › Tools.
struct CreatedToolRow: View {
    let record: DynamicToolRecord
    static var emptyCopy: String {
        #if os(macOS)
        "None yet. When the model needs a tool it does not have, it writes one in Swift and loads it here."
        #else
        "None yet. When the model needs a tool it does not have, it writes one in JavaScript and loads it here — Swift it writes is kept for your Mac."
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.name).font(.body.monospaced())
                Text(record.language == .swift ? "Swift" : "JavaScript").font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
                if !record.status.isActive {
                    Text(record.status.label).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(record.status.label == "failed" ? AnyShapeStyle(.red.opacity(0.15)) : AnyShapeStyle(.quaternary), in: Capsule())
                        .foregroundStyle(record.status.label == "failed" ? .red : .secondary)
                }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(record.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
    var subtitle: String {
        switch record.status {
        case .active: return record.description.isEmpty ? "Live — the model can call it." : record.description
        case .saved(let why): return why
        case .failed(let err): return "Failed to load: " + (err.split(separator: "\n").first.map(String.init) ?? err)
        }
    }
}

/// The source the model wrote, read-only, with Delete.
struct CreatedToolSourceView: View {
    let record: DynamicToolRecord
    let engine: Engine
    @State private var source: String?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CreatedToolRow(record: record)
                if case .failed(let err) = record.status {
                    Text(err).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                }
                Text(source ?? "Loading…").font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("createdTool-source")
                Text(record.language == .swift
                     ? "Compiled on a Mac with swiftc and loaded as a library after a sandboxed check. Each call crosses a small C ABI as JSON."
                     : "Runs in JavaScriptCore on this device: a fresh context per call, no eval, a 30 s limit. `loopl.call` reaches the other tools you have on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(record.name)
        .toolbar {
            Button("Delete", role: .destructive) { confirmDelete = true }.accessibilityIdentifier("createdTool-delete")
        }
        .confirmationDialog("Delete \(record.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete tool", role: .destructive) { Task { await engine.deleteCreatedTool(record.name); dismiss() } }
        } message: { Text("The model loses this tool on its next call. Its source is removed from this device.") }
        .task { source = await engine.createdToolSource(record.name) }
    }
}
