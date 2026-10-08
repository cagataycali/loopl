import Foundation

/// What the copy of a model on this device IS: the Hugging Face commit it was fetched at, and when it arrived.
/// Recorded when a download finishes — nothing before that release knows its own revision, which is exactly why
/// `ModelFreshness` refuses to guess.
public struct InstalledVersion: Codable, Sendable, Equatable, Hashable {
    /// The repo's commit sha at download time; `nil` when the Hub could not be asked (offline, rate limited).
    public var sha: String?
    public var at: Date
    public init(sha: String?, at: Date) { self.sha = sha; self.at = at }
    /// `47d27b44` — the form a person can compare with a model card, never the full 40 characters.
    public var shortSha: String? { sha.map { String($0.prefix(8)) } }
}

/// Is the copy on this iPhone still what the repo serves? Pure, so the rule is testable without a network or a view.
///
/// Every loopl row pins no revision, so a download takes whatever `main` points at that day. On 2026-10-07 all three
/// loopl sizes were replaced in place by v1.2: a new install got v1.2, an existing one kept v1.1, and the app said
/// nothing either way. This answers it — but only when it KNOWS, because the alternative is telling someone to spend
/// 1.75 GB on a guess.
public enum ModelFreshness {
    public enum Verdict: Sendable, Equatable {
        /// The copy here is the commit the repo serves.
        case current
        /// The repo moved on. `installed` is what this device has, for the line a person reads.
        case newer(installed: InstalledVersion)
        /// Not asked yet, asked and failed, or a copy from before loopl recorded revisions. Say nothing.
        case unknown
    }

    public static func verdict(installed: InstalledVersion?, remote: String?) -> Verdict {
        guard let installed, let mine = installed.sha, let remote, !remote.isEmpty else { return .unknown }
        return mine == remote ? .current : .newer(installed: installed)
    }

    /// The one line under the row, in words that say what happened and what it costs. `nil` when there is nothing
    /// honest to say — an unknown copy is never nagged about.
    public static func line(installed: InstalledVersion?, remote: String?, now: Date = Date(),
                            calendar: Calendar = .current) -> String? {
        guard case .newer(let mine) = verdict(installed: installed, remote: remote) else { return nil }
        return "Hugging Face has a newer version. Your copy arrived \(when(mine.at, now: now, calendar: calendar))."
    }

    /// "today" · "yesterday" · "on 2 October" — the same plain-words scale the agenda uses.
    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        // Day distance from the GIVEN `now`, not from the system clock: `isDateInToday` ignores the argument, which
        // makes the rule untestable and — in an app left open past midnight — makes yesterday's copy say "today".
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "on " + date.formatted(.dateTime.day().month(.wide))
    }
}
