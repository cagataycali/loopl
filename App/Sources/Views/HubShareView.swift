import SwiftUI
import Loopl
import LooplUI

/// The "Share to Hugging Face" sheet: review → (token) → dataset → push → link. One `HubShare` drives it;
/// steps cross-fade (Reduce Motion: plain fade), the push button pulses the flame, success/failure are
/// haptic. Design: document style, no cards-in-cards, the jsonl preview is monospaced and foldable.
struct HubShareView: View {
    @State var share: HubShare
    var onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var showPreview = false
    @Namespace private var ns

    var body: some View {
        NavigationStack {
            Group {
                switch share.stage {
                case .review: review
                case .account: account
                case .repo: repo
                case .pushing(let label): progress(label)
                case .done(let url, let rows, let images): done(url, rows: rows, images: images)
                case .failed(let msg): failed(msg)
                }
            }
            .animation(LooplDesign.Motion.faded(LooplDesign.spring, reduceMotion), value: share.stage)
            .navigationTitle("Share to Hugging Face")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isTerminal ? "Done" : "Cancel") { LooplDesign.haptic(); onDone() }
                        .disabled(isPushing)
                }
            }
            .looplBottomBar(false)
        }
        .interactiveDismissDisabled(isPushing)
    }

    private var isPushing: Bool { if case .pushing = share.stage { return true }; return false }
    private var isTerminal: Bool { if case .done = share.stage { return true }; return false }

    // MARK: Review

    private var review: some View {
        let shard = share.shard
        return List {
            Section {
                ForEach(share.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).lineLimit(2)
                            if let why = row.skipped {
                                Label(why, systemImage: LooplDesign.iconWarning).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            } else {
                                Text(summary(row)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: row.skipped == nil ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(row.skipped == nil ? LooplDesign.accent : .secondary)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("\(row.title), \(row.skipped ?? summary(row))")
                }
            } header: {
                Text("\(shard.records.count) of \(share.conversations.count) conversation\(share.conversations.count == 1 ? "" : "s") will be shared")
            } footer: {
                Text("Rows follow loopl-train's schema: the loopl system prompt, your turns, the model's answers, tool calls with their results\(share.hasTools ? ", and the tools each thread offered" : "").")
            }

            Section("Before it leaves this device") {
                Toggle(isOn: $share.redaction.stripImages) { Label("Remove pictures", systemImage: "photo.badge.exclamationmark") }
                Toggle(isOn: $share.redaction.stripToolResults) { Label("Remove tool results", systemImage: LooplDesign.iconTool) }
                Toggle(isOn: $share.redaction.anonymiseURLs) { Label("Replace URLs with example.com", systemImage: "link.badge.plus") }
            }
            .tint(LooplDesign.accent)

            Section {
                DisclosureGroup(isExpanded: $showPreview) {
                    ScrollView(.horizontal) {
                        Text(share.preview)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 320)
                } label: {
                    LabeledContent("Preview") { Text(sizeLine(shard)).foregroundStyle(.secondary) }
                }
            } footer: {
                Text("One jsonl line per conversation in `data/train-<timestamp>.jsonl`; pictures as `images/<hash>.png`. Private repo, your account, your Hugging Face token stays in the Keychain.")
            }
        }
        .looplScrollClearance()
        .safeAreaInset(edge: .bottom) {
            primaryButton(shard.records.isEmpty ? "Nothing to share" : "Continue", disabled: shard.records.isEmpty) {
                LooplDesign.haptic(); Task { await share.proceed() }
            }
        }
    }

    private func summary(_ r: HubShare.Row) -> String {
        var parts = ["\(r.turns) turn\(r.turns == 1 ? "" : "s")"]
        if r.toolCalls > 0 { parts.append("\(r.toolCalls) tool call\(r.toolCalls == 1 ? "" : "s")") }
        if r.images > 0 { parts.append("\(r.images) picture\(r.images == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
    private func sizeLine(_ s: ConversationExport.Shard) -> String {
        var t = ByteSize.label(Int64(s.byteCount))
        if !s.images.isEmpty { t += " · \(s.images.count) picture\(s.images.count == 1 ? "" : "s")" }
        return t
    }

    // MARK: Account

    private var account: some View {
        Form {
            Section {
                SecureField("hf_…", text: $share.tokenDraft)
                    .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .submitLabel(.go)
                    .onSubmit { Task { await share.verify(nil) } }
                    .accessibilityLabel("Hugging Face token")
            } header: {
                Text("Your Hugging Face token")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs **write** access to repositories (a classic *write* token, or a fine-grained token with *Write access to contents of all repos*). It is stored in this device's Keychain and sent only to huggingface.co.")
                    Button("Get a token at huggingface.co/settings/tokens") { openURL(URL(string: "https://huggingface.co/settings/tokens")!) }
                        .font(.footnote)
                }
            }
            if let error = share.error {
                Section { Label(error, systemImage: LooplDesign.iconWarning).foregroundStyle(.red) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            primaryButton("Verify", disabled: !HFAccount.looksLikeToken(share.tokenDraft)) { LooplDesign.haptic(); Task { await share.verify(nil) } }
        }
    }

    // MARK: Repo

    private var repo: some View {
        Form {
            if let who = share.whoami {
                Section {
                    HStack {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(LooplDesign.accent)
                        VStack(alignment: .leading) {
                            Text(who.fullname ?? who.name)
                            Text("@\(who.name) · \(who.scopeBadges.joined(separator: " · "))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign out") { share.signOut() }.font(.footnote)
                    }
                }
            }
            Section("Dataset") {
                Picker("Push to", selection: $share.chosenRepo) {
                    Text("New private dataset").tag(String?.none)
                    ForEach(share.datasets) { d in Text(d.name).tag(String?.some(d.id)) }
                }
                .pickerStyle(.menu)
                if share.chosenRepo == nil {
                    TextField("loopl-conversations", text: $share.repoName)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("New dataset name")
                }
                if let repo = share.targetRepo {
                    LabeledContent("Repository") { Text(repo).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }
            if let error = share.error {
                Section { Label(error, systemImage: LooplDesign.iconWarning).foregroundStyle(.red) }
            }
            Section {
                LabeledContent("Conversations", value: "\(share.shard.records.count)")
                LabeledContent("Upload", value: sizeLine(share.shard))
            } footer: {
                Text(share.createsNewRepo ? "A private dataset repo is created in your account; later shares append new shards to it." : "A new shard is appended; nothing already there is touched.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            primaryButton("Push \(share.shard.records.count) conversation\(share.shard.records.count == 1 ? "" : "s")", disabled: share.targetRepo == nil) {
                LooplDesign.haptic(1); Task { await share.push() }
            }
        }
    }

    // MARK: Progress / done / failed

    private func progress(_ label: String) -> some View {
        VStack(spacing: 18) {
            LooplMark()
                .frame(width: 64, height: 64)
                .scaleEffect(pulse ? 1.06 : 0.96)
                .animation(reduceMotion ? nil : LooplDesign.Motion.pulse, value: pulse)
                .onAppear { pulse = true }
                .matchedGeometryEffect(id: "mark", in: ns)
            Text(label).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ProgressView().tint(LooplDesign.accent)
        }
        .padding(LooplDesign.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sharing, \(label)")
    }
    @State private var pulse = false

    private func done(_ url: URL, rows: Int, images: Int) -> some View {
        VStack(spacing: 16) {
            LooplMark().frame(width: 64, height: 64).matchedGeometryEffect(id: "mark", in: ns)
            Text("Shared").font(.title2.weight(.semibold))
            Text("\(rows) conversation\(rows == 1 ? "" : "s")\(images > 0 ? " and \(images) picture\(images == 1 ? "" : "s")" : "") are in your private dataset.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { openURL(url) } label: { Label("Open on Hugging Face", systemImage: "arrow.up.right.square") }
                .buttonStyle(.bordered).tint(LooplDesign.accent)
            Text(url.absoluteString).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(LooplDesign.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { LooplDesign.success() }
    }

    private func failed(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: LooplDesign.iconWarning).font(.largeTitle).foregroundStyle(.red)
            Text("Not shared").font(.title2.weight(.semibold))
            Text(msg).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { LooplDesign.haptic(); share.retry() }.buttonStyle(.bordered).tint(LooplDesign.accent)
        }
        .padding(LooplDesign.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { LooplDesign.failure() }
    }

    // MARK: Primary button

    private func primaryButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent).tint(LooplDesign.accent)
        .disabled(disabled)
        .padding(.horizontal, LooplDesign.gutter)
        .padding(.bottom, 8)
        .background(.bar)
    }
}
