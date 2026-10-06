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
    /// Recordings made in the composer (files already in the thread's attachments dir).
    @State private var clips: [AudioClip] = []
    @State private var showHistory = false
    /// The user row being edited in place (hold → Edit). The composer dims while it is set.
    @State private var editing: UUID?
    @State private var showOffline = false
    @FocusState private var focused: Bool
    @Namespace private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                provenanceRow
                AgentTranscriptView(engine.transcript, showPerformance: settings.showPerformance, expandTools: DesignFixture.expandTools) {
                    readinessBanner
                } empty: {
                    EmptyState(hint: emptyHint)
                }
                .onApproval { req, decision in engine.resolve(req, decision) }
                .transcriptActions(TranscriptActions(
                    canEdit: !engine.isGenerating && engine.loadedModel != nil,
                    editing: $editing,
                    onSave: { item, text in engine.edit(item.id, text: text) },
                    onDeleteFrom: { item in engine.deleteFrom(item.id) },
                    onRetry: { item in engine.retry(item.id) }))
                .contentShape(Rectangle())
                .onTapGesture { focused = false }
                .onReceive(NotificationCenter.default.publisher(for: Onboarding.finished)) { _ in focused = true }   // first run just ended: the composer is the next thing
                .onAppear { if DesignFixture.focusComposer { focused = true } }   // screenshot switch: keyboard up
                // The iOS 26 keyboard is translucent: with the tab bar left in place under it, the Chat/Models/Settings
                // glyphs showed through its bottom row as an orange smear (UX audit, 16 Pro + Pro Max). The tab bar is
                // out of reach while typing anyway, so it steps out with the keyboard and returns on blur.
                .toolbarVisibility(focused ? .hidden : .visible, for: .tabBar)
                // One place per error: a load failure is the readiness banner's (with Try again); this line is for
                // errors while a model IS loaded (a failed turn, a refused send). Dismissable; cleared on the next send.
                if let err = engine.lastError, !engine.readiness.isFailed {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(err, systemImage: LooplDesign.iconWarning).font(.footnote).foregroundStyle(.red)
                        Spacer(minLength: 0)
                        Button { engine.lastError = nil } label: { Image(systemName: "xmark.circle.fill").font(.footnote).foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                    }
                    .padding(.horizontal, LooplDesign.gutter).padding(.bottom, 6)
                    .transition(.opacity)
                }
                Composer(draft: $draft, attachments: $attachments, clips: $clips, focused: $focused,
                         placeholder: placeholder,
                         generating: engine.isGenerating, canSend: engine.loadedModel != nil, canAttach: engine.canSeeImages,
                         attachmentsDir: { AudioAttachment.directory(for: engine.currentId) },
                         send: send, stop: engine.stop)
                // The composer keeps the transcript's reading measure on wide screens; its bar background spans the window.
                .frame(maxWidth: LooplDesign.readingWidth + 2 * LooplDesign.gutter)
                .frame(maxWidth: .infinity)
                .background(.bar)
                // While a row is being edited the composer steps back: dimmed, inert, until Save or Cancel.
                .opacity(editing == nil ? 1 : 0.35)
                .disabled(editing != nil)
                .accessibilityHidden(editing != nil)
                .animation(LooplDesign.Motion.faded(LooplDesign.Motion.value, reduceMotion), value: editing == nil)
            }
            .onChange(of: engine.currentId) { _, _ in
                // A new or reopened thread: unsent recordings belonged to the old one — drop them with their files.
                clips.forEach { try? FileManager.default.removeItem(at: $0.url) }
                withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { clips = [] }
            }
            .onChange(of: engine.transcript.items.count) { _, _ in
                // The edited row left the transcript (saved, or the thread was cut under it): no stale editor.
                if let editing, engine.transcript.index(of: editing) == nil { self.editing = nil }
            }
            .onAppear {
                #if DEBUG
                // Screenshot fixtures: the in-place editor on the last user row / History (+ share) already open.
                if DesignFixture.editing, editing == nil {
                    editing = engine.transcript.items.last { if case .user = $0.kind { return true }; return false }?.id
                }
                if DesignFixture.share != nil { showHistory = true }
                #endif
            }
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: engine.lastError)
            .navigationTitle(engine.loadedModel?.name ?? "loopl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The active model's name changes in place (interpolated, spring) instead of cutting.
                ToolbarItem(placement: .principal) {
                    Text(engine.loadedModel?.name ?? "loopl").font(.headline)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        // An inline bar title does not grow past the large sizes (UIKit's own never scales at all):
                        // at AX-XL it was shoved against the History button and clipped under the trailing group.
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .contentTransition(reduceMotion ? .opacity : .interpolate)
                        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: engine.loadedModel?.id)
                        .accessibilityAddTraits(.isHeader)
                }
                if !inSplit {
                    ToolbarItem(placement: .topBarLeading) {
                        // Label (icon-only) rather than a bare Image: the iPad ⌘-hold shortcut list shows the title.
                        Button { LooplDesign.haptic(); showHistory = true } label: { Label("History", systemImage: LooplDesign.iconHistory).labelStyle(.iconOnly) }
                            .keyboardShortcut("y", modifiers: .command)   // ⌘Y = History (Safari's chord; ⌘⇧H is the system Home on iPad)
                            .accessibilityLabel("History")
                            .matchedTransitionSource(id: "history", in: zoom)
                    }
                }
                if let current = shareable {
                    // #20: the open conversation as a Markdown file or a picture of the transcript. Its own item — inside the
                    // HStack below, XCUI (and VoiceOver hit-testing) resolved the menu to the whole group's frame.
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu { ConversationShareItems(conversation: current) } label: { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share conversation")
                            .accessibilityIdentifier("chat-share")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        if settings.offline {
                            // Not a dead glyph in a toolbar pill: tap to read what it means and turn it off here.
                            Button { LooplDesign.haptic(); showOffline = true } label: { Image(systemName: LooplDesign.iconOffline).foregroundStyle(.orange) }
                                .accessibilityLabel("Offline mode is on")
                                .accessibilityHint("explains offline mode; lets you turn it off")
                                .popover(isPresented: $showOffline, arrowEdge: .top) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Label("Offline mode is on", systemImage: LooplDesign.iconOffline).font(.callout.weight(.semibold))
                                        Text("Downloads and the http tool are refused. Models already on this device still load and run.").font(.footnote).foregroundStyle(.secondary)
                                        Button("Turn off offline mode") { settings.offline = false; showOffline = false }.font(.footnote.weight(.semibold))
                                    }
                                    .padding(16).frame(maxWidth: 300)
                                    .presentationCompactAdaptation(.popover)
                                }
                        }
                        Button { LooplDesign.haptic(); engine.newConversation() } label: { Label("New conversation", systemImage: "square.and.pencil").labelStyle(.iconOnly) }
                            .keyboardShortcut("n", modifiers: .command)
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

    /// The open thread as History would save it — nil while empty or while an answer is still streaming.
    private var shareable: SavedConversation? {
        guard !engine.isGenerating else { return nil }
        return SavedConversation.from(engine.transcript, id: engine.currentId, modelName: engine.loadedModel?.name)
    }

    /// What the field says before you type — honest about the state: a failed load is not "getting ready".
    private var placeholder: String {
        switch engine.readiness {
        case .ready: engine.canSeeImages ? "Message or photo" : "Message"
        case .downloading, .loading, .repairing: "Model is getting ready…"
        case .failed: "Pick a model to start"
        case .idle: "No model loaded"
        }
    }

    private var emptyHint: String {
        switch engine.readiness {
        case .ready(let s): "**\(s.name)** is ready. Everything runs on this device."
        case .downloading, .loading, .repairing: "Getting your model ready — the first launch downloads it once."
        case .failed: "Pick a model in **Models** to get started."
        case .idle: "Runs on this \(LooplDesign.deviceName). Nothing leaves it."
        }
    }

    /// Inline, never modal: download → load → (nothing) at the top of the document.
    /// #21: a reopened thread is replayed into a FRESH context under the model that is loaded now — so the answers
    /// on screen were written by a different one. Two placements were tried and measured:
    /// · as a title subtitle — the inline title bar is squeezed between two button groups and truncated it on an SE;
    /// · inside the transcript's scroll header — at AX-XXXL the taller header moved the content under the
    ///   scroll-to-bottom target and the transcript came up blank.
    /// So it is a static strip between the title bar and the scroll view: full reading width, outside the scroll math.
    @ViewBuilder private var provenanceRow: some View {
        if let by = engine.answeredBy {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.caption2)
                Text(engine.continuedHere ? "Earlier answers by \(by)" : "Answered by \(by)")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(2)
            // Capped like the onboarding footer (#19): unbounded, this secondary line wrapped to four lines at
            // AX-XXXL and took half an SE from the conversation it describes. VoiceOver still reads it in full.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, LooplDesign.gutter)
            .padding(.top, 2).padding(.bottom, 6)
            .frame(maxWidth: LooplDesign.readingWidth + 2 * LooplDesign.gutter, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var readinessBanner: some View {
        switch engine.readiness {
        case .downloading(let spec, let done, let total):
            // "Zero KB of 335.5 MB" is what the formatter says at byte 0 — "Starting" is what is happening.
            ReadinessRow(title: "Downloading \(spec.name)", detail: (done == 0 ? "Starting" : "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))") + " · once, then offline",
                         progress: total > 0 ? Double(done) / Double(total) : nil,
                         action: ("Pause", { store.pause(spec) }))   // the first-launch download could not be stopped from here
        case .loading(let spec, let p):
            ReadinessRow(title: "Loading \(spec.name)", detail: p > 0 && p < 1 ? "\(Int(p * 100))%" : "warming up", progress: p > 0 ? p : nil)
        case .repairing(let spec):
            ReadinessRow(title: "Repairing \(spec.name)", detail: "refreshing its tokenizer files from Hugging Face · weights stay", progress: nil)
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
        var t = draft, imgs = attachments
        // Each recording is one honest line in the message: the model sees the path and may call `transcribe`.
        // Nothing is transcribed for it behind the scenes — the point is to watch it pick the tool.
        if !clips.isEmpty { t = ([t.trimmingCharacters(in: .whitespacesAndNewlines)] + clips.map(\.marker.line)).filter { !$0.isEmpty }.joined(separator: "\n") }
        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { draft = ""; attachments = []; clips = [] }
        engine.send(t, images: imgs)   // the engine emits the .send haptic
    }
}

/// One quiet progress row.
struct ReadinessRow: View {
    var title: String
    var detail: String
    var progress: Double?
    /// An optional trailing action ("Pause").
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if progress == nil { PulsingMark().frame(width: 14, height: 14) }
                Text(title).font(.footnote.weight(.medium)).contentTransition(.interpolate)
                Spacer(minLength: 0)
                if let action { Button(action.0, action: action.1).font(.footnote.weight(.semibold)).buttonStyle(.plain).foregroundStyle(LooplDesign.accent) }
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

/// Bottom-pinned composer: a bare field (no fill — it sits on the bar's material, one surface with the keyboard)
/// that grows to 5 lines, ↑ send / ■ stop.
/// Swipe down on it (or drag the transcript) to dismiss the keyboard.
struct Composer: View {
    @Binding var draft: String
    @Binding var attachments: [ImageBlock]
    @Binding var clips: [AudioClip]
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    var generating: Bool
    var canSend: Bool
    /// The loaded model has a vision tower — show the attach button (photos / camera / paste).
    var canAttach: Bool = false
    /// Where a new recording is written (the current thread's attachments dir).
    var attachmentsDir: () -> URL
    var send: () -> Void
    var stop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recorder = AudioRecorder()
    /// Finger-following offset while the composer is dragged down (rubber-banded).
    @State private var drag: CGFloat = 0
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var attachError: String?

    static let maxAttachments = 4
    /// The round buttons grow with the text (so the glyph never outgrows its circle at accessibility sizes) but stop
    /// at `LooplDesign.controlSideMax`: at 56 pt three of them left the field two words wide on an SE at AX-XL
    /// ("price / to / euros?"), so above that the attach + mic buttons also fold into ONE menu (`compactControls`).
    @ScaledMetric(relativeTo: .callout) private var scaledSide: CGFloat = LooplDesign.controlSide
    @Environment(\.dynamicTypeSize) private var typeSize
    private var side: CGFloat { min(scaledSide, LooplDesign.controlSideMax) }
    /// Accessibility sizes: one "+" menu (photo / camera / paste / record) instead of two round buttons.
    private var compactControls: Bool { typeSize.isAccessibilitySize }

    static let maxClips = 3

    private var sendable: Bool { canSend && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || !clips.isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            AttachmentChips(images: $attachments)
            audioChips
            if let attachError {
                Text(attachError).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.top, 6)
                    .transition(.opacity)
            }
            micNotice
            if recorder.isRecording { recordingBar } else { bar }
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: recorder.isRecording)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: recorder.state)
        .onDisappear { if recorder.isRecording { recorder.cancel() } }
        // No material of its own: ChatView paints one `.bar` across the whole window behind the composer. A second
        // `.bar` here was stacked inside the reading measure, so on iPad the composer read as a lighter slab on the bar.
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
            Image(systemName: "plus").font(.callout.weight(.bold)).frame(width: side, height: side)
                .background(LooplDesign.controlFill, in: Circle())
                .foregroundStyle(attachments.count >= Self.maxAttachments ? Color.secondary : Color.primary)
        }
        .disabled(attachments.count >= Self.maxAttachments || generating)
        .accessibilityLabel("Attach an image")
        .accessibilityIdentifier("composer-attach")
        .transition(.scale.combined(with: .opacity))
    }

    /// Accessibility sizes only: the attach menu and the mic as ONE round button, so the field keeps most of the bar.
    private var compactMenu: some View {
        Menu {
            if canAttach {
                Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    .disabled(attachments.count >= Self.maxAttachments)
                #if os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                        .disabled(attachments.count >= Self.maxAttachments)
                }
                #endif
                Button { paste() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                    .disabled(!ImageAttachment.pasteboardHasImage || attachments.count >= Self.maxAttachments)
            }
            Button {
                LooplDesign.haptic(1)
                focused.wrappedValue = false
                Task { await recorder.start(in: attachmentsDir()) }
            } label: { Label("Record Audio", systemImage: "mic") }
                .disabled(clips.count >= Self.maxClips)
        } label: {
            Image(systemName: "plus").font(.callout.weight(.bold)).frame(width: side, height: side)
                .background(LooplDesign.controlFill, in: Circle())
                .foregroundStyle(Color.primary)
        }
        .disabled(generating)
        .accessibilityLabel(canAttach ? "Attach an image or record audio" : "Record audio")
        .accessibilityIdentifier("composer-attach")
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Audio

    /// Recording chips sit with the picture chips, above the field.
    @ViewBuilder private var audioChips: some View {
        if !clips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(clips) { clip in
                        AudioClipChip(url: clip.url, duration: clip.duration) { remove(clip) }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: clips.count)
            .accessibilityLabel("\(clips.count) recording\(clips.count == 1 ? "" : "s") attached")
        }
    }

    /// Calm, inline: no alert. Points to Settings when the microphone was refused.
    @ViewBuilder private var micNotice: some View {
        switch recorder.state {
        case .denied:
            HStack(spacing: 8) {
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
                Text("Microphone is off for loopl.").font(.caption).foregroundStyle(.secondary)
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url).font(.caption.weight(.semibold))
                }
                #endif
                Spacer(minLength: 0)
                Button { recorder.dismissNotice() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14).padding(.top, 8)
            .transition(.opacity)
        case .failed(let msg):
            Text("Couldn't record: \(msg)").font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.top, 8)
                .transition(.opacity)
                .onTapGesture { recorder.dismissNotice() }
        default:
            EmptyView()
        }
    }

    /// Always shown (any model can be asked to `transcribe`); disabled at the cap and while generating.
    private var micButton: some View {
        Button {
            LooplDesign.haptic(1)
            focused.wrappedValue = false
            Task { await recorder.start(in: attachmentsDir()) }
        } label: {
            Image(systemName: "mic").font(.callout.weight(.bold)).frame(width: side, height: side)
                .background(LooplDesign.controlFill, in: Circle())
                .foregroundStyle(clips.count >= Self.maxClips ? Color.secondary : Color.primary)
        }
        .disabled(clips.count >= Self.maxClips || generating)
        .accessibilityLabel("Record audio")
        .transition(.scale.combined(with: .opacity))
    }

    /// The field becomes the take: × on the left, live waveform + clock in the middle, ✓ on the right.
    private var recordingBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                LooplDesign.haptic()
                recorder.cancel()
            } label: {
                Image(systemName: "xmark").font(.callout.weight(.bold)).frame(width: side, height: side)
                    .background(LooplDesign.controlFill, in: Circle()).foregroundStyle(Color.primary)
            }
            .accessibilityLabel("Cancel recording")
            HStack(spacing: 10) {
                RecordingDot()
                LiveWaveform(levels: recorder.levels).frame(height: 24)
                Text(AudioAttachmentMarker.clock(recorder.elapsed))
                    .font(.callout.weight(.medium)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(LooplDesign.Motion.faded(LooplDesign.Motion.value, reduceMotion), value: Int(recorder.elapsed))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording, \(AudioAttachmentMarker.clock(recorder.elapsed))")
            Button {
                finishRecording()
            } label: {
                Image(systemName: "checkmark").font(.callout.weight(.bold)).frame(width: side, height: side)
                    .background(LooplDesign.accent, in: Circle()).foregroundStyle(Color.white)
            }
            .accessibilityLabel("Finish recording")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        // Swipe the take away (left) to cancel, like dragging a card off.
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
            if v.translation.width < -80 { LooplDesign.haptic(); recorder.cancel() }
        })
    }

    private func finishRecording() {
        guard let clip = recorder.stop() else { attachError = "That was too short to keep."; return }
        attachError = nil
        LooplDesign.success()
        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { clips.append(clip) }
    }

    private func remove(_ clip: AudioClip) {
        try? FileManager.default.removeItem(at: clip.url)
        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { clips.removeAll { $0 == clip } }
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: compactControls ? 8 : 10) {
            if compactControls {
                compactMenu
            } else {
                if canAttach { attachButton }
                micButton
            }
            // No fill behind the field: a second rounded shape here fought the keyboard's own corner radius right
            // above it (owner, 2026-10-06). The field sits straight on the bar's material, so composer + keyboard read
            // as one surface. Vertical padding 9: a one-line body field is 22 pt, so the box is 40 pt — the same height
            // as the round buttons, which puts the caret on their centre line (10 pt made it 42 and 1 pt off).
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 6).padding(.vertical, 9)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit { if sendable { send() } }
                // ⌘↩ while typing: the field (a UITextView) swallows the chord, so it arrives via LooplAppDelegate's
                // priority key command; a plain Return still inserts a newline.
                .onReceive(NotificationCenter.default.publisher(for: .looplSendShortcut)) { _ in if sendable { send() } }
                .accessibilityLabel("Message")
            Group {
                if generating {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.callout.weight(.bold)).frame(width: side, height: side)
                            .background(Color.primary.opacity(0.85), in: Circle()).foregroundStyle(Color(.systemBackground))
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    // UIKit delivers ⌘. as Escape before SwiftUI sees the chord — this companion catches it (and plain Esc).
                    .background { Button("Stop", action: stop).keyboardShortcut(.escape, modifiers: []).opacity(0).accessibilityHidden(true) }
                    .accessibilityLabel("Stop generating")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.callout.weight(.bold)).frame(width: side, height: side)
                            .background(sendable ? LooplDesign.accent : Color(.tertiarySystemFill), in: Circle())
                            .foregroundStyle(sendable ? Color.white : Color.secondary)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
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

/// The red "live" dot of the recording bar. Breathes on a slow pulse; a steady dot under Reduce Motion.
struct RecordingDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(Color.red).frame(width: 10, height: 10)
            .scaleEffect(on && !reduceMotion ? 1.0 : 0.72)
            .opacity(on || reduceMotion ? 1 : 0.55)
            .onAppear { withAnimation(reduceMotion ? nil : LooplDesign.Motion.pulse) { on = true } }
            .accessibilityHidden(true)
    }
}
