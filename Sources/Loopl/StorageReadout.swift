import Foundation

/// The words under "Storage" in the Models tab — the two numbers a person wants before a download: what loopl uses and
/// how much space there IS. Pure, so the phrasing is unit-tested once and the view only lays it out.
public enum StorageReadout {
    /// `2.1 GB used · 54 GB free`; nothing downloaded → `Nothing downloaded · 54 GB free` (free never disappears).
    public static func spaceLine(used: Int64, free: Int64) -> String {
        let f = "\(ByteSize.label(free)) free"
        return used > 0 ? "\(ByteSize.label(used)) used · \(f)" : "Nothing downloaded · \(f)"
    }

    /// A remembered external volume: unplugged → `Not connected`; plugged in but unreadable → the one-line fix; else the numbers.
    public static func volumeLine(connected: Bool, usable: Bool, used: Int64, free: Int64) -> String {
        if !connected { return "Not connected" }
        if !usable { return "Connected, can't read — re-grant in Settings › Storage" }
        return spaceLine(used: used, free: free)
    }
}
