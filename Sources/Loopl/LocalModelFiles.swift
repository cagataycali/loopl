import Foundation

/// What the files on disk say about a downloaded model — read after a download or move so the app follows the
/// weights that are actually there, not the row that described them.
public enum LocalModelFiles {
    /// `true`/`false` when `<directory>/config.json` exists and parses (`HubCatalog.hasVisionConfig`), nil otherwise
    /// (GGUF directories have no config.json; a drive that is away has no directory).
    public static func hasVisionTower(in directory: URL) -> Bool? {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return HubCatalog.hasVisionConfig(row)
    }
}
