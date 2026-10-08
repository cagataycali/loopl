import Foundation

/// Byte sizes as people read them — with an honest word for *nothing*.
///
/// `ByteCountFormatter` renders zero as **"Zero KB"**, which reads like a
/// broken measurement instead of an empty shelf. Every size label in loopl goes
/// through ``ByteSize/label(_:zero:countStyle:)`` so an empty device says
/// "None" and a real size keeps the system formatter (localised, right units).
///
/// ```swift
/// ByteSize.label(0)              // "None"
/// ByteSize.label(968_080_210)    // "968.1 MB"
/// ByteSize.label(0, zero: "size unknown")
/// ```
public enum ByteSize {
    /// The word shown instead of a formatted zero.
    public static let none = "None"

    /// A size label, or `zero` when there is nothing to measure.
    ///
    /// - Parameters:
    ///   - bytes: the count. `0` — and any negative value, which only happens
    ///     when a subtraction goes wrong — yields `zero` rather than a formatted string.
    ///   - zero: what to say when there is nothing. Defaults to ``ByteSize/none``.
    ///   - countStyle: passed to `ByteCountFormatter` for non-zero counts.
    public static func label(_ bytes: Int64,
                             zero: String = ByteSize.none,
                             countStyle: ByteCountFormatter.CountStyle = .file) -> String {
        guard bytes > 0 else { return zero }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: countStyle)
    }

    /// `Int` overload, for call sites that count in `Int` (file sizes from `FileManager`).
    public static func label(_ bytes: Int,
                             zero: String = ByteSize.none,
                             countStyle: ByteCountFormatter.CountStyle = .file) -> String {
        label(Int64(bytes), zero: zero, countStyle: countStyle)
    }
}
