import Darwin
import Foundation
import Synchronization

/// A path reduced to the one form every rule is evaluated against.
public struct CanonicalPath: Sendable, Hashable {
    /// The post-`realpath`, pre-firmlink-rewrite path.
    ///
    /// This — not `components` — is what would be handed to `trashItem`, because
    /// the firmlink rewrite is a matching device and the user was shown the
    /// other spelling. See §B.3 of the reclaim spec.
    public let realPath: String
    /// NFC components after the firmlink rewrite. Matching uses only these.
    public let components: [String]
    /// Whether the containing volume compares names case-insensitively.
    public let caseInsensitive: Bool
    /// False when the path does not exist and only its deepest existing
    /// ancestor could be resolved.
    public let exists: Bool

    /// The rewritten path, for logs and for explaining a refusal. Never the
    /// thing that gets deleted.
    public var matchedPath: String { PathComponents.join(components) }

    public var url: URL { URL(filePath: realPath, directoryHint: .inferFromPath) }
}

public enum PathRejection: Error, Sendable, Hashable, CaseIterable {
    case notAFileURL
    case notAbsolute
    case empty
    case containsNUL
}

/// Turns any URL into a `CanonicalPath`.
///
/// One instance per `SafetyEngine`; the firmlink table and the per-volume case
/// rules are read once and cached for the life of the process, as §B.3 requires.
public final class PathCanonicalizer: Sendable {

    public let firmlinks: FirmlinkTable
    /// `st_dev` -> case-insensitive. Keyed by device rather than by path so one
    /// query answers for every file on the volume.
    private let caseRules = Mutex<[Int32: Bool]>([:])

    public init(firmlinks: FirmlinkTable = .load()) {
        self.firmlinks = firmlinks
    }

    public func canonicalize(_ url: URL) throws(PathRejection) -> CanonicalPath {
        guard url.isFileURL else { throw .notAFileURL }
        return try canonicalize(path: url.path(percentEncoded: false))
    }

    public func canonicalize(path: String) throws(PathRejection) -> CanonicalPath {
        guard !path.isEmpty else { throw .empty }
        guard !path.utf8.contains(0) else { throw .containsNUL }
        guard path.hasPrefix("/") else { throw .notAbsolute }

        let (resolved, exists) = Self.resolveDeepest(path)
        let device = Self.deviceOf(resolved)
        let insensitive = caseInsensitivity(device: device, path: resolved)
        let raw = PathComponents.normalizedComponents(of: resolved)
        let rewritten = firmlinks.normalized(raw, caseInsensitive: insensitive)
        return CanonicalPath(realPath: resolved, components: rewritten,
                             caseInsensitive: insensitive, exists: exists)
    }

    // MARK: - realpath

    /// `realpath(3)` on the longest prefix that exists, with the remainder
    /// re-applied lexically.
    ///
    /// `URL.resolvingSymlinksInPath()` is not a substitute: it does not consult
    /// the filesystem for every component, so a symlink in the middle of a path
    /// survives it. And a plain `realpath` of the whole path fails outright when
    /// the tail has been deleted — which is exactly the case the executor must
    /// still be able to reason about, so the failure is handled rather than
    /// propagated.
    static func resolveDeepest(_ path: String) -> (path: String, exists: Bool) {
        if let resolved = realpath(path) { return (resolved, true) }

        // Deliberately un-folded: `..` may only be collapsed lexically once we
        // know no symlink stands in the way, which is true of the tail (it does
        // not exist) and not true of the prefix (realpath handles that).
        let raw = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var depth = raw.count
        while depth > 0 {
            depth -= 1
            let prefix = PathComponents.join(Array(raw[0..<depth]))
            guard let resolvedPrefix = realpath(prefix) else { continue }
            let tail = raw[depth...].joined(separator: "/")
            let combined = resolvedPrefix + (resolvedPrefix.hasSuffix("/") ? "" : "/") + tail
            return (PathComponents.join(PathComponents.split(combined)), false)
        }
        return (PathComponents.join(PathComponents.split(path)), false)
    }

    private static func realpath(_ path: String) -> String? {
        guard let buffer = Darwin.realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    // MARK: - Case sensitivity

    private static func deviceOf(_ path: String) -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Int32(bitPattern: UInt32(info.st_dev))
    }

    /// Asks the volume, not the code.
    ///
    /// The query is made against the volume's mount point rather than the file:
    /// reading resource values on a candidate risks materialising an iCloud
    /// placeholder, and a mount point is never one.
    private func caseInsensitivity(device: Int32, path: String) -> Bool {
        if let cached = caseRules.withLock({ $0[device] }) { return cached }

        var answer = true   // The boot volume's behaviour, and the safe default:
                            // it makes deny rules match more, not fewer, paths.
        var info = statfs()
        if statfs(path, &info) == 0 {
            let mount = withUnsafeBytes(of: &info.f_mntonname) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                return bytes.baseAddress.map { String(cString: $0) } ?? "/"
            }
            let url = URL(filePath: mount, directoryHint: .isDirectory)
            if let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
               let sensitive = values.volumeSupportsCaseSensitiveNames {
                answer = !sensitive
            }
        }
        caseRules.withLock { $0[device] = answer }
        return answer
    }
}
