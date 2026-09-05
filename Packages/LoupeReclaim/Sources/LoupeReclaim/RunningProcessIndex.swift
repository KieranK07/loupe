import AppKit
import Darwin
import Foundation
import LoupeCore

/// Everything that is running right now, in the two forms the guard needs:
/// bundle roots to refuse deletion inside, and names to answer "is Xcode open".
///
/// `NSWorkspace.runningApplications` on its own is not enough, and the spec
/// proves it on this machine: neither Xcode.app nor Simulator.app appeared in
/// that list while `CoreSimulatorService`, `simdiskimaged` and
/// `SimulatorTrampoline` were all live. A workspace-only check would have
/// reported the simulator as idle and offered to delete its state.
public struct RunningProcessIndex: Sendable {

    /// Bundle roots and bare executables, keyed by `(dev, ino)` so a symlinked
    /// or firmlinked spelling of the same bundle still matches.
    public let occupiedRoots: [InodeKey: String]
    /// The same roots as canonical components, for the case where an ancestor
    /// cannot be `lstat`ed but its path is still known.
    public let occupiedComponents: [[String]]
    public let bundleIdentifiers: Set<String>
    /// Lowercased basenames of every executable we could resolve. This is how
    /// `xcodebuild`, `brew`, `node` and `com.docker.backend` are detected —
    /// none of them has an app to appear in the workspace list.
    public let executableNames: Set<String>
    public let capturedAt: Date
    /// Processes whose path `proc_pidpath` refused to report, almost always
    /// another user's. Surfaced because it bounds what this index can promise.
    public let unresolvedProcessCount: Int

    public func isRunning(bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }

    public func isRunning(executableNamed name: String) -> Bool {
        executableNames.contains(name.lowercased())
    }

    /// Bundle extensions worth walking up to. `.framework` and `.xpc` are not
    /// optional extras: the CoreSimulator processes above live inside a
    /// `.framework`, and a Chromium renderer lives inside a nested `.app` whose
    /// only useful answer is the parent application.
    private static let bundleSuffixes = [".app", ".xpc", ".framework", ".appex", ".bundle"]

    public static func snapshot(canonicalizer: PathCanonicalizer) -> RunningProcessIndex {
        var roots: [InodeKey: String] = [:]
        var components: [[String]] = []
        var identifiers: Set<String> = []
        var executables: Set<String> = []
        var unresolved = 0

        func record(path: String, label: String) {
            guard let canonical = try? canonicalizer.canonicalize(path: path) else { return }
            if let identity = FileIdentity.lstat(canonical.realPath) {
                let key = InodeKey(identity)
                if roots[key] == nil { roots[key] = label }
            }
            components.append(canonical.components)
        }

        // --- Stage 1: every GUI application -------------------------------
        for application in NSWorkspace.shared.runningApplications {
            if let identifier = application.bundleIdentifier { identifiers.insert(identifier) }
            guard let bundle = application.bundleURL else { continue }
            let label = application.localizedName ?? bundle.lastPathComponent
            record(path: bundle.path(percentEncoded: false), label: label)
        }

        // --- Stage 2: every process, GUI or not ---------------------------
        for path in executablePaths(unresolved: &unresolved) {
            let name = (path as NSString).lastPathComponent
            executables.insert(name.lowercased())
            // Walk up to the outermost enclosing bundle, not the innermost:
            // "Claude Helper (Renderer).app" inside "Claude.app" must protect
            // Claude.app, or a cache sweep could take the parent out from under
            // a running helper.
            if let bundle = outermostBundle(of: path) {
                record(path: bundle, label: (bundle as NSString).lastPathComponent)
            }
            record(path: path, label: name)
        }

        return RunningProcessIndex(occupiedRoots: roots, occupiedComponents: components,
                                   bundleIdentifiers: identifiers, executableNames: executables,
                                   capturedAt: .now, unresolvedProcessCount: unresolved)
    }

    /// - Returns: the resolvable executable path of every live process.
    ///
    /// `proc_pidpath` returns 0 for processes owned by another user when we are
    /// not root, and Loupe never escalates. Those are counted, not hidden: a
    /// bundle in use only by another user's process may not be detected, and
    /// that limit belongs in the report rather than in a footnote.
    private static func executablePaths(unresolved: inout Int) -> [String] {
        let probe = proc_listallpids(nil, 0)
        guard probe > 0 else { return [] }
        // Slack, because the process count can grow between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(probe) + 64)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.size)
        let written = proc_listallpids(&pids, byteCount)
        guard written > 0 else { return [] }

        let maximumPathBytes = 4 * Int(MAXPATHLEN)   // PROC_PIDPATHINFO_MAXSIZE
        var buffer = [CChar](repeating: 0, count: maximumPathBytes)
        var paths: [String] = []
        paths.reserveCapacity(Int(written))

        for index in 0..<Int(written) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let length = proc_pidpath(pid, &buffer, UInt32(maximumPathBytes))
            guard length > 0 else { unresolved += 1; continue }
            paths.append(decodePath(buffer, length: length))
        }
        return paths
    }

    /// The outermost ancestor whose name ends in a bundle extension.
    static func outermostBundle(of path: String) -> String? {
        let parts = PathComponents.split(path)
        for index in parts.indices where bundleSuffixes.contains(where: {
            parts[index].lowercased().hasSuffix($0)
        }) {
            return PathComponents.join(Array(parts[0...index]))
        }
        return nil
    }
}
