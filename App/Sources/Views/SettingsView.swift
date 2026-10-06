import SwiftUI
import Loopl
import LooplUI
import LooplRuntimes

struct SettingsView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var store: ModelStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        SystemPromptEditor(settings: settings)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("System prompt")
                            Text(settings.systemPrompt).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    NavigationLink {
                        ToolsEditor(engine: engine, settings: settings)
                    } label: {
                        LabeledContent("Tools", value: settings.enabledTools.isEmpty ? "off" : "\(settings.enabledTools.count) of \(engine.allTools.count)")
                    }
                    .accessibilityIdentifier("settings-tools")
                } header: { Text("Agent") } footer: {
                    Text("The loop runs until the model stops calling tools or you tap stop. Context and output length follow the model's recommended maximum.")
                }

                AppleToolsSection(activeRuntime: engine.loadedModel?.runtime)

                Section {
                    Toggle(isOn: $settings.offline) { Label("Offline mode", systemImage: LooplDesign.iconOffline) }
                    Picker(selection: $settings.askBefore) {
                        Text("Every request").tag(ApprovalPolicy.Mode.always)
                        Text("Writes only").tag(ApprovalPolicy.Mode.mutating)
                        Text("Never").tag(ApprovalPolicy.Mode.never)
                    } label: { Label("Ask before", systemImage: "hand.raised") }
                } header: { Text("Network") } footer: {
                    Text(askBeforeFooter)
                }

                HuggingFaceSection(hf: engine.hf, settings: settings)

                Section {
                    Picker(selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                    Toggle(isOn: $settings.haptics) { Label("Haptics", systemImage: "hand.tap") }
                    Toggle("Show performance details", isOn: $settings.showPerformance)
                } header: { Text("Look & feel") } footer: {
                    Text("Haptics: a soft tap when you send, when a tool starts and finishes, when a model is loaded. Performance: a quiet line under the conversation — tokens per second, time to first token, context used.")
                }

                Section {
                    NavigationLink {
                        StorageView(engine: engine, settings: settings, store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Storage", systemImage: "externaldrive")
                            Text(storageSummary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier("settings-storage")
                } footer: {
                    Text("Keep models on the iPhone or on a USB-C drive — plug one in and pick a folder.")
                }

                Section {
                    LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    LabeledContent("Device memory", value: MemoryBudget.label(MemoryBudget.physical))
                    runtimeStatus("MLX", MLXModel.availability())
                    runtimeStatus("Apple Intelligence", AppleFoundationModel.availability())
                    runtimeStatus("llama.cpp", GGUFModel.availability())
                    Link(destination: URL(string: "https://loopl.dev/privacy")!) { Label("Privacy — nothing leaves the device", systemImage: "hand.raised") }
                    Link(destination: URL(string: "https://loopl.dev")!) { Label("loopl.dev", systemImage: "book") }
                    Link(destination: URL(string: "https://github.com/cagataycali/loopl")!) { Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                } header: { Text("About") } footer: {
                    HStack { Spacer(); LooplMark().frame(width: 36, height: 36).opacity(0.9); Spacer() }.padding(.top, 12)
                }
            }
            .looplScrollClearance()
            .accessibilityIdentifier("pane-settings")
            .navigationTitle("Settings")
        }
    }

    private var storageSummary: String {
        var parts = ["\(ByteSize.label(store.diskUsed)) on this iPhone"]
        for v in store.storage.volumes { parts.append(v.connected ? "\(ByteSize.label(v.used)) on \(v.name)" : "\(v.name) not connected") }
        return parts.joined(separator: " · ")
    }

    private var askBeforeFooter: String {
        let base = "Offline mode refuses every network call: downloads and the http tool. "
        switch settings.askBefore {
        case .always: return base + "Ask before: every http request shows an approval card first."
        case .mutating: return base + "Ask before: GET and HEAD run; POST, PUT, PATCH and DELETE wait for your approval (2 minutes, then denied)."
        case .never: return base + "Ask before is off — the model's http calls run without asking."
        }
    }

    private func runtimeStatus(_ name: String, _ a: RuntimeAvailability) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
            Spacer()
            if a.available { Image(systemName: "checkmark.circle.fill").foregroundStyle(LooplDesign.accent).accessibilityLabel("available") }
            else { Text(a.reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        }
    }
}

struct SystemPromptEditor: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                TextEditor(text: $settings.systemPrompt).frame(minHeight: 180).font(.body)
            } footer: { Text("Sent at the start of every conversation.") }
            Section { Button("Reset to default") { settings.systemPrompt = AppSettings.defaultSystemPrompt } }
        }
        .looplScrollClearance()
        .navigationTitle("System prompt")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ToolsEditor: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                ForEach(engine.allTools, id: \.name) { tool in
                    Toggle(isOn: Binding(
                        get: { settings.enabledTools.contains(tool.name) },
                        set: { on in if on { settings.enabledTools.insert(tool.name) } else { settings.enabledTools.remove(tool.name) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.body.monospaced())
                            Text(tool.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("http is refused while offline mode is on — the agent sees the refusal as a tool error and answers without it. Writes ask for your approval first (Settings › Ask before).")
            }
        }
        .looplScrollClearance()
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}
