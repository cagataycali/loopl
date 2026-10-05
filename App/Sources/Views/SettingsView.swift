import SwiftUI
import Loopl
import LooplUI
import LooplRuntimes

struct SettingsView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var store: ModelStore
    @State private var tokenDraft = ""
    @State private var showToken = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if showToken { TextField("hf_…", text: $tokenDraft) } else { SecureField("hf_…", text: $tokenDraft) }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                        Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }.buttonStyle(.plain)
                    }
                    HStack {
                        Button("Save to Keychain") { settings.setToken(tokenDraft); tokenDraft = ""; LooplDesign.haptic() }.disabled(tokenDraft.isEmpty)
                        Spacer()
                        if settings.hasToken {
                            Label("token stored", systemImage: "checkmark.seal.fill").foregroundStyle(LooplDesign.accent).font(.footnote)
                            Button("Remove", role: .destructive) { settings.setToken("") }.font(.footnote)
                        } else {
                            Text("no token — public models only").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Hugging Face") } footer: {
                    Text("Read token from huggingface.co/settings/tokens. Stored in the device Keychain only; sent as a Bearer header to huggingface.co for gated repos (Llama, Gemma) after you accept their licence on the site.")
                }

                Section {
                    Toggle(isOn: $settings.offline) { Label("Offline mode", systemImage: LooplDesign.iconOffline) }
                    Text("Refuses every network call in the app: downloads, http_get. Models already on disk load and run normally — this is how you prove inference never touches the network before trying Airplane Mode for real.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Network") }

                Section {
                    Picker("Preferred runtime", selection: $settings.preferredRuntime) {
                        ForEach(RuntimeKind.allCases) { Text($0.label).tag($0) }
                    }
                    runtimeStatus("MLX", MLXModel.availability())
                    runtimeStatus("Apple Intelligence", AppleFoundationModel.availability())
                    runtimeStatus("llama.cpp", GGUFModel.availability())
                    Toggle("Demo (scripted) runtime", isOn: $settings.demoRuntime)
                    Text("Replays a scripted tool-call conversation so the UI can be exercised in the simulator. Not a model, not a benchmark — the Chat header says DEMO while it is on.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Runtime") }

                Section("Generation") {
                    HStack { Text("Temperature"); Slider(value: $settings.temperature, in: 0...1.5, step: 0.05); Text(settings.temperature.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 44) }
                    Picker("Max new tokens", selection: $settings.maxTokens) { ForEach([256, 512, 1024, 2048, 4096], id: \.self) { Text("\($0)").tag($0) } }
                    Picker("Context budget", selection: $settings.contextLength) { ForEach([2048, 4096, 8192, 16384, 32768], id: \.self) { Text("\($0.formatted())").tag($0) } }
                    Text("Context is capped at the model's nominal window. Bigger KV caches cost RAM: on an 8 GB phone 4k–8k is the safe range for 1–4B models.").font(.footnote).foregroundStyle(.secondary)
                }

                Section("Storage") {
                    HStack { Text("Models on disk"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: store.diskUsed, countStyle: .file)).foregroundStyle(.secondary) }
                    Button("Delete all downloaded models", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Delete every downloaded model?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Delete all", role: .destructive) { Task { await engine.unload() }; store.deleteAll() }
                        }
                    Text(ModelStore.root.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    LabeledContent("Device RAM", value: MemoryBudget.label(MemoryBudget.physical))
                    LabeledContent("Available to app", value: MemoryBudget.label(MemoryBudget.available))
                    Link("github.com/cagataycali/loopl", destination: URL(string: "https://github.com/cagataycali/loopl")!)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func runtimeStatus(_ name: String, _ a: RuntimeAvailability) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
            Spacer()
            if a.available { Label("ready", systemImage: "checkmark.circle.fill").foregroundStyle(LooplDesign.accent).font(.footnote) }
            else { Text(a.reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        }
    }
}
