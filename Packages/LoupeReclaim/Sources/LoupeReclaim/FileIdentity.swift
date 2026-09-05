import Darwin
import Foundation
import LoupeCore

/// What one `lstat` tells us about a path.
///
/// `lstat`, never `stat`: when the decision is "may this be deleted", the
/// question is about the symlink itself, because the symlink is what would be
/// moved. Following it would answer a question nobody asked.
public struct FileIdentity: Sendable, Hashable {
    public let device: Int32
    public let inode: UInt64
    public let flags: UInt32
    public let mode: UInt16
    public let uid: uid_t
    /// `st_blocks * 512`. The only size figure this pillar produces for a single
    /// file, and zero for an iCloud placeholder, which is the correct answer
    /// (R4) rather than a rounding error.
    public let physicalBytes: UInt64
    public let logicalBytes: UInt64
    public let modified: Date

    public var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    public var isSymlink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    public var isRegularFile: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }

    public init(device: Int32, inode: UInt64, flags: UInt32, mode: UInt16, uid: uid_t,
                physicalBytes: UInt64, logicalBytes: UInt64, modified: Date) {
        self.device = device; self.inode = inode; self.flags = flags; self.mode = mode
        self.uid = uid; self.physicalBytes = physicalBytes; self.logicalBytes = logicalBytes
        self.modified = modified
    }

    public static func lstat(_ path: String) -> FileIdentity? {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        return FileIdentity(
            device: Int32(bitPattern: UInt32(info.st_dev)),
            inode: UInt64(info.st_ino),
            flags: info.st_flags,
            mode: UInt16(info.st_mode),
            uid: info.st_uid,
            physicalBytes: UInt64(clamping: info.st_blocks) &* 512,
            logicalBytes: UInt64(clamping: info.st_size),
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                           + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9))
    }

    public static func lstat(_ url: URL) -> FileIdentity? {
        lstat(url.path(percentEncoded: false))
    }
}

/// `(st_dev, st_ino)` — the pair that names a file regardless of how it was
/// spelled. Every identity comparison in the safety engine is on this, because
/// a symlink, a hardlink and a firmlink all change the spelling and none of them
/// changes this.
public struct InodeKey: Sendable, Hashable {
    public let device: Int32
    public let inode: UInt64
    public init(device: Int32, inode: UInt64) { self.device = device; self.inode = inode }
    public init(_ identity: FileIdentity) {
        self.init(device: identity.device, inode: identity.inode)
    }
}

/// The `st_flags` bits this pillar acts on.
///
/// Values are restated from `<sys/stat.h>` and asserted against the Darwin
/// constants in the tests, so a future SDK that renumbers one of them fails the
/// suite rather than silently disarming a guard.
public enum ProtectionFlags {
    public static let sfRestricted: UInt32 = 0x0008_0000
    public static let sfDataless:   UInt32 = 0x4000_0000
    public static let sfNoUnlink:   UInt32 = 0x0010_0000
    public static let sfImmutable:  UInt32 = 0x0002_0000
    public static let sfFirmlink:   UInt32 = 0x0080_0000
    public static let ufImmutable:  UInt32 = 0x0000_0002
    public static let ufDataVault:  UInt32 = 0x0000_0080

    /// Flags that condemn the whole subtree beneath the file that carries them.
    public static let subtreeDenying: UInt32 = sfRestricted | ufDataVault
    /// Flags that condemn only the file that carries them.
    public static let itemDenying: UInt32 =
        sfDataless | sfNoUnlink | sfImmutable | ufImmutable | sfFirmlink
}

/// Turns off iCloud dataless-file materialisation for this process.
///
/// `LoupeFS` does this too, on the first scan. It is repeated here because the
/// reclaim pillar can run without a scan ever having started, and materialising
/// a placeholder while deciding whether to delete it would be the single worst
/// thing this code could do: it would download the user's file in order to ask
/// whether to throw it away.
enum DatalessPolicy {
    static let disabled: Bool = {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                       IOPOL_SCOPE_PROCESS,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        return true
    }()
}

/// Decodes a NUL-terminated C buffer of known length.
///
/// `String(cString:)` over a `[CChar]` is deprecated and, more to the point,
/// scans for a terminator the kernel already told us the position of. APFS names
/// are not required to be valid UTF-8, so this repairs rather than rejects: a
/// path Loupe cannot spell is still a path it must be able to refuse.
func decodePath(_ buffer: [CChar], length: Int32) -> String {
    guard length > 0 else { return "" }
    let count = min(Int(length), buffer.count)
    return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
