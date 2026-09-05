import CLoupeFS
import Darwin
import Foundation
import LoupeCore
import LoupeTree
import Synchronization

/// Disables iCloud dataless-file materialisation for this process, exactly once.
///
/// A Swift global `let` is initialised under `swift_once`, which is precisely
/// the "exactly once, before any walking" guarantee this needs. The policy is
/// process-scoped, so threads created later inherit it.
///
/// This is the single most important line in the app. A normal home directory
/// holds six figures of dataless placeholders (132,390 measured here); without
/// this, walking one downloads the user's entire iCloud Drive.
private let datalessMaterializationDisabled: Bool = {
    loupe_disable_dataless_materialization()
    return true
}()

/// Walks a directory tree into an `Arena`.
///
/// # Why `final class` + `@unchecked Sendable` and not an actor
///
/// `getattrlistbulk` is a blocking syscall. Swift Concurrency's cooperative
/// pool has a fixed width and no way to know a thread is parked in the kernel,
/// so running the walk on `Task`s would starve every other async operation in
/// the process — including the UI's. The walk therefore runs on dedicated
/// `Thread`s, which puts it outside the actor model by construction.
///
/// `@unchecked` is the honest label for that: the compiler cannot verify this,
/// so the invariant is stated and enforced by hand instead. Every piece of
/// mutable state below is either an `Atomic` or lives behind a `Mutex` /
/// `ScanWorkStack` lock, and nothing that crosses the `AsyncStream` boundary is
/// anything but a `Sendable` value type.
public final class ScanEngine: @unchecked Sendable {

    public let root: URL
    public let configuration: ScanConfiguration

    /// Absolute root path as bytes, trailing separator stripped (except for `/`).
    /// Bytes rather than `String` because APFS filenames are not required to be
    /// valid UTF-8 and a lossy round-trip produces paths that no longer open.
    private let rootPathBytes: [UInt8]
    /// `st_dev` of the scan root. Every entry's `dev_id` is compared to this.
    /// Written once before any worker exists and read once per directory, so an
    /// atomic keeps it off the hot path's lock entirely.
    private let rootDevice = Atomic<Int32>(0)

    private let arena: Mutex<Arena>
    private let work: ScanWorkStack
    private let inodes: ShardedInodeSet

    private let entriesSeen = Atomic<UInt64>(0)
    private let directoriesSeen = Atomic<UInt64>(0)
    private let physicalBytes = Atomic<UInt64>(0)
    private let logicalBytes = Atomic<UInt64>(0)
    private let deniedCount = Atomic<UInt64>(0)
    private let truncatedPathCount = Atomic<UInt64>(0)
    private let datalessCount = Atomic<UInt64>(0)
    private let hardlinkDuplicates = Atomic<UInt64>(0)

    /// Read once per directory, so worst-case cancellation latency is one
    /// directory read. Relaxed ordering is sufficient: the work stack's lock
    /// supplies the happens-before edge that actually matters.
    private let cancelledFlag = Atomic<Bool>(false)
    private let started = Atomic<Bool>(false)
    private let stopProgress = Atomic<Bool>(false)

    /// Most recently opened directory, for the progress readout. Held as the
    /// same COW byte array the work item already owns, so publishing it costs a
    /// retain rather than a copy or a `String` allocation per directory.
    private let currentPathBytes = Mutex<[UInt8]>([])

    private let startedAt = Mutex<Date>(.distantPast)
    private let clockStart = Mutex<ContinuousClock.Instant?>(nil)

    public init(root: URL, configuration: ScanConfiguration = .default) {
        self.root = root
        self.configuration = configuration
        self.rootPathBytes = Self.normalizedPathBytes(root)
        self.arena = Mutex(configuration.expectedEntries > 0
                           ? Arena(reservingCapacityForEntries: configuration.expectedEntries)
                           : Arena())
        self.work = ScanWorkStack(breadthFirstDepth: configuration.breadthFirstLevels)
        // Only entries with linkCount > 1 are ever inserted; ~4% of entries on
        // a real home directory.
        self.inodes = ShardedInodeSet(reservingCapacity: configuration.expectedEntries / 16)
    }

    // MARK: - Public surface

    /// Starts the walk and returns the event channel.
    ///
    /// `.bufferingNewest(1)` per the scan contract: a slow frame drops stale
    /// progress rather than queueing it. `.started` is emitted before any worker
    /// exists and the first `.progress` cannot arrive for a full interval, so
    /// the terminal `.finished` / `.failed` — always the newest event, always
    /// followed immediately by `finish()` — is never the one that gets dropped.
    public func start() -> AsyncStream<ScanEvent> {
        let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1))

        // An engine walks once. A second `start()` would seed a second root
        // into an arena that already has one and trip its precondition, so it
        // is refused here instead. `.cancelled` is the closest the contract has
        // to "this scan never ran".
        guard started.compareExchange(expected: false, desired: true,
                                      ordering: .sequentiallyConsistent).exchanged else {
            continuation.yield(.failed(.cancelled))
            continuation.finish()
            return stream
        }

        _ = datalessMaterializationDisabled

        let openedAt = Date()
        startedAt.withLock { $0 = openedAt }
        clockStart.withLock { $0 = ContinuousClock.now }

        switch prepareRoot() {
        case .failure(let failure):
            continuation.yield(.failed(failure))
            continuation.finish()
            return stream
        case .success(let device):
            rootDevice.store(device, ordering: .relaxed)
        }

        continuation.yield(.started(root: root, at: openedAt))

        let rootName = configuration.rootDisplayName
            ?? (root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent)
        arena.withLock { _ = $0.createRoot(name: rootName) }
        work.seed(DirectoryWork(path: rootPathBytes, slot: 0, depth: 0))

        let group = DispatchGroup()
        for index in 0..<configuration.threadCount {
            group.enter()
            let thread = Thread { [self] in
                defer { group.leave() }
                workerLoop()
            }
            thread.name = "com.loupe.scan.worker.\(index)"
            thread.qualityOfService = .userInitiated
            // 512 KiB: the walk recurses nowhere and the 256 KiB attribute
            // buffer is heap-allocated, so the default 512 KiB is ample.
            thread.stackSize = 512 * 1024
            thread.start()
        }

        startProgressThread(continuation: continuation)
        startSupervisorThread(group: group, continuation: continuation, startedAt: openedAt)

        return stream
    }

    public func cancel() {
        cancelledFlag.store(true, ordering: .sequentiallyConsistent)
        work.cancel()
    }

    /// Parks the frontier. The directory each worker already holds is finished
    /// first, so a paused arena is never half-committed.
    public func pause() { work.pause() }
    public func resume() { work.resume() }
    public var isPaused: Bool { work.isPaused }

    public var progress: ScanProgress { snapshotProgress() }

    /// Reads the arena under its lock.
    ///
    /// `borrowing` so a caller cannot smuggle the value out: the arena's arrays
    /// are copy-on-write, and a stray copy retained outside the lock would turn
    /// the next commit into a full duplication of every node.
    public func withArena<R>(_ body: (borrowing Arena) throws -> R) rethrows -> R {
        try arena.withLock { try body($0) }
    }

    // MARK: - Root validation

    private func prepareRoot() -> Result<Int32, ScanFailure> {
        let path = root.path(percentEncoded: false)
        var info = stat()
        guard stat(path, &info) == 0 else {
            return .failure(.rootUnreadable(root, errno: errno))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return .failure(.notADirectory(root))
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            // TCC refuses with EPERM where POSIX permissions refuse with
            // EACCES, which is the only signal available to tell "you need Full
            // Disk Access" apart from "this directory is not yours".
            return .failure(code == EPERM
                            ? .fullDiskAccessRequired(root)
                            : .rootUnreadable(root, errno: code))
        }
        close(fd)
        return .success(Int32(bitPattern: UInt32(info.st_dev)))
    }

    private static func normalizedPathBytes(_ url: URL) -> [UInt8] {
        var bytes = Array(url.path(percentEncoded: false).utf8)
        let separator = UInt8(ascii: "/")
        while bytes.count > 1, bytes.last == separator { bytes.removeLast() }
        return bytes
    }

    // MARK: - Threads

    private func startProgressThread(continuation: AsyncStream<ScanEvent>.Continuation) {
        let interval = TimeInterval(configuration.progressInterval.components.seconds)
            + TimeInterval(configuration.progressInterval.components.attoseconds) / 1e18
        let thread = Thread { [self] in
            while !stopProgress.load(ordering: .relaxed) {
                Thread.sleep(forTimeInterval: interval)
                if stopProgress.load(ordering: .relaxed) { break }
                continuation.yield(.progress(snapshotProgress()))
            }
        }
        thread.name = "com.loupe.scan.progress"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func startSupervisorThread(group: DispatchGroup,
                                       continuation: AsyncStream<ScanEvent>.Continuation,
                                       startedAt: Date) {
        let thread = Thread { [self] in
            group.wait()
            stopProgress.store(true, ordering: .relaxed)

            if work.wasCancelled {
                continuation.yield(.failed(.cancelled))
                continuation.finish()
                return
            }

            arena.withLock { $0.finishWalk() }
            let summary = ScanSummary(
                root: root,
                progress: snapshotProgress(),
                hardlinkDuplicatesSkipped: hardlinkDuplicates.load(ordering: .relaxed),
                datalessPlaceholders: datalessCount.load(ordering: .relaxed),
                startedAt: startedAt,
                finishedAt: Date())
            continuation.yield(.finished(summary))
            continuation.finish()
        }
        thread.name = "com.loupe.scan.supervisor"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func snapshotProgress() -> ScanProgress {
        let elapsed = clockStart.withLock { $0?.duration(to: .now) } ?? .zero
        let path = currentPathBytes.withLock { bytes -> String? in
            bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
        return ScanProgress(
            entriesSeen: entriesSeen.load(ordering: .relaxed),
            directoriesSeen: directoriesSeen.load(ordering: .relaxed),
            physicalBytes: physicalBytes.load(ordering: .relaxed),
            logicalBytes: logicalBytes.load(ordering: .relaxed),
            deniedCount: deniedCount.load(ordering: .relaxed),
            truncatedPathCount: truncatedPathCount.load(ordering: .relaxed),
            currentPath: path,
            elapsed: elapsed)
    }

    // MARK: - Worker

    private func workerLoop() {
        guard let worker = Worker(bufferBytes: configuration.bufferBytes,
                                  measuresPrivateSize: configuration.measuresPrivateSize) else {
            LoupeLog.scan.error("walker thread could not allocate its read buffer")
            return
        }
        defer { worker.dispose() }
        while let item = work.take() {
            let children = readDirectory(item, worker: worker)
            work.complete(pushing: children)
        }
    }

    /// Reads one directory end to end, stages its children, and commits them in
    /// a single critical section — one arena lock acquisition per *directory*,
    /// never per entry.
    private func readDirectory(_ item: DirectoryWork, worker: Worker) -> [DirectoryWork] {
        if cancelledFlag.load(ordering: .relaxed) { return [] }

        currentPathBytes.withLock { $0 = item.path }
        worker.reset()

        let openResult = worker.open(path: item.path)
        guard openResult == 0 else {
            handleUnreadable(item, errorCode: openResult)
            return []
        }
        defer { worker.close() }

        let device = rootDevice.load(ordering: .relaxed)
        var localEntries: UInt64 = 0
        var localDirectories: UInt64 = 0
        var localPhysical: UInt64 = 0
        var localLogical: UInt64 = 0
        var localDataless: UInt64 = 0
        var localDuplicates: UInt64 = 0
        var localTruncated: UInt64 = 0
        var localDenied: UInt64 = 0

        var entry = loupe_entry_t()
        readLoop: while true {
            let status = loupe_dir_reader_next(worker.reader, &entry)
            switch status {
            case LOUPE_ENTRY:
                break
            case LOUPE_END:
                break readLoop
            default:
                // A decode failure is not recoverable within this directory:
                // the buffer cursor is no longer trustworthy. Take what was
                // read and move on rather than risk fabricated entries.
                LoupeLog.scan.error("directory read failed: errno \(-status, privacy: .public)")
                break readLoop
            }

            // A per-entry error means the kernel returned only this entry's
            // name and nothing else — no type, no size. There is nothing
            // truthful to record about it, so it is dropped rather than added
            // to the tree as a zero-byte guess.
            guard entry.entry_error == 0 else { continue }
            guard let namePointer = entry.name, entry.name_len > 0 else { continue }
            let nameBytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(namePointer),
                                                   count: Int(entry.name_len))

            localEntries += 1

            if entry.obj_type == UInt32(LOUPE_OBJ_DIR) {
                localDirectories += 1
                var flags = DirFlags()
                if entry.cmn_flags & LOUPE_SF_RESTRICTED != 0 { flags.insert(.restricted) }
                // A firmlink re-enters the Data volume: following one double-
                // counts everything below it. The device check cannot catch
                // this, because macOS reports the same device id on both sides.
                if entry.cmn_flags & LOUPE_SF_FIRMLINK != 0 { flags.insert(.firmlink) }
                if entry.dev_id != device { flags.insert(.crossedDevice) }

                var descend = !flags.contains(.firmlink) && !flags.contains(.crossedDevice)
                var childPath: [UInt8]? = nil

                if descend {
                    guard let composed = Self.childPath(parent: item.path, name: nameBytes) else {
                        // A truncated path is not merely lossy: it can resolve
                        // to an ancestor directory and turn the walk into an
                        // infinite cycle. Skip the entry outright and account
                        // for it, so the tree is visibly incomplete rather than
                        // quietly wrong.
                        localTruncated += 1
                        continue
                    }
                    // Ask before descending, using the parent's open descriptor
                    // so there is no second path resolution. Knowing here — not
                    // when the child worker fails to open it — is what lets the
                    // directory be committed already marked `.denied`, which in
                    // turn keeps it out of the parent's outstanding-child count
                    // so the roll-up cannot stall on a subtree nobody can read.
                    // Measured cost on a 1.98M-entry walk: none (6.376 s vs
                    // 6.380 s).
                    if faccessat(loupe_dir_reader_fd(worker.reader), namePointer,
                                 R_OK | X_OK, 0) != 0 {
                        flags.insert(.denied)
                        localDenied += 1
                        descend = false
                    } else {
                        childPath = composed
                    }
                }

                let name = worker.stageName(nameBytes)
                worker.dirs.append(StagedDir(nameStart: name.start, nameLength: name.length,
                                             mtime: entry.mtime_sec, flags: flags))
                if let childPath {
                    worker.descendable.append(Worker.Descendable(
                        index: worker.dirs.count - 1, path: childPath))
                }
                continue
            }

            // Everything that is not a directory is a leaf: regular files,
            // symlinks (recorded, never followed), devices, sockets, fifos.
            var flags = FileFlags()
            if entry.cmn_flags & LOUPE_SF_DATALESS != 0 {
                flags.insert(.dataless)
                localDataless += 1
            }
            if entry.cmn_flags & LOUPE_SF_RESTRICTED != 0 { flags.insert(.restricted) }
            if entry.cmn_flags & LOUPE_UF_COMPRESSED != 0 { flags.insert(.compressed) }

            // ATTR_CMNEXT_PRIVATESIZE is the bytes this file alone owns. When it
            // is short of the allocated size, the difference is shared with an
            // APFS clone somewhere else and deleting this file will not free it.
            // Unrequested, the field is zero for everything, which would flag
            // every file on the volume — hence the explicit opt-in check rather
            // than trusting the value alone.
            if configuration.measuresPrivateSize,
               entry.alloc_size > 0, entry.private_size < entry.alloc_size {
                flags.insert(.clone)
            }

            if entry.obj_type == UInt32(LOUPE_OBJ_REG), entry.link_count > 1 {
                if !inodes.claim(device: entry.dev_id, inode: entry.file_id) {
                    flags.insert(.hardlinkDuplicate)
                    localDuplicates += 1
                }
            }

            // Allocated size is always a block multiple, but round up rather
            // than assume it: a filesystem that disagrees should cost a byte,
            // not silently lose a block.
            let blocks = UInt32(clamping: (entry.alloc_size &+ 4095) / 4096)
            if !flags.contains(.hardlinkDuplicate) {
                localPhysical &+= UInt64(blocks) &* 4096
                localLogical &+= entry.logical_size
            }

            let name = worker.stageName(nameBytes)
            worker.files.append(StagedFile(nameStart: name.start, nameLength: name.length,
                                           logicalBytes: entry.logical_size,
                                           physicalBlocks: blocks,
                                           mtime: entry.mtime_sec, flags: flags))
        }

        // One acquisition covers the commit *and* the roll-up chain it triggers.
        let newSlots = arena.withLock { storage -> Range<UInt32> in
            let result = storage.commitChildren(parent: item.slot,
                                                nameBuffer: worker.nameBytes,
                                                files: worker.files,
                                                dirs: worker.dirs)
            if result.parentCompleted {
                var next: UInt32? = storage.completeDirectory(item.slot)
                while let slot = next { next = storage.completeDirectory(slot) }
            }
            return result.newDirectorySlots
        }

        entriesSeen.wrappingAdd(localEntries, ordering: .relaxed)
        directoriesSeen.wrappingAdd(localDirectories, ordering: .relaxed)
        physicalBytes.wrappingAdd(localPhysical, ordering: .relaxed)
        logicalBytes.wrappingAdd(localLogical, ordering: .relaxed)
        datalessCount.wrappingAdd(localDataless, ordering: .relaxed)
        hardlinkDuplicates.wrappingAdd(localDuplicates, ordering: .relaxed)
        truncatedPathCount.wrappingAdd(localTruncated, ordering: .relaxed)
        deniedCount.wrappingAdd(localDenied, ordering: .relaxed)

        let nextDepth = item.depth == .max ? item.depth : item.depth &+ 1
        var children: [DirectoryWork] = []
        children.reserveCapacity(worker.descendable.count)
        for candidate in worker.descendable {
            children.append(DirectoryWork(path: candidate.path,
                                          slot: newSlots.lowerBound &+ UInt32(candidate.index),
                                          depth: nextDepth))
        }
        return children
    }

    /// A directory that could not be opened after all — a TCC refusal the
    /// `faccessat` pre-flight does not see, or a directory deleted mid-walk.
    ///
    /// It must still be completed, or its parent's outstanding-child counter
    /// never reaches zero and the roll-up stalls for the rest of the run.
    private func handleUnreadable(_ item: DirectoryWork, errorCode: Int32) {
        let isPermission = errorCode == EACCES || errorCode == EPERM
        arena.withLock { storage in
            if isPermission { storage.noteDenied() }
            var next: UInt32? = storage.completeDirectory(item.slot)
            while let slot = next { next = storage.completeDirectory(slot) }
        }
        if isPermission {
            deniedCount.wrappingAdd(1, ordering: .relaxed)
        } else {
            LoupeLog.scan.debug("skipped directory: errno \(errorCode, privacy: .public)")
        }
    }

    /// Composes `parent/name`, or nil if the result would not fit in `PATH_MAX`.
    static func childPath(parent: [UInt8], name: UnsafeRawBufferPointer) -> [UInt8]? {
        let separator = UInt8(ascii: "/")
        let parentIsRoot = parent.count == 1 && parent[0] == separator
        let prefixLength = parentIsRoot ? 0 : parent.count
        let needed = prefixLength + 1 + name.count
        // PATH_MAX counts the terminating NUL, so a path of exactly PATH_MAX
        // bytes plus its NUL is already one too many.
        guard needed < Int(PATH_MAX) else { return nil }
        var path = [UInt8]()
        path.reserveCapacity(needed)
        if !parentIsRoot { path.append(contentsOf: parent) }
        path.append(separator)
        path.append(contentsOf: name)
        return path
    }
}

// MARK: - Per-thread scratch

/// Everything one walker thread reuses across every directory it visits: the
/// batch reader, its 256 KiB kernel buffer, and the staging arrays that let a
/// whole directory be committed in one lock acquisition.
private final class Worker {
    struct Descendable {
        let index: Int
        let path: [UInt8]
    }

    let reader: OpaquePointer
    private let buffer: UnsafeMutableRawPointer
    private let bufferBytes: Int
    private let measuresPrivateSize: Bool

    var nameBytes: [UInt8] = []
    var files: [StagedFile] = []
    var dirs: [StagedDir] = []
    var descendable: [Descendable] = []

    init?(bufferBytes: Int, measuresPrivateSize: Bool) {
        guard let reader = loupe_dir_reader_create() else { return nil }
        self.reader = reader
        self.bufferBytes = bufferBytes
        self.measuresPrivateSize = measuresPrivateSize
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: 8)
        nameBytes.reserveCapacity(8 * 1024)
        files.reserveCapacity(256)
        dirs.reserveCapacity(64)
        descendable.reserveCapacity(64)
    }

    func dispose() {
        loupe_dir_reader_destroy(reader)
        buffer.deallocate()
    }

    func reset() {
        nameBytes.removeAll(keepingCapacity: true)
        files.removeAll(keepingCapacity: true)
        dirs.removeAll(keepingCapacity: true)
        descendable.removeAll(keepingCapacity: true)
    }

    /// - Returns: 0, or the `errno` from `open`.
    func open(path: [UInt8]) -> Int32 {
        var terminated = path
        terminated.append(0)
        return terminated.withUnsafeBufferPointer { raw -> Int32 in
            guard let base = raw.baseAddress else { return EINVAL }
            return base.withMemoryRebound(to: CChar.self, capacity: raw.count) { cPath in
                loupe_dir_reader_open(reader, cPath, buffer, bufferBytes, measuresPrivateSize)
            }
        }
    }

    func close() { loupe_dir_reader_close(reader) }

    /// Copies a name into the staging buffer.
    ///
    /// Clipped to 255 bytes because the arena's `nameLength` is a `UInt8`.
    /// Measured: zero names above 255 bytes across ~2M real entries, but a
    /// truncating conversion that traps in production is not a bound worth
    /// betting on.
    func stageName(_ bytes: UnsafeRawBufferPointer) -> (start: UInt32, length: UInt8) {
        let start = UInt32(truncatingIfNeeded: nameBytes.count)
        let clipped = bytes.count > 255 ? UnsafeRawBufferPointer(rebasing: bytes[0..<255]) : bytes
        nameBytes.append(contentsOf: clipped)
        return (start, UInt8(clipped.count))
    }
}
