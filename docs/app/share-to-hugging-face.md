---
title: Share to Hugging Face
description: Turn finished conversations into a private training set in your own Hugging Face account — reviewed, redacted and pushed from the phone.
---

# Share to Hugging Face

Your conversations are training data you already own. History › **Select** lets you pick the ones worth keeping and push them to a **private dataset in your Hugging Face account**, in the same schema loopl's own models are trained on — so a later [training job](https://huggingface.co/docs/huggingface_hub/guides/jobs) can turn them into *your* model.

Nothing leaves the device until you tap **Push**.

## Steps

1. **History → Select** (or hold a conversation → *Share to Hugging Face*). Pick any number; *Select all* is one tap.
2. **Review.** Each conversation shows its turns, tool calls and pictures, or the reason it would be skipped (a thread with no finished answer is not learnable). Fold open **Preview** to see the exact first JSON line.
3. **Before it leaves this device** — three switches, all off by default:
   - *Remove pictures* — images are dropped and the row says so (off: every picture you attached travels with its conversation);
   - *Remove tool results* — tool calls stay, their outputs are replaced by a marker;
   - *Replace URLs with example.com* — every link in your turns, answers and tool arguments.
4. **Token.** The first time, paste a Hugging Face token with **write** access. It is verified against `whoami` before it is stored, lives in the Keychain, and is sent only to `huggingface.co`. Already signed in under Settings › Hugging Face? This step is skipped.
5. **Dataset.** Pick one of your existing private datasets, or type a name for a new one (created private). The repository line shows exactly where the rows go.
6. **Push.** One commit: `data/train-<timestamp>.jsonl`, `images/<sha>.png` for kept pictures, and a `README.md` dataset card (tags `loopl`, `loopl-conversations`). Later shares append a new shard; nothing already there is touched. The success screen links to the files.

## What a row contains

One JSON line per conversation, following loopl-train's `schema/conversation.schema.json`:

| field | content |
|---|---|
| `messages` | the loopl system prompt (versioned), your turns, the model's answers, tool calls with their results — in order |
| `tools` | the tool specs the thread offered, so the model learns *when* to call, not just *what* |
| `gen` | provenance: model id, app version, platform, timestamp, system-prompt version, which redactions were applied |
| `images/` | referenced by hash from the row; only when *Remove pictures* is off |

Rows that would not validate are never written — the review screen is the validator.

## Privacy

- Private repo, your account, your token. loopl has no server in this path.
- Redaction runs on the device before anything is encoded; the preview shows the redacted bytes.
- Removing the token (Settings › Hugging Face, or *Sign out* on the dataset step) deletes it from the Keychain.

The SDK side: `ConversationExport.record(_:options:)` turns a `Thread` into one validated row (redaction in `Options`), `shard(_:options:)` batches rows into the JSONL + images + card a push commits, and `validate(_:)` lists schema problems; `HFHubClient` — see [Private repos](../sdk/models.md#private-repos) in the SDK docs. Then [train on it](train.md).

---

<div class="l-actions l-actions--page"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9">Get it on TestFlight</a><a class="l-link" href="index.md">The app</a></div>
