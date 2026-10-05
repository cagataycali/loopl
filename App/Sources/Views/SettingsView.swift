import SwiftUI
import Loopl
import LooplUI
import LooplRuntimes

struct SettingsView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var store: ModelStore
    @State private var confirmClear = false
    @State private var confirmHistory = false

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
                } header: { Text("Agent") } footer: {
                    Text("The loop runs until the model stops calling tools or you tap stop. Context and output length follow the model's recommended maximum.")
                }

                Section {
                    Toggle(isOn: $settings.offline) { Label("Offline mode", systemImage: LooplDesign.iconOffline) }
                } header: { Text("Network") } footer: {
                    Text("Refuses every network call: downloads and http_get. Models already on this device load and run normally.")
                }

                Section {
                    Toggle("Show performance details", isOn: $settings.showPerformance)
                } footer: {
                    Text("A quiet line under the conversation: tokens per second, time to first token, context used.")
                }

                Section("Storage") {
                    LabeledContent("Models on device", value: ByteCountFormatter.string(fromByteCount: store.diskUsed, countStyle: .file))
                    Button("Delete all downloaded models", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Delete every downloaded model?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Delete all", role: .destructive) { Task { await engine.unload() }; store.deleteAll(); settings.lastModelId = nil }
                        }
                    Button("Delete conversation history", role: .destructive) { confirmHistory = true }
                        .confirmationDialog("Delete all saved conversations?", isPresented: $confirmHistory, titleVisibility: .visible) {
                            Button("Delete history", role: .destructive) { engine.archive.deleteAll(); engine.clear() }
                        }
                        .disabled(engine.archive.conversations.isEmpty)
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
            .navigationTitle("Settings")
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
                Text("http_get is refused while offline mode is on — the agent sees the refusal as a tool error and answers without it.")
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}
