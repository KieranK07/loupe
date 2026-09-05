import Foundation

public struct ScanConfiguration: Sendable {
    /// Dedicated walker threads.
    ///
    /// Measured on a 4P+6E machine: the knee is at 6–8 threads (j=8 is 4.83x
    /// j=1; j=12 buys another 0.6 s and costs the UI its headroom). Leaving two
    /// cores free is what keeps the compositor smooth while a scan runs.
    public var threadCount: Int
    /// Per-thread `getattrlistbulk` buffer. 256 KiB is the prototype's measured
    /// size; smaller buffers cost extra syscalls on directories with many entries.
    public var bufferBytes: Int
    /// Depth below which the frontier is handed out breadth-first, so the
    /// sunburst's inner rings fill within the first couple of seconds.
    public var breadthFirstLevels: UInt8
    /// Roughly 10 Hz. Faster than the display can usefully show, slower than
    /// the walk can saturate the channel.
    public var progressInterval: Duration
    /// Optional hint used to pre-reserve the arena and the hard-link set.
    public var expectedEntries: Int
    /// Ask the kernel for `ATTR_CMNEXT_PRIVATESIZE` — the bytes each file
    /// uniquely owns — which is the only way to tell an APFS clone from an
    /// ordinary file without opening anything.
    ///
    /// Off by default because it is expensive, and measurably so on this
    /// machine: a `/Applications` walk drops from 905k to 245k entries/sec, and
    /// `$HOME` (1.98M entries) goes from 6.5 s to 14.1 s. The cost is entirely
    /// in the kernel — it has to consult each file's extent map — so no amount
    /// of care on our side buys it back. Loupe's physical totals come from
    /// `ATTR_FILE_ALLOCSIZE` either way; this only adds the `.clone` flag.
    /// What the root of the tree is called on screen.
    ///
    /// Defaults to the last path component, which for the boot volume is "Data" —
    /// an implementation detail, not a name anyone recognises. The caller passes
    /// the volume's real name so the centre of the chart reads "Macintosh HD".
    public var rootDisplayName: String?

    public var measuresPrivateSize: Bool

    public init(threadCount: Int = ScanConfiguration.defaultThreadCount,
                bufferBytes: Int = 256 * 1024,
                breadthFirstLevels: UInt8 = 3,
                progressInterval: Duration = .milliseconds(100),
                expectedEntries: Int = 0,
                measuresPrivateSize: Bool = false,
                rootDisplayName: String? = nil) {
        self.threadCount = max(1, threadCount)
        self.bufferBytes = max(64 * 1024, bufferBytes)
        self.breadthFirstLevels = breadthFirstLevels
        self.progressInterval = progressInterval
        self.expectedEntries = expectedEntries
        self.measuresPrivateSize = measuresPrivateSize
        self.rootDisplayName = rootDisplayName
    }

    public static var defaultThreadCount: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount - 2, 4), 8)
    }

    public static let `default` = ScanConfiguration()
}
