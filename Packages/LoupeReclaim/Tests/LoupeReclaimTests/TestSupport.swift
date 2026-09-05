import Darwin
import Foundation
import LoupeCore
import Testing
@testable import LoupeReclaim

/// A throwaway tree under `/private/tmp`.
///
/// `/private/tmp` and not `NSTemporaryDirectory()` on purpose: the per-user
/// temporary directory lives under `/private/var/folders`, which the blocklist
/// denies outright, so every candidate built there would be refused for the
/// wrong reason and the tests would prove nothing.
///
/// Nothing in this suite ever creates, evaluates or trashes a path outside the
/// directory it made.
final class TempTree {
    let root: URL

    init(_ label: String = "tree") throws {
        let base = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
        root = base.appending(component: "loupe-reclaim-\(label)-\(UUID().uuidString)",
                              directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let url = root.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 64) throws -> URL {
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x4C, count: bytes).write(to: url)
        return url
    }

    /// A file whose name is created byte-for-byte, bypassing anything that might
    /// normalise it on the way in.
    @discardableResult
    func rawNamedFile(in directory: URL, name: String, bytes: Int = 8) throws -> URL {
        let url = directory.appending(component: name, directoryHint: .notDirectory)
        try Data(repeating: 0x4C, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func symlink(_ relative: String, to destination: String) throws -> URL {
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path(percentEncoded: false),
                                                   withDestinationPath: destination)
        return url
    }

    @discardableResult
    func hardlink(_ relative: String, to existing: URL) throws -> URL {
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let code = link(existing.path(percentEncoded: false), url.path(percentEncoded: false))
        try #require(code == 0, "link() failed with errno \(errno)")
        return url
    }

    /// The tree's own path with symlinks resolved, which is what every rule is
    /// evaluated against.
    var realRoot: URL {
        URL(filePath: PathCanonicalizer.resolveDeepest(root.path(percentEncoded: false)).path,
            directoryHint: .isDirectory)
    }
}

/// A `SafetyScope` covering one directory, for tests that are about a guard
/// rather than about the catalog.
func scope(_ id: String, roots: [URL], excluding: [String] = [],
           refusing: [String] = []) -> SafetyScope {
    SafetyScope(
        targetID: id,
        roots: roots.map {
            PathComponents.normalizedComponents(
                of: PathCanonicalizer.resolveDeepest($0.path(percentEncoded: false)).path)
        },
        excludedComponents: excluding,
        refuseWhileRunning: refusing)
}

extension SafetyVerdict {
    var refusalRule: BlocklistRule? { rule }
}
