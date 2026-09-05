import Testing
import Foundation
import LoupeCore
@testable import LoupeFS

@Suite("Volume catalog hides machinery")
struct VolumeCatalogTests {

    @Test("APFS helper volumes never reach the user")
    func helpersHidden() {
        let names = Set(VolumeCatalog.userVolumes().map(\.mountPoint.path))
        // A stock Mac mounts all of these nobrowse; none is a place to keep files.
        for helper in ["/System/Volumes/VM", "/System/Volumes/Preboot",
                       "/System/Volumes/Update", "/System/Volumes/xarts",
                       "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware"] {
            #expect(!names.contains(helper), "\(helper) should not be offered as a scan target")
        }
    }

    @Test("the sealed system volume is not offered as a scan target")
    func sealedHidden() {
        #expect(!VolumeCatalog.userVolumes().contains { $0.isSealedSystemVolume })
    }

    @Test("the boot volume is offered, and named the way a person names it")
    func bootVolumeNamed() throws {
        let target = try #require(VolumeCatalog.defaultTarget())
        // Loupe scans the writable half...
        #expect(target.mountPoint.path == "/System/Volumes/Data")
        #expect(target.isRootDataVolume)
        // ...but "Data" is an implementation detail, not a name.
        #expect(target.name != "Data")
        #expect(!target.name.isEmpty)
    }

    @Test("hidden volumes come with a reason rather than vanishing")
    func hiddenExplained() {
        let hidden = VolumeCatalog.hiddenVolumes()
        #expect(!hidden.isEmpty)
        for entry in hidden { #expect(!entry.reason.isEmpty) }
    }

    @Test("the residual is named rather than absorbed into a bucket called Other")
    func residualIsExplained() throws {
        let volume = try #require(VolumeCatalog.defaultTarget())
        let breakdown = SpaceReporter.breakdown(for: volume,
                                                scannedBytes: 100_000_000,
                                                unreadableCount: 179)
        // Not measured, and says so, rather than reporting a plausible fiction.
        #expect(breakdown.systemVolumeBytes == nil)
        let text = breakdown.unaccountedExplanation
        #expect(text.contains("sealed macOS system volume"))
        #expect(text.contains("179"))
        // Never the word this app refuses to hide behind.
        #expect(!text.lowercased().contains("other"))
    }
}
