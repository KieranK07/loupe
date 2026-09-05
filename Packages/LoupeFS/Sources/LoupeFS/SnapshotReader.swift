import CLoupeFS
import Darwin
import Foundation
import LoupeCore

// ─────────────────────────────────────────────────────────────────────────────
// `diskutil` IS BANNED FROM THIS FILE, AND FROM LOUPE.
//
// `/usr/sbin/diskutil apfs listSnapshots` looks harmless and is not. Every
// diskutil invocation goes to `authd` and requests privileged rights —
// com.apple.private.storagekitd.destructive, ...storagekitd.mountaudit,
// ...diskmanagement.set-boot-device, ...security.disk-device-access,
// system.hdd.smart — and creates session credentials for the calling user. On
// this machine that produced an admin password prompt from a read-only listing.
//
// Loupe is a read-only inspection tool. It must never ask the user for their
// admin password, and it must never route a question through a tool that might.
// A missing number is acceptable; an unexplained password prompt is not.
//
// The replacement below is `fs_snapshot_list(2)`: a public syscall, verified to
// work as an ordinary user (uid 501) with no authorization request and no
// subprocess of any kind. There is nothing here to escalate, prompt, or parse.
// ─────────────────────────────────────────────────────────────────────────────

/// Enumerates local APFS snapshots on a mounted volume.
///
/// Snapshots are the most common reason a Mac reports far less free space than
/// its file tree accounts for, so Loupe names them rather than burying the
/// difference in a bucket called "Other".
public enum SnapshotReader {

    /// Snapshots on the volume mounted at `mountPoint`.
    ///
    /// Returns an empty array when the volume has none *and* when the volume
    /// cannot answer the question — the two are reported apart by
    /// `snapshotsAreAvailable(at:)` so the UI can say "none" or "unknown"
    /// honestly instead of guessing.
    public static func snapshots(at mountPoint: URL) -> [LocalSnapshot] {
        (try? list(at: mountPoint)) ?? []
    }

    /// Whether snapshot enumeration works on this volume at all.
    public static func snapshotsAreAvailable(at mountPoint: URL) -> Bool {
        (try? list(at: mountPoint)) != nil
    }

    /// - Throws: `SnapshotError.unavailable` carrying the underlying `errno`.
    public static func list(at mountPoint: URL) throws -> [LocalSnapshot] {
        let path = mountPoint.path(percentEncoded: false)

        // 64 KiB of scratch for the packed attribute buffer and 64 KiB for the
        // flattened names. A volume with more than a few hundred snapshots is
        // already pathological; ERANGE is reported rather than silently clipped.
        let scratchSize = 64 * 1024
        let namesSize = 64 * 1024
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 8)
        defer { scratch.deallocate() }
        let names = UnsafeMutablePointer<CChar>.allocate(capacity: namesSize)
        defer { names.deallocate() }

        let count = path.withCString { cPath in
            loupe_list_snapshots(cPath, scratch, scratchSize, names, namesSize)
        }
        guard count >= 0 else { throw SnapshotError.unavailable(errno: -count) }

        var result: [LocalSnapshot] = []
        result.reserveCapacity(Int(count))
        var cursor = names
        for _ in 0..<Int(count) {
            let name = String(cString: cursor)
            result.append(LocalSnapshot(name: name, createdAt: creationDate(fromName: name)))
            cursor = cursor.advanced(by: name.utf8.count + 1)
        }
        return result
    }

    public enum SnapshotError: Error, Sendable, Hashable {
        case unavailable(errno: Int32)
    }

    /// Time Machine encodes the snapshot's creation time in its name, e.g.
    /// `com.apple.TimeMachine.2026-08-27-091315.local`. Nothing else does, so
    /// anything that does not match keeps a nil date rather than being dropped
    /// — an OS-update snapshot with no timestamp still occupies real bytes.
    static func creationDate(fromName name: String) -> Date? {
        guard let dot = name.range(of: "com.apple.TimeMachine.") else { return nil }
        let tail = name[dot.upperBound...]
        let stamp = tail.hasSuffix(".local") ? String(tail.dropLast(".local".count)) : String(tail)
        var components = DateComponents()
        let parts = stamp.split(separator: "-")
        guard parts.count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts[3].count == 6, let clock = Int(parts[3])
        else { return nil }
        components.year = year
        components.month = month
        components.day = day
        components.hour = clock / 10000
        components.minute = (clock / 100) % 100
        components.second = clock % 100
        // Snapshot names are stamped in the machine's local time zone.
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
