import Testing
import Foundation
import LoupeCore
import LoupeTree
@testable import LoupeFS

/// Walks a real tree with the real engine and projects it with the real
/// projector. Each module is unit-tested on its own; this is the only test that
/// proves the seam between them holds — which is exactly where an off-by-one in
/// the ring convention or a mis-set flag would hide.
@Suite("Engine to layout, end to end")
struct PipelineIntegrationTests {

    private func makeTree() throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "loupe-pipeline-\(UUID().uuidString)")
        let fm = FileManager.default
        // big/ 300 KiB · small/ 100 KiB · empty/
        for (dir, files) in [("big", [("a.bin", 200), ("b.bin", 100)]),
                             ("small", [("c.bin", 100)]),
                             ("empty", [])] {
            let d = root.appending(path: dir)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            for (name, kib) in files {
                try Data(count: kib * 1024).write(to: d.appending(path: name))
            }
        }
        return root
    }

    @Test("a walked tree projects into wedges with the right shape and order")
    func pipeline() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ScanEngine(root: root)
        var summary: ScanSummary?
        for await event in engine.start() {
            if case .finished(let s) = event { summary = s }
        }
        let done = try #require(summary)
        // 3 directories + 3 files beneath the root.
        #expect(done.progress.entriesSeen == 6)

        let projector = SunburstProjector(rootPath: root.path(percentEncoded: false))
        let layout = engine.withArena { arena in
            projector.project(arena: arena, focus: .directory(0), basis: .physical,
                              generation: 1, scannedAt: .now, isComplete: true)
        }

        // The focus is the centre disc, so its direct children are ring 0. An
        // off-by-one here would leave the innermost band empty on screen.
        let firstRing = layout.wedges.filter { $0.ring == 0 }
        #expect(firstRing.count >= 2)
        #expect(firstRing.map(\.name).prefix(2) == ["big", "small"])   // descending by size

        // Angles tile the full circle.
        let sweep = firstRing.reduce(0.0) { $0 + $1.sweep }
        #expect(abs(sweep - 2 * .pi) < 1e-9)

        // Containment: every deeper wedge sits inside a ring-0 wedge.
        for deep in layout.wedges where deep.ring == 1 {
            let mid = (deep.startAngle + deep.endAngle) / 2
            #expect(firstRing.contains { $0.startAngle <= mid && mid <= $0.endAngle })
        }

        // The tree really is 300 KiB + 100 KiB, and physical is block-rounded.
        #expect(layout.totalPhysicalBytes >= 400 * 1024)
        #expect(layout.isComplete)
    }

    @Test("an empty directory contributes no wedge rather than a zero-width one")
    func emptyDirectory() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ScanEngine(root: root)
        for await _ in engine.start() {}
        let layout = engine.withArena { arena in
            SunburstProjector(rootPath: root.path(percentEncoded: false))
                .project(arena: arena, focus: .directory(0), basis: .physical,
                         generation: 1, scannedAt: .now, isComplete: true)
        }
        #expect(!layout.wedges.contains { $0.name == "empty" })
        #expect(layout.wedges.allSatisfy { $0.sweep > 0 })
    }
}
