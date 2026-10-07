import SwiftUI
import Loopl
import LooplUI
import LooplRuntimes

struct SettingsView: View {
    @State private var storagePushed = false
    @AppStorage("loopl.settings.toolsExpanded") private var toolsExpanded = false
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
                            if case .agent = settings.systemPromptOrigin {
                                Label(settings.systemPromptOrigin.label, systemImage: "sparkles").font(.caption).foregroundStyle(LooplDesign.accent)
                                    .accessibilityIdentifier("settings-system-prompt-origin")
                            }
                        }
                    }
                    .accessibilityIdentifier("settings-system-prompt")
                    ToolsSection(engine: engine, settings: settings)
                } header: { Text("Agent") } footer: {
                    Text("The loop runs until the model stops calling tools or you tap stop. " + ToolsSection.footer(expanded: toolsExpanded))
                }

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
                    Toggle("Show GGUF builds", isOn: $settings.showGGUF).accessibilityIdentifier("settings-show-gguf")
                } header: { Text("Look & feel") } footer: {
                    Text("Haptics: a soft tap when you send, when a tool starts and finishes, when a model is loaded. Performance: a quiet line under the conversation — tokens per second, time to first token, context used. GGUF: llama.cpp builds (text only) in the Models tab, next to the MLX models.")
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
                    Button { NotificationCenter.default.post(name: Onboarding.replay, object: nil) } label: { Label("Show intro again", systemImage: "sparkles") }
                        .accessibilityIdentifier("settings-show-intro")
                } header: { Text("About") } footer: {
                    HStack { Spacer(); LooplMark().frame(width: 36, height: 36).opacity(0.9); Spacer() }.padding(.top, 12)
                }
            }
            .looplScrollClearance()
            .accessibilityIdentifier("pane-settings")
            .navigationDestination(isPresented: $storagePushed) { StorageView(engine: engine, settings: settings, store: store) }   // DEBUG `--design-settings storage`
            .onAppear { if DesignFixture.settingsPane == "storage" { storagePushed = true } }
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
    /// "Revert to the prompt from before the agent's change" — names what comes back (your edit / the default / an earlier agent change).
    private var revertLabel: String {
        guard let previous = settings.systemPromptHistory.last else { return "Revert" }
        switch previous.origin {
        case .default: return "Revert to the default prompt"
        case .user: return "Revert to your prompt"
        case .agent: return "Revert to the previous prompt"
        }
    }
    var body: some View {
        Form {
            // Phase 6 F: when the model changed this prompt (system_prompt tool, after an approval card) say so FIRST,
            // with the way back beside it — the editor below can be 500 pt tall, so this cannot live under it.
            if settings.canRevertSystemPrompt || { if case .agent = settings.systemPromptOrigin { true } else { false } }() {
                Section {
                    if case .agent = settings.systemPromptOrigin {
                        Label(settings.systemPromptOrigin.label, systemImage: "sparkles").foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine).accessibilityIdentifier("system-prompt-origin")
                    }
                    if settings.canRevertSystemPrompt {
                        Button { LooplDesign.haptic(); settings.revertSystemPrompt() } label: {
                            Label(revertLabel, systemImage: "arrow.uturn.backward")
                        }
                        .accessibilityIdentifier("system-prompt-revert")
                    }
                } footer: { Text("Changed by the model through the system_prompt tool, after you approved it. Revert puts the previous prompt back.") }
            }
            Section {
                TextEditor(text: $settings.systemPrompt).frame(minHeight: 180).font(.body)
                    .accessibilityIdentifier("system-prompt-editor")
            } footer: {
                Text("Sent at the start of every conversation, to every model — nothing is added in front of it. When you ask for a standing rule, the model can change this with the system_prompt tool; each change asks you first.")
            }
            Section {
                Button("Reset to default") { settings.systemPrompt = AppSettings.defaultSystemPrompt }
                    .disabled(settings.systemPrompt == AppSettings.defaultSystemPrompt)
            }
        }
        .looplScrollClearance()
        .navigationTitle("System prompt")
        .navigationBarTitleDisplayMode(.inline)
    }
}
