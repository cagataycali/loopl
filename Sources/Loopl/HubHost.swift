import Foundation

/// Where Hub requests go. One place, so a DEBUG build can be pointed at a local stand-in and
/// someone can finally SEE a 429, a 503 or a mid-download disconnect land in the Models list —
/// the words, the Retry button and the `.part` sidecar resuming — instead of trusting a unit test.
///
/// RELEASE BUILDS CANNOT BE REDIRECTED: the override is compiled out entirely, so what ships
/// talks to huggingface.co and nothing else. In DEBUG it is read from the process environment,
/// which on iOS only the launching process (Xcode, `simctl --console`, a test runner) can set —
/// never another app and never the user.
///
///     LOOPL_HUB_HOST=http://127.0.0.1:8899
public enum HubHost {
    /// The real Hugging Face.
    public static let production = "https://huggingface.co"

    /// The host every Hub type defaults to.
    public static var current: String {
        #if DEBUG
        if let h = ProcessInfo.processInfo.environment["LOOPL_HUB_HOST"],
           !h.isEmpty, let u = URL(string: h), u.scheme != nil, u.host != nil {
            return h.hasSuffix("/") ? String(h.dropLast()) : h
        }
        #endif
        return production
    }

    /// True when this process is NOT talking to the real Hub — for a banner or a log line that
    /// says so, because a failure injected by a stand-in must never read as a Hugging Face outage.
    public static var isOverridden: Bool { current != production }
}
