import Foundation
import Synchronization

/// Identity of a file on disk. Two directory entries with the same pair are the
/// same bytes seen twice.
struct InodeKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

/// Remembers which inodes have already been charged for their bytes.
///
/// Consulted only for entries whose link count exceeds one — 74,701 of the
/// 1.97M entries measured on a real home directory — so the common file costs
/// nothing at all. Ignoring hard links overcounts `Xcode.app` by 5.6%.
///
/// Sixty-four independently locked shards, because eight walker threads hitting
/// one set would serialise on exactly the directories (developer toolchains,
/// framework bundles) that contain the most hard links.
final class ShardedInodeSet: @unchecked Sendable {
    /// `Mutex` is non-copyable and so cannot live in an array directly; one
    /// class box per shard is the cheapest way to get an indexable row of them.
    private final class Shard {
        let seen: Mutex<Set<InodeKey>>
        init(reserving capacity: Int) {
            var set = Set<InodeKey>()
            if capacity > 0 { set.reserveCapacity(capacity) }
            seen = Mutex(set)
        }
    }

    private static let shardCount = 64
    private let shards: [Shard]

    init(reservingCapacity capacity: Int = 0) {
        let perShard = capacity / Self.shardCount
        shards = (0..<Self.shardCount).map { _ in Shard(reserving: perShard) }
    }

    /// - Returns: true if this is the first sighting, so the caller owns the
    ///   bytes; false if the inode has already been counted elsewhere.
    func claim(device: Int32, inode: UInt64) -> Bool {
        let key = InodeKey(device: device, inode: inode)
        // Inode numbers are dense and sequential, so the low bits alone would
        // pile consecutive files into one shard. Fibonacci hashing spreads them.
        let mixed = inode &* 0x9E37_79B9_7F4A_7C15
        let shard = Int(truncatingIfNeeded: mixed >> 58) & (Self.shardCount - 1)
        return shards[shard].seen.withLock { $0.insert(key).inserted }
    }
}
