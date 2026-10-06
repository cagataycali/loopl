import Foundation
import XCTest
@testable import Loopl

/// Pure model layer behind the Train screen: cost estimate, the HF Jobs launch contract, and the `[loopl] stage=` log parser.
final class TrainingTests: XCTestCase {
    /// Verbatim `[loopl]` lines of the first real app-path job (6ac4711f, a10g-small, 476 s) — the 1.0.0 run whose GGUF stage failed.
    static let smokeJobLog: [String] = [
        "[loopl] stage=discover t=1s {\"revision\": \"d91e2b6857dcecf22541a4b575f6da80200e5425\", \"read\": 191, \"invalid\": 0, \"duplicates\": 0, \"denylisted\": 0, \"pii_scrubbed\": 0, \"train\": 174, \"eval\": 17, \"source\": \"cagataydev/loopl-app-smoke-data@d91e2b6857dcecf22541a4b575f6da80200e5425\"}",
        "[loopl] stage=render t=1s",
        "[loopl] stage=train t=24s {\"method\": \"lora\", \"steps\": 24, \"rows\": 191}",
        "[loopl] stage=merge t=317s",
        "[loopl] stage=eval t=321s {\"probes\": 17}",
        "[loopl] stage=push t=420s {\"repo\": \"cagataydev/loopl-app-smoke\"}",
        "[loopl] stage=mlx t=428s {\"repo\": \"cagataydev/loopl-app-smoke-4bit\"}",
        "[loopl] stage=gguf t=446s {\"repo\": \"cagataydev/loopl-app-smoke-GGUF\"}",
        "[loopl] done {\"out\": {\"merged\": \"cagataydev/loopl-app-smoke\", \"mlx\": \"cagataydev/loopl-app-smoke-4bit\", \"gguf\": null, \"gguf_error\": \"Command '['uv', 'run', '--no-project', '--python', '3.12', '--with-requirements'\\u2026\"}, \"conversations\": 191, \"rows\": 191, \"steps\": 24, \"eval_loss_base\": 2.3794, \"eval_loss_tuned\": 2.1477, \"tool_name_match\": \"0/0\", \"wall_s\": 476, \"script\": \"1.0.0\"}",
    ]

    func testRecommendedBaseFollowsSampleCount() {
        XCTAssertEqual(TrainingBase.recommended(forConversations: 120), .b0_8)
        XCTAssertEqual(TrainingBase.recommended(forConversations: 300), .b2)
        XCTAssertEqual(TrainingBase.recommended(forConversations: 2000), .b2)
        XCTAssertEqual(TrainingBase.recommended(forConversations: 2001), .b4)
    }

    func testDefaultOutputNameIsRepoSafe() {
        XCTAssertEqual(TrainingPlan.defaultOutputName(dataset: "cagataydev/loopl-app-conversations", base: .b0_8), "loopl-app-0-8b")
        XCTAssertEqual(TrainingPlan.defaultOutputName(dataset: "me/My Chats.data", base: .b4), "loopl-my-chats.data-4b")
        XCTAssertEqual(TrainingPlan.repoSafe("--weird  name--"), "weird-name")
        let name = TrainingPlan.jobName(outputName: "loopl-mine-0.8b", now: Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertTrue(name.hasPrefix("loopl-mine-0-8b-2026") && name.count == "loopl-mine-0-8b-20261002T1240".count, name)
        XCTAssertNil(name.first { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }, "job labels: ^[a-zA-Z0-9_-]*$")
    }

    func testEstimateMatchesTheReadmeCostGuide() {
        // README-app.md: 0.8B LoRA, 200 conversations, 2 epochs on a10g-small ≈ 15 min ≈ $0.30
        let small = TrainingPlan(dataset: "u/d", conversations: 200, base: .b0_8).estimate
        XCTAssertEqual(small.steps, 25)
        // measured: 191 conversations ran 476 s ≈ $0.13 (job 6ac4711f); the guide says ~15 min ≈ $0.30 — the estimate must sit between, leaning long
        XCTAssertEqual(small.totalSeconds / 60, 13, accuracy: 3)
        XCTAssertEqual(small.usd, 0.25, accuracy: 0.1)
        XCTAssertFalse(small.exceedsCap)
        // 4B LoRA, 5 000 conversations on a100-large ≈ 5 h ≈ $12 → exceeds a 2 h cap, billed only up to the cap
        let big = TrainingPlan(dataset: "u/d", conversations: 5000, base: .b4, hoursCap: 2).estimate
        XCTAssertTrue(big.exceedsCap)
        XCTAssertEqual(big.usd, 5.0, accuracy: 0.01, "2 h × $2.50/h is the most HF can bill before the timeout")
        XCTAssertEqual(TrainingPlan(dataset: "u/d", conversations: 5000, base: .b4, hoursCap: 8).estimate.usd, 12, accuracy: 3)
        // tool conversations render in two dialects → more steps
        XCTAssertGreaterThan(TrainingPlan(dataset: "u/d", conversations: 200, withTools: 200, base: .b0_8).estimate.steps, small.steps)
        // a faster flavor is fewer seconds but not necessarily cheaper
        let h200 = TrainingPlan(dataset: "u/d", conversations: 5000, base: .b4, flavor: .h200, hoursCap: 8).estimate
        XCTAssertLessThan(h200.totalSeconds, TrainingPlan(dataset: "u/d", conversations: 5000, base: .b4, hoursCap: 8).estimate.totalSeconds)
        XCTAssertEqual(TrainingEstimate.usd(0.004), "< $0.01"); XCTAssertEqual(TrainingEstimate.usd(0.3), "$0.30"); XCTAssertEqual(TrainingEstimate.usd(12.4), "$12")
        XCTAssertEqual(TrainingEstimate.duration(900), "15 min"); XCTAssertEqual(TrainingEstimate.duration(5400), "1.5 h")
    }

    func testJobSpecIsTheLaunchContract() throws {
        let plan = TrainingPlan(dataset: "cagataydev/loopl-app-smoke-data", conversations: 191, base: .b0_8, outputName: "loopl-app-smoke", hoursCap: 1)
        let spec = TrainingLaunch.jobSpec(plan: plan, user: "cagataydev", token: "hf_secret")
        XCTAssertEqual(spec.dockerImage, "ghcr.io/astral-sh/uv:python3.12-bookworm")
        XCTAssertEqual(spec.command, ["bash", "-lc",
            "set -euo pipefail; curl -fsSL -H \"Authorization: Bearer $HF_TOKEN\" \"$LOOPL_SCRIPT_URL\" -o /tmp/loopl_sft.py && exec uv run /tmp/loopl_sft.py \"$@\"",
            "loopl", "--dataset", "cagataydev/loopl-app-smoke-data", "--base", "0.8b", "--out", "cagataydev/loopl-app-smoke", "--epochs", "2", "--method", "lora"])
        XCTAssertEqual(spec.environment, ["LOOPL_SCRIPT_URL": "https://huggingface.co/datasets/cagataydev/loopl-app-smoke-data/resolve/main/train/loopl_sft.py"])
        XCTAssertEqual(spec.secrets, ["HF_TOKEN": "hf_secret"])
        XCTAssertEqual(spec.flavor, "a10g-small")
        XCTAssertEqual(spec.timeoutSeconds, 3600)
        // the body HFHubClient posts carries the token ONLY under secrets
        let body = String(decoding: HFHubClient.createJobBody(spec), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "hf_secret").count - 1, 1)
        XCTAssertTrue(body.contains("\"secrets\""))
        XCTAssertEqual(TrainingLaunch.scriptVersion(in: "x\nSCRIPT_VERSION = \"1.0.2\"\ny"), "1.0.2")
    }

    func testProgressParsesARealJobLog() {
        var p = TrainingProgress()
        for (i, line) in Self.smokeJobLog.enumerated() {
            p.ingest(line)
            if i == 2 {
                XCTAssertEqual(p.current?.name, "train")
                XCTAssertEqual(p.trainStep?.total, 24)
                XCTAssertEqual(p.fraction, 2.0 / 8, accuracy: 0.001)
                p.ingest("  8%|▊         | 2/24 [01:01<09:39, 26.35s/it]")
                XCTAssertEqual(p.trainStep?.step, 2)
                p.ingest("{'loss': 2.2134, 'grad_norm': 1.2, 'learning_rate': 9e-05, 'epoch': 0.67}")
                XCTAssertEqual(p.loss ?? 0, 2.2134, accuracy: 0.0001)
                XCTAssertFalse(p.isDone)
            }
        }
        XCTAssertEqual(p.stages.map(\.name), ["discover", "render", "train", "merge", "eval", "push", "mlx", "gguf", "done"])
        XCTAssertEqual(p.stages[0].elapsed, 1); XCTAssertEqual(p.stages[7].elapsed, 446)
        XCTAssertEqual(p.stages[0].detail?["train"]?.doubleValue, 174)
        XCTAssertTrue(p.isDone); XCTAssertFalse(p.isFailed); XCTAssertEqual(p.fraction, 1)
        let out = p.output!
        XCTAssertEqual(out.merged, "cagataydev/loopl-app-smoke")
        XCTAssertEqual(out.mlx, "cagataydev/loopl-app-smoke-4bit")
        XCTAssertNil(out.gguf)
        XCTAssertTrue(out.ggufError?.hasPrefix("Command ") == true, "a failed conversion is reported, the merged model is still pushed")
        XCTAssertEqual(out.runnableRepo, "cagataydev/loopl-app-smoke-4bit")
        XCTAssertEqual(out.evalLossBase ?? 0, 2.3794, accuracy: 0.0001)
        XCTAssertEqual(out.evalLossTuned ?? 0, 2.1477, accuracy: 0.0001)
        XCTAssertEqual(out.scriptVersion, "1.0.0")
        // re-ingesting the same lines (log polling returns the whole buffer) does not duplicate stages
        p.ingest(Self.smokeJobLog)
        XCTAssertEqual(p.stages.count, 9)
    }

    func testProgressSurfacesFailure() {
        var p = TrainingProgress()
        p.ingest(Array(Self.smokeJobLog.prefix(3)))
        p.ingest("Traceback (most recent call last):")
        p.ingest("torch.OutOfMemoryError: CUDA out of memory.")
        p.markFailed(nil)
        XCTAssertTrue(p.isFailed)
        XCTAssertEqual(p.error, "torch.OutOfMemoryError: CUDA out of memory.")
        XCTAssertEqual(p.current?.name, "error")
        var q = TrainingProgress(); q.ingest("[loopl] error: no trainable conversations after validation"); 
        XCTAssertEqual(q.error, "no trainable conversations after validation")
    }
}
