import Foundation
import LoupeCore

/// How prominently a shape is drawn while a search is running.
public enum SunburstSearchEmphasis: Sendable, Hashable {
    case match
    /// Not itself a match, but a match lives inside it. Kept legible so a hit
    /// four rings out is still visibly attached to the folder it is in.
    case onPathToMatch
    case unrelated

    /// Non-matches are dimmed, never hidden. Removing them would change the
    /// shape of the disk under the user's hands and cost them the spatial
    /// bearings that are the whole point of drawing it this way.
    public var fillOpacity: Double {
        switch self {
        case .match: 1
        case .onPathToMatch: 0.62
        case .unrelated: 0.28
        }
    }
}

/// A search over the names in a layout.
///
/// Pure and `Sendable`: the app owns the `.searchable` field and hands the text
/// down; this decides what it means. Case- and diacritic-insensitive, so
/// `cafe` finds `Café` and `RESUME` finds `résumé`.
public struct SunburstSearch: Sendable, Hashable {
    public let query: String
    /// Case- and diacritic-folded once, at init, rather than per name.
    let needle: String
    let needleBytes: [UInt8]
    let needleIsASCII: Bool

    public static let inactive = SunburstSearch(query: "")

    public init(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed
        // Locale-independent on purpose. A file name is not prose, and a search
        // that behaves differently in a Turkish locale than an English one is a
        // bug report nobody can reproduce.
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        needle = folded
        needleBytes = Array(folded.utf8)
        needleIsASCII = folded.allSatisfy(\.isASCII)
    }

    public var isActive: Bool { !query.isEmpty }

    /// Substring match, folded on both sides.
    ///
    /// The ASCII path exists because folding allocates a new string, and a
    /// keystroke in the search field re-tests every name in the layout — up to
    /// six thousand of them. Almost every path on a Mac is ASCII, and for those
    /// this walks the UTF-8 bytes and allocates nothing.
    public func matches(_ name: String) -> Bool {
        guard !needleBytes.isEmpty else { return false }
        if needleIsASCII, let quick = Self.asciiContains(name, needleBytes) { return quick }
        return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .contains(needle)
    }

    /// nil when `haystack` is not plain ASCII and the caller must fold it properly.
    static func asciiContains(_ haystack: String, _ needle: [UInt8]) -> Bool? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(haystack.utf8.count)
        for byte in haystack.utf8 {
            if byte >= 0x80 { return nil }
            // Lowercase in place; the needle was folded to lowercase already.
            bytes.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
        }
        guard needle.count <= bytes.count else { return false }
        let last = bytes.count - needle.count
        var start = 0
        while start <= last {
            var i = 0
            while i < needle.count, bytes[start + i] == needle[i] { i += 1 }
            if i == needle.count { return true }
            start += 1
        }
        return false
    }

    // MARK: - Against a layout

    public func result(in index: SunburstIndex) -> SunburstSearchResult {
        guard isActive else { return .inactive }
        var matched: Set<UInt32> = []
        var onPath: Set<UInt32> = []
        let navigator = SunburstNavigator(index: index)

        for ring in 0..<index.ringCount {
            let range = index.ringRanges[ring]
            for i in range {
                let wedge = index.wedges[i]
                guard matches(SunburstDescription.chartLabel(for: wedge)) else { continue }
                matched.insert(wedge.id)
                var position = SunburstPosition(ring: ring, offset: i - range.lowerBound)
                // Walk inward marking the containing folders. Stop the moment the
                // path is already marked: with many matches under one folder this
                // turns a per-match walk into one walk per distinct branch.
                while let parent = navigator.parent(of: position), let wedge = index[parent] {
                    if !onPath.insert(wedge.id).inserted { break }
                    position = parent
                }
            }
        }
        onPath.subtract(matched)
        return SunburstSearchResult(query: query, matched: matched, onPath: onPath)
    }

    public func result(in index: TreemapIndex) -> SunburstSearchResult {
        guard isActive else { return .inactive }
        var matched: Set<UInt32> = []
        var onPath: Set<UInt32> = []
        for (i, tile) in index.tiles.enumerated() {
            guard matches(SunburstDescription.chartLabel(for: tile.kind, name: tile.name)) else { continue }
            matched.insert(tile.id)
            var current = i
            while let parent = index.parentIndex(of: current) {
                if !onPath.insert(index.tiles[parent].id).inserted { break }
                current = parent
            }
        }
        onPath.subtract(matched)
        return SunburstSearchResult(query: query, matched: matched, onPath: onPath)
    }
}

/// Which shapes a query picked out, resolved once per layout and query rather
/// than per frame.
public struct SunburstSearchResult: Sendable, Equatable {
    public let query: String
    public let matched: Set<UInt32>
    public let onPath: Set<UInt32>

    public static let inactive = SunburstSearchResult(query: "", matched: [], onPath: [])

    public init(query: String, matched: Set<UInt32>, onPath: Set<UInt32>) {
        self.query = query
        self.matched = matched
        self.onPath = onPath
    }

    public var matchCount: Int { matched.count }

    /// A query with no hits does not dim anything. Greying out the whole chart
    /// says nothing that the match count does not already say, and it makes a
    /// working window look broken.
    public var isDimming: Bool { !query.isEmpty && !matched.isEmpty }

    public func emphasis(for id: UInt32) -> SunburstSearchEmphasis {
        guard isDimming else { return .match }
        if matched.contains(id) { return .match }
        if onPath.contains(id) { return .onPathToMatch }
        return .unrelated
    }

    public func opacity(for id: UInt32) -> Double {
        isDimming ? emphasis(for: id).fillOpacity : 1
    }
}
