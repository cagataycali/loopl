---
title: "Asking the user"
description: "ask_user: the agent asks the human mid-turn with a native form — confirm, select, multiselect, input, buttons, form, message — and waits for the answer through the same interrupt an approval uses."
---

# Asking the user

Sometimes the model cannot proceed without a decision, a missing detail, a credential or a preference. Guessing is worse than asking, and asking in prose ("which restaurant?") ends the turn — the user types, the agent starts over. **`ask_user`** keeps the turn alive: the model emits a small **typed spec**, the host draws it as a **native card** in the transcript, and the human's answer comes back as the tool's result. The model then continues with the value in hand.

```json
{"type": "select", "title": "Pick a restaurant", "text": "Where should I book for tonight at 20:00, for two?",
 "options": ["Antica Pesa · Italian", "Oda · Turkish", "Blue Ribbon · Sushi"]}
```

| `type` | the card | `value` the model reads |
|---|---|---|
| `confirm` | two buttons, Yes / No | `true` / `false` |
| `select` | a radio list + **Choose** | the picked option |
| `multiselect` | checkboxes, All/None, **Done** | `["a", "b"]` (may be empty) |
| `input` | a text field (optional `default`) + Send | the text |
| `buttons` | a row of chips (`default` tinted) | the tapped option |
| `form` | grouped fields — `text`, `password`, `number`, `toggle` — + **Submit**; `required` fields are checked | `{name: value}` — toggles are booleans, numbers are numbers |
| `message` | an information box + **Continue** | `"acknowledged"` |

Options may be plain strings or `{value, label}` objects (the label is what the card shows, the value is what the model gets back). Every card has **Cancel**, and the agent waits at most `timeout_s` (default 180 s, clamped 5…3600).

The result is JSON the model reads:

```text
{"ok": true, "value": "Oda · Turkish"}
{"ok": false, "cancelled": true}        — the user tapped Cancel
{"ok": false, "timeout": true}          — nobody answered in time
ERROR: ask_user: options required for select, e.g. ["a", "b"]   — a bad spec, written so the model can repair it
```

## It is the approval mechanism

`ask_user` adds **no new control flow**. The tool raises an [interrupt](hitl.md) named `ask_user` through `InterruptScope.interrupt` — exactly what a human-in-the-loop approval does. The agent emits `.interruptRaised`, parks that one call on its gate (the other tools of the same message keep running), and when the host calls `agent.resolve(interrupt:response:)` the tool body runs a second time with the answer and returns it. A timeout substitutes `.null`, which the tool turns into `{ok:false, timeout:true}`.

```swift
// snippet: compile
import Loopl

func run(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [AskUserTool(), CalculatorTool()])
    for try await event in agent.stream("Book me a table tonight.") {
        switch event {
        case .interruptRaised(let interrupt):
            // Draw the card from the spec. In the app this is `AskUserCard`; here we answer at once.
            if let toolUseId = AskUserTool.toolUseId(fromInterruptId: interrupt.id),
               let request = AskUserRequest(interruptReason: interrupt.reason ?? .null) {
                print("the agent asks:", request.text, request.options.map(\.label))
                let answer = AskUserAnswer.answered(.string(request.options.first?.value ?? ""))
                Task { await agent.resolve(interrupt: AskUserTool.interruptId(toolUseId: toolUseId), response: answer.interruptResponse) }
            }
        case .text(let t): print(t, terminator: "")
        default: break
        }
    }
}
```

`Transcript` folds the events for you: when the interrupt is raised, the tool's own row becomes **`TranscriptItem.Kind.ask(toolUseId:, request, answer: nil)`**; `.interruptResolved` settles it; the tool result folds into the card (no duplicate row). `transcript.pendingAsks` lists the cards still waiting. Inside a [sub-agent](sub-agents.md) the card appears in the child's card and is answered on the child (`SubAgentHub.resolve(child:interrupt:response:)`).

The interrupt carries its own wait: `Interrupt.timeout` (new, optional) overrides the agent's `approvalTimeout` for that one interrupt — `ask_user` sets it from `timeout_s`.

## Passwords: the privacy rule

A `password` field's value reaches the model **only inside this tool's result** — that is the point of asking for it. Everything else never sees it:

- the transcript card keeps the answer **masked** (`••••`) — `AskUserAnswer.masked(for:)` runs before the card settles;
- History on disk and the Share-to-Hugging-Face export store the masked answer (the card is saved as its `ask_user` tool pair);
- a history rebuilt from the transcript (edit / retry) carries the masked pair, so an edited thread never re-sends the secret;
- the field is a secure text field marked so iOS does **not** offer to save it to the keychain;
- the tool's description tells the model never to repeat a password in prose.

The model's working context for the *current* turn does hold the value (the tool result) — it needs it to use it. That context is not persisted.

## In the app

`ask_user` is on by default (Settings › Tools). The card is `AskUserCard` in `LooplUI`: *waiting for you* pill, native controls per type, Cancel always, one quiet line once settled (tap the chevron to re-read the question). Accessibility sizes stack the controls; VoiceOver reads the card as *question from the agent: <title>, waiting for you*. On iPad with a hardware keyboard, ⌘↩ sends an input or submits a form.

Measured with the real MLX stack (see the PR): an ambiguous request produces **one** `ask_user` and the answer is used in the very next step; a plain question never asks.
