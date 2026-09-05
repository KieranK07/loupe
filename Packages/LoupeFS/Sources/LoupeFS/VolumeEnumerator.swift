import Darwin
import Foundation
import LoupeCore

/// Discovers the local volumes Loupe is willing to offer as scan targets.
///
/// Every mount is reported as a separate target. Loupe never silently folds one
/// volume's bytes into another's, because a walk that crosses a device boundary
/// is a walk that double-counts.
public enum VolumeEnumerator {

    /// All mounted local volumes, in mount-table order.
    ///
    /// Never throws: a machine with an unreadable mount is still a machine the
    /// user wants to look at, so a volume that cannot be interrogated comes back
    /// with zeroed capacities rather than taking the whole list down with it.
    public static func localVolumes() -> [VolumeDescriptor] {
        var raw: UnsafeMutablePointer<statfs>?
        // getmntinfo_r_np is the reentrant form: it mallocs a fresh array for
        // this caller rather than handing back a shared static buffer, which
        // matters because volume enumeration can run while a scan is in flight.
        let count = getmntinfo_r_np(&raw, MNT_NOWAIT)
        guard count > 0, let mounts = raw else { return [] }
        defer { free(raw) }

        var result: [VolumeDescriptor] = []
        result.reserveCapacity(Int(count))

        for i in 0..<Int(count) {
            var entry = mounts[i]
            guard entry.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
            let fsType = withUnsafeBytes(of: &entry.f_fstypename) { cString(from: $0) }
            // devfs is local but is not storage: its entries are device nodes
            // with no bytes behind them, so offering it as a scan target would
            // only ever produce an empty sunburst.
            guard fsType != "devfs" else { continue }
            if let descriptor = describe(&entry) { result.append(descriptor) }
        }
        return result
    }

    /// The volume Loupe scans by default: the writable half of the boot volume.
    public static func rootDataVolume() -> VolumeDescriptor? {
        localVolumes().first { $0.isRootDataVolume }
    }

    private static func describe(_ entry: inout statfs) -> VolumeDescriptor? {
        let mountPath = withUnsafeBytes(of: &entry.f_mntonname) { cString(from: $0) }
        guard !mountPath.isEmpty else { return nil }
        let fromPath = withUnsafeBytes(of: &entry.f_mntfromname) { cString(from: $0) }
        let mountPoint = URL(fileURLWithPath: mountPath, isDirectory: true)

        // f_mntfromname is "/dev/disk3s5" for a real volume and something like
        // "map auto_home" for a synthetic one; the BSD name is the tail either way.
        let bsdName = fromPath.hasPrefix("/dev/")
            ? String(fromPath.dropFirst("/dev/".count))
            : fromPath

        let isReadOnly = entry.f_flags & UInt32(MNT_RDONLY) != 0
        let isRootData = mountPath == "/System/Volumes/Data"
        let isSealedSystem = mountPath == "/" && isReadOnly

        // The device id comes from stat(2) rather than f_fsid because that is
        // what ATTR_CMN_DEVID reports for entries on this volume, and the walk's
        // boundary check compares the two directly. On a firmlinked boot volume
        // the two disagree: `/` reports the *Data* volume's device, which is
        // exactly why firmlinks are refused by flag and not by device id alone.
        var st = stat()
        let deviceID: Int32 = stat(mountPath, &st) == 0 ? Int32(bitPattern: UInt32(st.st_dev)) : 0

        let values = try? mountPoint.resourceValues(forKeys: [
            .volumeNameKey, .volumeIsInternalKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])

        let name = values?.volumeName ?? (mountPath == "/" ? "Macintosh HD" : mountPoint.lastPathComponent)
        let total = UInt64(max(0, values?.volumeTotalCapacity ?? 0))
        let available = UInt64(max(0, values?.volumeAvailableCapacity ?? 0))
        let important = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))

        return VolumeDescriptor(
            mountPoint: mountPoint,
            name: name.isEmpty ? mountPoint.lastPathComponent : name,
            bsdName: bsdName,
            deviceID: deviceID,
            isReadOnly: isReadOnly,
            isInternal: values?.volumeIsInternal ?? true,
            isRootDataVolume: isRootData,
            isSealedSystemVolume: isSealedSystem,
            totalCapacity: total,
            availableCapacity: available,
            availableForImportantUsage: important)
    }

    /// Reads a fixed-size C char array out of a `statfs` field.
    private static func cString(from bytes: UnsafeRawBufferPointer) -> String {
        let significant = bytes.prefix { $0 != 0 }
        return String(decoding: significant, as: UTF8.self)
    }
}
