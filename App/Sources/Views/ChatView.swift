import SwiftUI
import Loopl
import LooplUI

struct ChatView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                AgentTranscriptView(engine.transcript, emptyHint: engine.loadedModel == nil
                                    ? "Download a model in **Models**, tap Load, then ask away."
                                    : "Ask something. Try: *what time is it in Istanbul and what is 23*47?*")
                if let err = engine.lastError {
                    Label(err, systemImage: LooplDesign.iconWarning).font(.footnote).foregroundStyle(.red).padding(.horizontal).padding(.bottom, 4)
                }
                composer
            }
            .navigationTitle("loopl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if settings.offline { Image(systemName: LooplDesign.iconOffline).foregroundStyle(.orange).accessibilityLabel("offline mode") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { engine.clear() } label: { Image(systemName: "trash") }
                        .disabled(engine.transcript.items.isEmpty || engine.isGenerating).accessibilityLabel("Clear conversation")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: LooplDesign.iconLoaded).foregroundStyle(engine.loadedModel == nil ? .secondary : LooplDesign.accent)
                Text(engine.loadedModel?.name ?? "no model loaded").font(.footnote.weight(.medium)).lineLimit(1)
                if settings.demoRuntime { Pill("DEMO", tint: .orange) }
                Spacer()
                if engine.isGenerating { ProgressView().controlSize(.mini) }
                if engine.transcript.iteration > 0 { Pill("iter \(engine.transcript.iteration)") }
            }
            TokenMeter(engine.transcript.metrics)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(engine.loadedModel == nil ? "Load a model in Models first" : "Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .focused($focused)
                .onSubmit(send)
            if engine.isGenerating {
                Button { engine.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }.accessibilityLabel("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || engine.loadedModel == nil)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let t = draft; draft = ""
        LooplDesign.haptic()
        engine.send(t)
    }
}
