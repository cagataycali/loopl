import XCTest
import Loopl

/// Every `http` tool call the small models ACTUALLY emitted for ten http-style asks, captured
/// verbatim on 2026-10-06 :
/// mlx-community/Qwen3.5-0.8B-4bit and Qwen3-0.6B-4bit through mlx_lm with (a) the model's own chat
/// template + native tools — exactly what MLXModel.swift does — and (b) PromptBuilder's hermes system
/// prompt; plus the real Apple Foundation Models with AppleFMPrompt's instructions.
///
/// The owner's report ("http tool fails … missing required parameter url") came from two of these shapes
/// that the parser did not understand: Qwen3.5's FLAT hermes call `{"name": "http", "url": …}` (every
/// argument at the top level → `arguments` = {}) and Qwen3.5's own XML dialect
/// `<function=http><parameter=url>…</parameter></function>` in all its sloppy variants (→ no call at all).
/// Each shape must resolve to a valid http call with the right URL — through the parser, the validator
/// and `HttpTool.parse`, i.e. the path the agent runs.
final class HttpCallShapesTests: XCTestCase {
    struct Shape { let model: String; let mode: String; let ask: String; let url: String; let method: String; let raw: String }

    static let shapes: [Shape] = [
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "template", ask: "fetch https://loopl.dev", url: "https://loopl.dev", method: "GET", raw: #"""
…</think>

<tool_call>
<function=http>
<url>
https://loopl.dev
</parameter>
<method=GET>
</parameter>
<parameter=headers>
{"Accept": "application/json"}
</parameter>
</function>
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "hermes", ask: "fetch https://loopl.dev", url: "https://loopl.dev", method: "GET", raw: #"""
…</think>

<tool_call>
{"name": "http", "url": "https://loopl.dev", "method": "GET", "timeout": 30}
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "template", ask: "POST {\"hello\": 1} to https://httpbin.org/post", url: "https://httpbin.org/post", method: "POST", raw: #"""
…</think>

<tool_call>
<function=http>
<method=POST>
<url=https://httpbin.org/post>
<body>{"hello": 1}</body>
</function>
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "template", ask: "get the headers of https://example.com with a HEAD request", url: "https://example.com", method: "HEAD", raw: #"""
…</think>

<tool_call>
<function=http>
<method=HEAD>
https://example.com
</parameter>
</function>
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "template", ask: "download https://loopl.dev/sitemap.xml and tell me how many urls it has", url: "https://loopl.dev/sitemap.xml", method: "GET", raw: #"""
…</think>

<tool_call>
<function=http>
<method=GET>
<url>
https://loopl.dev/sitemap.xml
</parameter>
</function>
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "template", ask: "send a PUT request to https://httpbin.org/put with body name=loopl", url: "https://httpbin.org/put", method: "PUT", raw: #"""
…</think>

<tool_call>
<function=http>
<method="PUT">
<url>
https://httpbin.org/put
</parameter>
<parameter=body>
{"name": "loopl"}
</parameter>
</function>
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "hermes", ask: "send a PUT request to https://httpbin.org/put with body name=loopl", url: "https://httpbin.org/put", method: "PUT", raw: #"""
…</think>

<tool_call>
{"name": "http", "url": "https://httpbin.org/put", "method": "PUT", "body": {"name": "loopl"}}
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "template", ask: "check if https://github.com/cagataycali/loopl is up", url: "https://github.com/cagataycali/loopl", method: "GET", raw: #"""
…</think>

<tool_call>
<function=http>
<method=GET>
<url>
https://github.com/cagataycali/loopl
</parameter>
</function>
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "hermes", ask: "check if https://github.com/cagataycali/loopl is up", url: "https://github.com/cagataycali/loopl", method: "GET", raw: #"""
…</think>

I'll check if https://github.com/cagataycali/loopl is up by making an HTTP request.

<tool_call>
{"name": "http", "url": "https://github.com/cagataycali/loopl", "method": "GET"}
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "hermes", ask: "call https://api.github.com/repos/cagataycali/loopl with header Accept: application/vnd.github+json", url: "https://api.github.com/repos/cagataycali/loopl", method: "GET", raw: #"""
…</think>

<tool_call>
{"name": "http", "url": "https://api.github.com/repos/cagataycali/loopl", "headers": {"Accept": "application/vnd.github+json"}, "method": "GET"}
</tool_call>
"""#),
        Shape(model: "Qwen3.5-0.8B-4bit", mode: "template", ask: "fetch loopl.dev", url: "https://loopl.dev", method: "GET", raw: #"""
…</think>

<tool_call>
<function=http>
<method=GET>
<url>
https://loopl.dev
</parameter>
</function>
</tool_call>
"""#),
        Shape(model: "Qwen3-0.6B-4bit", mode: "template", ask: "fetch https://loopl.dev", url: "https://loopl.dev", method: "GET", raw: #"""
<think>…</think>

<tool_call>
{"name": "http", "arguments": {"method": "GET", "url": "https://loopl.dev"}}
</tool_call>
"""#),
        Shape(model: "Qwen3-0.6B-4bit", mode: "template", ask: "get the headers of https://example.com with a HEAD request", url: "https://example.com", method: "HEAD", raw: #"""
<think>…</think>

<tool_call>
{"name": "http", "arguments": {"method": "HEAD", "url": "https://example.com"}}
</tool_call>
"""#),
        Shape(model: "Qwen3-0.6B-4bit", mode: "template", ask: "check if https://github.com/cagataycali/loopl is up", url: "https://github.com/cagataycali/loopl", method: "GET", raw: #"""
<think>…</think>

<tool_call>
{"name": "http", "arguments": {"method": "GET", "url": "https://github.com/cagataycali/loopl"}}
</tool_call>
"""#),
        Shape(model: "Qwen3-0.6B-4bit", mode: "hermes", ask: "call https://api.github.com/repos/cagataycali/loopl with header Accept: application/vnd.github+json", url: "https://api.github.com/repos/cagataycali/loopl", method: "GET", raw: #"""
<think>…</think>

<tool_call>
{"name": "http", "arguments": {"url": "https://api.github.com/repos/cagataycali/loopl", "headers": {"Accept": "application/vnd.github+json"}}}
</tool_call>
"""#),
        Shape(model: "Qwen3-0.6B-4bit", mode: "template", ask: "delete https://httpbin.org/delete", url: "https://httpbin.org/delete", method: "DELETE", raw: #"""
<think>…</think>

<tool_call>
{"name": "http", "arguments": {"method": "DELETE", "url": "https://httpbin.org/delete"}}
</tool_call>
"""#),
        Shape(model: "Qwen3-0.6B-4bit", mode: "hermes", ask: "delete https://httpbin.org/delete", url: "https://httpbin.org/delete", method: "DELETE", raw: #"""
<think>…</think>

<tool_call>
{"name": "http", "arguments": {"url": "httpbin.org/delete", "method": "DELETE"}}
</tool_call>
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "fetch https://loopl.dev", url: "https://loopl.dev", method: "GET", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://loopl.dev", "timeout": 10}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "fetch https://loopl.dev", url: "https://loopl.dev", method: "GET", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://loopl.dev", "method": "GET", "timeout": 5}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "POST {\"hello\": 1} to https://httpbin.org/post", url: "https://httpbin.org/post", method: "POST", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://httpbin.org/post", "body": "hello: 1"}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "POST {\"hello\": 1} to https://httpbin.org/post", url: "https://httpbin.org/post", method: "POST", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://httpbin.org/post", "body": "hello=1"}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "get the headers of https://example.com with a HEAD request", url: "https://example.com", method: "HEAD", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://example.com", "method": "HEAD"}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "download https://loopl.dev/sitemap.xml and tell me how many urls it has", url: "https://loopl.dev/sitemap.xml", method: "GET", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://loopl.dev/sitemap.xml", "method": "GET", "timeout": 10}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "download https://loopl.dev/sitemap.xml and tell me how many urls it has", url: "https://loopl.dev/sitemap.xml", method: "GET", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://loopl.dev/sitemap.xml", "method": "GET"}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "send a PUT request to https://httpbin.org/put with body name=loopl", url: "https://httpbin.org/put", method: "POST", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://httpbin.org/put", "body": "name=loopl"}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "check if https://github.com/cagataycali/loopl is up", url: "https://github.com/cagataycali/loopl", method: "GET", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://github.com/cagataycali/loopl", "method": "GET"}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "check if https://github.com/cagataycali/loopl is up", url: "https://github.com/cagataycali/loopl", method: "GET", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://github.com/cagataycali/loopl", "method": "GET", "timeout": 10}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "delete https://httpbin.org/delete", url: "https://httpbin.org/delete", method: "DELETE", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://httpbin.org/delete", "method": "DELETE", "timeout": 10}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "delete https://httpbin.org/delete", url: "https://httpbin.org/delete", method: "DELETE", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://httpbin.org/delete", "method": "DELETE", "timeout": 5}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "fetch loopl.dev", url: "https://loopl.dev", method: "GET", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://loopl.dev/", "timeout": 10}}
```
"""#),
        Shape(model: "Apple FM (macOS 26.4.1)", mode: "fm", ask: "fetch loopl.dev", url: "https://loopl.dev", method: "GET", raw: #"""
```json
{"name": "http", "arguments": {"url": "https://loopl.dev"}}
```
"""#),
    ]

    func testEveryCapturedShapeIsAValidHttpCall() {
        let http = HttpTool()
        for shape in Self.shapes {
            let label = "\(shape.model) [\(shape.mode)] \(shape.ask)"
            let parsed = ToolCallParser(family: .hermes).parse(shape.raw)
            XCTAssertEqual(parsed.calls.count, 1, "exactly one call — \(label)\n\(shape.raw)")
            guard let call = parsed.calls.first else { continue }
            XCTAssertEqual(call.name, "http", label)
            XCTAssertFalse(parsed.text.contains("<function="), "markup leaked into the visible text — \(label)")
            XCTAssertFalse(parsed.text.contains("<tool_call>"), "markup leaked into the visible text — \(label)")
            let outcome = ToolValidation.validateAndPrepare(toolUses: [call], tools: [http])
            XCTAssertTrue(outcome.results.isEmpty, "validator rejected it: \(outcome.results.first?.content ?? "") — \(label)\nargs: \(JSONValue.object(call.input).compact)")
            guard let valid = outcome.valid.first else { continue }
            do {
                let request = try HttpTool.parse(valid.input)
                XCTAssertEqual(request.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), shape.url, label)
                XCTAssertEqual(request.method, shape.method, label)
            } catch {
                XCTFail("HttpTool.parse threw \(error) — \(label)\nargs: \(JSONValue.object(valid.input).compact)")
            }
        }
    }

    /// The same shapes through the streaming gate, fed in small chunks the way a runtime decodes them:
    /// no markup may reach the text stream and the call must come out of `finish`.
    func testEveryCapturedShapeSurvivesTheStreamGate() {
        for shape in Self.shapes {
            var gate = ToolCallStreamGate(family: .hermes)
            var events: [StreamEvent] = []
            var rest = Substring(shape.raw)
            while !rest.isEmpty {
                let n = min(3, rest.count)
                events += gate.feed(String(rest.prefix(n)))
                rest = rest.dropFirst(n)
            }
            events += gate.finish()
            var text = ""; var calls: [String] = []
            for e in events {
                if case .contentBlockDelta(.text(let t)) = e { text += t }
                if case .contentBlockStart(.toolUse(_, let name)) = e { calls.append(name) }
            }
            let label = "\(shape.model) [\(shape.mode)] \(shape.ask)"
            XCTAssertEqual(calls, ["http"], label)
            XCTAssertFalse(text.contains("<function=") || text.contains("<tool_call>") || text.contains("\"name\""), "markup streamed as text — \(label): \(text)")
        }
    }
}
