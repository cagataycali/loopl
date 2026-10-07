import SwiftUI
import Loopl

// Phase 7 `ask_user` card. Rendered inline by `AgentTranscriptView` (and inside a sub-agent's card) for every
// `TranscriptItem.Kind.ask`: a pending card is the question with native controls — two buttons (confirm), a radio
// list (select), checkboxes + Done (multiselect), a text field + Send (input), a chip row (buttons), grouped fields +
// Submit (form) or an information box + Continue (message) — plus a visible "waiting for you" line and Cancel, always.
// A settled card folds to one quiet line, the same way the ApprovalCard does. Passwords are drawn with SecureField and
// the settled line never contains them (the transcript holds the masked answer — see AskUser.swift).
// Motion through `LooplDesign.Motion`; Reduce Motion cross-fades; haptics on each answer.

public struct AskUserCard: View {
    public var toolUseId: String
    public var request: AskUserRequest
    public var answer: AskUserAnswer?
    /// Called once with the human's answer (or `.cancelled`); the host routes it to `agent.resolve(interrupt:)`.
    public var onAnswer: (AskUserAnswer) -> Void

    @State private var text: String = ""
    @State private var picked: String?
    @State private var checked: Set<String> = []
    @State private var formValues: [String: String] = [:]
    @State private var formToggles: [String: Bool] = [:]
    @State private var showMissing = false
    @State private var showDetail = false
    @FocusState private var focusedField: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private var stacked: Bool { typeSize.isAccessibilitySize }
    private var pending: Bool { answer == nil }

    public init(toolUseId: String, request: AskUserRequest, answer: AskUserAnswer? = nil, onAnswer: @escaping (AskUserAnswer) -> Void) {
        self.toolUseId = toolUseId; self.request = request; self.answer = answer; self.onAnswer = onAnswer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if pending {
                Text(request.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask-text")
                controls
                footer
            } else if showDetail {
                Text(request.text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(borderTint, lineWidth: 1))
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: answer)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: showMissing)
        .onAppear(perform: seed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask-card-\(request.type.rawValue)")
    }

    // MARK: header / footer

    private var header: some View {
        // Default sizes: one line — glyph · title · pill/chevron. Accessibility sizes: the pill drops under the title so
        // "Delete reminders" is never crushed to "Del-ete re…" beside a fixed-size pill (seen on the AX-XL capture).
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph).font(.footnote).foregroundStyle(pending ? LooplDesign.accent : Color.secondary)
                    .transition(.scale.combined(with: .opacity))
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title ?? defaultTitle).font(.callout.weight(.semibold)).lineLimit(stacked ? 3 : 2)
                    if let answer {
                        Text(answer.summary(for: request)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            .transition(.opacity).accessibilityIdentifier("ask-summary")
                    }
                }
                if !stacked { Spacer(minLength: 0); trailing }
            }
            if stacked { trailing }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11y)
    }
    @ViewBuilder private var trailing: some View {
        if pending { Pill("waiting for you", tint: LooplDesign.accent).fixedSize().accessibilityIdentifier("ask-waiting") }
        else {
            Button { LooplDesign.haptic(); showDetail.toggle() } label: { DisclosureChevron(expanded: showDetail) }
                .buttonStyle(.plain).accessibilityLabel(showDetail ? "hide the question" : "show the question")
        }
    }

    /// Cancel is always possible and honest: the model is told `{ok:false, cancelled:true}`.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("The agent waits for your answer").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            Spacer(minLength: 8)
            Button(role: .cancel) { finish(.cancelled, haptic: LooplDesign.failure) } label: {
                Text("Cancel").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityIdentifier("ask-cancel")
            .accessibilityHint("the agent is told you did not answer")
        }
        .padding(.top, 2)
    }

    // MARK: controls per type

    @ViewBuilder private var controls: some View {
        switch request.type {
        case .confirm: confirmButtons
        case .select: radioList
        case .multiselect: checkboxList
        case .input: inputField
        case .buttons: chips
        case .form: form
        case .message:
            primaryButton("Continue", systemImage: "arrow.right", id: "ask-continue") { finish(.answered(.string("acknowledged"))) }
        }
    }

    private var confirmButtons: some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            primaryButton("Yes", systemImage: "checkmark", id: "ask-yes") { finish(.answered(.bool(true))) }
            secondaryButton("No", systemImage: "xmark", id: "ask-no") { finish(.answered(.bool(false)), haptic: { LooplDesign.haptic() }) }
        }
    }

    private var radioList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(request.options) { option in
                Button {
                    LooplDesign.haptic()
                    picked = option.value
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: picked == option.value ? "largecircle.fill.circle" : "circle")
                            .font(.body).foregroundStyle(picked == option.value ? LooplDesign.accent : Color.secondary)
                        Text(option.label).font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .background(picked == option.value ? LooplDesign.accent.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask-option-\(option.value)")
                .accessibilityAddTraits(picked == option.value ? [.isSelected] : [])
            }
            primaryButton("Choose", systemImage: "checkmark", id: "ask-done", enabled: picked != nil) {
                if let picked { finish(.answered(.string(picked))) }
            }
            .padding(.top, 4)
        }
    }

    private var checkboxList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(request.options) { option in
                let on = checked.contains(option.value)
                Button {
                    LooplDesign.haptic()
                    if on { checked.remove(option.value) } else { checked.insert(option.value) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .font(.body).foregroundStyle(on ? LooplDesign.accent : Color.secondary)
                        Text(option.label).font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .background(on ? LooplDesign.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask-option-\(option.value)")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
            HStack(spacing: 10) {
                Button {
                    LooplDesign.haptic()
                    if checked.count == request.options.count { checked.removeAll() } else { checked = Set(request.options.map(\.value)) }
                } label: {
                    Text(checked.count == request.options.count ? "None" : "All").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("ask-all")
                Spacer(minLength: 0)
                Text(checked.isEmpty ? "none picked" : "\(checked.count) picked").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            primaryButton("Done", systemImage: "checkmark", id: "ask-done") {
                finish(.answered(.array(request.options.map(\.value).filter { checked.contains($0) }.map(JSONValue.string))))
            }
            .padding(.top, 4)
        }
    }

    private var inputField: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            TextField("Your answer", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(LooplDesign.tertiaryFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .focused($focusedField, equals: "input")
                .submitLabel(.send)
                .onSubmit { sendInput() }
                .accessibilityIdentifier("ask-input")
            Button { sendInput() } label: {
                Group {
                    if stacked { Label("Send", systemImage: "arrow.up").frame(maxWidth: .infinity) }
                    else { Image(systemName: "arrow.up").frame(width: 44) }
                }
                .font(.callout.weight(.semibold)).padding(.vertical, 9)
                .background(LooplDesign.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(ApprovalPressStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send").accessibilityIdentifier("ask-send")
        }
    }

    private var chips: some View {
        // Chips wrap onto as many rows as they need; accessibility sizes stack them full width.
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(FlowLayout(spacing: 8))
        return layout {
            ForEach(request.options) { option in
                Button {
                    finish(.answered(.string(option.value)))
                } label: {
                    Text(option.label).font(.callout.weight(.medium)).lineLimit(stacked ? 3 : 1)
                        .frame(maxWidth: stacked ? .infinity : nil)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(option.value == request.default ? LooplDesign.accent.opacity(0.18) : LooplDesign.tertiaryFill, in: Capsule())
                        .foregroundStyle(option.value == request.default ? LooplDesign.accent : Color.primary)
                }
                .buttonStyle(ApprovalPressStyle())
                .accessibilityIdentifier("ask-option-\(option.value)")
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(request.fields) { field in
                let missing = showMissing && field.required && isEmpty(field)
                VStack(alignment: .leading, spacing: 4) {
                    if field.type != .toggle {
                        HStack(spacing: 4) {
                            Text(field.label).font(.caption.weight(.semibold)).foregroundStyle(missing ? Color.red : Color.secondary)
                            if field.required { Text("*").font(.caption.weight(.semibold)).foregroundStyle(missing ? Color.red : LooplDesign.accent).accessibilityLabel("required") }
                        }
                    }
                    switch field.type {
                    case .text:
                        TextField(field.label, text: binding(field))
                            .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(LooplDesign.tertiaryFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .focused($focusedField, equals: field.name).submitLabel(.next).onSubmit { focusNext(after: field) }
                            .accessibilityIdentifier("ask-field-\(field.name)")
                    case .password:
                        // `.oneTimeCode` keeps iOS from offering to SAVE this password (the "Save Password?" sheet came up on the first
                        // capture): the value is a one-off handed to the agent, not an account the keychain should keep.
                        SecureField(field.label, text: binding(field))
                            .textContentType(.oneTimeCode)
                            .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(LooplDesign.tertiaryFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .focused($focusedField, equals: field.name).submitLabel(.next).onSubmit { focusNext(after: field) }
                            .accessibilityIdentifier("ask-field-\(field.name)")
                    case .number:
                        TextField(field.label, text: binding(field))
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(LooplDesign.tertiaryFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .focused($focusedField, equals: field.name).submitLabel(.next).onSubmit { focusNext(after: field) }
                            .accessibilityIdentifier("ask-field-\(field.name)")
                    case .toggle:
                        Toggle(isOn: Binding(get: { formToggles[field.name] ?? (field.default.map(Self.truthy) ?? false) },
                                             set: { formToggles[field.name] = $0 })) {
                            Text(field.label).font(.callout)
                        }
                        .tint(LooplDesign.accent)
                        .accessibilityIdentifier("ask-field-\(field.name)")
                    }
                }
            }
            if showMissing, request.fields.contains(where: { $0.required && isEmpty($0) }) {
                Text("Fill in the required fields").font(.caption).foregroundStyle(.red).transition(.opacity)
                    .accessibilityIdentifier("ask-missing")
            }
            primaryButton("Submit", systemImage: "checkmark", id: "ask-submit") { submitForm() }
                .keyboardShortcut(.return, modifiers: .command)
                .padding(.top, 2)
        }
    }

    // MARK: buttons

    private func primaryButton(_ title: String, systemImage: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(enabled ? LooplDesign.accent : LooplDesign.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(ApprovalPressStyle())
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }
    private func secondaryButton(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(LooplDesign.tertiaryFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .foregroundStyle(.primary)
        }
        .buttonStyle(ApprovalPressStyle())
        .accessibilityIdentifier(id)
    }

    // MARK: behaviour

    private func seed() {
        guard pending else { return }
        if text.isEmpty, request.type == .input, let d = request.default { text = d }
        if picked == nil, request.type == .select, let d = request.default, request.options.contains(where: { $0.value == d }) { picked = d }
        for f in request.fields where formValues[f.name] == nil {
            if f.type == .toggle { formToggles[f.name] = f.default.map(Self.truthy) ?? false }
            else if let d = f.default { formValues[f.name] = d }
        }
    }
    private func binding(_ field: AskUserRequest.Field) -> Binding<String> {
        Binding(get: { formValues[field.name] ?? "" }, set: { formValues[field.name] = $0 })
    }
    private func isEmpty(_ field: AskUserRequest.Field) -> Bool {
        field.type != .toggle && (formValues[field.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    private func focusNext(after field: AskUserRequest.Field) {
        let typed = request.fields.filter { $0.type != .toggle }
        guard let i = typed.firstIndex(where: { $0.name == field.name }) else { return }
        if i + 1 < typed.count { focusedField = typed[i + 1].name } else { focusedField = nil; submitForm() }
    }
    private func sendInput() {
        finish(.answered(.string(text.trimmingCharacters(in: .whitespacesAndNewlines))))
    }
    private func submitForm() {
        if request.fields.contains(where: { $0.required && isEmpty($0) }) {
            LooplDesign.failure(); showMissing = true
            focusedField = request.fields.first { $0.required && isEmpty($0) }?.name
            return
        }
        var out: [String: JSONValue] = [:]
        for f in request.fields {
            switch f.type {
            case .toggle: out[f.name] = .bool(formToggles[f.name] ?? (f.default.map(Self.truthy) ?? false))
            case .number:
                let raw = (formValues[f.name] ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                out[f.name] = Double(raw).map(JSONValue.number) ?? (raw.isEmpty ? .null : .string(raw))
            case .text, .password: out[f.name] = .string(formValues[f.name] ?? "")
            }
        }
        finish(.answered(.object(out)))
    }
    private func finish(_ a: AskUserAnswer, haptic: @MainActor () -> Void = LooplDesign.success) {
        guard pending else { return }
        focusedField = nil
        haptic()
        onAnswer(a)
    }
    static func truthy(_ s: String) -> Bool { ["true", "yes", "on", "1"].contains(s.lowercased()) }

    // MARK: copy

    private var glyph: String {
        if let answer {
            switch answer { case .answered: return "checkmark.bubble.fill"; case .cancelled: return "xmark.bubble"; case .timedOut: return "clock.badge.xmark" }
        }
        switch request.type {
        case .confirm: return "questionmark.bubble.fill"
        case .select, .buttons: return "list.bullet.circle.fill"
        case .multiselect: return "checklist"
        case .input: return "text.cursor"
        case .form: return "list.bullet.rectangle.fill"
        case .message: return "info.circle.fill"
        }
    }
    private var defaultTitle: String {
        switch request.type {
        case .confirm: "Confirm"
        case .select, .buttons: "Pick one"
        case .multiselect: "Pick any"
        case .input: "Your answer"
        case .form: "Fill in"
        case .message: "Note"
        }
    }
    private var borderTint: Color { pending ? LooplDesign.accent.opacity(0.35) : LooplDesign.accent.opacity(0.12) }
    private var a11y: String {
        if let answer { return "\(request.title ?? defaultTitle): \(answer.summary(for: request))" }
        // VoiceOver: the question itself first, then the state (glossary: never "the agent" in user-facing words).
        return "The model asks: \(request.text). Waiting for your answer."
    }
}

/// Left-aligned wrapping row (the `buttons` chips). Minimal: measures each child at its ideal size and breaks lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
