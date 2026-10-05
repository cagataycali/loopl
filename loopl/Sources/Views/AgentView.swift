import SwiftUI

struct AgentView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
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
                } header: { Text("Tools") } footer: {
                    Text("http_get is refused while offline mode is on — the agent sees the refusal as a tool error and answers without it.")
                }
                Section("Loop") {
                    Stepper("Max iterations: \(settings.maxIterations)", value: $settings.maxIterations, in: 1...20)
                    HStack { Text("Tool dialect"); Spacer(); Text(engine.loadedModel?.family.rawValue ?? "from model").foregroundStyle(.secondary) }
                }
                Section("System prompt") {
                    TextEditor(text: $settings.systemPrompt).frame(minHeight: 110).font(.callout)
                    Button("Reset to default") { settings.systemPrompt = AppSettings.defaultSystemPrompt }.font(.footnote)
                }
                Section {
                    Text("Algorithm: stream → parse tool calls (<tool_call>, <|python_tag|>, fenced JSON) → run tools → append results → stream again, until the model answers plainly or the cap is hit. Every step shows as a card in Chat.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Agent")
        }
    }
}
