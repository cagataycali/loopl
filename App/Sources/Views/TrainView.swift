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
    @State private var base: TrainingBase = .b0_8
    @State private var method: TrainingMethod = .lora
    @State private var flavor: TrainingFlavor = .a10gSmall
    @State private var epochs = 2
    @State private var hoursCap = 2.0
    @State private var outputName = ""
    @State private var confirming = false
    @State private var session: TrainingSession?
    @State private var showLog = false
    @State private var addError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    private var account: HFAccount { HFAccount.shared }
    private var signedIn: Bool { fixture != nil || fixtureSignedIn || (account.hasToken && account.username != nil) }
    private var user: String { fixture?.user ?? account.username ?? (fixtureSignedIn ? "cagataydev" : "") }

    private var plan: TrainingPlan? {
        guard let ds = dataset else { return nil }
        return TrainingPlan(dataset: ds.id, conversations: max(conversations, 1), withTools: conversations / 3, base: base, method: method,
                            flavor: flavor, epochs: epochs, outputName: outputName.isEmpty ? nil : TrainingPlan.repoSafe(outputName), hoursCap: hoursCap)
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
            } else if fixture == nil { await loadDatasets() }
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
                        LabeledContent("Rows", value: conversations > 0 ? "≈ \(conversations) conversations · \(ByteSize.label(shardBytes))" : "reading…")
                    }
                }
            } header: { Text("Dataset") } footer: {
                Text("Private, in your account (@\(user)). The training script is committed next to the shards as train/loopl_sft.py.")
            }

            Section {
                Picker("Base model", selection: $base) {
                    ForEach(TrainingBase.allCases) { b in Text(b.label).tag(b) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("train-base")
                Picker("Method", selection: $method) { ForEach(TrainingMethod.allCases, id: \.self) { Text($0.label).tag($0) } }
                Picker("GPU", selection: $flavor) {
                    ForEach(TrainingFlavor.gpuChoices) { f in Text("\(f.label) · \(f.priceLabel)").tag(f) }
                }
                .accessibilityIdentifier("train-flavor")
                Stepper("Epochs: \(epochs)", value: $epochs, in: 1...4)
                HStack {
                    Text("Stop after")
                    Spacer()
                    Text(TrainingEstimate.duration(hoursCap * 3600)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $hoursCap, in: 0.5...8, step: 0.5).accessibilityIdentifier("train-cap")
                TextField("Model name", text: $outputName, prompt: Text(plan.map(\.outputName) ?? "loopl-mine-0-8b"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("train-name")
            } header: { Text("Recipe") } footer: {
                Text(base == TrainingBase.recommended(forConversations: conversations)
                     ? "\(base.label) is the suggested size for \(conversations) conversations."
                     : "Suggested for \(conversations) conversations: \(TrainingBase.recommended(forConversations: conversations).label).")
            }
            .onChange(of: base) { _, b in method = b.defaultMethod; flavor = b.recommendedFlavor }

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
                        .disabled(conversations == 0 || settings.offline)
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
                    Text("\(s.plan.base.label) · \(s.plan.method.label) · \(s.plan.flavor.label) · \(s.plan.conversations) conversations")
                        .font(.footnote).foregroundStyle(.secondary)
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

    // MARK: actions

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

    /// Count the shards: `ConversationExport` writes one JSON object per line, ~4 KB each → an honest "≈ N conversations".
    private func inspect(_ d: HFHubClient.DatasetSummary?) async {
        conversations = 0; shardBytes = 0
        guard let d else { return }
        do {
            let entries = try await account.client().tree(repo: d.id, type: .dataset, path: "data")
            let shards = entries.filter { $0.isFile && $0.path.hasSuffix(".jsonl") }
            let bytes = shards.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            // small datasets: count lines exactly (one download), big ones: estimate
            var n = Int(bytes / 4096)
            if shards.count <= 2, bytes < 3_000_000 {
                var exact = 0
                for s in shards { if let data = try? await account.client().fileData(repo: d.id, type: .dataset, path: s.path) { exact += data.split(separator: UInt8(ascii: "\n")).count } }
                if exact > 0 { n = exact }
            }
            guard dataset?.id == d.id else { return }
            shardBytes = bytes; conversations = max(n, shards.isEmpty ? 0 : 1)
            base = TrainingBase.recommended(forConversations: conversations)
        } catch { datasetsError = error.localizedDescription }
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
            let hub = HubCatalog()
            let r = try await hub.repo(repo)
            let c = try await hub.config(repo)
            let spec = try HubCatalog.spec(for: r, config: c)
            let row = store.add(spec)
            LooplDesign.haptic(1)
            await engine.select(row)
        } catch {
            addError = "Could not add \(repo): \(error.localizedDescription). It is private — once you are signed in, find it under Models › Mine."
        }
    }
}
