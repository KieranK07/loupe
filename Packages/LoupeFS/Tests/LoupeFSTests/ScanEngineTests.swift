import Darwin
import Foundation
import LoupeCore
import LoupeTree
import Testing
@testable import LoupeFS

// MARK: - Harness

extension Tag {
    /// Prints a measurement instead of asserting one. Never fails on a slow machine.
    @Tag static var benchmark: Self
}

/// The terminal state of one scan plus whatever progress arrived on the way.
struct ScanOutcome {
    var summary: ScanSummary?
    var failure: ScanFailure?
    var startedRoots: [URL] = []
    var lastProgress: ScanProgress?
    var progressEvents = 0
}

/// Runs a scan to its terminal event.
///
/// `.bufferingNewest(1)` means intermediate progress may legitimately be
/// dropped, so nothing here asserts on how many progress events arrived.
@discardableResult
func runScan(_ engine: ScanEngine) async -> ScanOutcome {
    var outcome = ScanOutcome()
    for await event in engine.start() {
        switch event {
        case .started(let root, _): outcome.startedRoots.append(root)
        case .progress(let progress):
            outcome.lastProgress = progress
            outcome.progressEvents += 1
        case .layout: break
        case .finished(let summary): outcome.summary = summary
        case .failed(let failure): outcome.failure = failure
        }
    }
    return outcome
}

/// A throwaway directory tree that cleans itself up.
final class TempTree {
    let root: URL

    init(_ label: String = "tree") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loupe-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let url = root.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `bytes` of incompressible data, so APFS cannot quietly change the
    /// allocated size out from under the assertions.
    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        if bytes > 0 {
            data.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { arc4random_buf(base, bytes) }
            }
        }
        try data.write(to: url)
        return url
    }

    func symlink(_ relative: String, to target: String) throws {
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(atPath: url.path(percentEncoded: false),
                                                   withDestinationPath: target)
    }

    /// Ground truth for physical bytes, straight from `stat(2)`.
    func allocatedBytes(of relative: String) -> UInt64 {
        var info = stat()
        let path = root.appending(path: relative).path(percentEncoded: false)
        guard lstat(path, &info) == 0 else { return 0 }
        return UInt64(info.st_blocks) * 512
    }
}

func engine(for tree: TempTree, threads: Int = 4) -> ScanEngine {
    ScanEngine(root: tree.root,
               configuration: ScanConfiguration(threadCount: threads,
                                                progressInterval: .milliseconds(20)))
}

// MARK: - Totals

@Suite("Walk totals")
struct WalkTotalsTests {

    @Test("A known tree's sizes and counts come back exactly")
    func totalsMatch() async throws {
        let tree = try TempTree("totals")
        try tree.directory("a")
        try tree.directory("b/c")
        try tree.file("a/f1", bytes: 1_000)
        try tree.file("a/f2", bytes: 5_000)
        try tree.file("b/c/f3", bytes: 100_000)
        try tree.file("f4", bytes: 0)

        let expectedLogical: UInt64 = 106_000
        let expectedPhysical = ["a/f1", "a/f2", "b/c/f3", "f4"]
            .reduce(UInt64(0)) { $0 + tree.allocatedBytes(of: $1) }

        let scanner = engine(for: tree)
        let outcome = await runScan(scanner)

        #expect(outcome.failure == nil)
        let summary = try #require(outcome.summary)
        #expect(summary.progress.entriesSeen == 7)        // 3 dirs + 4 files, root excluded
        #expect(summary.progress.directoriesSeen == 3)
        #expect(summary.progress.logicalBytes == expectedLogical)
        #expect(summary.progress.physicalBytes == expectedPhysical)
        #expect(summary.progress.deniedCount == 0)
        #expect(summary.progress.truncatedPathCount == 0)

        scanner.withArena { arena in
            #expect(arena.totalEntries == 8)              // 4 dirs incl. root + 4 files
            #expect(arena.rootTotalLogicalBytes == expectedLogical)
            #expect(arena.rootTotalPhysicalBytes == expectedPhysical)
            // Every directory must have rolled up; nothing left incomplete.
            for slot in 0..<UInt32(arena.dirs.count) {
                #expect(!arena.dirs[Int(slot)].flags.contains(.incomplete),
                        "directory \(arena.name(ofDirectory: slot)) never completed")
            }
        }
    }

    @Test("An empty directory still completes and rolls up")
    func emptyTree() async throws {
        let tree = try TempTree("empty")
        let scanner = engine(for: tree)
        let outcome = await runScan(scanner)
        let summary = try #require(outcome.summary)
        #expect(summary.progress.entriesSeen == 0)
        #expect(summary.progress.physicalBytes == 0)
        scanner.withArena { #expect($0.totalEntries == 1) }
    }

    @Test("Subtree totals roll up to every ancestor")
    func rollUpReachesTheRoot() async throws {
        let tree = try TempTree("rollup")
        for depth in 1...6 {
            let path = (1...depth).map { "level\($0)" }.joined(separator: "/")
            try tree.file("\(path)/leaf", bytes: 4_096)
        }
        let scanner = engine(for: tree)
        let outcome = await runScan(scanner)
        let summary = try #require(outcome.summary)
        #expect(summary.progress.logicalBytes == 6 * 4_096)
        scanner.withArena { arena in
            #expect(arena.rootTotalLogicalBytes == 6 * 4_096)
            #expect(arena.dirs[0].subtreeItems == 12)     // 6 nested dirs + 6 leaves
        }
    }
}

// MARK: - Hard links

@Suite("Hard links")
struct HardLinkTests {

    @Test("A hard-linked file's bytes are counted exactly once")
    func hardLinkCountedOnce() async throws {
        let tree = try TempTree("hardlink")
        let original = try tree.file("original.bin", bytes: 64 * 1024)
        let linkPath = tree.root.appending(path: "linked.bin").path(percentEncoded: false)
        #expect(link(original.path(percentEncoded: false), linkPath) == 0,
                "link(2) failed: \(String(cString: strerror(errno)))")

        let oneCopy = tree.allocatedBytes(of: "original.bin")
        #expect(oneCopy >= 64 * 1024)

        let scanner = engine(for: tree)
        let outcome = await runScan(scanner)
        let summary = try #require(outcome.summary)

        // Both names are real entries; only one of them owns the bytes.
        #expect(summary.progress.entriesSeen == 2)
        #expect(summary.hardlinkDuplicatesSkipped == 1)
        #expect(summary.progress.physicalBytes == oneCopy)
        #expect(summary.progress.logicalBytes == 64 * 1024)

        scanner.withArena { arena in
            #expect(arena.hardlinkDuplicates == 1)
            #expect(arena.rootTotalPhysicalBytes == oneCopy)
            let flagged = (0..<arena.files.count).filter {
                arena.files[$0].flags.contains(.hardlinkDuplicate)
            }
            #expect(flagged.count == 1)
        }
    }

    @Test("Files with one link are never consulted against the inode set")
    func singleLinkFilesAreNotDeduplicated() async throws {
        let tree = try TempTree("nodedup")
        try tree.file("a.bin", bytes: 8_192)
        try tree.file("b.bin", bytes: 8_192)
        let scanner = engine(for: tree)
        let outcome = await runScan(scanner)
        let summary = try #require(outcome.summary)
        #expect(summary.hardlinkDuplicatesSkipped == 0)
        #expect(summary.progress.logicalBytes == 16_384)
    }
}

// MARK: - Symlinks

@Suite("Symlinks")
struct SymlinkTests {

    @Test("A symlink to a directory is recorded but never followed")
    func symlinkNotFollowed() async throws {
        let tree = try TempTree("symlink")
        try tree.directory("target")
        try tree.file("target/inside.bin", bytes: 4_096)
        try tree.symlink("alias", to: "target")

        let scanner = engine(for: tree)
        let outcome = await runScan(scanner)
        let summary = try #require(outcome.summary)

        // target/, target/inside.bin, alias — and `alias` counts as a leaf.
        #expect(summary.progress.directoriesSeen == 1)
        #expect(summary.progress.entriesSeen == 3)
        scanner.withArena { arena in
            // Followed, `inside.bin` would appear twice.
            let insideCount = (0..<arena.files.count)
                .map { arena.name(ofFile: UInt32($0)) }
                .filter { $0 == "inside.bin" }.count
            #expect(insideCount == 1)
        }
    }

    @Test("A symlink cycle cannot hang the walk", .timeLimit(.minutes(1)))
    func symlinkCycleTerminates() async throws {
        let tree = try TempTree("cycle")
        try tree.directory("a/b/c")
        try tree.symlink("a/b/c/up", to: "../../..")
        try tree.symlink("a/b/self", to: ".")
        try tree.symlink("a/loop", to: "../a")
        try tree.file("a/b/c/leaf.bin", bytes: 1_024)

        let clock = ContinuousClock()
        var outcome = ScanOutcome()
        let elapsed = await clock.measure { outcome = await runScan(engine(for: tree)) }

        let summary = try #require(outcome.summary)
        #expect(elapsed < .seconds(10))
        #expect(summary.progress.directoriesSeen == 3)   // a, a/b, a/b/c only
        #expect(summary.progress.logicalBytes >= 1_024)
    }
}

// MARK: - Paths longer than PATH_MAX

@Suite("Path limits")
struct PathLimitTests {

    /// Builds a chain deeper than `PATH_MAX` using `mkdirat`, which addresses
    /// each component relative to an open descriptor and so is not itself
    /// bounded by the total path length.
    /// - Returns: the descriptors of every level, outermost first, for teardown.
    @discardableResult
    static func buildOverlongChain(at base: URL, component: String, levels: Int) throws -> [Int32] {
        var descriptors: [Int32] = []
        var current = open(base.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(current >= 0)
        descriptors.append(current)
        for _ in 0..<levels {
            let made = component.withCString { mkdirat(current, $0, 0o755) }
            try #require(made == 0 || errno == EEXIST)
            let next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            try #require(next >= 0)
            descriptors.append(next)
            current = next
        }
        return descriptors
    }

    static func tearDownChain(_ descriptors: [Int32], component: String) {
        // Deepest first: a directory cannot be removed while it has children.
        for index in stride(from: descriptors.count - 2, through: 0, by: -1) {
            _ = component.withCString { unlinkat(descriptors[index], $0, AT_REMOVEDIR) }
        }
        for fd in descriptors { close(fd) }
    }

    @Test("A path that would exceed PATH_MAX is skipped, not walked",
          .timeLimit(.minutes(1)))
    func overlongPathsAreSkipped() async throws {
        let tree = try TempTree("pathmax")
        let component = String(repeating: "d", count: 200)
        // 8 x 201 bytes is comfortably past PATH_MAX (1024) from any temp root.
        let descriptors = try Self.buildOverlongChain(at: tree.root, component: component, levels: 8)
        defer { Self.tearDownChain(descriptors, component: component) }

        let outcome = await runScan(engine(for: tree))
        let summary = try #require(outcome.summary)

        #expect(summary.progress.truncatedPathCount >= 1)
        // The walk must stop at the boundary, not loop through an ancestor.
        #expect(summary.progress.directoriesSeen < 8)
    }

    @Test("Child path composition refuses to truncate")
    func childPathRefusesTruncation() {
        let parent = Array(String(repeating: "a", count: Int(PATH_MAX) - 10).utf8)
        let longName = Array("abcdefghijklmnop".utf8)
        let fits = Array("ab".utf8)

        let tooLong = longName.withUnsafeBytes { ScanEngine.childPath(parent: parent, name: $0) }
        #expect(tooLong == nil)

        let ok = fits.withUnsafeBytes { ScanEngine.childPath(parent: parent, name: $0) }
        #expect(ok?.count == parent.count + 3)
    }

    @Test("The filesystem root composes children without a doubled separator")
    func rootPathHasNoDoubleSeparator() {
        let name = Array("Users".utf8)
        let composed = name.withUnsafeBytes {
            ScanEngine.childPath(parent: Array("/".utf8), name: $0)
        }
        #expect(composed.map { String(decoding: $0, as: UTF8.self) } == "/Users")
    }
}

// MARK: - Work distribution

@Suite("Work distribution")
struct WorkStackTests {

    private func item(_ name: String, depth: UInt8) -> DirectoryWork {
        DirectoryWork(path: Array(name.utf8), slot: 0, depth: depth)
    }

    private func name(_ work: DirectoryWork) -> String {
        String(decoding: work.path, as: UTF8.self)
    }

    /// The inner rings of a sunburst are the ones the user sees first, so the
    /// shallow frontier has to drain before any deep branch does.
    @Test("Shallow work is handed out breadth-first, deep work depth-first")
    func shallowFirstThenDepthFirst() throws {
        let stack = ScanWorkStack(breadthFirstDepth: 3)
        stack.seed(item("shallow-a", depth: 0))
        stack.seed(item("shallow-b", depth: 1))
        stack.seed(item("deep-a", depth: 3))
        stack.seed(item("shallow-c", depth: 2))
        stack.seed(item("deep-b", depth: 7))

        var order: [String] = []
        while let work = stack.take() {
            order.append(name(work))
            stack.complete(pushing: [])
        }

        // Shallow items in the order they were seeded, then deep items newest-first.
        #expect(order == ["shallow-a", "shallow-b", "shallow-c", "deep-b", "deep-a"])
    }

    @Test("A cancelled stack hands out nothing")
    func cancelledStackIsEmpty() {
        let stack = ScanWorkStack(breadthFirstDepth: 3)
        stack.seed(item("a", depth: 0))
        stack.cancel()
        #expect(stack.take() == nil)
        #expect(stack.wasCancelled)
    }

    @Test("Children discovered mid-walk join the frontier")
    func childrenAreQueued() {
        let stack = ScanWorkStack(breadthFirstDepth: 1)
        stack.seed(item("root", depth: 0))
        var seen: [String] = []
        while let work = stack.take() {
            seen.append(name(work))
            let children = name(work) == "root"
                ? [item("child-1", depth: 1), item("child-2", depth: 1)]
                : []
            stack.complete(pushing: children)
        }
        #expect(seen.count == 3)
        #expect(Set(seen) == ["root", "child-1", "child-2"])
    }
}

// MARK: - Cancellation and pause

@Suite("Lifecycle")
struct LifecycleTests {

    /// A tree wide enough that a single-threaded walk cannot finish before the
    /// cancel lands, but small enough to build in well under a second.
    private func wideTree() throws -> TempTree {
        let tree = try TempTree("cancel")
        for outer in 0..<40 {
            for inner in 0..<40 {
                try tree.directory("d\(outer)/e\(inner)")
            }
        }
        return tree
    }

    @Test("Cancellation stops the walk promptly", .timeLimit(.minutes(1)))
    func cancelStopsTheWalk() async throws {
        let tree = try wideTree()
        let scanner = ScanEngine(root: tree.root,
                                 configuration: ScanConfiguration(threadCount: 1,
                                                                  progressInterval: .milliseconds(10)))
        let clock = ContinuousClock()
        let start = clock.now
        let stream = scanner.start()
        scanner.cancel()

        var failure: ScanFailure?
        var summary: ScanSummary?
        for await event in stream {
            if case .failed(let value) = event { failure = value }
            if case .finished(let value) = event { summary = value }
        }
        let elapsed = clock.now - start

        #expect(elapsed < .seconds(5), "cancellation took \(elapsed)")
        #expect(summary == nil, "a cancelled walk must not report a summary")
        #expect(failure == .cancelled)
    }

    @Test("Pause parks the walk and resume finishes it", .timeLimit(.minutes(1)))
    func pauseThenResume() async throws {
        let tree = try TempTree("pause")
        for index in 0..<50 { try tree.file("d\(index % 5)/f\(index).bin", bytes: 4_096) }

        let scanner = engine(for: tree, threads: 2)
        scanner.pause()
        let stream = scanner.start()
        #expect(scanner.isPaused)

        // Nothing can be committed while parked, so resuming is what lets the
        // stream terminate at all.
        scanner.resume()
        var summary: ScanSummary?
        for await event in stream {
            if case .finished(let value) = event { summary = value }
        }
        let finished = try #require(summary)
        #expect(finished.progress.logicalBytes == 50 * 4_096)
    }

    @Test("A root that is not a directory fails cleanly")
    func fileRootFails() async throws {
        let tree = try TempTree("notadir")
        let file = try tree.file("plain.bin", bytes: 16)
        let scanner = ScanEngine(root: file)
        let outcome = await runScan(scanner)
        #expect(outcome.summary == nil)
        #expect(outcome.failure == .notADirectory(file))
    }

    @Test("A root that does not exist fails cleanly")
    func missingRootFails() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        let outcome = await runScan(ScanEngine(root: missing))
        #expect(outcome.summary == nil)
        if case .rootUnreadable(_, let code) = outcome.failure {
            #expect(code == ENOENT)
        } else {
            Issue.record("expected .rootUnreadable, got \(String(describing: outcome.failure))")
        }
    }

    @Test("The walk announces itself before it reports anything else")
    func startedIsEmitted() async throws {
        let tree = try TempTree("started")
        try tree.file("a.bin", bytes: 1_024)
        let outcome = await runScan(engine(for: tree))
        #expect(outcome.startedRoots == [tree.root])
    }
}

// MARK: - Denied directories

@Suite("Unreadable directories")
struct DeniedTests {

    @Test("An unreadable directory is flagged, counted, and does not stall the roll-up",
          .enabled(if: getuid() != 0, "root can read anything, so nothing would be denied"),
          .timeLimit(.minutes(1)))
    func deniedDirectoryDoesNotStall() async throws {
        let tree = try TempTree("denied")
        let secret = try tree.directory("secret")
        try tree.file("secret/hidden.bin", bytes: 8_192)
        try tree.file("visible.bin", bytes: 4_096)
        try #require(chmod(secret.path(percentEncoded: false), 0o000) == 0)
        defer { _ = chmod(secret.path(percentEncoded: false), 0o755) }

        let scanner = engine(for: tree)
        let outcome = await runScan(scanner)
        let summary = try #require(outcome.summary)

        #expect(summary.progress.deniedCount == 1)
        // The readable half is still reported in full.
        #expect(summary.progress.logicalBytes == 4_096)
        try scanner.withArena { arena in
            #expect(arena.deniedCount == 1)
            let denied = (0..<arena.dirs.count).filter { arena.dirs[$0].flags.contains(.denied) }
            #expect(denied.count == 1)
            #expect(denied.first.map { arena.name(ofDirectory: UInt32($0)) } == "secret")
            // An unreadable directory is not "still scanning" — nothing will
            // ever complete it, so it must not read as in-progress forever.
            let deniedSlot = try #require(denied.first)
            #expect(!arena.dirs[deniedSlot].flags.contains(.incomplete))
            // The root completed despite an unreadable child.
            #expect(!arena.dirs[0].flags.contains(.incomplete))
        }
    }
}

// MARK: - Throughput

@Suite("Throughput")
struct ThroughputTests {

    /// The directory to measure. `/Applications` by default; set
    /// `LOUPE_BENCH_PATH` to point it at a bigger tree such as `$HOME`.
    static var benchmarkPath: String {
        ProcessInfo.processInfo.environment["LOUPE_BENCH_PATH"] ?? "/Applications"
    }

    /// Reports entries/sec on a real tree. Deliberately asserts nothing about
    /// speed: CI machines are slow and a timing assertion there is just noise.
    @Test("Walk a real directory and report throughput",
          .tags(.benchmark),
          .enabled(if: FileManager.default.fileExists(atPath: ThroughputTests.benchmarkPath)),
          .timeLimit(.minutes(5)))
    func benchmarkApplications() async throws {
        let target = URL(fileURLWithPath: Self.benchmarkPath, isDirectory: true)
        let scanner = ScanEngine(root: target,
                                 configuration: ScanConfiguration(expectedEntries: 400_000))
        let clock = ContinuousClock()
        var outcome = ScanOutcome()
        let elapsed = await clock.measure { outcome = await runScan(scanner) }

        let summary = try #require(outcome.summary)
        let entries = summary.progress.entriesSeen
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let rate = seconds > 0 ? Double(entries) / seconds : 0

        print("""
        [benchmark] \(Self.benchmarkPath)
          threads     : \(ScanConfiguration.defaultThreadCount)
          entries     : \(entries)
          directories : \(summary.progress.directoriesSeen)
          physical    : \(ByteFormat.string(summary.progress.physicalBytes))
          logical     : \(ByteFormat.string(summary.progress.logicalBytes))
          hardlink dup: \(summary.hardlinkDuplicatesSkipped)
          dataless    : \(summary.datalessPlaceholders)
          denied      : \(summary.progress.deniedCount)
          truncated   : \(summary.progress.truncatedPathCount)
          elapsed     : \(String(format: "%.3f", seconds)) s
          throughput  : \(String(format: "%.0f", rate)) entries/sec
          arena       : \(scanner.withArena { $0.approximateBytesResident / 1_048_576 }) MB
        """)

        #expect(entries > 0)
    }
}
