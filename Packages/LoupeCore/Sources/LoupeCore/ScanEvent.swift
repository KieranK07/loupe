import Foundation

public struct ScanProgress: Sendable, Hashable {
    public let entriesSeen: UInt64
    public let directoriesSeen: UInt64
    public let physicalBytes: UInt64
    public let logicalBytes: UInt64
    /// Directories the walk could not open. Surfaced plainly rather than
    /// silently folded into the totals — a number you cannot see is a number
    /// you cannot trust.
    public let deniedCount: UInt64
    /// Entries skipped because a constructed path exceeded PATH_MAX. Should be
    /// zero; if it is not, the tree is genuinely incomplete and we say so.
    public let truncatedPathCount: UInt64
    public let currentPath: String?
    public let elapsed: Duration

    public init(entriesSeen: UInt64 = 0, directoriesSeen: UInt64 = 0,
                physicalBytes: UInt64 = 0, logicalBytes: UInt64 = 0,
                deniedCount: UInt64 = 0, truncatedPathCount: UInt64 = 0,
                currentPath: String? = nil, elapsed: Duration = .zero) {
        self.entriesSeen = entriesSeen; self.directoriesSeen = directoriesSeen
        self.physicalBytes = physicalBytes; self.logicalBytes = logicalBytes
        self.deniedCount = deniedCount; self.truncatedPathCount = truncatedPathCount
        self.currentPath = currentPath; self.elapsed = elapsed
    }
}

public struct ScanSummary: Sendable, Hashable {
    public let root: URL
    public let progress: ScanProgress
    public let hardlinkDuplicatesSkipped: UInt64
    public let datalessPlaceholders: UInt64
    public let startedAt: Date
    public let finishedAt: Date

    public init(root: URL, progress: ScanProgress, hardlinkDuplicatesSkipped: UInt64,
                datalessPlaceholders: UInt64, startedAt: Date, finishedAt: Date) {
        self.root = root; self.progress = progress
        self.hardlinkDuplicatesSkipped = hardlinkDuplicatesSkipped
        self.datalessPlaceholders = datalessPlaceholders
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public enum ScanFailure: Error, Sendable, Hashable {
    case rootUnreadable(URL, errno: Int32)
    case notADirectory(URL)
    case fullDiskAccessRequired(URL)
    case cancelled
}

/// The single channel from the scan engine to the UI. Delivered as an
/// `AsyncStream` with `.bufferingNewest(1)` for the high-frequency cases, so a
/// slow frame drops stale work rather than queueing it up.
public enum ScanEvent: Sendable {
    case started(root: URL, at: Date)
    case progress(ScanProgress)
    case layout(SunburstLayout)
    case finished(ScanSummary)
    case failed(ScanFailure)
}

public enum ScanState: Sendable, Hashable {
    case idle
    case scanning(ScanProgress)
    case paused(ScanProgress)
    case complete(ScanSummary)
    case failed(ScanFailure)

    public var isRunning: Bool { if case .scanning = self { true } else { false } }
}
