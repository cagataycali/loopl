import SwiftUI
import Loopl
import LooplUI

/// Models › Train your own: pick the conversations the user pushed to their Hugging Face account and a base (a public loopl size — the Qwen3.5-rooted v1.1 checkpoints — or
/// one of their own tuned models); epochs/GPU/method are Auto unless "Fine-tune manually" is opened; the cost guard is automatic
/// (2× the estimate, ≥ 15 min) and lives in the estimate sentence. See an honest cost estimate, confirm on the same ApprovalCard the agent uses for HITL, then watch the job's
/// `[loopl] stage=` ladder. The resulting private model lands under Models › Mine (HF-ACCOUNT lane) → download → default.
struct TrainView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var engine: Engine
    @Bindable var store: ModelStore
    @Bindable var settings: AppSettings
    /// Design fixture: a pre-baked session (no network). `nil` = live.
    var fixture: TrainingSession? = nil
    /// Design fixture: pretend a token is present so the form renders without an account.
    var fixtureSignedIn = false

    @State private var datasets: [HFHubClient.DatasetSummary] = []
    @State private var datasetsError: String?
    @State private var loadingDatasets = false
    @State private var dataset: HFHubClient.DatasetSummary?
    @State private var shardBytes: Int64 = 0
    @State private var conversations = 0
    @State private var inspecting = false
    @State private var inspectError: String?
    @State private var base: TrainingBase = .b0_8
    @State private var tunedBases: [TrainingTunedBase] = []
    @State private var tuned: TrainingTunedBase?          // nil = start from the public loopl checkpoint of the picked size
    @State private var method: TrainingMethod? = nil        // nil = Auto (the size's default)
    @State private var flavor: TrainingFlavor? = nil        // nil = Auto (the cheapest GPU the size trains well on)
    @State private var epochsChoice = 0                     // 0 = Auto, 1…4 fixed
    @State private var includeAllShards = true
    @State private var manual = false                       // "Fine-tune manually" disclosure
    @State private var outputName = ""
    @State private var confirming = false
    @State private var session: TrainingSession?
    @State private var showLog = false
    @State private var addError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    private var account: HFAccount { HFAccount.shared }
    private var signedIn: Bool { fixture != nil || fixtureSignedIn || (engine.hf.isSignedIn && engine.hf.author != nil) }
    private var user: String { fixture?.user ?? engine.hf.author ?? account.username ?? (fixtureSignedIn ? "cagataydev" : "") }
    /// A read-only token can list datasets but `POST /api/jobs` needs write — say so before the user fills the form.
    private var canRunJobs: Bool { fixture != nil || fixtureSignedIn || (engine.hf.identity?.scopes.contains(.jobs) ?? true) }

    /// What Auto resolves to right now (shown next to the pickers so "Auto" is never a mystery).
    private var size: TrainingBase { tuned?.size ?? base }
    private var autoFlavor: TrainingFlavor { size.recommendedFlavor }
    private var autoMethod: TrainingMethod { tuned != nil ? .lora : size.defaultMethod }

    private var plan: TrainingPlan? {
        guard let ds = dataset else { return nil }
        return TrainingPlan(dataset: ds.id, conversations: max(conversations, 1), withTools: conversations / 3, base: base, tunedBase: tuned, method: method ?? autoMethod,
                            flavor: flavor ?? autoFlavor, epochs: epochsChoice == 0 ? .auto : .fixed(epochsChoice), includeAllShards: includeAllShards,
                            outputName: outputName.isEmpty ? nil : TrainingPlan.repoSafe(outputName))
    }

    var body: some View {
        Group {
            if let s = session ?? fixture { runView(s) }
            else if !signedIn { signedOut }
            else { form }
        }
        .navigationTitle("Train your own")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("pane-train")
        .task {
            if fixtureSignedIn, fixture == nil {
                datasets = [HFHubClient.DatasetSummary(id: "cagataydev/loopl-app-conversations", tags: ["loopl", "loopl-conversations"]), HFHubClient.DatasetSummary(id: "cagataydev/loopl-train")]
                dataset = datasets.first; conversations = 191; shardBytes = 812_000; base = .b0_8
                tunedBases = [TrainingTunedBase(repo: "cagataydev/loopl-app-sim-4bit", bf16Repo: "cagataydev/loopl-app-sim", round: 1, size: .b0_8),
                              TrainingTunedBase(repo: "cagataydev/loopl-old-GGUF", bf16Repo: nil, round: 1, size: .b0_8)]
            } else if fixture == nil { await loadDatasets(); await loadTunedBases() }
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: confirming)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: session?.phase)
    }

    // MARK: signed out

    private var signedOut: some View {
        ContentUnavailableView {
            Label("Sign in to Hugging Face", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Training runs on Hugging Face Jobs under your own account: your conversations stay in your private dataset, the tuned model is yours. Add a **write** token in Settings › Hugging Face.")
                .accessibilityIdentifier("train-signed-out-text")
        } actions: {
            Button("Get a token") { openURL(URL(string: "https://huggingface.co/settings/tokens/new?tokenType=write")!) }
                .buttonStyle(.borderedProminent).tint(LooplDesign.accent)
        }
        .accessibilityIdentifier("train-signed-out")
    }

    // MARK: form

    private var form: some View {
        Form {
            Section {
                if loadingDatasets && datasets.isEmpty {
                    HStack { ProgressView(); Text("Looking for your conversation datasets…").foregroundStyle(.secondary) }
                } else if datasets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No conversation datasets yet").font(.body.weight(.medium))
                        Text("Open a chat in History, choose **Share to Hugging Face**, and the conversations you pick become a private dataset here.").font(.footnote).foregroundStyle(.secondary)
                        if let e = datasetsError { Text(e).font(.footnote).foregroundStyle(.orange) }
                    }
                } else {
                    if typeSize.isAccessibilitySize {
                        // Inline rows instead of a menu: the menu's label squeezed a repo name to "loopl-a…ations" at AX-XL
                        // however wide it was. A user has a handful of datasets; each gets a full-width, wrapping row.
                        Picker("Conversations", selection: $dataset) {
                            ForEach(datasets) { d in Text(d.name).tag(Optional(d)) }
                        }
                        .pickerStyle(.inline)
                        .accessibilityIdentifier("train-dataset")
                    } else {
                        Picker("Conversations", selection: $dataset) {
                            ForEach(datasets) { d in Text(d.name).tag(Optional(d)) }
                        }
                        .accessibilityIdentifier("train-dataset")
                    }
                    if dataset != nil {
                        LabeledContent("Size", value: inspecting ? "reading…" : conversations > 0 ? "≈ \(conversations) conversations · \(ByteSize.label(shardBytes))" : "no conversations found yet")
                            .accessibilityIdentifier("train-rows")
                        if let e = inspectError { Text(e).font(.footnote).foregroundStyle(.orange) }
                    }
                }
            } header: { Text("Your conversations") } footer: {
                if canRunJobs {
                    Text("Private, in your Hugging Face account (@\(user)).")
                } else {
                    Label("Your Hugging Face token can only read. Training needs a token that can write — Settings › Hugging Face.", systemImage: LooplDesign.iconWarning).foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Base model", selection: $base) {
                    ForEach(TrainingBase.allCases) { b in Text(b.label).tag(b) }
                }
                .pickerStyle(.segmented)
                .disabled(tuned != nil)
                .accessibilityIdentifier("train-base")
                if !tunedBases.isEmpty {
                    Picker("Continue a model", selection: $tuned) {
                        Text("No — start fresh").tag(Optional<TrainingTunedBase>.none)
                        ForEach(tunedBases.filter(\.isTrainable)) { t in
                            Text("\(t.name) · \(t.roundLabel)").tag(Optional(t))
                        }
                    }
                    .accessibilityIdentifier("train-continue")
                    if let t = tuned {
                        Label("Round \(t.round + 1): builds on \(t.name) — what it already learned stays in.", systemImage: "arrow.triangle.branch")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("train-continue-note")
                        Toggle("Learn from everything I've shared so far", isOn: $includeAllShards)
                            .accessibilityIdentifier("train-replay")
                    }
                }
                LabeledContent("Passes", value: epochsChoice == 0 ? "Auto (recommended)" : "\(epochsChoice)")
                    .accessibilityIdentifier("train-epochs")
                TextField("Model name", text: $outputName, prompt: Text(plan.map(\.outputName) ?? "loopl-mine-0-8b"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("train-name")
                DisclosureGroup(isExpanded: $manual) {
                    Picker("Passes", selection: $epochsChoice) {
                        Text("Auto (recommended)").tag(0)
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .accessibilityIdentifier("train-epochs-picker")
                    Text(epochsFootnote).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("train-epochs-note")
                    Picker("GPU", selection: $flavor) {
                        Text("Auto · \(autoFlavor.label)").tag(Optional<TrainingFlavor>.none)
                        ForEach(TrainingFlavor.gpuChoices) { f in Text("\(f.label) · \(f.priceLabel)").tag(Optional(f)) }
                    }
                    .accessibilityIdentifier("train-flavor")
                    Picker("Method", selection: $method) {
                        Text("Auto · \(autoMethod.label)").tag(Optional<TrainingMethod>.none)
                        ForEach(TrainingMethod.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("train-method")
                } label: {
                    Label("More options", systemImage: "slider.horizontal.3")
                        .accessibilityIdentifier("train-manual")
                }
            } header: { Text("How it trains") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let plan {
                        Text(plan.summary(user: user)).accessibilityIdentifier("train-summary")
                    }
                    if tuned == nil, base != TrainingBase.recommended(forConversations: conversations) {
                        Text("Suggested for \(conversations) conversations: \(TrainingBase.recommended(forConversations: conversations).label).")
                    }
                    let blocked = tunedBases.filter { !$0.isTrainable }
                    if !blocked.isEmpty {
                        Text("\(blocked.map(\.name).joined(separator: ", ")) can't be continued — \(blocked.count == 1 ? "it was" : "they were") not saved in a form that can be trained further. Start fresh or pick another model.")
                            .accessibilityIdentifier("train-continue-blocked")
                    }
                }
            }

            if let plan {
                Section {
                    estimateCard(plan.estimate, plan: plan)
                    if confirming {
                        ApprovalCard(request: approvalRequest(plan)) { decision in
                            confirming = false
                            if decision.isApproved { launch(plan) }
                        }
                        .accessibilityIdentifier("train-approval")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Button {
                            LooplDesign.haptic(1)
                            confirming = true
                        } label: {
                            Label("Train on Hugging Face", systemImage: "sparkles").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(LooplDesign.accent).controlSize(.large)
                        .disabled(conversations == 0 || settings.offline || !canRunJobs)
                        .accessibilityIdentifier("train-start")
                    }
                } footer: {
                    Text(settings.offline ? "Offline mode is on — turn it off in Settings to start a job." :
                         "You confirm the exact job before anything is billed.")
                }
            }
        }
        .looplScrollClearance()
        .onChange(of: dataset) { _, d in if !fixtureSignedIn { Task { await inspect(d) } } }
    }

    private var epochsFootnote: String {
        let h = TrainingEpochs.heuristic(forConversations: conversations)
        // A pass = the model reads every conversation once. Fewer conversations want more passes.
        let guide = "Fewer conversations need more passes: under 200 → 3–4, up to 1 000 → 2, more → 1–2. For your \(conversations): \(h.text)."
        return epochsChoice == 0 ? "Auto tries up to \(h.autoMax) pass\(h.autoMax == 1 ? "" : "es") and keeps the one that scores best. \(guide)" : guide
    }

    private func estimateCard(_ e: TrainingEstimate, plan: TrainingPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.usdLabel).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                Text("· about \(TrainingEstimate.spoken(e.totalSeconds))").foregroundStyle(.secondary)
                Spacer()
            }
            Text("Stops by itself if it runs past \(TrainingEstimate.spoken(Double(e.capSeconds))) — Hugging Face bills your account per minute until then.")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("train-cap")
            Text("About \(e.steps) training steps on \(plan.flavor.label) at \(plan.flavor.priceLabel), then checking and making the iPhone version\(plan.skipGGUF ? "" : " and the Mac and PC version"). An estimate, not a quote.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(e.sentence)
        .accessibilityIdentifier("train-estimate")
    }

    private func approvalRequest(_ plan: TrainingPlan) -> ApprovalRequest {
        let spec = TrainingLaunch.jobSpec(plan: plan, user: user, token: "•••", now: Date())
        let args = spec.command.dropFirst(4).joined(separator: " ")
        return ApprovalRequest(
            toolName: "hf_jobs",
            title: "Start a training job on Hugging Face",
            method: "POST", url: "https://huggingface.co/api/jobs/\(user)",
            bodyPreview: "flavor \(plan.flavor.id) · timeout \(TrainingEstimate.duration(Double(plan.timeoutSeconds)))\nloopl_sft.py \(args)",
            detail: "\(plan.estimate.sentence) Saved privately as \(plan.outputRepo(user: user)), with the iPhone version\(plan.skipGGUF ? "" : " and the Mac and PC version").",
            risk: .high)
    }

    // MARK: running / finished

    @ViewBuilder
    private func runView(_ s: TrainingSession) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(phaseTitle(s)).font(.title3.weight(.semibold))
                        Spacer()
                        Text(TrainingEstimate.usd(s.spentUSD)).monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityIdentifier("train-spent")
                    }
                    ProgressView(value: s.phase.isActive || s.progress.isDone ? s.progress.fraction : (s.progress.isFailed ? s.progress.fraction : 0))
                        .tint(s.progress.isFailed ? .orange : LooplDesign.accent)
                        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.value, reduceMotion), value: s.progress.fraction)
                    Text(([s.plan.baseLabel, s.plan.method == .full ? s.plan.method.label : nil, "\(s.plan.conversations) conversations", "passes: \(s.plan.epochs.label.lowercased())"].compactMap { $0 }).joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                    if let p = s.progress.plan, (p.stitched ?? 0) > 0 || (p.round ?? 1) > 1 {
                        Text([p.stitched.map { "\($0) conversations joined by day" }, p.epochsMax.map { "up to \(Int($0)) passes" }].compactMap { $0 }.joined(separator: " · "))   // round is already on the line above
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("train-plan")
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(TrainingStage.order, id: \.self) { name in stageRow(name, s) }
                if let e = s.progress.error {
                    // The sentence a person can act on first; the raw line one tap away in the Job log (IMPROVE-4 #28).
                    VStack(alignment: .leading, spacing: 4) {
                        Label(TrainingFailure.plain(e), systemImage: LooplDesign.iconWarning).font(.footnote.weight(.medium)).foregroundStyle(.orange)
                        Text(e.split(whereSeparator: \.isNewline).first.map(String.init) ?? e).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("train-error")
                }
            } header: { Text("Stages") }

            if case .finished(_, let out) = s.phase { resultSection(out, s) }

            Section {
                DisclosureGroup("Job log", isExpanded: $showLog) {
                    ScrollView(.horizontal) {
                        Text(s.logTail.suffix(40).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .frame(minHeight: 60)
                }
                .accessibilityIdentifier("train-log")
                if let url = s.jobURL { Link(destination: url) { Label("Open on Hugging Face", systemImage: "arrow.up.right.square") } }
                if s.phase.isActive {
                    Button(role: .destructive) { Task { await s.cancel() } } label: { Label("Cancel job", systemImage: "xmark.circle") }
                        .accessibilityIdentifier("train-cancel")
                } else {
                    Button { session = nil; confirming = false } label: { Label("Train another", systemImage: "arrow.counterclockwise") }
                }
            }
        }
        .looplScrollClearance()
        .accessibilityIdentifier("train-run")
    }

    private func phaseTitle(_ s: TrainingSession) -> String {
        switch s.phase {
        case .idle: "Ready"
        case .preparing(let what): what
        case .running: s.progress.current.map { st in st.name == "train" && s.progress.trainStep != nil ? "Training · step \(s.progress.trainStep!.step)/\(s.progress.trainStep!.total)" : st.label } ?? "Starting…"
        case .finished: "Your model is ready"
        case .failed: "Training failed"
        case .cancelled: "Cancelled"
        }
    }

    private func stageRow(_ name: String, _ s: TrainingSession) -> some View {
        let done = s.progress.stages.first { $0.name == name }
        let isCurrent = s.progress.current?.name == name && s.phase.isActive
        let reached = done != nil
        // the stage that was running when the job died gets the warning, not a checkmark
        let broke = s.progress.isFailed && s.progress.stages.filter { $0.name != "error" }.max { $0.index < $1.index }?.name == name
        let tint: Color = broke ? .orange : LooplDesign.accent
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(reached ? tint : Color.secondary.opacity(0.3), lineWidth: 1.5).frame(width: 18, height: 18)
                if broke { Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(tint) }
                else if reached && !isCurrent { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(tint) }
                if isCurrent { Circle().fill(tint).frame(width: 8, height: 8).opacity(0.9) }
            }
            Text(TrainingStage(name: name).label).foregroundStyle(reached ? .primary : .secondary)
            Spacer()
            if let t = done?.elapsed, name != "done" { Text(TrainingEstimate.duration(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if name == "train", isCurrent, let l = s.progress.loss { Text(String(format: "loss %.2f", l)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("train-stage-\(name)")
    }

    @ViewBuilder
    private func resultSection(_ out: TrainingOutput, _ s: TrainingSession) -> some View {
        Section {
            if let b = out.evalLossBase, let t = out.evalLossTuned {
                LabeledContent("Held-out loss", value: String(format: "%.2f → %.2f", b, t))
                    .accessibilityIdentifier("train-loss")
            }
            if let m = out.toolNameMatch { LabeledContent("Tool calls right", value: m) }
            if out.mlx != nil, let kept = out.keptVision {
                LabeledContent("Vision") { Label(kept ? "kept ✓ (\(out.visionTensors ?? 0) tensors)" : "text-only", systemImage: kept ? "eye" : "eye.slash") }
                    .accessibilityIdentifier("train-vision")
            }
            if let hist = out.evalHistory ?? (s.progress.evalHistory.isEmpty ? nil : s.progress.evalHistory), !hist.isEmpty {
                epochChart(hist, best: out.bestEpoch)
            }
            if let lineage = out.lineage, lineage.count > 1 || (out.round ?? 1) > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lineage · round \(out.round ?? lineage.count)").font(.footnote.weight(.medium))
                    Text((lineage + [out.merged ?? s.plan.outputRepo(user: s.user)]).map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: " → "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                }
                .accessibilityIdentifier("train-lineage")
            }
            if let repo = out.mlx {
                Button {
                    Task { await addToModels(repo) }
                } label: { Label("Add \(repo.split(separator: "/").last.map(String.init) ?? repo) to Models", systemImage: LooplDesign.iconDownload) }
                .accessibilityIdentifier("train-add-model")
            } else if let e = out.mlxError {
                Label("iPhone conversion failed: \(e.prefix(160))", systemImage: LooplDesign.iconWarning).font(.footnote).foregroundStyle(.orange)
            }
            if let e = out.ggufError { Text("GGUF: \(e.prefix(120))").font(.caption).foregroundStyle(.secondary) }
            if let e = addError { Text(e).font(.footnote).foregroundStyle(.orange) }
        } header: { Text("Result") } footer: {
            Text("Private repos in your account: \(out.merged ?? "") (weights), \(out.mlx ?? "–") (iPhone), \(out.gguf ?? "–") (GGUF). They also appear under Models › Mine.")
        }
    }

    /// Held-out loss per epoch as bars (lower is better); the kept epoch is accented. No Charts dependency — a few capsules.
    private func epochChart(_ hist: [TrainingEpochLoss], best: Int?) -> some View {
        let lo = hist.map(\.evalLoss).min() ?? 0, hi = hist.map(\.evalLoss).max() ?? 1
        let span = max(hi - lo, 0.01)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Score by pass — lower is better").font(.footnote.weight(.medium))
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(hist) { h in
                    VStack(spacing: 3) {
                        Text(String(format: "%.2f", h.evalLoss)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Capsule().fill(h.epoch == best ? LooplDesign.accent : Color.secondary.opacity(0.35))
                            .frame(width: 22, height: 14 + 40 * CGFloat((h.evalLoss - lo) / span))
                        Text("pass \(h.epoch)").font(.caption2).foregroundStyle(h.epoch == best ? .primary : .secondary)
                    }
                }
                Spacer()
            }
            if let best { Text("Kept pass \(best) — it scored best.").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("train-epochs-chart")
        .accessibilityLabel("Score by pass, lower is better: " + hist.map { "pass \($0.epoch) \(String(format: "%.2f", $0.evalLoss))" }.joined(separator: ", "))
    }

    // MARK: actions

    /// Mine's runnable repos → one trainable base per bf16 twin (the script trains from bf16, never from 4-bit).
    private func loadTunedBases() async {
        guard signedIn, !user.isEmpty else { return }
        do {
            let hub = HubCatalog(token: account.provider)
            let runnable = try await hub.mine(author: user).map(\.id)
            let owned = try await hub.owned(author: user)
            let bases = TrainingTunedBase.fromOwned(runnable: runnable, owned: owned)
            withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { tunedBases = bases }
        } catch { /* the stock picker is always there; Mine is optional */ }
    }

    private func loadDatasets() async {
        guard signedIn, !user.isEmpty else { return }
        loadingDatasets = true; defer { loadingDatasets = false }
        do {
            let all = try await account.client().datasets(author: user)
            // app shares (tag loopl-conversations) first and the only auto-pick; a curated set like loopl-train is never a default
            let mine = all.filter(\.isLooplShare) + all.filter { !$0.isLooplShare }
            withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion)) { datasets = mine }
            if dataset == nil { dataset = mine.first(where: \.isLooplShare) }
        } catch { datasetsError = error.localizedDescription }
    }

    /// Count the shards the script will read (every `*.jsonl` in the repo: lane C's `data/`, older `conversations/`, or the root):
    /// one JSON object per line → an exact count for small sets (one download), ≈ bytes / 4 KB for big ones.
    private func inspect(_ d: HFHubClient.DatasetSummary?) async {
        conversations = 0; shardBytes = 0; inspectError = nil
        guard let d else { return }
        inspecting = true; defer { inspecting = false }
        do {
            let client = account.client()
            var shards: [HFHubClient.TreeEntry] = []
            let root = try await client.tree(repo: d.id, type: .dataset)
            shards += root.filter { $0.isFile && $0.path.hasSuffix(".jsonl") }
            for dir in root.filter({ !$0.isFile && $0.path != "train" && !$0.path.hasPrefix(".") }) {
                let sub = try await client.tree(repo: d.id, type: .dataset, path: dir.path)
                shards += sub.filter { $0.isFile && $0.path.hasSuffix(".jsonl") }
            }
            let bytes = shards.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            var n = Int(bytes / 4096)
            if shards.count <= 3, bytes < 3_000_000 {
                var exact = 0
                for s in shards {
                    guard let data = try? await client.fileData(repo: d.id, type: .dataset, path: s.path) else { continue }
                    exact += data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.count
                }
                if exact > 0 { n = exact }
            }
            guard dataset?.id == d.id else { return }
            shardBytes = bytes; conversations = shards.isEmpty ? 0 : max(n, 1)
            if tuned == nil { base = TrainingBase.recommended(forConversations: conversations) }
        } catch { inspectError = error.localizedDescription }
    }

    private func launch(_ plan: TrainingPlan) {
        guard let url = Bundle.main.url(forResource: "loopl_sft", withExtension: "py", subdirectory: "train") ?? Bundle.main.url(forResource: "loopl_sft", withExtension: "py"),
              let script = try? Data(contentsOf: url) else { addError = "Training script missing from the app bundle"; return }
        let s = TrainingSession(plan: plan, user: user, client: account.client(), script: script)
        session = s
        LooplDesign.success()
        Task { _ = try? await s.launch() }
    }

    private func addToModels(_ repo: String) async {
        addError = nil
        do {
            let hub = HubCatalog(token: account.provider)
            let r = try await hub.repo(repo)
            let c = try await hub.config(repo)
            let spec = try HubCatalog.spec(for: r, config: c)
            let row = store.add(spec)
            LooplDesign.haptic(1)
            await engine.select(row)
        } catch {
            addError = "Could not add \(repo): \(error.localizedDescription). It is private — it is also listed under Models › Mine."
        }
    }
}
