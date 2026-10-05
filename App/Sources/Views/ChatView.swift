import SwiftUI
import Loopl
import LooplUI

struct ChatView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var store: ModelStore
    var inSplit = false
    @State private var draft = ""
    @State private var showHistory = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AgentTranscriptView(engine.transcript, showPerformance: settings.showPerformance, expandTools: DesignFixture.expandTools) {
                    readinessBanner
                } empty: {
                    EmptyState(hint: emptyHint)
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = false }
                if let err = engine.lastError {
                    Label(err, systemImage: LooplDesign.iconWarning).font(.footnote).foregroundStyle(.red)
                        .padding(.horizontal, LooplDesign.gutter).padding(.bottom, 6)
                        .transition(.opacity)
                }
                Composer(draft: $draft, focused: $focused,
                         placeholder: engine.loadedModel == nil ? "Model is getting ready…" : "Message",
                         generating: engine.isGenerating, canSend: engine.loadedModel != nil,
                         send: send, stop: engine.stop)
            }
            .animation(reduceMotion ? nil : LooplDesign.spring, value: engine.lastError)
            .navigationTitle(engine.loadedModel?.name ?? "loopl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !inSplit {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showHistory = true } label: { Image(systemName: LooplDesign.iconHistory) }
                            .accessibilityLabel("History")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        if settings.offline { Image(systemName: LooplDesign.iconOffline).foregroundStyle(.orange).accessibilityLabel("offline mode on") }
                        Button { LooplDesign.haptic(); engine.newConversation() } label: { Image(systemName: "square.and.pencil") }
                            .disabled(engine.transcript.items.isEmpty || engine.isGenerating)
                            .accessibilityLabel("New conversation")
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    HistoryList(engine: engine, selection: .constant(.chat)) { showHistory = false }
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showHistory = false } } }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var emptyHint: String {
        switch engine.readiness {
        case .ready(let s): "**\(s.name)** is ready. Everything runs on this device."
        case .downloading, .loading: "Getting your model ready — the first launch downloads it once."
        case .failed: "Pick a model in **Models** to get started."
        case .idle: "Runs on this iPhone. Nothing leaves it."
        }
    }

    /// Inline, never modal: download → load → (nothing) at the top of the document.
    @ViewBuilder private var readinessBanner: some View {
        switch engine.readiness {
        case .downloading(let spec, let done, let total):
            ReadinessRow(title: "Downloading \(spec.name)", detail: "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · once, then offline",
                         progress: total > 0 ? Double(done) / Double(total) : nil)
        case .loading(let spec, let p):
            ReadinessRow(title: "Loading \(spec.name)", detail: p > 0 && p < 1 ? "\(Int(p * 100))%" : "warming up", progress: p > 0 ? p : nil)
        case .failed(let spec, let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label(msg, systemImage: LooplDesign.iconWarning).font(.footnote).foregroundStyle(.secondary)
                if let spec { Button("Try again") { Task { await engine.select(spec) } }.font(.footnote.weight(.semibold)) }
            }
            .padding(.vertical, 4)
        case .idle, .ready:
            EmptyView()
        }
    }

    private func send() {
        let t = draft; draft = ""
        LooplDesign.haptic()
        engine.send(t)
    }
}

/// One quiet progress row.
struct ReadinessRow: View {
    var title: String
    var detail: String
    var progress: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if progress == nil { ProgressView().controlSize(.mini) }
                Text(title).font(.footnote.weight(.medium))
            }
            if let progress { ProgressView(value: progress).tint(LooplDesign.accent) }
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }
}

/// Bottom-pinned composer: rounded field that grows to 5 lines, ↑ send / ■ stop.
/// Swipe down on it (or drag the transcript) to dismiss the keyboard.
struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    var generating: Bool
    var canSend: Bool
    var send: () -> Void
    var stop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sendable: Bool { canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .focused(focused)
                .submitLabel(.send)
                .onSubmit { if sendable { send() } }
                .accessibilityLabel("Message")
            Group {
                if generating {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.callout.weight(.bold)).frame(width: 40, height: 40)
                            .background(Color.primary.opacity(0.85), in: Circle()).foregroundStyle(Color(.systemBackground))
                    }
                    .accessibilityLabel("Stop generating")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.callout.weight(.bold)).frame(width: 40, height: 40)
                            .background(sendable ? LooplDesign.accent : Color(.tertiarySystemFill), in: Circle())
                            .foregroundStyle(sendable ? Color.white : Color.secondary)
                    }
                    .disabled(!sendable)
                    .accessibilityLabel("Send")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : LooplDesign.spring, value: generating)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: sendable)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .gesture(DragGesture(minimumDistance: 24).onEnded { v in if v.translation.height > 24 { focused.wrappedValue = false } })
    }
}
