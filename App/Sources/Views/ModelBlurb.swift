import Loopl
import LooplUI

/// One line of plain language per loopl model — used by onboarding cards and the Models › loopl models rows, so the
/// first thing a new user reads is never a Hub card ("MLX 4-bit, 297 vision tensors, quiz 158 vs base 83").
enum ModelBlurb {
    /// Hand-written for the picks the app ships; nil for anything else.
    static func known(_ spec: ModelSpec) -> String? {
        switch spec.id {
        case "loopl-0.8b-4bit": "Smallest — quick answers and tools, sees pictures. Any recent \(LooplDesign.deviceName)."
        case "loopl-2b-4bit": "The best balance of speed and quality on \(LooplDesign.deviceName). Photos, tools, memory."
        case "loopl-4b-4bit": LooplDesign.deviceName == "iPhone" ? "Most capable — needs a Pro-class iPhone (8 GB of memory)." : "Most capable — needs 8 GB of memory (Pro-class \(LooplDesign.deviceName))."
        case "qwen3-0.6b-4bit": "Fastest. Chat, tools and quick answers — runs on any recent iPhone."
        case "qwen3.5-0.8b-4bit": "Small and sees pictures. Ask about a photo or a screenshot."
        case "qwen3.5-2b-4bit": "Smartest of the three. Photos + tools — needs about 3 GB of memory."
        default: nil
        }
    }
    /// The line for a spec: hand-written when we have one, else the row's own notes, shortened.
    static func text(_ spec: ModelSpec) -> String { known(spec) ?? spec.notes.map { String($0.prefix(90)) } ?? "" }
    /// A curator's note from the Hub, made readable: the first sentence only, with build clauses
    /// ("— MLX 4-bit, vision:" / "(3.03 GB, 297 vision tensors)") dropped. Pure, so it is testable.
    static func plain(note: String) -> String {
        var s = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"\s*\([^)]*\b(tensors?|bit|bf16|GB|MB)\b[^)]*\)"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"\s+—\s+(MLX|GGUF|bf16)[^:]*:\s*"#, options: .regularExpression) { s.replaceSubrange(r, with: " — ") }
        if let dot = s.range(of: ". ") { s = String(s[..<dot.lowerBound]) + "." }
        return s
    }
}
