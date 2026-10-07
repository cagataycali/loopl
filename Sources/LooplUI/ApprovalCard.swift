import SwiftUI
import Loopl

// Human-in-the-loop card. Rendered inline by `AgentTranscriptView` for every
// `TranscriptItem.Kind.approval`: a pending card asks (Approve · Deny · Edit),
// a resolved card collapses to one quiet line. Motion through
// `LooplDesign.Motion` only; Reduce Motion crossfades; haptics on each answer.

public struct ApprovalCard: View {
    public var request: ApprovalRequest
    public var decision: ApprovalDecision?
    public var onDecide: (ApprovalDecision) -> Void
    @State private var showBody = false
    @State private var editing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Accessibility text sizes: the header stacks and the three actions go vertical, so nothing hyphenates or truncates.
    private var stacked: Bool { typeSize.isAccessibilitySize }

    public init(request: ApprovalRequest, decision: ApprovalDecision? = nil, onDecide: @escaping (ApprovalDecision) -> Void) {
        self.request = request; self.decision = decision; self.onDecide = onDecide
        // An http body is a detail the user may open; a CHANGE preview (old → new, e.g. `system_prompt`) IS the decision — open.
        _showBody = State(initialValue: request.method == nil && request.url == nil && (request.bodyPreview?.isEmpty == false))
    }
    /// The disclosure's word: `body` for something actually sent over the network, `change` for what a tool will
    /// alter on this phone. The discriminator is the HOST, not the method — keying it off `method == nil` meant the
    /// clipboard card (`method: "COPY"`, no URL) offered **"Show what is sent"** for a write that sends nothing
    /// anywhere, which flatly contradicts the card's own pill. Same rule as `riskWord`: a host means data leaves.
    private var bodyWord: String { request.host == nil ? "change" : "body" }
    /// Pure form of the rule above, so a test can pin it without rendering a view.
    public static func bodyWord(of request: ApprovalRequest) -> String { request.host == nil ? "change" : "body" }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if decision == nil {
                if let detail = request.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                if !request.headers.isEmpty { headersView }
                if let preview = request.bodyPreview, !preview.isEmpty { bodyPreview(preview) }
                actions
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(borderTint, lineWidth: 1))
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: decision)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: showBody)
        .sheet(isPresented: $editing) {
            ApprovalEditor(request: request) { edited in
                editing = false
                LooplDesign.success()
                onDecide(.approveEdited(edited))
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: pieces

    private var header: some View {
        // The host is the one word a person must read before tapping Approve, so it is never shortened. One line while
        // glyph · METHOD · host · risk pill all fit (ViewThatFits measures the host at full width — `fixedSize`); when
        // they do not — a long host on a 375 pt screen, or an accessibility text size — the pill moves above the host
        // and the host may wrap to two lines. IMPROVE-5: on an SE the pill squeezed it to "notes.examp…".
        VStack(alignment: .leading, spacing: 2) {
            if stacked {
                stackedTitle
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        badges
                        hostText(lines: 1).fixedSize(horizontal: true, vertical: false)
                        if decision == nil { riskPill }
                    }
                    stackedTitle    // last candidate = the fallback, used whether or not it fits
                }
            }
            if let what = titleParts.what {
                // "Add reminder · Call the dentist back": the thing being approved gets its own line and may wrap —
                // it is the one part of the card the user must be able to read before tapping Approve.
                Text(what).font(.callout).lineLimit(3)
                    .accessibilityIdentifier("approval-what")
            }
            if let path = pathLine {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(stacked ? 3 : 1).truncationMode(stacked ? .tail : .middle)
            }
            if let d = decision { Text(verdict(d)).font(.caption).foregroundStyle(.secondary).transition(.opacity) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11y)
    }

    /// glyph · METHOD, then the risk pill pushed to the trailing edge (used when the title cannot be one line).
    private var stackedTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                badges
                Spacer(minLength: 0)
                if decision == nil { riskPill }
            }
            hostText(lines: 2)
        }
    }

    @ViewBuilder private var badges: some View {
        if let d = decision {
            Image(systemName: d.isApproved ? "checkmark.shield.fill" : "xmark.shield.fill")
                .font(.footnote).foregroundStyle(d.isApproved ? LooplDesign.accent : Color.secondary)
                .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: "hand.raised.fill").font(.footnote).foregroundStyle(riskTint)
                .transition(.scale.combined(with: .opacity))
        }
        if let m = request.method { MethodBadge(m, tint: riskTint).fixedSize() }
    }

    private func hostText(lines: Int) -> some View {
        Text(request.host ?? titleParts.head).font(.callout.weight(.semibold)).lineLimit(lines)
            .accessibilityIdentifier("approval-host")
    }

    private var headersView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(request.headers.keys.sorted(), id: \.self) { k in
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    Text(k).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                    Text(request.headers[k] ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(stacked ? 2 : 1)
                }
            }
        }
    }

    private func bodyPreview(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                LooplDesign.haptic()
                showBody.toggle()
            } label: {
                HStack(spacing: 6) {
                    // "Show what is sent" rather than "BODY 51 B" (IMPROVE-3 audit #11); the size is for the a11y label.
                    Text(showBody ? "Hide \(bodyWord == "change" ? "the change" : "what is sent")" : "Show \(bodyWord == "change" ? "the change" : "what is sent")")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    DisclosureChevron(expanded: showBody)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel((showBody ? "hide \(bodyWord)" : "show \(bodyWord)") + ", \(preview.utf8.count) bytes")
            .accessibilityIdentifier("approval-\(bodyWord)-toggle")
            if showBody {
                Text(preview).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(14)
                    .accessibilityIdentifier("approval-\(bodyWord)-preview")
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LooplDesign.tertiaryFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var actions: some View {
        // Default sizes: Approve · Deny side by side, Edit as a square icon button. Accessibility sizes: one column,
        // every button full width with its label — "Ap-prov-e" / "Den-y" hyphenation is what the row did before.
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button {
                LooplDesign.success()
                onDecide(.approve)
            } label: {
                Label("Approve", systemImage: "checkmark").font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(LooplDesign.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(ApprovalPressStyle())
            .accessibilityHint("runs the call as shown")
            Button {
                LooplDesign.failure()
                onDecide(.deny(reason: nil))
            } label: {
                Label("Deny", systemImage: "xmark").font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(LooplDesign.tertiaryFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(ApprovalPressStyle())
            .accessibilityHint("the model is told you refused")
            Button {
                LooplDesign.haptic()
                editing = true
            } label: {
                Group {
                    if stacked { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity) }
                    else { Image(systemName: "pencil").frame(width: 44) }
                }
                .font(.callout.weight(.semibold)).padding(.vertical, 9)
                .background(LooplDesign.tertiaryFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .foregroundStyle(.primary)
            }
            .buttonStyle(ApprovalPressStyle())
            .accessibilityLabel("Edit")
            .accessibilityHint("change the request before approving")
        }
        .padding(.top, 2)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
    }

    /// The consequence pill. `approval-risk` is a stable identifier so a test can read it without pinning the words
    /// — the words are exactly what this lane keeps improving (IMPROVE-6's rule: find a row by its identifier).
    private var riskPill: some View {
        Pill(Self.riskWord(of: request), tint: riskTint).fixedSize()
            .accessibilityIdentifier("approval-risk")
    }
    private var riskTint: Color {
        switch request.risk { case .low: LooplDesign.accent; case .medium: LooplDesign.amber; case .high: .red }
    }
    /// What the pill SAYS. `ApprovalRequest.Risk` is the SDK's grade — "low", "medium", "high" — and a grade is a
    /// developer's word for a policy decision, not an answer to the question the person holding the phone is asking:
    /// *what does tapping Approve actually do to me?* So the pill names the consequence, from the two facts that
    /// decide it — whether a network host is involved (does my data leave this phone, which is the whole point of
    /// an on-device app) and whether the thing can be taken back.
    ///
    /// Kept to three short words on purpose: the header is one line while glyph · METHOD · host · pill all fit, and
    /// the host is the part that must never be shortened (IMPROVE-5 #170). The sentence underneath already says
    /// exactly what the tool will do ("Sends 41 bytes of JSON to api.notes.app."), so the pill is the headline, not
    /// the explanation. The colour (accent · amber · red) still carries the grade.
    public static func riskWord(of request: ApprovalRequest) -> String {
        switch request.risk {
        case .low:    return "only reads"
        case .medium: return request.host == nil ? "makes a change" : "sends data out"
        case .high:   return "hard to undo"
        }
    }
    /// The same fact as a sentence, for VoiceOver — the pill is a visual shorthand and is folded into the card's
    /// combined label. Before this, a VoiceOver user heard the severity only on a `.high` card.
    public static func riskSentence(of request: ApprovalRequest) -> String {
        switch request.risk {
        case .low:    return "It only reads."
        case .medium: return request.host == nil ? "It changes something on your phone." : "It sends data off your phone."
        case .high:   return "This is hard to undo."
        }
    }
    private var borderTint: Color {
        guard decision == nil else { return LooplDesign.accent.opacity(0.12) }
        return riskTint.opacity(0.35)
    }
    /// Non-http titles come as "Label · payload" ("Copy to clipboard · See you at six"). The label is the heading, the
    /// payload is its own wrapping line; http cards (host set) and plain titles are unchanged.
    private var titleParts: (head: String, what: String?) { Self.titleParts(of: request) }
    public static func titleParts(of request: ApprovalRequest) -> (head: String, what: String?) {
        guard request.host == nil, let r = request.title.range(of: " · ") else { return (request.title, nil) }
        let what = String(request.title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return what.isEmpty ? (request.title, nil) : (String(request.title[..<r.lowerBound]), what)
    }
    private var pathLine: String? {
        guard let s = request.url, let u = URL(string: s), request.host != nil else { return nil }
        var p = u.path.isEmpty ? "/" : u.path
        if let q = u.query, !q.isEmpty { p += "?" + q }
        return p
    }
    private func verdict(_ d: ApprovalDecision) -> String {
        switch d {
        case .approve: "Approved"
        case .approveEdited: "Approved with edits"
        case .deny(let reason): reason.map { "Denied — \($0)" } ?? "Denied"
        }
    }
    /// VoiceOver: the question in words, then what it does ("Asks you first: send a note to api.notes.app. Sends data to…").
    private var a11y: String {
        let parts = titleParts
        let what = [parts.head, parts.what].compactMap { $0 }.joined(separator: " ")
        if let d = decision { return "\(what), \(verdict(d))" }
        var line = "Asks you first: \(what)."
        if let detail = request.detail, !detail.isEmpty { line += " \(detail)" }
        line += " " + Self.riskSentence(of: request)
        return line
    }
}

/// `POST` / `GET` chip, tinted by risk.
public struct MethodBadge: View {
    public var method: String
    public var tint: Color
    public init(_ method: String, tint: Color = LooplDesign.accent) { self.method = method; self.tint = tint }
    public var body: some View {
        Text(method).font(.caption2.monospaced().weight(.bold)).kerning(0.5)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(tint)
            .accessibilityLabel("method \(method)")
    }
}

/// Press feedback: a small scale + dim, interruptible (interactive spring); Reduce Motion dims only.
struct ApprovalPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(LooplDesign.Motion.interactive, value: configuration.isPressed)
    }
}

/// Edit the proposed input before approving. Each field is one line (strings)
/// or JSON (objects/arrays/numbers); invalid JSON keeps the Approve button off.
public struct ApprovalEditor: View {
    public var request: ApprovalRequest
    public var onApprove: ([String: JSONValue]) -> Void
    @State private var fields: [(key: String, text: String)] = []
    @State private var invalid: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    public init(request: ApprovalRequest, onApprove: @escaping ([String: JSONValue]) -> Void) {
        self.request = request; self.onApprove = onApprove
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(fields.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fields[i].key).font(.caption.weight(.semibold)).foregroundStyle(invalid.contains(fields[i].key) ? .red : .secondary)
                            TextField(fields[i].key, text: binding(i), axis: .vertical).font(.body.monospaced()).lineLimit(1...8)
                                .autocorrectionDisabled().noAutocapitalization()
                        }
                    }
                } header: { Text(request.title) } footer: {
                    Text(invalid.isEmpty ? "Strings are sent as typed; other values are parsed as JSON." : "Fix the JSON in \(invalid.sorted().joined(separator: ", ")).")
                }
            }
            .navigationTitle("Edit request")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") { onApprove(assembled()) }.font(.body.weight(.semibold)).disabled(!invalid.isEmpty)
                }
            }
            .onAppear { if fields.isEmpty { fields = request.input.sorted { $0.key < $1.key }.map { ($0.key, Self.text($0.value)) } } }
        }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { fields[i].text }, set: { v in
            fields[i].text = v
            let key = fields[i].key
            if case .string = request.input[key] { invalid.remove(key); return }
            if Self.parse(v) == nil { invalid.insert(key) } else { invalid.remove(key) }
        })
    }
    private func assembled() -> [String: JSONValue] {
        var out = request.input
        for f in fields {
            if case .string = request.input[f.key] { out[f.key] = .string(f.text) }
            else if let v = Self.parse(f.text) { out[f.key] = v }
        }
        return out
    }
    static func text(_ v: JSONValue) -> String { if case .string(let s) = v { return s }; return v.compact }
    static func parse(_ s: String) -> JSONValue? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }
}

private extension View {
    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func noAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
