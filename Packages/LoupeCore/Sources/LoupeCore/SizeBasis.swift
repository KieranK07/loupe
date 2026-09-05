import Foundation

/// Which of the two true sizes of a file we are reporting.
///
/// On APFS these routinely disagree by a factor of three or more: clones share
/// blocks, sparse files reserve none, compressed files store fewer, and iCloud
/// placeholders have a logical size with essentially no bytes behind it.
/// Loupe never shows one without labelling which it is.
public enum SizeBasis: String, Sendable, CaseIterable, Codable, Identifiable {
    /// Blocks actually allocated on the volume. This is the number that changes
    /// when you delete something.
    case physical
    /// Apparent size — what the file claims to be. Larger than physical for
    /// clones, sparse files, compressed files and dataless placeholders.
    case logical

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .physical: "On disk"
        case .logical: "Apparent"
        }
    }

    /// One honest sentence, shown next to the toggle. No hedging, no jargon.
    public var explanation: String {
        switch self {
        case .physical:
            "Blocks actually used on this volume. Deleting an item frees roughly this much."
        case .logical:
            "The size each file reports. Higher than the space used when files are compressed, sparse, copied with clones, or stored in iCloud."
        }
    }
}

public enum ByteFormat {
    /// Matches Finder's decimal convention so Loupe's numbers can be compared
    /// with the rest of the system rather than quietly disagreeing with it.
    public static func string(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(clamping: bytes))
    }

    public static func string(_ bytes: UInt64, basis: SizeBasis) -> String {
        "\(string(bytes)) \(basis == .physical ? "on disk" : "apparent")"
    }
}
