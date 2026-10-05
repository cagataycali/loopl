import SwiftUI

struct ChatView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatsBar(stats: engine.stats, model: engine.loadedModel, iteration: engine.iteration, generating: engine.isGenerating)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if engine.transcript.isEmpty { EmptyChat(model: engine.loadedModel) }
                            ForEach(engine.transcript) { item in
                                ChatRow(item: item).id(item.id)
                            }
                            if let err = engine.lastError {
                                Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red).padding(.horizontal)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: engine.transcript.last?.kind) { _, _ in
                        if let last = engine.transcript.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
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
                    Button { engine.clear() } label: { Image(systemName: "trash") }.disabled(engine.transcript.isEmpty || engine.isGenerating)
                }
            }
        }
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
                Button { engine.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .accessibilityLabel("Stop")
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

struct StatsBar: View {
    var stats: StreamStats
    var model: ModelSpec?
    var iteration: Int
    var generating: Bool
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: LooplDesign.iconLoaded).foregroundStyle(model == nil ? .secondary : LooplDesign.accent)
                Text(model?.name ?? "no model loaded").font(.footnote.weight(.medium)).lineLimit(1)
                Spacer()
                if generating { ProgressView().controlSize(.mini) }
                if iteration > 0 { Pill(text: "iter \(iteration)") }
            }
            HStack(spacing: 12) {
                stat("TTFT", stats.ttftMs > 0 ? String(format: "%.0f ms", stats.ttftMs) : "—")
                stat("tok/s", stats.tokensPerSecond > 0 ? String(format: "%.1f", stats.tokensPerSecond) : "—")
                stat("prompt", "\(stats.promptTokens)")
                stat("gen", "\(stats.generatedTokens)")
                Spacer()
                ctxMeter
            }
            .font(.caption2.monospacedDigit())
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
    private func stat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 3) { Text(k).foregroundStyle(.secondary); Text(v).fontWeight(.semibold) }
    }
    private var ctxMeter: some View {
        let max = Swift.max(1, stats.contextMax)
        let frac = min(1, Double(stats.contextUsed) / Double(max))
        return HStack(spacing: 6) {
            Text("ctx \(stats.contextUsed)/\(stats.contextMax)").foregroundStyle(.secondary)
            Capsule().fill(Color(.tertiarySystemFill)).frame(width: 60, height: 6)
                .overlay(alignment: .leading) { Capsule().fill(frac > 0.9 ? Color.red : LooplDesign.accent).frame(width: 60 * frac) }
        }
        .accessibilityLabel("context \(stats.contextUsed) of \(stats.contextMax) tokens")
    }
}

struct EmptyChat: View {
    var model: ModelSpec?
    var body: some View {
        VStack(spacing: 10) {
            Text("🔁").font(.system(size: 44))
            Text(model == nil ? "Download a model in **Models**, tap Load, then ask away." : "Ask something. Try: *what time is it in Istanbul and what is 23*47?*")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
        }
        .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 32)
    }
}

struct ChatRow: View {
    var item: ChatItem
    @State private var expanded = false
    var body: some View {
        switch item.kind {
        case .user(let s):
            HStack { Spacer(minLength: 48)
                Text(s).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(LooplDesign.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 18))
            }.padding(.horizontal, 12)
        case .assistant(let s):
            HStack { Text(s.isEmpty ? "…" : s).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 48) }.padding(.horizontal, 12)
        case .toolCall(let call, let result, let ms, let isError):
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation { expanded.toggle() } } label: {
                    HStack {
                        Image(systemName: LooplDesign.iconTool).foregroundStyle(isError ? .red : LooplDesign.accent)
                        Text(call.name).font(.subheadline.weight(.semibold).monospaced())
                        Spacer()
                        if let ms { Text(String(format: "%.0f ms", ms)).font(.caption2).foregroundStyle(.secondary) }
                        else { ProgressView().controlSize(.mini) }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
                Text(JSONValue.object(call.arguments).compact).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
                if let result, expanded || result.count < 120 {
                    Divider()
                    Text(result).font(.caption.monospaced()).foregroundStyle(isError ? .red : .primary).lineLimit(expanded ? nil : 4).textSelection(.enabled)
                }
            }
            .looplCard().padding(.horizontal, 12)
        case .note(let s):
            Text(s).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.horizontal, 24)
        }
    }
}
