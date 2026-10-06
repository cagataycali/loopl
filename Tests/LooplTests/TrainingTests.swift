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
        // the automatic cost guard: 2× the estimate, never under 15 min, whole minutes — and the bill follows the estimate, not the cap
        XCTAssertEqual(small.capSeconds, TrainingEstimate.cap(forEstimatedSeconds: small.totalSeconds))
        XCTAssertEqual(small.capSeconds % 60, 0)
        XCTAssertGreaterThanOrEqual(Double(small.capSeconds), 2 * small.totalSeconds)
        XCTAssertLessThan(Double(small.capSeconds), 2 * small.totalSeconds + 60)
        XCTAssertEqual(TrainingEstimate.cap(forEstimatedSeconds: 100), 900, "a tiny job still gets 15 minutes")
        XCTAssertEqual(TrainingEstimate.cap(forEstimatedSeconds: 540), 1080, "9 min → 18 min")
        XCTAssertEqual(TrainingEstimate.cap(forEstimatedSeconds: 541), 1140, "rounded UP to the minute")
        // 4B LoRA, 5 000 conversations on a100-large ≈ 5 h ≈ $12 → the cap grows with the data (≈ 10 h), nothing to raise by hand
        let big = TrainingPlan(dataset: "u/d", conversations: 5000, base: .b4).estimate
        XCTAssertEqual(big.usd, 12, accuracy: 3)
        XCTAssertEqual(Double(big.capSeconds) / 3600, 2 * big.totalSeconds / 3600, accuracy: 0.02)
        XCTAssertEqual(TrainingPlan(dataset: "u/d", conversations: 5000, base: .b4).timeoutSeconds, big.capSeconds, "the plan's HF timeoutSeconds IS the automatic cap")
        // tool conversations render in two dialects → more steps
        XCTAssertGreaterThan(TrainingPlan(dataset: "u/d", conversations: 200, withTools: 200, base: .b0_8).estimate.steps, small.steps)
        // a faster flavor is fewer seconds but not necessarily cheaper
        let h200 = TrainingPlan(dataset: "u/d", conversations: 5000, base: .b4, flavor: .h200).estimate
        XCTAssertLessThan(h200.totalSeconds, TrainingPlan(dataset: "u/d", conversations: 5000, base: .b4).estimate.totalSeconds)
        XCTAssertEqual(TrainingEstimate.usd(0.004), "< $0.01"); XCTAssertEqual(TrainingEstimate.usd(0.3), "$0.30"); XCTAssertEqual(TrainingEstimate.usd(12.4), "$12")
        XCTAssertEqual(TrainingEstimate.duration(900), "15 min"); XCTAssertEqual(TrainingEstimate.duration(5400), "1.5 h")
        // the one sentence the Train screen and the ApprovalCard share
        XCTAssertEqual(TrainingEstimate.spoken(45), "a minute"); XCTAssertEqual(TrainingEstimate.spoken(540), "9 minutes")
        XCTAssertEqual(TrainingEstimate.spoken(3600), "1 hour"); XCTAssertEqual(TrainingEstimate.spoken(5400), "1.5 hours"); XCTAssertEqual(TrainingEstimate.spoken(7200), "2 hours")
        XCTAssertTrue(small.sentence.hasPrefix("≈ $0."), small.sentence)
        XCTAssertTrue(small.sentence.contains(" · about ") && small.sentence.contains(" minutes · stops by itself if it runs past ") && small.sentence.hasSuffix(" minutes."), small.sentence)
        let capMinutes = Int(String(small.sentence.split(separator: "past ").last!.split(separator: " ").first!))!
        XCTAssertEqual(capMinutes, small.capSeconds / 60)
    }

    func testPlanSummaryReadsInPlainWords() {
        let fresh = TrainingPlan(dataset: "me/loopl-app-conversations", conversations: 191, base: .b0_8)
        let s = fresh.summary(user: "me")
        XCTAssertTrue(s.hasPrefix("Starts from Qwen3.5 0.8B and learns from your 191 conversations in up to 3 passes, keeping the one that scores best"), s)
        XCTAssertTrue(s.contains("A small LoRA adapter is trained and merged in on an A10G 24 GB at Hugging Face"), s)
        XCTAssertTrue(TrainingPlan(dataset: "me/d", conversations: 10, base: .b0_8, flavor: .t4Small).summary(user: "me").contains("on a T4 16 GB"))
        XCTAssertTrue(TrainingPlan(dataset: "me/d", conversations: 10, base: .b0_8, flavor: .h200).summary(user: "me").contains("on an H200"))
        XCTAssertTrue(s.contains("saved privately as me/loopl-app-0-8b, ready for your iPhone and as GGUF."), s)
        let tuned = TrainingTunedBase(repo: "me/loopl-app-sim-4bit", bf16Repo: "me/loopl-app-sim", round: 1, size: .b0_8)
        var r2 = TrainingPlan(dataset: "me/d", conversations: 40, base: .b0_8, tunedBase: tuned, epochs: .fixed(1))
        XCTAssertTrue(r2.summary(user: "me").hasPrefix("Continues loopl-app-sim (round 2) and learns from everything you have shared so far (40 conversations) in 1 pass."), r2.summary(user: "me"))
        r2.includeAllShards = false
        XCTAssertTrue(r2.summary(user: "me").contains("shared since the last round"), r2.summary(user: "me"))
        XCTAssertFalse(r2.summary(user: "me").contains("stitch"), "stitching is the script's decision, never a word on the screen")
    }

    func testJobSpecIsTheLaunchContract() throws {
        let plan = TrainingPlan(dataset: "cagataydev/loopl-app-smoke-data", conversations: 191, base: .b0_8, epochs: .fixed(2), outputName: "loopl-app-smoke")
        let spec = TrainingLaunch.jobSpec(plan: plan, user: "cagataydev", token: "hf_secret")
        XCTAssertEqual(spec.dockerImage, "ghcr.io/astral-sh/uv:python3.12-bookworm")
        XCTAssertEqual(spec.command, ["bash", "-lc",
            "set -euo pipefail; curl -fsSL -H \"Authorization: Bearer $HF_TOKEN\" \"$LOOPL_SCRIPT_URL\" -o /tmp/loopl_sft.py && exec uv run /tmp/loopl_sft.py \"$@\"",
            "loopl", "--dataset", "cagataydev/loopl-app-smoke-data", "--base", "0.8b", "--out", "cagataydev/loopl-app-smoke", "--epochs", "2", "--method", "lora", "--expect-vision"])
        XCTAssertEqual(spec.environment, ["LOOPL_SCRIPT_URL": "https://huggingface.co/datasets/cagataydev/loopl-app-smoke-data/resolve/main/train/loopl_sft.py"])
        XCTAssertEqual(spec.secrets, ["HF_TOKEN": "hf_secret"])
        XCTAssertEqual(spec.flavor, "a10g-small")
        XCTAssertEqual(spec.timeoutSeconds, plan.estimate.capSeconds, "the automatic cap is what HF enforces")
        XCTAssertGreaterThanOrEqual(spec.timeoutSeconds ?? 0, 900)
        // the body HFHubClient posts carries the token ONLY under secrets
        let body = String(decoding: HFHubClient.createJobBody(spec), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "hf_secret").count - 1, 1)
        XCTAssertTrue(body.contains("\"secrets\""))
        XCTAssertEqual(TrainingLaunch.scriptVersion(in: "x\nSCRIPT_VERSION = \"1.0.3\"\ny"), "1.0.3")
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

    // MARK: script 1.2.0 — continual tuning, epochs auto, stitch

    func testTunedBaseResolvesToBF16AndRefusesWithoutIt() {
        let owned = [HubCatalog.OwnedRepo(id: "me/loopl-app-sim", library: "transformers", looplRound: 1),
                     HubCatalog.OwnedRepo(id: "me/loopl-app-sim-4bit", library: "mlx", looplRound: 1, looplParent: "me/loopl-app-sim"),
                     HubCatalog.OwnedRepo(id: "me/loopl-app-sim-GGUF", library: "gguf"),
                     HubCatalog.OwnedRepo(id: "me/loopl-2b-r2-4bit", library: "mlx", looplRound: 2), HubCatalog.OwnedRepo(id: "me/loopl-2b-r2", looplRound: 2),
                     HubCatalog.OwnedRepo(id: "me/orphan-4bit", library: "mlx")]
        let bases = TrainingTunedBase.fromOwned(runnable: ["me/loopl-app-sim-4bit", "me/loopl-app-sim-GGUF", "me/loopl-2b-r2-4bit", "me/orphan-4bit"], owned: owned)
        XCTAssertEqual(bases.map(\.repo), ["me/loopl-app-sim-4bit", "me/loopl-2b-r2-4bit", "me/orphan-4bit"], "one base per bf16 twin; GGUF twin folds in")
        XCTAssertEqual(bases[0].name, "loopl-app-sim", "named after the bf16 twin, not the export")
        // Mine lists GGUF first (lastModified) — the MLX row must still be the face of the base
        let ggufFirst = TrainingTunedBase.fromOwned(runnable: ["me/loopl-app-sim-GGUF", "me/loopl-app-sim-4bit"], owned: owned)
        XCTAssertEqual(ggufFirst.map(\.repo), ["me/loopl-app-sim-4bit"]); XCTAssertEqual(ggufFirst[0].name, "loopl-app-sim")
        let ggufOnly = TrainingTunedBase.fromOwned(runnable: ["me/loopl-app-sim-GGUF"], owned: owned)
        XCTAssertEqual(ggufOnly[0].name, "loopl-app-sim"); XCTAssertEqual(ggufOnly[0].bf16Repo, "me/loopl-app-sim")
        XCTAssertEqual(bases[0].bf16Repo, "me/loopl-app-sim"); XCTAssertEqual(bases[0].round, 1); XCTAssertEqual(bases[0].size, .b0_8)
        XCTAssertEqual(bases[1].bf16Repo, "me/loopl-2b-r2"); XCTAssertEqual(bases[1].round, 2); XCTAssertEqual(bases[1].size, .b2)
        XCTAssertNil(bases[2].bf16Repo, "no bf16 next to the 4-bit weights → not trainable (the script refuses 4-bit)")
        XCTAssertFalse(bases[2].isTrainable)
        XCTAssertEqual(TrainingTunedBase.bf16Sibling(of: "x/loopl-mine-GGUF"), "x/loopl-mine")
        XCTAssertEqual(TrainingBase.sizeToken(in: "Qwen/Qwen3.5-0.8B"), "0.8b"); XCTAssertEqual(TrainingBase.sizeToken(in: "me/loopl-4b-4bit"), "4b")
        XCTAssertNil(TrainingBase.sizeToken(in: "me/loopl-app-sim"))
    }

    func testContinualPlanArgumentsAndDefaults() {
        let tuned = TrainingTunedBase(repo: "me/loopl-app-sim-4bit", bf16Repo: "me/loopl-app-sim", round: 1, size: .b0_8)
        let plan = TrainingPlan(dataset: "me/loopl-app-conversations", conversations: 120, base: .b2, tunedBase: tuned, stitch: .day)
        XCTAssertEqual(plan.base, .b0_8, "the tuned base's Qwen root wins over the stock pick")
        XCTAssertEqual(plan.method, .lora, "round ≥ 2 defaults to LoRA, like the script")
        XCTAssertEqual(plan.round, 2)
        XCTAssertEqual(plan.outputName, "loopl-app-sim-r2")
        XCTAssertEqual(plan.baseLabel, "loopl-app-sim · round 2")
        XCTAssertEqual(plan.scriptArguments(user: "me"),
                       ["--dataset", "me/loopl-app-conversations", "--base", "me/loopl-app-sim", "--out", "me/loopl-app-sim-r2",
                        "--epochs", "auto", "--method", "lora", "--stitch", "day", "--expect-vision"])
        var noReplay = plan; noReplay.includeAllShards = false
        XCTAssertTrue(noReplay.scriptArguments(user: "me").contains("--new-shards-only"))
        var fresh = TrainingPlan(dataset: "me/d", conversations: 50, base: .b0_8, epochs: .fixed(9))
        fresh.includeAllShards = false
        XCTAssertEqual(fresh.scriptArguments(user: "me")[7], "4", "fixed epochs clamp to 1…4")
        XCTAssertFalse(fresh.scriptArguments(user: "me").contains("--new-shards-only"), "round 1 has nothing to replay")
        // round-aware output names do not pile up suffixes
        XCTAssertEqual(TrainingPlan.defaultOutputName(continuing: TrainingTunedBase(repo: "me/loopl-app-sim-r2-4bit", bf16Repo: "me/loopl-app-sim-r2", round: 2, size: .b0_8)), "loopl-app-sim-r3")
    }

    func testEpochsHeuristicDrivesAutoAndTheEstimate() {
        XCTAssertEqual(TrainingEpochs.heuristic(forConversations: 120).text, "3–4"); XCTAssertEqual(TrainingEpochs.heuristic(forConversations: 120).autoMax, 3)
        XCTAssertEqual(TrainingEpochs.heuristic(forConversations: 500).text, "2"); XCTAssertEqual(TrainingEpochs.heuristic(forConversations: 500).autoMax, 2)
        XCTAssertEqual(TrainingEpochs.heuristic(forConversations: 5000).text, "1–2"); XCTAssertEqual(TrainingEpochs.heuristic(forConversations: 5000).autoMax, 2)
        let auto = TrainingPlan(dataset: "me/d", conversations: 120, base: .b0_8, epochs: .auto)
        let three = TrainingPlan(dataset: "me/d", conversations: 120, base: .b0_8, epochs: .fixed(3))
        XCTAssertEqual(auto.estimate.steps, three.estimate.steps, "auto bills for the heuristic's upper bound — never a surprise")
        XCTAssertEqual(TrainingEpochs.auto.argument, "auto"); XCTAssertEqual(TrainingEpochs.fixed(2).label, "2")
    }

    func testProgressReadsPlanEpochAndLineageLines() {
        var p = TrainingProgress()
        p.ingest(#"[loopl] plan {"round": 2, "base": "me/loopl-app-sim", "lineage": ["Qwen/Qwen3.5-0.8B", "me/loopl-app-sim"], "epochs": {"mode": "auto", "max": 3.0, "heuristic": "3–4", "conversations": 120, "early_stop": true}, "replay": true, "stitch": {"mode": "day", "stitched": 9, "unkeyed": 12}}"#)
        XCTAssertEqual(p.plan?.round, 2); XCTAssertEqual(p.plan?.lineage, ["Qwen/Qwen3.5-0.8B", "me/loopl-app-sim"])
        XCTAssertEqual(p.plan?.epochsMode, "auto"); XCTAssertEqual(p.plan?.heuristic, "3–4"); XCTAssertEqual(p.plan?.stitched, 9); XCTAssertEqual(p.plan?.unkeyed, 12); XCTAssertEqual(p.plan?.replay, true)
        p.ingest("[loopl] epoch=1 eval_loss=2.2410 best=2.2410")
        p.ingest("[loopl] epoch=2 eval_loss=2.1477 best=2.1477")
        p.ingest("[loopl] epoch=2 eval_loss=2.1470 best=2.1470")   // a re-read line updates, never duplicates
        XCTAssertEqual(p.evalHistory.map(\.epoch), [1, 2]); XCTAssertEqual(p.evalHistory.last?.evalLoss, 2.147)
        p.ingest(#"[loopl] done {"out": {"merged": "me/loopl-app-sim-r2", "mlx": "me/loopl-app-sim-r2-4bit"}, "round": 2, "lineage": ["Qwen/Qwen3.5-0.8B", "me/loopl-app-sim"], "epochs_trained": 3.0, "best_epoch": 2, "eval_history": [{"epoch": 1.0, "eval_loss": 2.241}, {"epoch": 2.0, "eval_loss": 2.147}, {"epoch": 3.0, "eval_loss": 2.17}, {"epoch": 3.0, "eval_loss": 2.147}], "stitched": 9, "eval_loss_base": 2.38, "eval_loss_tuned": 2.147, "script": "1.2.0"}"#)
        let o = try! XCTUnwrap(p.output)
        XCTAssertEqual(o.round, 2); XCTAssertEqual(o.bestEpoch, 2); XCTAssertEqual(o.epochsTrained, 3); XCTAssertEqual(o.stitched, 9)
        XCTAssertEqual(o.evalHistory?.map(\.epoch), [1, 2, 3], "the final best-model evaluate (a 2nd 'epoch 3' from scripts < 1.2.3) is not a 4th bar")
        XCTAssertEqual(o.evalHistory?.last?.evalLoss, 2.17); XCTAssertEqual(o.lineage?.last, "me/loopl-app-sim")
        // a 1.1.0 job without the new keys still parses (nil, not garbage)
        var old = TrainingProgress()
        old.ingest(#"[loopl] done {"out": {"merged": "x/y"}, "eval_loss_base": 2.3, "eval_loss_tuned": 2.1, "script": "1.1.0"}"#)
        XCTAssertNil(old.output?.round); XCTAssertNil(old.output?.evalHistory)
    }

    func testOwnedRepoParsing() throws {
        let json = #"[{"id": "me/loopl-app-sim", "library_name": "transformers", "tags": ["loopl"], "cardData": {"loopl_round": 1, "base_model": "Qwen/Qwen3.5-0.8B"}}, {"id": "me/loopl-app-sim-4bit", "library_name": "mlx", "cardData": {"loopl_round": "1", "loopl_parent": "me/loopl-app-sim"}}, {"id": "me/plain"}]"#
        let owned = try HubCatalog.parseOwned(Data(json.utf8))
        XCTAssertEqual(owned.map(\.id), ["me/loopl-app-sim", "me/loopl-app-sim-4bit", "me/plain"])
        XCTAssertEqual(owned[0].looplRound, 1); XCTAssertEqual(owned[1].looplRound, 1); XCTAssertEqual(owned[1].looplParent, "me/loopl-app-sim"); XCTAssertNil(owned[2].looplRound)
        let url = HubCatalog(token: nil).ownedURL(author: "me").absoluteString
        XCTAssertTrue(url.contains("author=me") && url.contains("expand%5B%5D=cardData"))
    }
}
