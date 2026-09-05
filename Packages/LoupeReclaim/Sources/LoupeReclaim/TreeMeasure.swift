import Foundation
import LoupeCore
import LoupeFS
import LoupeTree

/// What one candidate is worth, in the only units this app prints.
public struct TreeMeasurement: Sendable, Hashable {
    /// Blocks actually allocated: `Σ st_blocks × 512` over the tree, with
    /// hardlinks counted once and iCloud placeholders counted as zero. Never a
    /// logical figure — on the development machine `Docker.raw` reports 494.38 GB
    /// logically and 1.77 GB on disk, and printing the first number would be a
    /// 279-fold lie about what deleting it frees.
    public let physicalBytes: UInt64
    public let itemCount: UInt32
    public let lastModified: Date?
    /// Directories inside the candidate that could not be read. The size is a
    /// floor when this is non-zero, and the row says so instead of pretending
    /// the number is complete.
    public let unreadableCount: UInt64
}

/// Measures a candidate by running `LoupeFS`'s walker over it.
///
/// This is the same `ScanEngine` Pillar 1 uses — same `getattrlistbulk` reader,
/// same hardlink deduplication, same allocated-size arithmetic. A second walker
/// written here would be a second place for the size rules to drift.
public enum TreeMeasure {

    /// Fewer threads than a volume scan. A candidate is usually a few thousand
    /// entries, and a plan measures dozens of them one after another; eight
    /// threads apiece would spend more time starting than walking.
    public static let configuration = ScanConfiguration(threadCount: 4)

    public static func measure(_ url: URL, identity: FileIdentity) async -> TreeMeasurement {
        guard identity.isDirectory else {
            // A single file, a symlink, or a dataless placeholder whose
            // st_blocks is legitimately zero.
            return TreeMeasurement(physicalBytes: identity.physicalBytes, itemCount: 1,
                                   lastModified: identity.modified, unreadableCount: 0)
        }

        let engine = ScanEngine(root: url, configuration: configuration)
        var failure: ScanFailure?
        var unreadable: UInt64 = 0
        for await event in engine.start() {
            switch event {
            case .finished(let summary): unreadable = summary.progress.deniedCount
            case .failed(let scanFailure): failure = scanFailure
            case .started, .progress, .layout: break
            }
        }
        if let failure {
            LoupeLogReclaim.reclaim.notice(
                "could not measure \(url.lastPathComponent, privacy: .public): \(String(describing: failure), privacy: .public)")
            return TreeMeasurement(physicalBytes: 0, itemCount: 0,
                                   lastModified: identity.modified, unreadableCount: 1)
        }
        let (bytes, items) = engine.withArena { arena in
            (arena.rootTotalPhysicalBytes, UInt32(clamping: arena.totalEntries))
        }
        return TreeMeasurement(physicalBytes: bytes, itemCount: items,
                               lastModified: identity.modified, unreadableCount: unreadable)
    }

    /// The newest modification time among the files a person actually edits.
    ///
    /// Entry 19's dormancy signal. Generated output, dependency trees and VCS
    /// metadata are excluded because their timestamps move for reasons that have
    /// nothing to do with whether anyone is still working on the project — the
    /// measured case being a project whose `node_modules` was 76 days old while
    /// its sources were 28.
    public static let generatedDirectories: Set<String> = [
        "node_modules", ".git", ".next", "dist", "build", "out", ".turbo",
        ".venv", "venv", "target", "coverage", ".cache", ".parcel-cache", ".svelte-kit"
    ]

    public static func newestSourceModification(under root: URL) async -> Date? {
        let engine = ScanEngine(root: root, configuration: configuration)
        for await event in engine.start() where event.isTerminalFailure { return nil }

        let newest = engine.withArena { arena -> UInt32 in
            guard !arena.dirs.isEmpty else { return 0 }
            var best: UInt32 = 0
            var stack: [UInt32] = [0]
            while let slot = stack.popLast() {
                for file in arena.fileChildren(of: slot) {
                    best = max(best, arena.files[Int(file)].mtime)
                }
                for child in arena.directoryChildren(of: slot)
                where !generatedDirectories.contains(arena.name(ofDirectory: child)) {
                    stack.append(child)
                }
            }
            return best
        }
        return newest == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(newest))
    }
}

private extension ScanEvent {
    var isTerminalFailure: Bool { if case .failed = self { true } else { false } }
}
