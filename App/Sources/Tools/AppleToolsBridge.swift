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
    private init() {
        enabled = Set((UserDefaults.standard.array(forKey: "loopl.appleTools") as? [String]) ?? AppleTools.names)
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
            }
        } header: { Text("On-device Apple tools") } footer: {
            Text("Everything here runs on this iPhone with Apple's own frameworks — no account, no download, nothing sent anywhere. Tools the device cannot run stay greyed and are never offered to the model.")
        }
    }
    private func chip(_ reason: String) -> String {
        if reason.hasPrefix("Needs Apple Intelligence") || reason.contains("Apple Intelligence") { return "Apple Intelligence" }
        if reason.hasPrefix("Not on Simulator") { return "Simulator" }
        if reason.hasPrefix("Needs iOS") { return String(reason.dropFirst(6)).components(separatedBy: " or").first.map { "iOS \($0)".replacingOccurrences(of: "iOS iOS", with: "iOS") } ?? "unavailable" }
        return "unavailable"
    }
}
