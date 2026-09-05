import LoupeCore
import OSLog

/// Local aliases for the two `LoupeLog` categories this pillar writes to, so a
/// reader can tell at a glance whether a line is a safety decision or a scan
/// detail. Nothing here logs a file's contents; paths only, and only locally.
enum LoupeLogReclaim {
    static let security: Logger = LoupeLog.security
    static let reclaim: Logger = LoupeLog.reclaim
}
