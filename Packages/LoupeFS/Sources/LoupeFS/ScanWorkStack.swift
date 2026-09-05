import Foundation

/// One directory waiting to be read.
///
/// The path is carried as raw bytes, not a `String`. APFS filenames are opaque
/// byte sequences that need not be valid UTF-8; round-tripping one through
/// `String` can substitute replacement characters and produce a path that no
/// longer opens. The arena stores names as bytes for the same reason.
struct DirectoryWork: Sendable {
    /// Absolute path, no trailing NUL.
    let path: [UInt8]
    /// Slot of this directory in the arena.
    let slot: UInt32
    let depth: UInt8
}

/// The shared frontier of the walk.
///
/// One lock guards everything. Workers are depth-first for locality, but the
/// first few levels are handed out breadth-first so the inner rings of the
/// sunburst have real totals within a second or two instead of waiting for one
/// arbitrary deep branch to bottom out.
///
/// `NSCondition` rather than `Mutex` because this lock is the only place a
/// worker ever sleeps: it needs a condition variable to park idle workers, to
/// hold them during a pause, and to release them all at once when the walk ends
/// or is cancelled. Contention is low — one acquire per directory read.
final class ScanWorkStack: @unchecked Sendable {
    private let condition = NSCondition()

    /// Shallow work, taken in FIFO order.
    private var seeds: [DirectoryWork] = []
    private var seedHead = 0
    /// Deep work, taken in LIFO order.
    private var deep: [DirectoryWork] = []

    /// Directories taken but not yet finished. The walk is over when this is
    /// zero and nothing is queued — not merely when the queues run dry, since a
    /// busy worker is about to push that directory's children.
    private var busy = 0
    private var finished = false
    private var cancelled = false
    private var paused = false

    /// Depth below which work is handed out breadth-first.
    private let breadthFirstDepth: UInt8

    init(breadthFirstDepth: UInt8) {
        self.breadthFirstDepth = breadthFirstDepth
    }

    func seed(_ item: DirectoryWork) {
        condition.lock()
        pushLocked(item)
        condition.unlock()
    }

    private func pushLocked(_ item: DirectoryWork) {
        if item.depth < breadthFirstDepth {
            seeds.append(item)
        } else {
            deep.append(item)
        }
    }

    private func popLocked() -> DirectoryWork? {
        if seedHead < seeds.count {
            let item = seeds[seedHead]
            seedHead += 1
            // Reclaim the drained prefix once, not on every pop.
            if seedHead == seeds.count { seeds.removeAll(keepingCapacity: true); seedHead = 0 }
            return item
        }
        return deep.popLast()
    }

    private var isEmptyLocked: Bool { seedHead >= seeds.count && deep.isEmpty }

    /// Blocks until work is available, the walk finishes, or it is cancelled.
    /// A returned item counts as busy until the matching `complete` call.
    func take() -> DirectoryWork? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled || finished { return nil }
            if paused {
                // A pause that lands exactly as the walk drains must still let
                // the walk finish, or nothing would ever report completion.
                if busy == 0 && isEmptyLocked {
                    finished = true
                    condition.broadcast()
                    return nil
                }
                condition.wait()
                continue
            }
            if let item = popLocked() {
                busy += 1
                return item
            }
            if busy == 0 {
                finished = true
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    /// Finishes the item taken by `take`, queueing whatever it discovered.
    func complete(pushing children: [DirectoryWork]) {
        condition.lock()
        for child in children { pushLocked(child) }
        busy -= 1
        if busy == 0 && isEmptyLocked && !paused {
            finished = true
        }
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Parks the frontier. Workers stop taking new directories; the one
    /// directory each worker already holds is finished first.
    func pause() {
        condition.lock()
        paused = true
        condition.broadcast()
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return paused
    }

    var wasCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    /// Blocks the caller until every worker has stopped.
    func waitUntilFinished() {
        condition.lock()
        while !finished { condition.wait() }
        condition.unlock()
    }
}
