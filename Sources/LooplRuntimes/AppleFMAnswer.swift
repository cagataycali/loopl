import Foundation
import Loopl

/// Apple FM, taught the tool-call JSON shape, sometimes answers in JSON too:
/// `{"status": "completed", "message": "Istanbul is currently 05:02."}` (the
/// owner's exact report). That object is not a tool call — no `"name"` — so
/// the gate rightly lets it through as text, and the user reads JSON. This
/// unwraps such a wrapper into the sentence it carries. Anything else
/// (a real list, an object the user asked for, prose) is left alone.
public enum AppleFMAnswer {
    /// Keys whose string value is the answer, in order of preference.
    public static let answerKeys = ["message", "answer", "response", "reply", "content", "text", "result", "output", "summary"]

    /// The prose inside a JSON wrapper, or `nil` when `text` is not one.
    public static func unwrap(_ text: String) -> String? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = String(body.dropFirst(3))
            if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) } else { return nil }
            if let close = body.range(of: "```", options: .backwards) { body = String(body[..<close.lowerBound]) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.hasPrefix("{"), body.hasSuffix("}"), let obj = JSONValue.parse(body)?.objectValue else { return nil }
        guard obj["name"] == nil, obj["arguments"] == nil else { return nil }       // a tool call is the parser's business
        for key in answerKeys {
            if let s = obj[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        // `{"status": "completed"}` alone — nothing to show; keep the model's text.
        return nil
    }
}
