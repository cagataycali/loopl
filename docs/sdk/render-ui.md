---
title: "Render UI"
description: "render_ui: the model emits a small typed spec — chart, map, diagram, table, key/value, list, progress, markdown — and the host draws it with native SwiftUI. No code runs."
---

# Render UI

Some answers are not prose. Steps per day want a bar chart; three cafés want a map; a login flow wants boxes and
arrows. `render_ui` lets the model **say so in data**: it emits a small, typed JSON spec, and the host draws it with
native views — Swift Charts, MapKit, a Canvas. Nothing in the spec is code and nothing is executed; a web view is
never involved. The same spec is what tiny's `use_render` draws in a terminal and what loopl's iOS app draws as a card.

```swift
// snippet: compile
import Loopl

func run(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [RenderUITool()], systemPrompt: "Show numbers as a chart, places as a map.")
    for try await event in agent.stream("Chart my steps: Mon 4000, Tue 6200, Wed 7100.") {
        if case .toolResult(let r) = event, r.name == RenderUITool.toolName {
            print(r.content)   // "rendered 1 component (chart). The user sees the card — do not repeat the same data in prose."
        }
    }
}
```

## The spec

```json
{ "title": "Your week",
  "components": [
    { "type": "markdown", "content": "Steps up **18 %** on last week." },
    { "type": "chart", "kind": "bar", "title": "Steps",
      "series": [ { "name": "steps", "points": [ { "label": "Mon", "value": 4000 }, { "label": "Tue", "value": 6200 } ] } ] },
    { "type": "map", "pins": [ { "lat": 40.7447, "lon": -74.0323, "label": "bwè kafe" } ], "route": [[40.7447, -74.0323], [40.7398, -74.03]] },
    { "type": "diagram", "nodes": [ { "id": "open", "label": "Open app" }, { "id": "home" } ], "edges": [ { "from": "open", "to": "home", "label": "ok" } ] }
  ] }
```

One `type` per component; everything else is optional so a 0.8B model can emit it.

| type | fields | drawn as |
|---|---|---|
| `markdown` | `content` | the transcript's Markdown renderer |
| `text` | `content`, `style: plain · secondary · strong · caption · mono` | one styled line |
| `rule` | `title?` | a divider, optionally titled |
| `keyvalue` | `title?`, `data: {key: value}` | an aligned grid (stacked at accessibility sizes) |
| `table` | `title?`, `headers: [String]`, `rows: [[String]]` | `MarkdownTable`; ragged rows are padded, ≤ 8 columns × 50 rows |
| `list` | `title?`, `items: [String \| {title, subtitle?, icon?}]` | bullets or SF Symbol rows |
| `chart` | `title?`, `kind: bar · line · pie`, `series: [{name?, points: [{label, value}]}]` | Swift Charts — grouped bars, smoothed lines, a donut with a value legend (first series) |
| `map` | `title?`, `pins: [{lat, lon, label?}]`, `route?: [[lat, lon]]` | MapKit markers + polyline; tap opens Apple Maps with every pin |
| `diagram` | `title?`, `nodes: [{id, label?}]`, `edges: [{from, to, label?}]` | a layered node-edge graph on a Canvas (`DiagramLayout`) |
| `progress` | `description?`, `total`, `completed` | a bar with the percentage and *x of y* |
| `image` | `url` **or** `attachment` (index into the user's pictures), `caption?` | the picture; an attachment comes back through `ToolOutput.images` |

## Lenient by design, honest by contract

The author is a small on-device model, so `RenderSpec(args:)` repairs what it can — `"4k"` and `"7,100"` become
numbers, `{Mon: 4000}` becomes points, object rows are read by header, `"login -> home"` is an edge, a node named only
by an edge is added; and the shapes measured on loopl-0.8b/2b: `components` sent as a JSON *string* (also when the
schema check has wrapped it into a one-element array), an extra `}` or a truncated tail (brackets are rebalanced), a
key missing its closing quote, a missing `type` (inferred from `kind`, from a type-named key such as `{"chart": {…}}`,
or from the fields present), `edges`/`pins`/`series` left beside the component instead of inside it, and a diagram
split across edge-less components — and **records every repair in `issues`**. The result the model reads names the kinds it drew and
appends the issues as *notes for the next call* — worded so that the model knows the card **is** already drawn
(measured on loopl-0.8b: a line labelled `issues:` read as failure and the same card was re-sent four times). An
unknown `type` is kept as
`RenderComponent.unknown(type:)`: the card says *unknown component type "gauge"* and the result lists the known
types. Only a missing or empty `components` throws.

```swift
let spec = try RenderSpec(args: ["components": .array([.object(["type": "chart", "points": .array([.object(["label": "Mon", "value": "4k"])])])])])
spec.components[0]      // .chart(title: nil, kind: .bar, series: [Series(points: [Point("Mon", 4000)])])
spec.issues             // []  — "4k" was read as 4000; a value with no number would be listed here
spec.resultText         // "rendered 1 component (chart). The user sees the card — do not repeat the same data in prose."
```

Caps (`RenderSpec.maxComponents` 12, rows 50, points 120, pins 50, nodes 40 …) exist because the spec is untrusted
output rendered eagerly as views; overflow is reported, not silently cut.

## Drawing it (LooplUI)

`RenderCard(call:result:spec:images:)` is the row the app shows: the ordinary tool row (tap for the raw arguments) with
the card beneath — `RenderBody(spec:)` if you only want the card. A `render_ui` call is a normal `toolUse` in the
transcript; the card **re-renders from the saved `ToolUse.input`**, so History needs no second format. Every kind
carries a spoken summary for VoiceOver (*bar chart Steps: Mon 4000, Tue 6200 …*; *diagram Login flow with 6 steps: Open
app to Verify …*), the map is a button that opens Maps, and the diagram's layout is pure
(`DiagramLayout(nodes:edges:)`: DFS back-edge detection, then longest-path layers) so it is unit-tested without a Canvas.

Training note: the trajectories loopl's models learn for `render_ui` (one call, then one sentence that does not repeat
the numbers) are the DATASET-V12 families R1–R6.
