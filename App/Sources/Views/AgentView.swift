import SwiftUI
import Loopl
import LooplUI

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
                    Stepper(settings.maxIterations == 0 ? "Iterations: unlimited (loopl default)" : "Max iterations: \(settings.maxIterations)", value: $settings.maxIterations, in: 0...50)
                    Text("Unlimited means the loop runs until the model stops calling tools or you tap Stop. A loop detector warns when the same call repeats 3× — it never stops the agent for you.").font(.footnote).foregroundStyle(.secondary)
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
