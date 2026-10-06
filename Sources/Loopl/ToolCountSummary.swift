import Foundation

/// How many tools the model is actually offered, for a one-line settings summary.
///
/// The app's tool set is two lists: the portable ones (`current_time`, `calculator`, `device_info`,
/// `remember`, `recall`, `http`) and the on-device Apple ones, each of which can be switched off OR be
/// unavailable on this hardware (no Image Playground on a simulator, no torch on an iPad). The agent gets
/// `enabled && available` from both — so a summary that counts only the first list under-reports by the whole
/// second one: build 10's Settings said **"Tools 6 of 6"** on a phone whose loop ran with fourteen.
///
/// ```swift
/// ToolCountSummary.label(core: 6, coreEnabled: 6, apple: [(true, true), (true, false)])   // "7 of 7"
/// ToolCountSummary.label(core: 6, coreEnabled: 0, apple: [(false, true)])                 // "off"
/// ```
public enum ToolCountSummary: Sendable {
    /// `nil` when nothing is offered — the caller shows "off".
    public static func counts(core: Int, coreEnabled: Int, apple: [(enabled: Bool, available: Bool)]) -> (offered: Int, offerable: Int) {
        let usable = apple.filter(\.available)
        return (max(0, min(coreEnabled, core)) + usable.filter(\.enabled).count, max(0, core) + usable.count)
    }

    /// "9 of 14", or "off" when the model is offered no tools at all.
    public static func label(core: Int, coreEnabled: Int, apple: [(enabled: Bool, available: Bool)]) -> String {
        let c = counts(core: core, coreEnabled: coreEnabled, apple: apple)
        return c.offered == 0 ? "off" : "\(c.offered) of \(c.offerable)"
    }
}
