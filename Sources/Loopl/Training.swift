import Foundation

// MARK: - Training on Hugging Face Jobs from the app
//
// The app post-tunes a Qwen3.5 base on the conversations the user pushed to their own private dataset
// (`ConversationExport`), by running loopl-train's single-file `train/loopl_sft.py` on HF Jobs. Everything here is
// pure and testable: the plan → cost estimate, the exact job body (the launch contract in loopl-train
// `train/README-app.md`), and the parser for the `[loopl] stage=…` progress lines the script prints.
//
// Launch contract (byte-for-byte what `hf jobs uv run` would do, plus the token hop a PRIVATE dataset needs):
//   1. the bundled script is committed into the user's dataset repo as `train/loopl_sft.py`;
//   2. POST /api/jobs/<user> with command = ["bash","-lc", curl-with-token … && exec uv run /tmp/loopl_sft.py "$@", "loopl", <args…>],
//      environment LOOPL_SCRIPT_URL = the private resolve URL, secret HF_TOKEN, the flavor, a timeout and a name label.

/// A Qwen3.5 base the script knows (`--base 0.8b|2b|4b`).
public enum TrainingBase: String, CaseIterable, Sendable, Codable, Identifiable {
    case b0_8 = "0.8b", b2 = "2b", b4 = "4b"
    public var id: String { rawValue }
    public var hubId: String {
        switch self { case .b0_8: "Qwen/Qwen3.5-0.8B"; case .b2: "Qwen/Qwen3.5-2B"; case .b4: "Qwen/Qwen3.5-4B" }
    }
    public var label: String { switch self { case .b0_8: "Qwen3.5 0.8B"; case .b2: "Qwen3.5 2B"; case .b4: "Qwen3.5 4B" } }
    /// The script's default method per size (full FT beats LoRA 3× on knowledge for the same data; 4B full FT wants an H200).
    public var defaultMethod: TrainingMethod { switch self { case .b0_8: .lora; case .b2: .full; case .b4: .lora } }
    public var recommendedFlavor: TrainingFlavor { switch self { case .b0_8: .a10gSmall; case .b2, .b4: .a100Large } }
    /// Seconds per optimizer step on the recommended flavor, measured by the TRAIN lane (train/FULL-RUNS.md, README-app.md).
    public var secondsPerStep: Double { switch self { case .b0_8: 8; case .b2: 15; case .b4: 18 } }
    /// Rough weights-only size of the 4-bit artifact the phone downloads afterwards.
    public var quantizedBytes: Int64 { switch self { case .b0_8: 450_000_000; case .b2: 1_300_000_000; case .b4: 2_500_000_000 } }
    /// README-app.md: < 300 conversations → 0.8B · 300–2 000 → 2B · > 2 000 → 4B.
    public static func recommended(forConversations n: Int) -> TrainingBase { n < 300 ? .b0_8 : (n <= 2000 ? .b2 : .b4) }
    /// "0.8b" / "2b" / "4b" as written in a repo name (`loopl-2b-4bit`, `Qwen3.5-0.8B`), nil when absent.
    public static func sizeToken(in name: String) -> String? {
        let lower = name.lowercased()
        for t in ["0.8b", "2b", "4b"] {
            var i = lower.startIndex
            while let r = lower.range(of: t, range: i..<lower.endIndex) {
                let before = r.lowerBound == lower.startIndex ? nil : lower[lower.index(before: r.lowerBound)]
                let after = r.upperBound == lower.endIndex ? nil : lower[r.upperBound]
                let ok = (before.map { !$0.isNumber && $0 != "." } ?? true) && (after.map { !$0.isLetter && !$0.isNumber } ?? true)
                if ok { return t }
                i = r.upperBound
            }
        }
        return nil
    }
}

/// What `--base` names: a stock Qwen3.5 size, or a model the user already tuned (continual tuning, script 1.2.0).
/// A tuned model trains from its **bf16** repo — the `-4bit` Mine row maps to it by name (`loopl-x-4bit` → `loopl-x`);
/// the script refuses quantized weights, so `bf16Repo == nil` greys the choice out with the reason.
public struct TrainingTunedBase: Hashable, Sendable, Codable, Identifiable {
    public var repo: String             // the Mine repo the user tapped (usually the -4bit one)
    public var bf16Repo: String?        // what `--base` gets; nil = no bf16 checkpoint next to it
    public var round: Int               // rounds already closed (card `loopl_round`); this run is `round + 1`
    public var size: TrainingBase       // the Qwen root's size → recipe + estimate
    public var id: String { repo }
    public init(repo: String, bf16Repo: String?, round: Int = 1, size: TrainingBase) {
        self.repo = repo; self.bf16Repo = bf16Repo; self.round = round; self.size = size
    }
    /// The model's own name — the bf16 twin's, so "loopl-app-sim" whether Mine listed the -4bit or the -GGUF row.
    public var name: String { Self.bf16Sibling(of: bf16Repo ?? repo).split(separator: "/").last.map(String.init) ?? repo }
    public var isTrainable: Bool { bf16Repo != nil }
    /// "tuned from loopl-2b · round 2" — Mine's badge and the base picker's subtitle.
    public var roundLabel: String { "round \(round)" }

    /// `x/loopl-mine-4bit` → `x/loopl-mine`, `x/loopl-mine-GGUF` → `x/loopl-mine`; a bf16 repo id maps to itself.
    public static func bf16Sibling(of repo: String) -> String {
        for suffix in ["-4bit", "-8bit", "-GGUF", "-gguf", "-mlx"] where repo.hasSuffix(suffix) { return String(repo.dropLast(suffix.count)) }
        return repo
    }
    /// From a Mine listing: the runnable repos the user owns (`-4bit`/`-GGUF`) grouped by their bf16 sibling; a group whose
    /// bf16 repo is in `allRepos` is trainable. `rounds` = card `loopl_round` per bf16 repo when known (default 1 — a loopl
    /// output always closed one round). Size from the name (`0.8b`/`2b`/`4b`), else `fallbackSize`.
    /// From `HubCatalog.owned(author:)`: Mine's runnable rows → one trainable base per bf16 twin (card `loopl_round` → round).
    public static func fromOwned(runnable: [String], owned: [HubCatalog.OwnedRepo], fallbackSize: TrainingBase = .b0_8) -> [TrainingTunedBase] {
        var rounds: [String: Int] = [:]
        for o in owned { if let r = o.looplRound { rounds[o.id] = r } }
        // an export's card names its bf16 parent — trust it over the name
        let runnableResolved = runnable.map { r in owned.first { $0.id == r }?.looplParent.map { _ in r } ?? r }
        var bases = fromMine(runnable: runnableResolved, allRepos: owned.map(\.id), rounds: rounds, fallbackSize: fallbackSize)
        for i in bases.indices where bases[i].bf16Repo == nil {
            if let parent = owned.first(where: { $0.id == bases[i].repo })?.looplParent, owned.contains(where: { $0.id == parent }) {
                bases[i].bf16Repo = parent; bases[i].round = max(1, rounds[parent] ?? 1)
            }
        }
        return bases
    }

    public static func fromMine(runnable: [String], allRepos: [String], rounds: [String: Int] = [:], fallbackSize: TrainingBase = .b0_8) -> [TrainingTunedBase] {
        var seen = Set<String>(), out: [TrainingTunedBase] = []
        // Mine sorts by lastModified, which puts a model's GGUF first; the MLX row is what the phone runs → prefer it as the face of the base
        let ordered = runnable.filter { !$0.lowercased().hasSuffix("-gguf") } + runnable.filter { $0.lowercased().hasSuffix("-gguf") }
        for r in ordered {
            let bf16 = bf16Sibling(of: r)
            guard !seen.contains(bf16) else { continue }
            seen.insert(bf16)
            let size = TrainingBase.allCases.first { TrainingBase.sizeToken(in: bf16) == $0.rawValue } ?? fallbackSize
            out.append(TrainingTunedBase(repo: r, bf16Repo: allRepos.contains(bf16) ? bf16 : nil, round: max(1, rounds[bf16] ?? 1), size: size))
        }
        return out
    }
}

/// How many passes over the data: the script's `--epochs auto` (≤ 3, best-eval checkpoint, early stop) or a fixed 1–4.
public enum TrainingEpochs: Hashable, Sendable, Codable {
    case auto
    case fixed(Int)
    public var argument: String { switch self { case .auto: "auto"; case .fixed(let n): String(max(1, min(4, n))) } }
    public var label: String { switch self { case .auto: "Auto (recommended)"; case .fixed(let n): "\(n)" } }
    /// The heuristic the owner agreed on, exactly as the script prints it: < 200 conversations → 3–4 · 200–1 000 → 2 · > 1 000 → 1–2.
    public static func heuristic(forConversations n: Int) -> (text: String, autoMax: Int) {
        n < 200 ? ("3–4", 3) : (n <= 1000 ? ("2", 2) : ("1–2", 2))
    }
    /// Epochs the estimate should bill for.
    public func planned(forConversations n: Int) -> Int { switch self { case .auto: Self.heuristic(forConversations: n).autoMax; case .fixed(let k): max(1, min(4, k)) } }
}

/// `--stitch`: connect related conversations into one multi-turn sample (script 1.2.0).
public enum TrainingStitch: String, CaseIterable, Sendable, Codable, Identifiable {
    case none, day, topic
    public var id: String { rawValue }
    public var label: String { switch self { case .none: "Off"; case .day: "By day"; case .topic: "By topic" } }
    public var footnote: String {
        switch self {
        case .none: "Each conversation trains on its own."
        case .day: "Conversations shared on the same day are joined, oldest first, into one longer sample — the model learns to carry context across chats. Shares without a date stay separate."
        case .topic: "Conversations about the same thing (their most frequent word) are joined into one longer sample."
        }
    }
}

/// LoRA adapters or a full fine-tune.
public enum TrainingMethod: String, CaseIterable, Sendable, Codable {
    case lora, full
    public var label: String { self == .lora ? "LoRA" : "Full fine-tune" }
}

/// An HF Jobs hardware flavor with its list price (USD per hour; HF bills per minute of the flavor's hourly price).
public struct TrainingFlavor: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var label: String
    public var usdPerHour: Double
    public var isGPU: Bool
    /// Relative speed vs the a10g (1.0) for the estimate when the user picks a non-recommended flavor.
    public var speed: Double

    public init(id: String, label: String, usdPerHour: Double, isGPU: Bool = true, speed: Double = 1) {
        self.id = id; self.label = label; self.usdPerHour = usdPerHour; self.isGPU = isGPU; self.speed = speed
    }

    public static let cpuUpgrade = TrainingFlavor(id: "cpu-upgrade", label: "CPU", usdPerHour: 0.03, isGPU: false, speed: 0.02)
    public static let t4Small = TrainingFlavor(id: "t4-small", label: "T4 16 GB", usdPerHour: 0.40, speed: 0.45)
    public static let l4x1 = TrainingFlavor(id: "l4x1", label: "L4 24 GB", usdPerHour: 0.80, speed: 0.9)
    public static let a10gSmall = TrainingFlavor(id: "a10g-small", label: "A10G 24 GB", usdPerHour: 1.00, speed: 1.0)
    public static let a10gLarge = TrainingFlavor(id: "a10g-large", label: "A10G 24 GB · 12 vCPU", usdPerHour: 1.50, speed: 1.05)
    public static let a100Large = TrainingFlavor(id: "a100-large", label: "A100 80 GB", usdPerHour: 2.50, speed: 1.6)
    public static let h200 = TrainingFlavor(id: "h200", label: "H200 141 GB", usdPerHour: 5.00, speed: 3.2)

    /// What the Train screen offers (GPU flavors a 0.8B–4B SFT can use; the CPU flavor exists for `--from-merged` re-exports only).
    public static let gpuChoices: [TrainingFlavor] = [.t4Small, .l4x1, .a10gSmall, .a10gLarge, .a100Large, .h200]
    public static let all: [TrainingFlavor] = [.cpuUpgrade] + gpuChoices
    public static func named(_ id: String) -> TrainingFlavor? { all.first { $0.id == id } }

    public var priceLabel: String { TrainingEstimate.usd(usdPerHour) + "/h" }
}

/// What the script will do, as the user configured it on the Train screen.
public struct TrainingPlan: Hashable, Sendable, Codable {
    public var dataset: String              // "<user>/<conversations-dataset>" (private, owned by the token's user)
    public var conversations: Int           // rows in the dataset (for the estimate)
    public var withTools: Int = 0           // rows that carry tool calls (rendered in two dialects → 1.6×)
    public var base: TrainingBase           // the Qwen size (recipe + estimate) — the root of a tuned base's lineage
    public var tunedBase: TrainingTunedBase? = nil   // continual tuning: `--base <bf16 repo>` instead of the stock size
    public var method: TrainingMethod
    public var flavor: TrainingFlavor
    public var epochs: TrainingEpochs = .auto
    public var includeAllShards: Bool = true // round ≥ 2: replay every shard (off → `--new-shards-only`)
    /// Not a user control since TRAIN-SIMPLIFY: the Train screen never sets it, the script's default decides (`none` today).
    public var stitch: TrainingStitch = .none
    public var outputName: String           // bare repo name, e.g. "loopl-mine-0.8b" → <user>/loopl-mine-0.8b
    public var skipGGUF: Bool = false
    public var skipMLX: Bool = false

    public init(dataset: String, conversations: Int, withTools: Int = 0, base: TrainingBase, tunedBase: TrainingTunedBase? = nil,
                method: TrainingMethod? = nil, flavor: TrainingFlavor? = nil, epochs: TrainingEpochs = .auto, includeAllShards: Bool = true,
                stitch: TrainingStitch = .none, outputName: String? = nil, skipGGUF: Bool = false, skipMLX: Bool = false) {
        self.dataset = dataset; self.conversations = conversations; self.withTools = withTools; self.base = tunedBase?.size ?? base
        self.tunedBase = tunedBase
        self.method = method ?? (tunedBase != nil ? .lora : base.defaultMethod)   // the script's round ≥ 2 default is LoRA r32
        self.flavor = flavor ?? base.recommendedFlavor
        self.epochs = epochs; self.includeAllShards = includeAllShards; self.stitch = stitch
        self.outputName = outputName ?? (tunedBase.map { Self.defaultOutputName(continuing: $0) } ?? Self.defaultOutputName(dataset: dataset, base: base))
        self.skipGGUF = skipGGUF; self.skipMLX = skipMLX
    }

    /// Round this job closes: 1 from a stock base, `tunedBase.round + 1` when continuing.
    public var round: Int { (tunedBase?.round ?? 0) + 1 }
    /// `--base` as the script receives it.
    public var baseArgument: String { tunedBase?.bf16Repo ?? base.rawValue }
    /// "Qwen3.5 0.8B" or "loopl-app-sim · round 2".
    public var baseLabel: String { tunedBase.map { "\($0.name) · round \(round)" } ?? base.label }
    /// Epochs the estimate bills for (auto → the heuristic's upper bound).
    public var plannedEpochs: Int { epochs.planned(forConversations: conversations) }

    /// "loopl-app-sim" → "loopl-app-sim-r2" (round-aware, so each round keeps its own repo).
    public static func defaultOutputName(continuing t: TrainingTunedBase) -> String {
        var name = TrainingTunedBase.bf16Sibling(of: t.repo).split(separator: "/").last.map(String.init) ?? t.name
        if let r = name.range(of: "-r", options: .backwards), Int(name[r.upperBound...]) != nil { name = String(name[..<r.lowerBound]) }
        return repoSafe("\(name)-r\(t.round + 1)")
    }

    /// "<dataset-name>" → "loopl-<dataset-name>-<size>", repo-name safe.
    public static func defaultOutputName(dataset: String, base: TrainingBase) -> String {
        var name = dataset.split(separator: "/").last.map(String.init) ?? dataset
        for suffix in ["-conversations", "-data", "-dataset"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        if name.hasPrefix("loopl-") { name.removeFirst(6) }
        let size = base.rawValue.replacingOccurrences(of: ".", with: "-")
        return Self.repoSafe("loopl-\(name)-\(size)")
    }

    /// Hub repo names: letters, digits, `-`, `_`, `.`; no leading/trailing dot or dash, ≤ 96 chars.
    public static func repoSafe(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." { out.append(ch) }
            else if ch == " " { out.append("-") }
        }
        while out.hasPrefix("-") || out.hasPrefix(".") { out.removeFirst() }
        while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return String(out.prefix(96))
    }

    /// Job label: `^[a-zA-Z0-9_-]*$`, no dots (README-app.md).
    public static func jobName(outputName: String, now: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmm"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        let base = outputName.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : Character("-") }
        return "\(String(base))-\(f.string(from: now))"
    }

    public func outputRepo(user: String) -> String { "\(user)/\(outputName)" }

    /// The script's CLI (after the leading `loopl` argv[0] of the bash -lc trampoline).
    public func scriptArguments(user: String) -> [String] {
        var a = ["--dataset", dataset, "--base", baseArgument, "--out", outputRepo(user: user),
                 "--epochs", epochs.argument, "--method", method.rawValue]
        if stitch != .none { a += ["--stitch", stitch.rawValue] }
        if tunedBase != nil, !includeAllShards { a.append("--new-shards-only") }
        if skipMLX { a.append("--skip-mlx") } else { a.append("--expect-vision") }   // every base here sees; a text-only export is a failure, not a model
        if skipGGUF { a.append("--skip-gguf") }
        return a
    }

    /// The automatic cost guard (no user control): HF kills the job — and the bill — at `estimate.capSeconds`.
    public var timeoutSeconds: Int { estimate.capSeconds }

    public var estimate: TrainingEstimate { TrainingEstimate(plan: self) }

    /// The plan in plain words, for the Recipe footer: what it starts from, what it learns, how, where it lands.
    public func summary(user: String) -> String {
        let start = tunedBase.map { "Continues \($0.name) (round \(round))" } ?? "Starts from \(base.label)"
        let what: String
        if tunedBase != nil {
            what = includeAllShards ? "learns from everything you have shared so far (\(conversations) conversations)" : "learns from the \(conversations) conversations shared since the last round"
        } else {
            what = "learns from your \(conversations) conversation\(conversations == 1 ? "" : "s")"
        }
        let passes: String
        switch epochs {
        case .auto: passes = "in up to \(plannedEpochs) pass\(plannedEpochs == 1 ? "" : "es"), keeping the one that scores best on held-out chats"
        case .fixed(let n): passes = "in \(n) pass\(n == 1 ? "" : "es")"
        }
        let how = method == .full ? "Every weight is updated" : "A small LoRA adapter is trained and merged in"
        let article = flavor.label.first.map { "AEFHILMNORSX".contains($0) ? "an" : "a" } ?? "a"   // "an A10G", "an H200", "a T4"
        let formats = skipMLX ? "." : (skipGGUF ? ", ready for your iPhone." : ", ready for your iPhone and as GGUF.")
        return "\(start) and \(what) \(passes). \(how) on \(article) \(flavor.label) at Hugging Face; the result is saved privately as \(outputRepo(user: user))\(formats)"
    }
}

/// An honest estimate, not a quote — README-app.md's model: rows ≈ 1.6 × tool conversations + 1 × the rest; steps = rows × epochs / 16;
/// + install/download/warm-up + two conversions. HF bills per minute of the flavor's hourly price for the whole job.
public struct TrainingEstimate: Hashable, Sendable {
    public var steps: Int
    public var trainSeconds: Double
    public var overheadSeconds: Double
    public var totalSeconds: Double { trainSeconds + overheadSeconds }
    public var usd: Double
    /// The automatic cost guard: the job is killed (and billing stops) here — 2× the estimate, never under 15 minutes, whole minutes.
    public var capSeconds: Int
    /// Measured runs land under the guide more often than over it; the estimate leans long on purpose (owner pays).
    public static let safetyFactor = 1.25
    public static let capFactor = 2.0
    public static let capMinimumSeconds = 15 * 60

    public init(plan: TrainingPlan) {
        let rows = Double(plan.conversations - plan.withTools) + 1.6 * Double(plan.withTools)
        steps = max(1, Int((rows * Double(plan.plannedEpochs) / 16).rounded(.up)))
        let perStep = plan.base.secondsPerStep * (plan.base.recommendedFlavor.speed / max(plan.flavor.speed, 0.01))
        trainSeconds = Double(steps) * perStep * Self.safetyFactor
        var overhead = 4 * 60 + 95.0                                   // install + model download + Triton warm-up
        overhead += plan.skipMLX ? 0 : (plan.base == .b0_8 ? 60 : plan.base == .b2 ? 150 : 300)
        overhead += plan.skipGGUF ? 0 : (plan.base == .b0_8 ? 120 : plan.base == .b2 ? 240 : 420)
        overheadSeconds = overhead
        usd = (trainSeconds + overhead) / 3600 * plan.flavor.usdPerHour
        capSeconds = Self.cap(forEstimatedSeconds: trainSeconds + overhead)
    }

    /// `max(2 × estimate, 15 min)`, rounded up to the minute (HF's `timeoutSeconds`).
    public static func cap(forEstimatedSeconds s: Double) -> Int {
        let raw = max(Double(capMinimumSeconds), s * capFactor)
        return Int((raw / 60).rounded(.up)) * 60
    }

    public var durationLabel: String { Self.duration(totalSeconds) }
    public var usdLabel: String { "≈ " + Self.usd(usd) }
    /// The one sentence the Train screen and its ApprovalCard both show: "≈ $0.30 · about 9 minutes · stops by itself if it runs past 18 minutes."
    public var sentence: String { "\(usdLabel) · about \(Self.spoken(totalSeconds)) · stops by itself if it runs past \(Self.spoken(Double(capSeconds)))." }

    /// Human durations for prose: "a minute", "9 minutes", "1.5 hours".
    public static func spoken(_ s: Double) -> String {
        if s < 90 { return "a minute" }
        if s < 3600 { return "\(Int((s / 60).rounded())) minutes" }
        let h = s / 3600
        if h < 10 { let t = (h * 10).rounded() / 10; return t == t.rounded() ? "\(Int(t)) hour\(t == 1 ? "" : "s")" : String(format: "%.1f hours", t) }
        return "\(Int(h.rounded())) hours"
    }

    public static func usd(_ v: Double) -> String {
        if v < 0.01 { return "< $0.01" }
        if v < 1 { return String(format: "$%.2f", v) }
        return v < 10 ? String(format: "$%.2f", v) : String(format: "$%.0f", v)
    }
    public static func duration(_ s: Double) -> String {
        if s < 90 { return "\(Int(s)) s" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        let h = s / 3600
        return h < 10 ? String(format: "%.1f h", h) : "\(Int(h.rounded())) h"
    }
}

// MARK: - Launch contract → HFHubClient.JobSpec

/// How a `TrainingPlan` becomes a Hugging Face Jobs request that runs `train/loopl_sft.py` with `uv`.
public enum TrainingLaunch {
    public static let scriptPath = "train/loopl_sft.py"
    public static let trampoline = "set -euo pipefail; curl -fsSL -H \"Authorization: Bearer $HF_TOKEN\" \"$LOOPL_SCRIPT_URL\" -o /tmp/loopl_sft.py && exec uv run /tmp/loopl_sft.py \"$@\""
    public static let image = "ghcr.io/astral-sh/uv:python3.12-bookworm"

    public static func scriptURL(dataset: String, host: String = "https://huggingface.co") -> String {
        "\(host)/datasets/\(dataset)/resolve/main/\(scriptPath)"
    }

    /// The exact body of `POST /api/jobs/<user>` for a plan (README-app.md §launch contract). `token` goes in `secrets` only.
    public static func jobSpec(plan: TrainingPlan, user: String, token: String, now: Date = Date()) -> HFHubClient.JobSpec {
        HFHubClient.JobSpec(dockerImage: image,
                            command: ["bash", "-lc", trampoline, "loopl"] + plan.scriptArguments(user: user),
                            environment: ["LOOPL_SCRIPT_URL": scriptURL(dataset: plan.dataset)],
                            secrets: ["HF_TOKEN": token],
                            flavor: plan.flavor.id,
                            timeoutSeconds: plan.timeoutSeconds)
    }

    /// `SCRIPT_VERSION = "x.y.z"` as written in the bundled script.
    public static func scriptVersion(in source: String) -> String? {
        guard let r = source.range(of: "SCRIPT_VERSION = \"") else { return nil }
        let rest = source[r.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}

// MARK: - Progress: the `[loopl] stage=…` lines

/// One stage the script reports: `[loopl] stage=<name> t=<secs>s {json}` and the final `[loopl] done {json}`.
public struct TrainingStage: Hashable, Sendable, Identifiable {
    public var name: String               // discover | render | train | merge | eval | push | mlx | gguf | done | error
    public var elapsed: Double?
    public var detail: JSONValue?
    public var id: String { name }
    public init(name: String, elapsed: Double? = nil, detail: JSONValue? = nil) { self.name = name; self.elapsed = elapsed; self.detail = detail }

    public static let order = ["discover", "render", "train", "merge", "eval", "push", "mlx", "gguf", "done"]
    public var index: Int { Self.order.firstIndex(of: name) ?? Self.order.count }
    public var label: String {
        switch name {
        case "discover": "Reading conversations"; case "render": "Rendering turns"; case "train": "Training"; case "merge": "Merging weights"
        case "eval": "Scoring"; case "push": "Uploading"; case "mlx": "Converting for iPhone (MLX 4-bit)"; case "gguf": "Converting GGUF"
        case "done": "Done"; case "error": "Failed"; case "download": "Downloading merged model"
        default: name.capitalized
        }
    }
}

/// What a finished job produced: `[loopl] done {"out":{"merged","mlx","gguf","gguf_file"}, "mlx_error"?, "gguf_error"?,
/// "eval_loss_base", "eval_loss_tuned", "tool_name_match":"7/9", "wall_s", "script"}`.
public struct TrainingOutput: Hashable, Sendable {
    public var merged: String?
    public var mlx: String?
    public var gguf: String?
    public var ggufFile: String?
    public var mlxError: String?
    public var ggufError: String?
    public var evalLossBase: Double?      // held-out loss of the base model
    public var evalLossTuned: Double?     // … of the tuned one (lower = learned)
    public var toolNameMatch: String?     // "7/9" — probes that called the right tool
    public var wallSeconds: Double?
    public var scriptVersion: String?
    /// `out.vision.visual_tensors` of the MLX export (loopl_sft.py ≥ 1.2.1): > 0 means the phone model sees. nil = the script did not say.
    public var visionTensors: Int?
    /// The MLX export kept its vision tower (vision_config + visual tensors + preprocessor_config).
    public var keptVision: Bool? { visionTensors.map { $0 > 0 } }
    // script 1.2.0
    public var round: Int?
    public var lineage: [String]?         // ["Qwen/Qwen3.5-0.8B", "me/loopl-app-sim"] → this model
    public var epochsTrained: Double?
    public var bestEpoch: Int?
    public var evalHistory: [TrainingEpochLoss]?
    public var stitched: Int?
    /// The repo the phone can run: MLX 4-bit first, else GGUF.
    public var runnableRepo: String? { mlx ?? gguf }
}

/// One evaluation: `[loopl] epoch=2 eval_loss=2.1454 best=2.1454`, or an `eval_history` entry.
public struct TrainingEpochLoss: Hashable, Sendable, Codable, Identifiable {
    public var epoch: Int
    public var evalLoss: Double
    public var id: Int { epoch }
    public init(epoch: Int, evalLoss: Double) { self.epoch = epoch; self.evalLoss = evalLoss }
}

/// `[loopl] plan {…}` — what the script decided after reading the data (round, lineage, epochs mode, stitching).
public struct TrainingPlanInfo: Hashable, Sendable {
    public var round: Int?
    public var base: String?
    public var lineage: [String]?
    public var epochsMode: String?        // "auto" | "fixed"
    public var epochsMax: Double?
    public var heuristic: String?         // "3–4"
    public var earlyStop: Bool?
    public var replay: Bool?
    public var stitchMode: String?
    public var stitched: Int?
    public var unkeyed: Int?
    public init() {}
    public init(json d: JSONValue) {
        round = d["round"]?.doubleValue.map(Int.init); base = d["base"]?.stringValue
        lineage = d["lineage"]?.arrayValue?.compactMap(\.stringValue)
        epochsMode = d["epochs"]?["mode"]?.stringValue; epochsMax = d["epochs"]?["max"]?.doubleValue
        heuristic = d["epochs"]?["heuristic"]?.stringValue; earlyStop = d["epochs"]?["early_stop"]?.boolValue
        replay = d["replay"]?.boolValue
        stitchMode = d["stitch"]?["mode"]?.stringValue; stitched = d["stitch"]?["stitched"]?.doubleValue.map(Int.init)
        unkeyed = d["stitch"]?["unkeyed"]?.doubleValue.map(Int.init)
    }
}

/// Incremental parser over job log lines. Feed every line (duplicates are fine — stages are keyed by name).
public struct TrainingProgress: Hashable, Sendable {
    public private(set) var stages: [TrainingStage] = []
    public private(set) var output: TrainingOutput?
    public private(set) var error: String?
    public private(set) var trainStep: (step: Int, total: Int)?
    public private(set) var loss: Double?
    public private(set) var lastLine: String?
    public private(set) var lineCount = 0
    public private(set) var plan: TrainingPlanInfo?
    public private(set) var evalHistory: [TrainingEpochLoss] = []

    public init() {}

    public var current: TrainingStage? { stages.max { $0.index < $1.index } }
    public var isDone: Bool { output != nil }
    public var isFailed: Bool { error != nil }
    /// 0…1 across the stage ladder; inside `train` it follows step/total.
    public var fraction: Double {
        guard let cur = current else { return 0 }
        if cur.name == "done" { return 1 }
        let n = Double(TrainingStage.order.count - 1)
        var f = Double(cur.index) / n
        if cur.name == "train", let s = trainStep, s.total > 0 { f += Double(s.step) / Double(s.total) / n }
        return min(f, 0.99)
    }

    public static func == (a: Self, b: Self) -> Bool { a.stages == b.stages && a.output == b.output && a.error == b.error && a.lineCount == b.lineCount && a.lastLine == b.lastLine }
    public func hash(into h: inout Hasher) { h.combine(lineCount); h.combine(lastLine) }

    public mutating func ingest(_ lines: [String]) { for l in lines { ingest(l) } }

    public mutating func ingest(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        lineCount += 1
        lastLine = line
        guard let r = line.range(of: "[loopl] ") else {
            // transformers' Trainer progress / loss lines when the script forwards them
            if let s = Self.stepPair(in: line) { trainStep = s }
            if let l = Self.loss(in: line) { loss = l }
            if line.hasPrefix("Traceback") || line.contains("Error:") && error == nil && line.count < 400 { /* wait for the loopl error line */ }
            return
        }
        let body = String(line[r.upperBound...])
        if body.hasPrefix("stage=") {
            var parts = body.dropFirst(6)
            let name = String(parts.prefix { $0 != " " })
            parts = parts.dropFirst(name.count).drop { $0 == " " }
            var elapsed: Double?
            if parts.hasPrefix("t=") {
                let t = parts.dropFirst(2).prefix { $0 != " " }
                elapsed = Double(t.hasSuffix("s") ? String(t.dropLast()) : String(t))
                parts = parts.dropFirst(t.count + 2).drop { $0 == " " }
            }
            let detail = JSONValue.parse(String(parts))
            upsert(TrainingStage(name: name, elapsed: elapsed, detail: detail))
            if name == "train", let d = detail {
                if let steps = d["steps"]?.doubleValue { trainStep = (0, Int(steps)) }
            }
        } else if body.hasPrefix("done") {
            let d = JSONValue.parse(String(body.dropFirst(4).drop { $0 == " " }))
            var o = TrainingOutput()
            if let out = d?["out"] {
                o.merged = out["merged"]?.stringValue; o.mlx = out["mlx"]?.stringValue
                o.gguf = out["gguf"]?.stringValue; o.ggufFile = out["gguf_file"]?.stringValue
                if let v = out["vision"]?["visual_tensors"]?.doubleValue { o.visionTensors = Int(v) }
            }
            o.mlxError = d?["out"]?["mlx_error"]?.stringValue ?? d?["mlx_error"]?.stringValue
            o.ggufError = d?["out"]?["gguf_error"]?.stringValue ?? d?["gguf_error"]?.stringValue
            o.evalLossBase = d?["eval_loss_base"]?.doubleValue
            o.evalLossTuned = d?["eval_loss_tuned"]?.doubleValue
            o.toolNameMatch = d?["tool_name_match"]?.stringValue
            o.wallSeconds = d?["wall_s"]?.doubleValue
            o.scriptVersion = d?["script"]?.stringValue
            o.round = d?["round"]?.doubleValue.map(Int.init)
            o.lineage = d?["lineage"]?.arrayValue?.compactMap(\.stringValue)
            o.epochsTrained = d?["epochs_trained"]?.doubleValue
            o.bestEpoch = d?["best_epoch"]?.doubleValue.map(Int.init)
            o.stitched = d?["stitched"]?.doubleValue.map(Int.init)
            if let h = d?["eval_history"]?.arrayValue {
                var hist: [TrainingEpochLoss] = []
                for e in h {   // one bar per epoch: scripts < 1.2.3 appended the final best-model evaluate() as a second last epoch
                    guard let ep = e["epoch"]?.doubleValue, let l = e["eval_loss"]?.doubleValue else { continue }
                    let epoch = Int(ep.rounded())
                    if !hist.contains(where: { $0.epoch == epoch }) { hist.append(TrainingEpochLoss(epoch: epoch, evalLoss: l)) }
                }
                o.evalHistory = hist.isEmpty ? (evalHistory.isEmpty ? nil : evalHistory) : hist
            } else if !evalHistory.isEmpty { o.evalHistory = evalHistory }
            output = o
            upsert(TrainingStage(name: "done", elapsed: nil, detail: d))
        } else if body.hasPrefix("plan ") {
            if let d = JSONValue.parse(String(body.dropFirst(5))) { plan = TrainingPlanInfo(json: d) }
        } else if body.hasPrefix("epoch=") {
            var epoch: Int?, l: Double?
            for kv in body.split(separator: " ") {
                let parts = kv.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                if parts[0] == "epoch" { epoch = Int(parts[1]) } else if parts[0] == "eval_loss" { l = Double(parts[1]) }
            }
            if let epoch, let l {
                if let i = evalHistory.firstIndex(where: { $0.epoch == epoch }) { evalHistory[i].evalLoss = l } else { evalHistory.append(TrainingEpochLoss(epoch: epoch, evalLoss: l)) }
            }
        } else if body.hasPrefix("error") || body.hasPrefix("fatal") {
            error = String(body.drop { !$0.isWhitespace }.drop { $0 == " " || $0 == ":" })
            upsert(TrainingStage(name: "error", elapsed: nil, detail: nil))
        } else if body.hasPrefix("step ") || body.hasPrefix("train step") {
            if let s = Self.stepPair(in: body) { trainStep = s }
            if let l = Self.loss(in: body) { loss = l }
        }
    }

    /// The job ended without a `done` line → surface the last thing it said.
    public mutating func markFailed(_ reason: String?) {
        if output == nil && error == nil { error = reason ?? lastLine ?? "job ended without a result" }
        if error != nil { upsert(TrainingStage(name: "error", elapsed: nil, detail: nil)) }
    }

    private mutating func upsert(_ s: TrainingStage) {
        if let i = stages.firstIndex(where: { $0.name == s.name }) { stages[i] = s } else { stages.append(s) }
    }

    /// "12/48", "step 12/48", " 12/48 [" → (12, 48)
    static func stepPair(in line: String) -> (step: Int, total: Int)? {
        let scalars = Array(line.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if CharacterSet.decimalDigits.contains(scalars[i]) {
                var j = i; while j < scalars.count, CharacterSet.decimalDigits.contains(scalars[j]) { j += 1 }
                if j < scalars.count, scalars[j] == "/" {
                    var k = j + 1; while k < scalars.count, CharacterSet.decimalDigits.contains(scalars[k]) { k += 1 }
                    if k > j + 1, let a = Int(String(String.UnicodeScalarView(scalars[i..<j]))), let b = Int(String(String.UnicodeScalarView(scalars[(j + 1)..<k]))), b > 0, a <= b {
                        return (a, b)
                    }
                }
                i = j
            } else { i += 1 }
        }
        return nil
    }

    /// `'loss': 2.21` / `loss=2.21` / `"loss": 2.21`
    static func loss(in line: String) -> Double? {
        for key in ["'loss': ", "\"loss\": ", "loss=", "loss "] {
            guard let r = line.range(of: key) else { continue }
            let rest = line[r.upperBound...].drop { $0 == " " }
            let num = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "e" }
            if let v = Double(String(num)) { return v }
        }
        return nil
    }
}
