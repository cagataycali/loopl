import Foundation
import Observation
import SwiftUI
import Loopl
import LooplUI
import LooplAppleTools

/// Which on-device Apple tools the user has switched on. Separate from
/// `AppSettings.enabledTools` so an existing install (whose saved list predates
/// these tools) gets them ON by default; unavailable tools are never sent to the
/// model whatever the toggle says.
@MainActor @Observable
public final class AppleToolPrefs {
    public static let shared = AppleToolPrefs()
    public var enabled: Set<String> { didSet { UserDefaults.standard.set(Array(enabled), forKey: "loopl.appleTools") } }
    /// open_app schemes that skip the approval card — observable mirror of `OpenAppTool.allowedSchemes` (the tool reads UserDefaults).
    public var openAppSchemes: Set<String> { didSet { OpenAppTool.allowedSchemes = Array(openAppSchemes) } }
    /// Tools this install has already seen — a tool added in an update starts ON even when a saved list exists.
    private static let seenKey = "loopl.appleTools.seen"
    private init() {
        let d = UserDefaults.standard
        let names = Set(AppleTools.names)
        let seen = Set((d.array(forKey: Self.seenKey) as? [String]) ?? [])
        var set = Set((d.array(forKey: "loopl.appleTools") as? [String]) ?? AppleTools.names)
        set.formUnion(names.subtracting(seen))     // new in this build → on by default
        set.formIntersection(names)                // removed tools (apple_intelligence) drop out of the saved list
        enabled = set
        openAppSchemes = Set(OpenAppTool.allowedSchemes)
        d.set(Array(names).sorted(), forKey: Self.seenKey)
    }
    /// The tools the agent gets this turn: switched on AND available on this device right now.
    public var active: [any Tool] {
        AppleTools.all.filter { enabled.contains($0.name) && type(of: $0).availability().available }
    }
}

/// Settings › On-device Apple tools: one row per tool, the one-line "what runs here"
/// copy, and an honest chip when the device cannot run it.
struct AppleToolsSection: View {
    @Bindable var prefs = AppleToolPrefs.shared
    var body: some View {
        Section {
            ForEach(AppleTools.all, id: \.name) { tool in
                let a = type(of: tool).availability()
                Toggle(isOn: Binding(
                    get: { prefs.enabled.contains(tool.name) },
                    set: { on in if on { prefs.enabled.insert(tool.name) } else { prefs.enabled.remove(tool.name) } }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(tool.name).font(.body.monospaced())
                            if !a.available {
                                Text(chip(a.reason)).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
                                    .accessibilityLabel("unavailable: \(a.reason)")
                            }
                        }
                        Text(a.available ? type(of: tool).onDeviceCopy : a.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(LooplDesign.accent)
                if tool.name == OpenAppTool().name, prefs.enabled.contains(tool.name) {
                    NavigationLink {
                        OpenAppAllowlistEditor()
                    } label: {
                        LabeledContent("Open without asking", value: allowlistSummary)
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("openAppAllowlist")
                }
            }
        } header: { Text("On-device Apple tools") } footer: {
            Text("Everything here runs on this iPhone with Apple's own frameworks — no account, no download, nothing sent anywhere. Tools the device cannot run stay greyed and are never offered to the model. open_app leaves loopl, so it shows an approval card first unless you allow its scheme.")
        }
    }
    private var allowlistSummary: String {
        let n = prefs.openAppSchemes.subtracting(["http"]).count
        return n == 0 ? "always ask" : "\(n) scheme\(n == 1 ? "" : "s")"
    }
    private func chip(_ reason: String) -> String {
        if reason.hasPrefix("Needs Apple Intelligence") || reason.contains("Apple Intelligence") { return "Apple Intelligence" }
        if reason.hasPrefix("Not on Simulator") { return "Simulator" }
        if reason.hasPrefix("No ") { return "not on this device" }
        if reason.hasPrefix("Needs iOS") { return String(reason.dropFirst(6)).components(separatedBy: " or").first.map { "iOS \($0)".replacingOccurrences(of: "iOS iOS", with: "iOS") } ?? "unavailable" }
        return "unavailable"
    }
}

/// Settings › open_app › Open without asking: the URL schemes the model may open
/// with no approval card. Known schemes are toggles; anything else can be typed.
struct OpenAppAllowlistEditor: View {
    @Bindable var prefs = AppleToolPrefs.shared
    @State private var custom = ""
    private var allowed: Set<String> {
        get { prefs.openAppSchemes }
        nonmutating set { prefs.openAppSchemes = newValue }
    }
    private var known: [String] { OpenAppTool.knownSchemes.filter { $0 != "http" } }
    private var extras: [String] { allowed.subtracting(known).subtracting(["http"]).sorted() }
    var body: some View {
        Form {
            Section {
                ForEach(known, id: \.self) { scheme in
                    Toggle(isOn: binding(scheme)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(OpenAppTool.appName(for: scheme))
                            Text(scheme == "https" ? "https:// links" : OpenAppTool.schemeLabel(scheme)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .tint(LooplDesign.accent)
                }
            } header: { Text("Open without asking") } footer: {
                Text("Schemes switched on open immediately when the model asks. Everything else shows an approval card with the full URL first. Settings › Network › Ask before set to Never skips the card for all of them.")
            }
            Section("Other schemes") {
                ForEach(extras, id: \.self) { s in
                    Text(OpenAppTool.schemeLabel(s)).font(.body.monospaced())
                        .swipeActions { Button("Remove", role: .destructive) { var a = allowed; a.remove(s); allowed = a } }
                }
                HStack {
                    TextField("scheme, e.g. things", text: $custom)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(addCustom)
                    Button("Add", action: addCustom).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("open_app")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func binding(_ scheme: String) -> Binding<Bool> {
        Binding(get: { allowed.contains(scheme) }, set: { on in
            var a = allowed
            if on { a.insert(scheme); if scheme == "https" { a.insert("http") } }
            else { a.remove(scheme); if scheme == "https" { a.remove("http") } }
            allowed = a
        })
    }
    private func addCustom() {
        let s = custom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "://", with: "").replacingOccurrences(of: ":", with: "")
        guard !s.isEmpty, s.first!.isLetter, s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "+" }) else { return }
        var a = allowed; a.insert(s); allowed = a; custom = ""
    }
}
