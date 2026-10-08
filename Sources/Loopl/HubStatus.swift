import Foundation

/// What a Hugging Face status code means to a person, and what to do next.
///
/// Before this, a rate limit or a Hub outage reached the user as `HTTP 429 for model.safetensors` (download) or
/// `Hugging Face answered HTTP 503 for /api/models/...` (browse) — a status code, a file path and no idea whether to
/// wait, retry or give up. The code stays in the sentence (one honest technical token, like the method on an approval
/// card), but it comes after the plain words. One mapper for both paths, so a 429 reads the same wherever it happens.
public enum HubStatus {
    /// `downloading` lets the sentence promise what is true on that path only: a partial download is kept in a
    /// `.part` sidecar and resumed with a `Range` request, so "what you have is kept" is a fact, not comfort.
    /// `path` names the file or endpoint; it is quoted only where it helps (a 404 says WHICH file went missing).
    public static func sentence(_ code: Int, path: String = "", downloading: Bool) -> String {
        // Short on purpose: the Models row draws this whole sentence in RED next to a Retry button, with no line
        // limit, so every extra clause is another line of alarm for a fact that is reassuring. "Your progress is
        // kept" costs four words and saves a line on a 375 pt screen (measured where the string lands).
        let kept = downloading ? " Your progress is kept." : ""
        switch code {
        case 429:
            return "Hugging Face is limiting requests right now — wait a minute and try again (429)." + kept
        case 408, 500...599:
            return "Hugging Face is having trouble right now — try again in a few minutes (\(code))." + kept
        case 404:
            let what = path.isEmpty ? "" : " (\(lastComponent(path)))"
            return downloading
            ? "A file this model needs is not on Hugging Face any more\(what) — the repo's files changed (404)."
            : "Not found on Hugging Face\(what) — the name may have changed (404)."
        case 416:
            return "The download could not carry on from where it stopped — starting it again fixes this (416)."
        default:
            return downloading
            ? "Hugging Face refused this download (status \(code))."
            : "Hugging Face refused this request (status \(code))."
        }
    }

    /// `/api/models/owner/name/tree/main` → `tree`, `weights/model.safetensors` → `model.safetensors`.
    /// A whole path is noise in a sentence a person reads; the file name is the part that identifies the thing.
    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
