import Foundation
import LoupeCore

/// Turns the raw mount table into the short list of volumes a person would
/// recognise.
///
/// The mount table on a modern Mac is mostly machinery. A stock machine mounts
/// eight APFS volumes, six of which are `nobrowse` helpers — Preboot, VM,
/// Update, xART, iSCPreboot, Hardware. Worse, every volume in an APFS container
/// reports the *container's* capacity through statfs, so listing them raw gives
/// six entries that each claim the entire disk. Both problems are fixed here
/// rather than in the UI, because they are facts about the filesystem.
public enum VolumeCatalog {

    /// Volumes worth offering as scan targets: the boot volume, named the way
    /// the user names it, plus anything mounted under `/Volumes`.
    public static func userVolumes() -> [VolumeDescriptor] {
        let all = VolumeEnumerator.localVolumes()
        let sealedSystem = all.first(where: \.isSealedSystemVolume)

        return all.compactMap { volume -> VolumeDescriptor? in
            guard volume.isUserSelectable else { return nil }
            guard volume.isRootDataVolume else { return volume }
            // The writable half of the boot volume is what Loupe scans, but
            // "Data" is an implementation detail. The name a user knows lives on
            // the sealed system volume mounted at `/` — "Macintosh HD".
            return volume.renamed(to: sealedSystem?.name ?? volume.name)
        }
    }

    /// The default target: the writable half of the boot volume. Scanning `/`
    /// instead would traverse firmlinks straight back into this same volume.
    public static func defaultTarget() -> VolumeDescriptor? {
        let volumes = userVolumes()
        return volumes.first(where: \.isRootDataVolume) ?? volumes.first
    }

    /// Volumes deliberately withheld, with the reason. Exposed so the UI can
    /// explain the omission if asked, rather than silently shortening the list.
    public static func hiddenVolumes() -> [(volume: VolumeDescriptor, reason: String)] {
        VolumeEnumerator.localVolumes().compactMap { volume in
            if volume.isSealedSystemVolume {
                return (volume, "The sealed macOS system volume is read-only and cannot be changed.")
            }
            if volume.isHelperVolume {
                return (volume, "An APFS helper volume used by macOS. It holds no user files.")
            }
            return nil
        }
    }
}

extension VolumeDescriptor {
    func renamed(to newName: String) -> VolumeDescriptor {
        VolumeDescriptor(mountPoint: mountPoint, name: newName, bsdName: bsdName,
                         deviceID: deviceID, isReadOnly: isReadOnly, isInternal: isInternal,
                         isRootDataVolume: isRootDataVolume,
                         isSealedSystemVolume: isSealedSystemVolume,
                         totalCapacity: totalCapacity, availableCapacity: availableCapacity,
                         availableForImportantUsage: availableForImportantUsage)
    }
}
