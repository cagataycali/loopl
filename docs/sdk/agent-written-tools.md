---
description: manage_tools create — the model writes a tool in Swift (Mac) or JavaScript (iPhone/iPad), loopl validates and loads it, and it is callable on the very next model call.
---

# Agent-written tools

When no tool does what the user needs, the model can **write one**. `manage_tools create` takes the source, validates it,
saves it, loads it — and the tool is offered on the model's **very next call** of the same turn. It comes back after a
relaunch, and it shows up in the app under **Settings › Tools › Created by the agent** (source view, delete).

```json
{"action": "create", "name": "reverse_string", "language": "swift", "source": "import Foundation\nstruct ReverseString: Tool { … }"}
```

Errors from the compiler or the JavaScript engine come back **verbatim** as the tool result, so the model reads
`reverse_string.swift:6:12: error: …`, fixes the line and calls `create` again.

## Which language — and why it depends on the device

| Device | Language | How it runs |
|---|---|---|
| **Mac** (tests, harnesses, Mac builds) | **Swift** | `swiftc -emit-library` → probed in a separate process → `dlopen` |
| **iPhone / iPad** | **JavaScript** | JavaScriptCore, a fresh context per call |

This is a hard fact, not a preference: **iOS cannot compile or `dlopen` code at runtime** — no toolchain ships, and the
kernel refuses unsigned pages — and App Store Review guideline 2.5.2 permits exactly one kind of downloaded code:
scripts run by JavaScriptCore/WebKit. So the system prompt steers the model: *on a Mac write Swift; on iPhone or iPad
write JavaScript*. Swift submitted on an iPhone is **saved and answered honestly** (*"saved; runs on your Mac"*), never
silently dropped; the `manage_tools` description tells the model which language this device runs.

## The Swift shape (Mac)

```swift
--8<-- "docs/snippets/agent-tool.swift"
```

One `struct <Name>: Tool` per file, `init()` with no arguments. `inputSchema` is JSON Schema as `[String: Any]`;
`call` receives the arguments as `[String: Any]` and returns the text the model reads. Throw `ToolError("…")` to hand
the model a message it can act on.

How it is loaded — mirroring tiny-tech's `manage_tools`, where nothing loads before a sandbox pass:

1. The source and a small **shim** (the `Tool` protocol above + three C symbols `loopl_tool_abi`, `loopl_tool_spec`,
   `loopl_tool_call`, JSON across them) are compiled with `swiftc -swift-version 5 -O -emit-library` (≈ 0.6 s).
   The dylib never links the `Loopl` module — the ABI is the three symbols, so a tool built today loads in next
   month's app.
2. A **probe executable** (built once per toolchain) `dlopen`s the dylib in its own process, reads the spec and must exit
   cleanly within 15 s. A dylib that crashes, hangs or exports no tool costs a subprocess, not the app.
3. Only then does the app `dlopen` it. `CompiledSwiftTool.call` sends the arguments as JSON and reads
   `{"ok": true, "text": …}` or `{"ok": false, "error": …}`.

## The JavaScript shape (iPhone, iPad, Mac)

```js
--8<-- "docs/snippets/agent-tool.js"
```

The script must define a global `tool` with `name`, `description`, `inputSchema` and `call(args)`; `call` may return a
string, an object (JSON-encoded for the model) or a Promise. What the script can reach, and nothing else:

- `loopl.call(toolName, args)` — runs another tool the model has on (calculator, http, remember…), returns its text.
- `loopl.http(url, {method, headers, body})` → `{status, body}` — the SDK's `HttpTool` rules (https only, offline mode, approvals).
- `console.log(…)` / `loopl.log(…)` — appended to the result as `[log]` lines.

`eval` and `Function` are removed before the script runs: fetched text is data, never code. Every call gets a fresh
`JSContext` and a 30 s deadline; like tiny-tech's `wrapHandler`, the deadline stops the *turn* waiting — a script in a
tight loop is abandoned on its thread and reported as a timeout.

## Persistence and Settings

`DynamicToolStore` keeps `<name>.swift|js` + `<name>.json` under *Application Support/loopl/tools* (pass a directory to
the initializer for your own location). `reload()` at launch loads every file again; one that fails stays listed as
**failed** with the compiler's words, the others still load. Names follow the registry rule (1–64 chars of letters,
digits, `_`, `-`; `my-tool` and `my_tool` collide), built-in names are refused, duplicates are refused with a
`remove`-first hint, and a `name` that disagrees with the code is refused.

```swift
let store = DynamicToolStore(directory: dir)          // default: Application Support/loopl/tools
await store.setReserved(engine.allTools.map(\.name))   // builtins win
await store.onChange { tools in await agent.setTools(base + tools) }   // next model call sees them
_ = await store.reload()
```

The app wires `DynamicToolStore.shared` into `Engine.activeTools` and sets `JSToolRuntime.bridge` so `loopl.call`
reaches the mounted tools. With the Phase 6 `ToolRegistry`, the store is its `ToolCreator`
(`create(name:source:language:)`, `remove(name:)`, `saved()`).

## The system-prompt directive

The default prompt (`loopl-train data/system/app-default.md`) carries, in substance:

> If you lack a tool for what the user asked, call `manage_tools` — `list` what exists and mount it, or **write the tool**:
> on a Mac write Swift (`struct X: Tool` as shown in the tool's description), on an iPhone or iPad write JavaScript
> (a global `tool` object), then load it with `manage_tools create`. It is available on your next step. If the compiler
> or engine reports an error, fix the code and create again. Keep tools small and named for what they do.

## Tests

`DynamicToolsTests` (SDK): JavaScript run / shape errors / Promise + `console.log` + bridge / no `eval` / timeout;
store create → persist → reload → remove, reserved and duplicate names; and on macOS the full Swift path — compile →
probe → `dlopen` → call, compile errors verbatim, relaunch recompiles from source.
