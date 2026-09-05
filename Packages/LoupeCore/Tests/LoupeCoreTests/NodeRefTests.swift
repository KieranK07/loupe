import Testing
import Foundation
@testable import LoupeCore

@Suite("NodeRef tagged-index encoding")
struct NodeRefTests {
    @Test("file and directory refs round-trip and stay distinguishable")
    func roundTrip() {
        for slot: UInt32 in [0, 1, 42, 1_000_000, 0x7FFF_FFFE] {
            let f = NodeRef.file(slot), d = NodeRef.directory(slot)
            #expect(f.slot == slot); #expect(d.slot == slot)
            #expect(f.isFile); #expect(!f.isDirectory)
            #expect(d.isDirectory); #expect(!d.isFile)
            // Same slot, different arena, must never collide.
            #expect(f != d)
        }
    }

    @Test("invalid is not mistaken for a real node")
    func invalid() {
        #expect(!NodeRef.invalid.isValid)
        #expect(!NodeRef.invalid.isFile)
        #expect(NodeRef.file(0).isValid)
        #expect(NodeRef.directory(0).isValid)
    }
}

@Suite("Sunburst geometry contract")
struct SunburstGeometryTests {
    @Test("sub-pixel threshold is small enough to be invisible, large enough to cull")
    func threshold() {
        // At a 400pt radius, 0.35 degrees is roughly one pixel of arc length.
        let arcAtRadius400 = SunburstGeometry.minimumSweepRadians * 400
        #expect(arcAtRadius400 < 3.0)
        #expect(arcAtRadius400 > 1.0)
    }

    @Test("the per-ring cull bounds a ring, and the ceiling backstops all rings together")
    func cullingBounds() {
        let maxPerRing = Int((2 * Double.pi) / SunburstGeometry.minimumSweepRadians)
        // The angular cull alone caps one ring at ~1028 wedges, so no single
        // ring can ever reach the global ceiling.
        #expect(maxPerRing < SunburstGeometry.maximumWedges)
        // But every ring filled to that cap would exceed it, which is precisely
        // why maximumWedges has to exist as a cross-ring backstop rather than
        // being decorative.
        let worstCase = maxPerRing * Int(SunburstGeometry.maximumRings)
        #expect(worstCase > SunburstGeometry.maximumWedges)
    }
}

@Suite("Size basis honesty")
struct SizeBasisTests {
    @Test("both bases carry a plain-language explanation")
    func explanations() {
        for basis in SizeBasis.allCases {
            #expect(!basis.explanation.isEmpty)
            #expect(!basis.shortLabel.isEmpty)
            // No marketing verbs anywhere near the size story.
            let banned = ["faster", "speed up", "optimize", "clean up your mac", "junk"]
            for word in banned {
                #expect(!basis.explanation.lowercased().contains(word))
            }
        }
    }

    @Test("purgeable estimate never goes negative")
    func purgeable() {
        let v = VolumeDescriptor(
            mountPoint: URL(filePath: "/System/Volumes/Data"), name: "Data",
            bsdName: "disk3s5", deviceID: 1, isReadOnly: false, isInternal: true,
            isRootDataVolume: true, isSealedSystemVolume: false,
            totalCapacity: 1_000, availableCapacity: 400,
            availableForImportantUsage: 300)   // deliberately lower
        #expect(v.purgeableEstimate == 0)
        #expect(v.usedCapacity == 600)
    }
}
