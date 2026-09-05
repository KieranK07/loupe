import Darwin
import Foundation

/// Turns a catalog pattern into the concrete paths that exist right now.
///
/// Expansion is done here rather than by a shell, because there is no shell in
/// this app: `*` is matched with `fnmatch(3)` against one directory entry at a
/// time, never against a joined path, so a pattern cannot escape the directory
/// it is being expanded in.
public enum PatternExpander {

    /// The result of expanding one pattern, keeping the two facts R7 needs
    /// apart: whether the place exists, and whether anything is in it.
    public struct Expansion: Sendable, Hashable {
        /// The longest leading run of literal components — the directory the
        /// pattern is anchored to, and the target's scope root.
        public let root: String
        public let rootExists: Bool
        public let matches: [String]
    }

    /// Directories a `**` search never enters.
    ///
    /// `node_modules` is the important one: without it, entry 19 finds every
    /// nested dependency tree inside every other one and counts the same bytes
    /// repeatedly. `Library` keeps the search out of application storage that
    /// belongs to other catalog entries.
    public static let neverDescend: Set<String> = [
        "node_modules", ".git", "Library", ".Trash", ".build", "Pods",
        ".venv", "venv", "vendor", ".gradle", ".cargo", "DerivedData"
    ]

    public static func expand(pattern: String, maximumDepth: Int = 0) -> Expansion {
        let components = pattern.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let literalCount = components.prefix { !isGlob($0) }.count
        let root = PathComponents.join(Array(components[0..<literalCount]))
        let rootExists = exists(root)

        guard rootExists else { return Expansion(root: root, rootExists: false, matches: []) }
        guard literalCount < components.count else {
            // A fully literal pattern names one path, and it is there.
            return Expansion(root: root, rootExists: true, matches: [root])
        }

        var frontier = [root]
        for index in literalCount..<components.count {
            let component = components[index]
            var next: [String] = []
            if component == "**" {
                for base in frontier {
                    next.append(contentsOf: descendants(of: base, maximumDepth: maximumDepth))
                }
            } else {
                for base in frontier {
                    for name in entries(of: base) where matches(name: name, pattern: component) {
                        next.append(base + "/" + name)
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return Expansion(root: root, rootExists: true, matches: frontier.sorted())
    }

    static func isGlob(_ component: String) -> Bool {
        component.contains("*") || component.contains("?") || component.contains("[")
    }

    /// Whole-name match, one directory entry at a time.
    ///
    /// `fnmatch` with no flags, so a leading dot is matched by `*` — `.npm` and
    /// `.Trash` are both real catalog paths and excluding them would be wrong.
    static func matches(name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    /// `base` itself plus every directory beneath it, to `maximumDepth` levels,
    /// never following a symlink.
    static func descendants(of base: String, maximumDepth: Int) -> [String] {
        var found = [base]
        var frontier = [(path: base, depth: 0)]
        while let current = frontier.popLast() {
            guard current.depth < maximumDepth else { continue }
            for name in entries(of: current.path) where !neverDescend.contains(name) {
                let child = current.path + "/" + name
                // lstat, so a symlink to a directory is recorded but never
                // walked through. That is what keeps a symlink loop from
                // becoming an expansion loop.
                guard let identity = FileIdentity.lstat(child), identity.isDirectory else {
                    continue
                }
                found.append(child)
                frontier.append((child, current.depth + 1))
            }
        }
        return found
    }

    /// One directory's entry names, without `.` or `..`.
    ///
    /// `opendir`/`readdir` rather than `FileManager.contentsOfDirectory`, whose
    /// URL results carry resource values that can materialise an iCloud
    /// placeholder. Nothing here opens a file.
    static func entries(of directory: String) -> [String] {
        guard let handle = opendir(directory) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                guard let base = bytes.baseAddress else { return "" }
                return String(cString: base)
            }
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
