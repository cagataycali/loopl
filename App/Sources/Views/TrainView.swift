import SwiftUI
import Loopl
import LooplUI

/// Models › Train your own: pick a dataset the user pushed to their Hugging Face account, a Qwen3.5 base and a GPU,
/// see an honest cost estimate, confirm on the same ApprovalCard the agent uses for HITL, then watch the job's
/// `[loopl] stage=` ladder. The resulting private model lands under Models › Mine (HF-ACCOUNT lane) → download → default.
struct TrainView: View {
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
    @State private var tuned: TrainingTunedBase?          // nil = start from the stock Qwen3.5 size
    @State private var method: TrainingMethod = .lora
    @State private var flavor: TrainingFlavor = .a10gSmall
    @State private var epochsChoice = 0                     // 0 = Auto, 1…4 fixed
    @State private var includeAllShards = true
    @State private var stitch: TrainingStitch = .none
    @State private var stitchPreview: (groups: Int, keyed: Int, rows: Int)?   // from the shards inspect() read
    @State private var hoursCap = 2.0
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

    private var plan: TrainingPlan? {
        guard let ds = dataset else { return nil }
        return TrainingPlan(dataset: ds.id, conversations: max(conversations, 1), withTools: conversations / 3, base: base, tunedBase: tuned, method: method,
                            flavor: flavor, epochs: epochsChoice == 0 ? .auto : .fixed(epochsChoice), includeAllShards: includeAllShards, stitch: stitch,
                            outputName: outputName.isEmpty ? nil : TrainingPlan.repoSafe(outputName), hoursCap: hoursCap)
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
                stitchPreview = (groups: 9, keyed: 179, rows: 191)
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
                    Picker("Conversations", selection: $dataset) {
                        ForEach(datasets) { d in Text(d.name).tag(Optional(d)) }
                    }
                    .accessibilityIdentifier("train-dataset")
                    if dataset != nil {
                        LabeledContent("Rows", value: inspecting ? "reading…" : conversations > 0 ? "≈ \(conversations) conversations · \(ByteSize.label(shardBytes))" : "no .jsonl shards found")
                            .accessibilityIdentifier("train-rows")
                        if let e = inspectError { Text(e).font(.footnote).foregroundStyle(.orange) }
                    }
                }
            } header: { Text("Dataset") } footer: {
                if canRunJobs {
                    Text("Private, in your account (@\(user)). The training script is committed next to the shards as train/loopl_sft.py.")
                } else {
                    Label("Your token is read-only. Jobs need a write token — Settings › Hugging Face.", systemImage: LooplDesign.iconWarning).foregroundStyle(.orange)
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
                        Label("Round \(t.round + 1): LoRA on top of \(t.bf16Repo ?? t.repo) — your earlier rounds stay in.", systemImage: "arrow.triangle.branch")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("train-continue-note")
                        Toggle("Include all previous shards", isOn: $includeAllShards)
                            .accessibilityIdentifier("train-replay")
                    }
                }
                Picker("Method", selection: $method) { ForEach(TrainingMethod.allCases, id: \.self) { Text($0.label).tag($0) } }
                Picker("GPU", selection: $flavor) {
                    ForEach(TrainingFlavor.gpuChoices) { f in Text("\(f.label) · \(f.priceLabel)").tag(f) }
                }
                .accessibilityIdentifier("train-flavor")
                Picker("Epochs", selection: $epochsChoice) {
                    Text("Auto (recommended)").tag(0)
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .accessibilityIdentifier("train-epochs")
                Text(epochsFootnote).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("train-epochs-note")
                Picker("Stitch related conversations", selection: $stitch) {
                    ForEach(TrainingStitch.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("train-stitch")
                Text(stitchFootnote).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("train-stitch-note")
                HStack {
                    Text("Stop after")
                    Spacer()
                    Text(TrainingEstimate.duration(hoursCap * 3600)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $hoursCap, in: 0.25...8, step: 0.25).accessibilityIdentifier("train-cap")
                TextField("Model name", text: $outputName, prompt: Text(plan.map(\.outputName) ?? "loopl-mine-0-8b"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("train-name")
            } header: { Text("Recipe") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if tuned == nil {
                        Text(base == TrainingBase.recommended(forConversations: conversations)
                             ? "\(base.label) is the suggested size for \(conversations) conversations."
                             : "Suggested for \(conversations) conversations: \(TrainingBase.recommended(forConversations: conversations).label).")
                    }
                    let blocked = tunedBases.filter { !$0.isTrainable }
                    if !blocked.isEmpty {
                        Text("Can't continue \(blocked.map(\.name).joined(separator: ", ")): no bf16 checkpoint next to the 4-bit weights — training from 4-bit is refused.")
                            .accessibilityIdentifier("train-continue-blocked")
                    }
                }
            }
            .onChange(of: base) { _, b in if tuned == nil { method = b.defaultMethod; flavor = b.recommendedFlavor } }
            .onChange(of: tuned) { _, t in
                if let t { base = t.size; method = .lora; flavor = t.size.recommendedFlavor } else { method = base.defaultMethod; flavor = base.recommendedFlavor }
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
                         "You confirm the exact job before anything is billed. Hugging Face charges your account per minute of GPU time, and stops at the cap.")
                }
            }
        }
        .looplScrollClearance()
        .onChange(of: dataset) { _, d in if !fixtureSignedIn { Task { await inspect(d) } } }
    }

    private var epochsFootnote: String {
        let h = TrainingEpochs.heuristic(forConversations: conversations)
        let guide = "Guide: under 200 conversations 3–4 epochs · 200–1 000 → 2 · over 1 000 → 1–2. For \(conversations): \(h.text)."
        return epochsChoice == 0 ? "Auto runs up to \(h.autoMax), keeps the best-scoring epoch and stops as soon as held-out loss rises. \(guide)" : guide
    }

    private var stitchFootnote: String {
        switch stitch {
        case .none: return TrainingStitch.none.footnote
        case .day:
            if let p = stitchPreview {
                let unkeyed = p.rows - p.keyed
                return "≈ \(p.groups) stitched samples from \(p.keyed) dated conversations" + (unkeyed > 0 ? " · \(unkeyed) without a date stay separate." : ".") + " Originals train too."
            }
            return TrainingStitch.day.footnote
        case .topic: return TrainingStitch.topic.footnote + " The count shows in the job plan."
        }
    }

    private func estimateCard(_ e: TrainingEstimate, plan: TrainingPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.usdLabel).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                Text("· about \(e.durationLabel)").foregroundStyle(.secondary)
                Spacer()
            }
            Text("\(e.steps) steps on \(plan.flavor.label) at \(plan.flavor.priceLabel), then merge, score, and convert for iPhone (MLX 4-bit) and GGUF. An estimate, not a quote.")
                .font(.footnote).foregroundStyle(.secondary)
            if e.exceedsCap {
                Label("Likely longer than the \(TrainingEstimate.duration(Double(plan.timeoutSeconds))) cap — the job would stop unfinished. Raise the cap or pick a faster GPU.", systemImage: LooplDesign.iconWarning)
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
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
            detail: "\(plan.estimate.usdLabel) (\(plan.estimate.durationLabel), billed per minute, stops at the cap). Output: \(plan.outputRepo(user: user)), -4bit, -GGUF — private.",
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
                    Text("\(s.plan.baseLabel) · \(s.plan.method.label) · \(s.plan.flavor.label) · \(s.plan.conversations) conversations · epochs \(s.plan.epochs.label.lowercased())")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let p = s.progress.plan, (p.stitched ?? 0) > 0 || (p.round ?? 1) > 1 {
                        Text([p.round.map { "round \($0)" }, p.stitched.map { "\($0) stitched" }, p.heuristic.map { "epochs auto ≤ \(Int(p.epochsMax ?? 0)) (guide \($0))" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("train-plan")
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(TrainingStage.order, id: \.self) { name in stageRow(name, s) }
                if let e = s.progress.error {
                    Label(e, systemImage: LooplDesign.iconWarning).font(.footnote).foregroundStyle(.orange)
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
            Text("Held-out loss by epoch").font(.footnote.weight(.medium))
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(hist) { h in
                    VStack(spacing: 3) {
                        Text(String(format: "%.2f", h.evalLoss)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Capsule().fill(h.epoch == best ? LooplDesign.accent : Color.secondary.opacity(0.35))
                            .frame(width: 22, height: 14 + 40 * CGFloat((h.evalLoss - lo) / span))
                        Text("e\(h.epoch)").font(.caption2).foregroundStyle(h.epoch == best ? .primary : .secondary)
                    }
                }
                Spacer()
            }
            if let best { Text("Kept epoch \(best) — the one with the lowest held-out loss.").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("train-epochs-chart")
        .accessibilityLabel("Held-out loss by epoch: " + hist.map { "epoch \($0.epoch) \(String(format: "%.2f", $0.evalLoss))" }.joined(separator: ", "))
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
            var preview: (groups: Int, keyed: Int, rows: Int)?
            if shards.count <= 3, bytes < 3_000_000 {
                var exact = 0, days: [String: Int] = [:], keyed = 0
                for s in shards {
                    guard let data = try? await client.fileData(repo: d.id, type: .dataset, path: s.path) else { continue }
                    for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                        exact += 1
                        // `"ts": "2026-10-06T14:…"` inside gen — a cheap byte scan, no JSON parse per row
                        if let day = Self.day(inRow: line) { keyed += 1; days[day, default: 0] += 1 }
                    }
                }
                if exact > 0 { n = exact; preview = (groups: days.values.filter { $0 >= 2 }.count, keyed: keyed, rows: exact) }
            }
            guard dataset?.id == d.id else { return }
            shardBytes = bytes; conversations = shards.isEmpty ? 0 : max(n, 1)
            stitchPreview = preview
            if tuned == nil { base = TrainingBase.recommended(forConversations: conversations) }
        } catch { inspectError = error.localizedDescription }
    }

    /// "YYYY-MM-DD" of the row's `"ts": "…"` (ConversationExport writes gen.ts), nil when absent.
    static func day(inRow line: Data.SubSequence) -> String? {
        guard let s = String(data: Data(line), encoding: .utf8), let r = s.range(of: "\"ts\": \"") ?? s.range(of: "\"ts\":\"") else { return nil }
        let rest = s[r.upperBound...]
        guard rest.count >= 10 else { return nil }
        let day = String(rest.prefix(10))
        return day.count == 10 && day[day.index(day.startIndex, offsetBy: 4)] == "-" ? day : nil
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
