import Foundation
import Loopl

// Two pieces of the GGUF runtime that are pure Swift — no llama.cpp symbol in sight — and therefore
// live OUTSIDE `#if canImport(llama)`. They used to sit inside it, which meant their tests could not
// compile at all without `Vendor/llama.xcframework`: `swift test` failed to BUILD on macOS, taking
// every other suite down with it, and the macOS CI job did not notice because it piped `swift test`
// into `tail` without `pipefail`. Out here they compile and get tested on any checkout.

extension GGUFModel {
    static func renderPrompt(template: String?, systemPrompt: String?, messages: [Loopl.Message], toolSpecs: [Loopl.ToolSpec], family: ToolFamily,
                             kwargs: [String: JSONValue]? = nil) -> String {
        let sys = PromptBuilder.toolSystemPrompt(toolSpecs: toolSpecs, family: family, base: systemPrompt)
        let folded = PromptBuilder.foldToolMessages(messages)
        var chat: [(String, String)] = []
        if !sys.isEmpty { chat.append(("system", sys)) }
        for m in folded { chat.append((m.role.rawValue, m.text)) }
        var out: String
        if let template, let rendered = applyTemplate(template, chat) { out = rendered }
        // Gemma-style templates reject a system role → merge into the first user turn and retry.
        else if let template, !sys.isEmpty, chat.count > 1, chat[1].0 == "user",
                let rendered = applyTemplate(template, { var m = Array(chat.dropFirst(2)); m.insert(("user", sys + "\n\n" + chat[1].1), at: 0); return m }()) { out = rendered }
        else { out = PromptBuilder.chatML(systemPrompt: sys.isEmpty ? nil : sys, messages: folded) }
        return applyKwargs(out, kwargs: kwargs)
    }

    /// `llama_chat_apply_template` takes no template kwargs. The one that matters on-device is Qwen3's
    /// `enable_thinking: false`, which the Jinja template implements by opening the assistant turn with an
    /// empty think block — so we append exactly that.
    static func applyKwargs(_ rendered: String, kwargs: [String: JSONValue]?) -> String {
        guard case .bool(false)? = kwargs?["enable_thinking"] else { return rendered }
        let empty = "<think>\n\n</think>\n\n"
        if rendered.hasSuffix(empty) || rendered.hasSuffix("</think>\n\n") { return rendered }
        return rendered + empty
    }
}

/// Byte-wise UTF-8 assembly: llama pieces may split a multi-byte scalar.
struct UTF8Accumulator {
    private var pending: [UInt8] = []
    mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        // Find the longest prefix that is complete UTF-8.
        var end = pending.count
        var i = pending.count - 1
        var back = 0
        while i >= 0, back < 4 {
            let b = pending[i]
            if b & 0b1100_0000 == 0b1000_0000 { i -= 1; back += 1; continue }   // continuation byte
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if i + need > pending.count { end = i }                                // incomplete scalar at the tail
            break
        }
        let ready = Array(pending[0..<end]); pending.removeFirst(end)
        return String(decoding: ready, as: UTF8.self)
    }
    mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

#if !canImport(llama)
extension GGUFModel {
    /// No llama.cpp in this build, so there is no Jinja engine: `renderPrompt` falls back to ChatML.
    static func applyTemplate(_ template: String, _ chat: [(String, String)]) -> String? { nil }
}
#endif
