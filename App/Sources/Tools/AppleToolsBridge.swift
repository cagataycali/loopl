import Foundation
import Observation
import SwiftUI
import Loopl
import LooplUI
import LooplAppleTools

/// Which on-device Apple tools the user has switched on. Separate from
/// `AppSettings.enabledTools` so an existing install (whose saved list predates
/// these tools) gets the DEFAULT-ON ones switched on (`AppleTool.defaultOn`; the
/// rest stay off — fewer tools help small models); unavailable tools are never
/// sent to the model whatever the toggle says.
@MainActor @Observable
public final class AppleToolPrefs {
    public static let shared = AppleToolPrefs()
    public var enabled: Set<String> { didSet { UserDefaults.standard.set(Array(enabled), forKey: "loopl.appleTools") } }
    /// open_app schemes that skip the approval card — observable mirror of `OpenAppTool.allowedSchemes` (the tool reads UserDefaults).
    public var openAppSchemes: Set<String> { didSet { OpenAppTool.allowedSchemes = Array(openAppSchemes) } }
    /// location: exact position instead of ~1 km — the PERSON's switch (a 0.8B set a `precise` argument true 9/9 times, so the model has none).
    public var preciseLocation: Bool { didSet { LocationTool.precise = preciseLocation } }
    /// Tools this install has already seen — a tool added in an update starts ON even when a saved list exists.
    private static let seenKey = "loopl.appleTools.seen"
    /// Tools that were default-OFF when first shipped and are default-ON now (once-only switch-on, see init).
    static let laterDefaultOn: Set<String> = ["location"]
    private static let flippedOnKey = "loopl.appleTools.flippedOn"
    private init() {
        let d = UserDefaults.standard
        let names = Set(AppleTools.names)
        let seen = Set((d.array(forKey: Self.seenKey) as? [String]) ?? [])
        var set = Set((d.array(forKey: "loopl.appleTools") as? [String]) ?? AppleTools.defaultOnNames)
        set.formUnion(names.subtracting(seen).filter(AppleTools.isDefaultOn))     // new in this build → on only when the tool is default-on
        // A tool whose default flipped to ON in a later build switches on ONCE for installs that already had it off
        // (STOP-LOCATION 2026-10-07: `location` shipped off; the owner's "not working" was partly the model saying it
        // could not). Switching it off again afterwards is respected — the flip is recorded.
        let flipped = Set((d.array(forKey: Self.flippedOnKey) as? [String]) ?? [])
        set.formUnion(Self.laterDefaultOn.subtracting(flipped).filter(AppleTools.isDefaultOn))
        d.set(Array(Self.laterDefaultOn).sorted(), forKey: Self.flippedOnKey)
        set.formIntersection(names)                // removed tools (apple_intelligence) drop out of the saved list
        enabled = set
        openAppSchemes = Set(OpenAppTool.allowedSchemes)
        preciseLocation = LocationTool.precise
        d.set(Array(names).sorted(), forKey: Self.seenKey)
    }
    /// The tools the agent gets this turn: switched on AND available on this device right now.
    public var active: [any Tool] {
        AppleTools.all.filter { enabled.contains($0.name) && type(of: $0).availability().available }
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
