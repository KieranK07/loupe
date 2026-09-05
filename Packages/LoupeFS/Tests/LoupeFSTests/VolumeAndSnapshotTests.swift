import Darwin
import Foundation
import LoupeCore
import Testing
@testable import LoupeFS

@Suite("Volume enumeration")
struct VolumeEnumeratorTests {

    @Test("Local volumes are discovered")
    func findsLocalVolumes() {
        let volumes = VolumeEnumerator.localVolumes()
        #expect(!volumes.isEmpty)
        // The id is the BSD name; a duplicate would collide in any list the UI builds.
        #expect(Set(volumes.map(\.id)).count == volumes.count)
        #expect(!volumes.contains { $0.mountPoint.path == "/dev" })
    }

    @Test("The sealed system volume and the root Data volume are told apart",
          .enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data")))
    func identifiesBootVolumes() throws {
        let volumes = VolumeEnumerator.localVolumes()

        let sealed = volumes.filter(\.isSealedSystemVolume)
        #expect(sealed.count == 1)
        #expect(sealed.first?.mountPoint.path == "/")
        #expect(sealed.first?.isReadOnly == true)

        let data = volumes.filter(\.isRootDataVolume)
        #expect(data.count == 1)
        let dataVolume = try #require(data.first)
        #expect(dataVolume.mountPoint.path == "/System/Volumes/Data")
        #expect(dataVolume.isReadOnly == false)
        #expect(dataVolume.totalCapacity > 0)
        #expect(dataVolume.availableCapacity > 0)
        #expect(dataVolume.usedCapacity > 0)
        // The Data volume is the default scan root, so the convenience accessor
        // must agree with the filter the UI would write by hand.
        #expect(VolumeEnumerator.rootDataVolume()?.bsdName == dataVolume.bsdName)
    }

    @Test("Capacity fields are internally consistent")
    func capacitiesAreConsistent() {
        for volume in VolumeEnumerator.localVolumes() where volume.totalCapacity > 0 {
            #expect(volume.availableCapacity <= volume.totalCapacity)
            #expect(volume.usedCapacity == volume.totalCapacity - volume.availableCapacity)
            // purgeableEstimate is a difference, and must never underflow.
            #expect(volume.purgeableEstimate < volume.totalCapacity)
        }
    }

    @Test("BSD names are stripped of their /dev prefix")
    func bsdNamesAreBare() {
        for volume in VolumeEnumerator.localVolumes() {
            #expect(!volume.bsdName.hasPrefix("/dev/"))
            #expect(!volume.bsdName.isEmpty)
        }
    }
}

@Suite("Snapshots")
struct SnapshotReaderTests {

    /// The point of the syscall route is that it needs no privilege and spawns
    /// nothing. If this ever regresses to a subprocess it will show up here as
    /// a hang, a prompt, or a failure — all three are better than a password
    /// dialog in front of a user.
    @Test("Listing snapshots works unprivileged and without a subprocess",
          .timeLimit(.minutes(1)))
    func listsSnapshotsOnTheBootVolume() throws {
        let snapshots = try SnapshotReader.list(at: URL(fileURLWithPath: "/", isDirectory: true))
        for snapshot in snapshots {
            #expect(!snapshot.name.isEmpty)
        }
        #expect(SnapshotReader.snapshotsAreAvailable(at: URL(fileURLWithPath: "/")))
    }

    @Test("The Data volume answers the snapshot question",
          .enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data")))
    func listsSnapshotsOnTheDataVolume() {
        let mount = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        #expect(SnapshotReader.snapshotsAreAvailable(at: mount))
        #expect(SnapshotReader.snapshots(at: mount).allSatisfy { !$0.name.isEmpty })
    }

    @Test("An unmounted path reports unavailable rather than pretending it has none")
    func missingVolumeIsUnavailable() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        #expect(!SnapshotReader.snapshotsAreAvailable(at: missing))
        #expect(SnapshotReader.snapshots(at: missing).isEmpty)
    }

    @Test("Time Machine snapshot names yield their creation date")
    func parsesTimeMachineDates() throws {
        let date = try #require(
            SnapshotReader.creationDate(fromName: "com.apple.TimeMachine.2026-08-27-091315.local"))
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 27)
        #expect(parts.hour == 9)
        #expect(parts.minute == 13)
        #expect(parts.second == 15)
    }

    @Test("A snapshot name with no date keeps a nil date instead of being dropped")
    func unparseableNamesSurvive() {
        #expect(SnapshotReader.creationDate(fromName: "com.apple.os.update-5B92CE4B") == nil)
        #expect(SnapshotReader.creationDate(fromName: "") == nil)
        #expect(SnapshotReader.creationDate(fromName: "com.apple.TimeMachine.garbage.local") == nil)
    }
}

@Suite("APFS clones")
struct CloneTests {

    @Test("A cloned file is flagged; a plain copy is not", .timeLimit(.minutes(1)))
    func clonesAreDetected() async throws {
        let tree = try TempTree("clone")
        let original = try tree.file("original.bin", bytes: 256 * 1024)
        let clonePath = tree.root.appending(path: "cloned.bin").path(percentEncoded: false)
        let sourcePath = original.path(percentEncoded: false)
        try #require(clonefile(sourcePath, clonePath, 0) == 0,
                     "clonefile(2) failed: \(String(cString: strerror(errno)))")
        // Written independently, not copied: `FileManager.copyItem` and Finder
        // both clone on APFS, so a "copy" would share every block and be a
        // clone by any honest definition.
        try tree.file("independent.bin", bytes: 256 * 1024)

        let scanner = ScanEngine(
            root: tree.root,
            configuration: ScanConfiguration(threadCount: 2, measuresPrivateSize: true))
        _ = await runScan(scanner)

        scanner.withArena { arena in
            var flagged: Set<String> = []
            for slot in 0..<UInt32(arena.files.count)
            where arena.files[Int(slot)].flags.contains(.clone) {
                flagged.insert(arena.name(ofFile: slot))
            }
            // The clone pair share every block, so neither uniquely owns them.
            #expect(flagged.contains("original.bin"))
            #expect(flagged.contains("cloned.bin"))
            #expect(!flagged.contains("independent.bin"))
        }
    }

    @Test("Without the opt-in, nothing is guessed at", .timeLimit(.minutes(1)))
    func clonesAreNotGuessedWhenNotMeasured() async throws {
        let tree = try TempTree("noclone")
        let original = try tree.file("original.bin", bytes: 256 * 1024)
        let clonePath = tree.root.appending(path: "cloned.bin").path(percentEncoded: false)
        try #require(clonefile(original.path(percentEncoded: false), clonePath, 0) == 0)

        let scanner = ScanEngine(root: tree.root,
                                 configuration: ScanConfiguration(threadCount: 2))
        _ = await runScan(scanner)

        // PRIVATESIZE comes back zero when it is not requested. Treating that as
        // "owns nothing" would flag every file on the volume as a clone.
        scanner.withArena { arena in
            let flagged = (0..<arena.files.count)
                .filter { arena.files[$0].flags.contains(.clone) }
            #expect(flagged.isEmpty)
        }
    }
}
