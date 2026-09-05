import Foundation
import LoupeCore

/// Reconciles what the walk measured against what the volume claims.
///
/// This is the answer to the single most common confusion on a modern Mac:
/// Finder's "Available" disagrees with everything else. Loupe's position is that
/// the honest response is to show the pieces and name the residual, not to pick
/// one number and defend it.
public enum SpaceReporter {

    public static func breakdown(for volume: VolumeDescriptor,
                                 scannedBytes: UInt64,
                                 unreadableCount: UInt64) -> SpaceBreakdown {
        let snapshots = SnapshotReader.snapshots(at: volume.mountPoint)
        return SpaceBreakdown(
            volume: volume,
            scannedBytes: scannedBytes,
            // Not measured: statfs cannot tell us, and guessing would be worse
            // than admitting it. See SpaceBreakdown.systemVolumeBytes.
            systemVolumeBytes: nil,
            snapshots: snapshots,
            // Snapshot *sizes* need root. The count is honest; a fabricated size
            // would not be.
            snapshotBytes: 0,
            purgeableBytes: volume.purgeableEstimate,
            unreadableCount: unreadableCount)
    }
}
