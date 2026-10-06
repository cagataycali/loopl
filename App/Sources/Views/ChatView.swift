import SwiftUI
import PhotosUI
import Loopl
import LooplUI

struct ChatView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var store: ModelStore
    var inSplit = false
    @State private var draft = ""
    @State private var attachments: [ImageBlock] = []
    @State private var showHistory = false
    @FocusState private var focused: Bool
    @Namespace private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AgentTranscriptView(engine.transcript, showPerformance: settings.showPerformance, expandTools: DesignFixture.expandTools) {
                    readinessBanner
                } empty: {
                    EmptyState(hint: emptyHint)
                }
                .onApproval { req, decision in engine.resolve(req, decision) }
                .contentShape(Rectangle())
                .onTapGesture { focused = false }
                if let err = engine.lastError {
                    Label(err, systemImage: LooplDesign.iconWarning).font(.footnote).foregroundStyle(.red)
                        .padding(.horizontal, LooplDesign.gutter).padding(.bottom, 6)
                        .transition(.opacity)
                }
                Composer(draft: $draft, attachments: $attachments, focused: $focused,
                         placeholder: engine.loadedModel == nil ? "Model is getting ready…" : (engine.canSeeImages ? "Message or photo" : "Message"),
                         generating: engine.isGenerating, canSend: engine.loadedModel != nil, canAttach: engine.canSeeImages,
                         send: send, stop: engine.stop)
            }
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: engine.lastError)
            .navigationTitle(engine.loadedModel?.name ?? "loopl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The active model's name changes in place (interpolated, spring) instead of cutting.
                ToolbarItem(placement: .principal) {
                    Text(engine.loadedModel?.name ?? "loopl").font(.headline)
                        .contentTransition(reduceMotion ? .opacity : .interpolate)
                        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: engine.loadedModel?.id)
                        .accessibilityAddTraits(.isHeader)
                }
                if !inSplit {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { LooplDesign.haptic(); showHistory = true } label: { Image(systemName: LooplDesign.iconHistory) }
                            .accessibilityLabel("History")
                            .matchedTransitionSource(id: "history", in: zoom)
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
                // iOS 18 zoom: the sheet grows out of the History button and shrinks back into it.
                .navigationTransition(.zoom(sourceID: "history", in: zoom))
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
        let t = draft, imgs = attachments
        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { draft = ""; attachments = [] }
        engine.send(t, images: imgs)   // the engine emits the .send haptic
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
                if progress == nil { PulsingMark().frame(width: 14, height: 14) }
                Text(title).font(.footnote.weight(.medium)).contentTransition(.interpolate)
            }
            if let progress {
                ProgressView(value: progress).tint(LooplDesign.accent)
                    .animation(LooplDesign.Motion.value, value: progress)
            } else {
                IndeterminateBar()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText())
                .animation(LooplDesign.Motion.value, value: detail)
        }
        .padding(.vertical, 6)
        .animation(LooplDesign.Motion.crossfade, value: progress == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }
}

/// Bottom-pinned composer: rounded field that grows to 5 lines, ↑ send / ■ stop.
/// Swipe down on it (or drag the transcript) to dismiss the keyboard.
struct Composer: View {
    @Binding var draft: String
    @Binding var attachments: [ImageBlock]
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    var generating: Bool
    var canSend: Bool
    /// The loaded model has a vision tower — show the attach button (photos / camera / paste).
    var canAttach: Bool = false
    var send: () -> Void
    var stop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Finger-following offset while the composer is dragged down (rubber-banded).
    @State private var drag: CGFloat = 0
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var attachError: String?

    static let maxAttachments = 4

    private var sendable: Bool { canSend && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            AttachmentChips(images: $attachments)
            if let attachError {
                Text(attachError).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.top, 6)
                    .transition(.opacity)
            }
            bar
        }
        .background(.bar)
        .offset(y: drag)
        .photosPicker(isPresented: $showPhotos, selection: $pickerItems, maxSelectionCount: Self.maxAttachments - attachments.count,
                      matching: .images, photoLibrary: .shared())
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await ingest(items); pickerItems = [] }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                if let data { add(ImageAttachment.block(from: data)) }
            }
            .ignoresSafeArea()
        }
        #endif
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: attachError)
        // Interruptible: the bar follows the finger (rubber-banded, interactive spring), and on release
        // either the keyboard goes (distance or velocity) or the bar springs back. Reduce Motion: no offset.
        // `simultaneousGesture`: a plain `.gesture` never fires over the TextField (UIKit's recognizers win).
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard focused.wrappedValue, !reduceMotion else { return }
                    let dy = max(0, v.translation.height)
                    withAnimation(LooplDesign.Motion.interactive) { drag = dy / (1 + dy / 80) }
                }
                .onEnded { v in
                    let dy = v.translation.height, vy = v.predictedEndTranslation.height - dy
                    if dy > LooplDesign.Motion.dismissDistance || vy > LooplDesign.Motion.dismissVelocity { focused.wrappedValue = false }
                    withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { drag = 0 }
                }
        )
    }

    /// Attach: Photos · Camera · Paste. Only shown for a vision model; disabled at the 4-picture cap.
    @ViewBuilder private var attachButton: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
            }
            #endif
            Button { paste() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                .disabled(!ImageAttachment.pasteboardHasImage)
        } label: {
            Image(systemName: "plus").font(.callout.weight(.bold)).frame(width: 40, height: 40)
                .background(Color(.secondarySystemBackground), in: Circle())
                .foregroundStyle(attachments.count >= Self.maxAttachments ? Color.secondary : Color.primary)
        }
        .disabled(attachments.count >= Self.maxAttachments || generating)
        .accessibilityLabel("Attach an image")
        .transition(.scale.combined(with: .opacity))
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if canAttach { attachButton }
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
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: generating)
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.value, reduceMotion), value: sendable)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: canAttach)
    }

    private func add(_ block: ImageBlock?) {
        guard let block else { attachError = "That image could not be read."; return }
        guard attachments.count < Self.maxAttachments else { attachError = "Up to \(Self.maxAttachments) images per message."; return }
        attachError = nil
        LooplDesign.haptic()
        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { attachments.append(block) }
    }

    private func ingest(_ items: [PhotosPickerItem]) async {
        for item in items {
            let data = try? await item.loadTransferable(type: Data.self)
            add(data.flatMap(ImageAttachment.block(from:)))
        }
    }

    private func paste() {
        add(ImageAttachment.fromPasteboard())
    }
}
