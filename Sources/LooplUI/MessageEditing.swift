import SwiftUI
import Loopl

// MARK: - Hold a message
//
// Long-press a USER row → Edit · Copy · Delete from here. Long-press an ASSISTANT row → Copy · Retry.
// Edit turns the row into an inline editor in place (the text and the field share a matched geometry,
// so the words do not jump); the host dims its composer meanwhile. While the agent is running the
// destructive actions are disabled and the menu says why. All motion through `LooplDesign.Motion`,
// every action a haptic, Reduce Motion = crossfades only.

/// What the host does when a row is acted on. Attach with `AgentTranscriptView.transcriptActions(_:)`.
public struct TranscriptActions {
    /// False while the agent is generating: Edit/Retry/Delete are shown disabled with a hint.
    public var canEdit: Bool
    /// The row the user is editing right now (nil = none). Owned by the host so Cancel/Save can clear it.
    public var editing: Binding<UUID?>
    /// Save & regenerate: the edited user turn (`item`) with its new text. Truncates + re-runs.
    public var onSave: (TranscriptItem, String) -> Void
    /// Delete from here: the item and everything after it.
    public var onDeleteFrom: (TranscriptItem) -> Void
    /// Retry: re-run the agent from the user turn that owns this assistant row.
    public var onRetry: (TranscriptItem) -> Void

    public init(canEdit: Bool, editing: Binding<UUID?>,
                onSave: @escaping (TranscriptItem, String) -> Void,
                onDeleteFrom: @escaping (TranscriptItem) -> Void,
                onRetry: @escaping (TranscriptItem) -> Void) {
        self.canEdit = canEdit; self.editing = editing; self.onSave = onSave; self.onDeleteFrom = onDeleteFrom; self.onRetry = onRetry
    }

    /// The one line the disabled menu items explain themselves with.
    public static let busyHint = "Wait for the answer, or stop it, to edit."
}

/// The user row with its hold menu. Wraps `UserTurn`; the plain `UserTurn` keeps its Copy-only menu
/// for hosts without editing.
public struct EditableUserTurn: View {
    public var item: TranscriptItem
    public var text: String
    public var actions: TranscriptActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(item: TranscriptItem, text: String, actions: TranscriptActions) {
        self.item = item; self.text = text; self.actions = actions
    }

    private var isEditing: Bool { actions.editing.wrappedValue == item.id }

    public var body: some View {
        Group {
            if isEditing {
                UserTurnEditor(item: item, original: text, actions: actions)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)), removal: .opacity))
            } else {
                UserTurn(text, images: item.images, menu: false)
                    .holdPreviewShape()
                    .contextMenu {
                        if !actions.canEdit {
                            Section(TranscriptActions.busyHint) {
                                Button("Edit", systemImage: "pencil") {}.disabled(true)
                            }
                        } else {
                            Button("Edit", systemImage: "pencil") {
                                LooplDesign.haptic()
                                withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { actions.editing.wrappedValue = item.id }
                            }
                        }
                        Button("Copy", systemImage: "doc.on.doc") { copy(text) }
                        Button("Delete from here", systemImage: "trash", role: .destructive) {
                            LooplDesign.haptic(1)
                            withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { actions.onDeleteFrom(item) }
                        }
                        .disabled(!actions.canEdit)
                    }
                    .accessibilityHint(actions.canEdit ? "Hold for Edit, Copy and Delete from here" : TranscriptActions.busyHint)
                    .transition(.opacity)
            }
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: isEditing)
    }
}

/// The in-place editor a user row becomes: the same "You" label, a growing text field prefilled with the
/// message, and Cancel · Save & regenerate. Save is disabled for an empty or unchanged message.
public struct UserTurnEditor: View {
    public var item: TranscriptItem
    public var original: String
    public var actions: TranscriptActions
    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(item: TranscriptItem, original: String, actions: TranscriptActions) {
        self.item = item; self.original = original; self.actions = actions
        _draft = State(initialValue: original)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).kerning(0.6)
                Text("· editing").font(.caption).foregroundStyle(LooplDesign.accent)
                    .transition(.opacity)
            }
            if !item.images.isEmpty { ImageStrip(item.images).padding(.bottom, 2) }
            HStack(alignment: .top, spacing: 6) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .font(.body).lineSpacing(4)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                    .accessibilityLabel("Edit message")
                    .accessibilityIdentifier("edit.field")
                if !draft.isEmpty {
                    Button { LooplDesign.haptic(); draft = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear text")
                    .accessibilityIdentifier("edit.clear")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(LooplDesign.accent.opacity(0.5), lineWidth: 1))
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: draft.isEmpty)
            HStack(spacing: 10) {
                Button("Cancel") { cancel() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.secondary)
                    .accessibilityIdentifier("edit.cancel")
                Button { save() } label: {
                    Label("Save & regenerate", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(LooplDesign.accent)
                .disabled(!canSave)
                .accessibilityIdentifier("edit.save")
                .accessibilityHint("Replaces this message, removes everything after it and asks again")
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.semibold))
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.value, reduceMotion), value: canSave)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LooplDesign.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
    }

    private func cancel() {
        LooplDesign.haptic()
        focused = false
        withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { actions.editing.wrappedValue = nil }
    }

    private func save() {
        guard canSave else { return }
        LooplDesign.success()
        focused = false
        let text = trimmed
        withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) {
            actions.editing.wrappedValue = nil
            actions.onSave(item, text)
        }
    }
}

/// The assistant row's hold menu: Copy · Retry. Wraps the streaming text; Retry re-runs from the owning user turn.
public struct RetryableAssistantTurn: View {
    public var item: TranscriptItem
    public var text: String
    public var streaming: Bool
    public var actions: TranscriptActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(item: TranscriptItem, text: String, streaming: Bool, actions: TranscriptActions) {
        self.item = item; self.text = text; self.streaming = streaming; self.actions = actions
    }

    public var body: some View {
        MarkdownBody(text, streaming: streaming)
            .holdPreviewShape()
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { copy(text) }
                if actions.canEdit {
                    Button("Retry", systemImage: "arrow.counterclockwise") {
                        LooplDesign.haptic()
                        withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { actions.onRetry(item) }
                    }
                } else {
                    Section(TranscriptActions.busyHint) { Button("Retry", systemImage: "arrow.counterclockwise") {}.disabled(true) }
                }
            }
            .accessibilityLabel(streaming ? "loopl is writing: \(text)" : "loopl: \(text)")
            .accessibilityHint(actions.canEdit ? "Hold for Copy and Retry" : "Hold to copy")
    }
}

extension View {
    /// The lifted preview under a long-press is a soft rounded card around the whole row, not a tight text box.
    @ViewBuilder func holdPreviewShape() -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous).inset(by: -8))
        #else
        self
        #endif
    }
}
