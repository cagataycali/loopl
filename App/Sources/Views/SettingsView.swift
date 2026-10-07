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
                    Text("The model keeps working until it has an answer or you tap stop. " + ToolsSection.footer(expanded: toolsExpanded))
                }

                Section {
                    Toggle(isOn: $settings.offline) { Label("Offline mode", systemImage: LooplDesign.iconOffline) }
                    Picker(selection: $settings.askBefore) {
                        Text("Every request").tag(ApprovalPolicy.Mode.always)
                        Text("Sending or changing data").tag(ApprovalPolicy.Mode.mutating)   // not "Writes only" (IMPROVE-4 #24)
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
                    // One short line under each switch instead of a six-line footer for three (IMPROVE-4 #16).
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $settings.haptics) { Label("Haptics", systemImage: "hand.tap") }
                        Text("A soft tap when you send, when a tool starts and finishes, and when a model is ready.").font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show performance details", isOn: $settings.showPerformance)
                        Text("A quiet line under each answer: how fast the model wrote, how long it took to start, how much of its memory the conversation uses.").font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show GGUF builds", isOn: $settings.showGGUF).accessibilityIdentifier("settings-show-gguf")
                        Text("An older, text-only model format — listed in Models for people who need it.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Look & feel") }

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
                    Text("Keep models on the \(LooplDesign.deviceName) or on a USB-C drive — plug one in and pick a folder.")
                }

                Section {
                    LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    LabeledContent("Device memory", value: MemoryBudget.label(MemoryBudget.physical))
                    // Engines in words (IMPROVE-4 #15): "MLX ✓ / llama.cpp ✓" told a first-time user nothing.
                    runtimeStatus("Fast engine (MLX)", MLXModel.availability())
                    runtimeStatus("Apple Intelligence", AppleFoundationModel.availability())
                    runtimeStatus("Older-format engine (llama.cpp)", GGUFModel.availability())
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
        var parts = ["\(ByteSize.label(store.diskUsed, zero: "None")) on this \(LooplDesign.deviceName)"]
        for v in store.storage.volumes { parts.append(v.connected ? "\(ByteSize.label(v.used)) on \(v.name)" : "\(v.name) not connected") }
        return parts.joined(separator: " · ")
    }

    private var askBeforeFooter: String {
        // IMPROVE-5 copy pass 3: two lines on a 16 Pro, each toggle's effect in one clause.
        let base = "Offline mode stops all network use, downloads included. "
        switch settings.askBefore {
        case .always: return base + "Every web request waits for your tap."
        case .mutating: return base + "Reading a page runs on its own; sending or changing data waits for your tap (2 minutes, then it is denied)."
        case .never: return base + "The model's web requests run without asking."
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
                } footer: { Text("Changed by the model, with your approval. Revert puts the previous prompt back.") }
            }
            Section {
                TextEditor(text: $settings.systemPrompt).frame(minHeight: 180).font(.body)
                    .accessibilityIdentifier("system-prompt-editor")
            } footer: {
                Text("Sent at the start of every conversation, to every model. Ask for a standing rule and the model can add it here — each change asks you first.")
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
