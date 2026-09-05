import Foundation

/// The APFS firmlink map, read from `/usr/share/firmlinks`.
///
/// A firmlink is the one aliasing route `realpath(3)` does not collapse. On this
/// machine `/Users/x/.Trash` and `/System/Volumes/Data/Users/x/.Trash` are the
/// same inode on the same device, and `realpath` returns both unchanged. A guard
/// that matched only on the text of a canonical path would therefore refuse
/// `/Users/x/.Trash` and cheerfully accept the other spelling of it.
///
/// The file is tab-separated: an absolute path on the system volume, then the
/// same location relative to the Data volume root.
public struct FirmlinkTable: Sendable, Hashable {

    /// `(systemComponents, dataComponents)` pairs, longest data path first so
    /// `System/Library/Caches` is tried before a hypothetical `System`.
    public let entries: [(system: [String], data: [String])]

    public static let defaultPath = "/usr/share/firmlinks"

    public init(entries: [(system: [String], data: [String])]) {
        self.entries = entries.sorted { $0.data.count > $1.data.count }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.entries.count == b.entries.count
            && zip(a.entries, b.entries).allSatisfy { $0.system == $1.system && $0.data == $1.data }
    }

    public func hash(into hasher: inout Hasher) {
        for entry in entries { hasher.combine(entry.system); hasher.combine(entry.data) }
    }

    /// Reads and parses the table. Never throws: the file lives on the sealed
    /// system volume and a future macOS may move it, and an unreadable table is
    /// a reason to fall back to the bare prefix strip, not a reason to refuse to
    /// run. Failing open is what is forbidden, and the fallback does not.
    public static func load(from path: String = FirmlinkTable.defaultPath) -> FirmlinkTable {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            LoupeLogReclaim.security.notice(
                "firmlink table unreadable at \(path, privacy: .public); using the bare /System/Volumes/Data prefix strip")
            return FirmlinkTable(entries: [])
        }
        var parsed: [(system: [String], data: [String])] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let system = PathComponents.normalizedComponents(of: String(fields[0]))
            let data = PathComponents.normalizedComponents(of: String(fields[1]))
            guard !system.isEmpty, !data.isEmpty else { continue }
            parsed.append((system: system, data: data))
        }
        return FirmlinkTable(entries: parsed)
    }

    /// Rewrites a `/System/Volumes/Data/...` path to the spelling the rest of the
    /// system uses. Anything else is returned unchanged.
    ///
    /// `/System/Volumes/Data` on its own becomes `[]` — the Data volume root,
    /// which is `/` as far as every rule here is concerned.
    public func normalized(_ components: [String], caseInsensitive: Bool) -> [String] {
        let prefix = ["System", "Volumes", "Data"]
        guard PathComponents.matchesSubtree(candidate: components, rule: prefix,
                                            caseInsensitive: caseInsensitive) else {
            return components
        }
        let rest = Array(components.dropFirst(prefix.count))
        for entry in entries where PathComponents.matchesSubtree(
            candidate: rest, rule: entry.data, caseInsensitive: caseInsensitive) {
            return entry.system + rest.dropFirst(entry.data.count)
        }
        // No table entry claims this path, so it is ordinary Data-volume
        // storage reached the long way round: strip the prefix and evaluate it
        // where it really lives.
        return rest
    }
}
