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
}

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
    public var base: TrainingBase
    public var method: TrainingMethod
    public var flavor: TrainingFlavor
    public var epochs: Int = 2
    public var outputName: String           // bare repo name, e.g. "loopl-mine-0.8b" → <user>/loopl-mine-0.8b
    public var hoursCap: Double = 2         // → timeoutSeconds; HF kills the job (and the bill) there
    public var skipGGUF: Bool = false
    public var skipMLX: Bool = false

    public init(dataset: String, conversations: Int, withTools: Int = 0, base: TrainingBase, method: TrainingMethod? = nil,
                flavor: TrainingFlavor? = nil, epochs: Int = 2, outputName: String? = nil, hoursCap: Double = 2,
                skipGGUF: Bool = false, skipMLX: Bool = false) {
        self.dataset = dataset; self.conversations = conversations; self.withTools = withTools; self.base = base
        self.method = method ?? base.defaultMethod
        self.flavor = flavor ?? base.recommendedFlavor
        self.epochs = epochs
        self.outputName = outputName ?? Self.defaultOutputName(dataset: dataset, base: base)
        self.hoursCap = hoursCap; self.skipGGUF = skipGGUF; self.skipMLX = skipMLX
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
        var a = ["--dataset", dataset, "--base", base.rawValue, "--out", outputRepo(user: user),
                 "--epochs", String(epochs), "--method", method.rawValue]
        if skipMLX { a.append("--skip-mlx") }
        if skipGGUF { a.append("--skip-gguf") }
        return a
    }

    public var timeoutSeconds: Int { max(600, Int(hoursCap * 3600)) }

    public var estimate: TrainingEstimate { TrainingEstimate(plan: self) }
}

/// An honest estimate, not a quote — README-app.md's model: rows ≈ 1.6 × tool conversations + 1 × the rest; steps = rows × epochs / 16;
/// + install/download/warm-up + two conversions. HF bills per minute of the flavor's hourly price for the whole job.
public struct TrainingEstimate: Hashable, Sendable {
    public var steps: Int
    public var trainSeconds: Double
    public var overheadSeconds: Double
    public var totalSeconds: Double { trainSeconds + overheadSeconds }
    public var usd: Double
    public var exceedsCap: Bool
    /// Measured runs land under the guide more often than over it; the estimate leans long on purpose (owner pays).
    public static let safetyFactor = 1.25

    public init(plan: TrainingPlan) {
        let rows = Double(plan.conversations - plan.withTools) + 1.6 * Double(plan.withTools)
        steps = max(1, Int((rows * Double(plan.epochs) / 16).rounded(.up)))
        let perStep = plan.base.secondsPerStep * (plan.base.recommendedFlavor.speed / max(plan.flavor.speed, 0.01))
        trainSeconds = Double(steps) * perStep * Self.safetyFactor
        var overhead = 4 * 60 + 95.0                                   // install + model download + Triton warm-up
        overhead += plan.skipMLX ? 0 : (plan.base == .b0_8 ? 60 : plan.base == .b2 ? 150 : 300)
        overhead += plan.skipGGUF ? 0 : (plan.base == .b0_8 ? 120 : plan.base == .b2 ? 240 : 420)
        overheadSeconds = overhead
        let billed = min(trainSeconds + overhead, Double(plan.timeoutSeconds))
        usd = billed / 3600 * plan.flavor.usdPerHour
        exceedsCap = trainSeconds + overhead > Double(plan.timeoutSeconds)
    }

    public var durationLabel: String { Self.duration(totalSeconds) }
    public var usdLabel: String { "≈ " + Self.usd(usd) }

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
    /// The repo the phone can run: MLX 4-bit first, else GGUF.
    public var runnableRepo: String? { mlx ?? gguf }
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
            }
            o.mlxError = d?["out"]?["mlx_error"]?.stringValue ?? d?["mlx_error"]?.stringValue
            o.ggufError = d?["out"]?["gguf_error"]?.stringValue ?? d?["gguf_error"]?.stringValue
            o.evalLossBase = d?["eval_loss_base"]?.doubleValue
            o.evalLossTuned = d?["eval_loss_tuned"]?.doubleValue
            o.toolNameMatch = d?["tool_name_match"]?.stringValue
            o.wallSeconds = d?["wall_s"]?.doubleValue
            o.scriptVersion = d?["script"]?.stringValue
            output = o
            upsert(TrainingStage(name: "done", elapsed: nil, detail: d))
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
