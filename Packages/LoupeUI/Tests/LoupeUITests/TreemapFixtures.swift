import CoreGraphics
import Foundation
import LoupeCore
@testable import LoupeUI

/// A stand-in for text metrics, so the label tests are hermetic.
///
/// Roughly the 10pt system font: an average advance a shade over five points
/// and a twelve-point line box. The real font is measured in the render smoke
/// tests; what these numbers are for is testing the *geometry*, which must not
/// depend on which machine is running it.
enum FakeText {
    static let advance: Double = 5.4
    static let lineHeight: Double = 12

    /// One line, however long. What the new pass asks for, because it does its
    /// own truncation.
    static func intrinsic(_ text: String) -> CGSize {
        CGSize(width: Double(text.count) * advance, height: lineHeight)
    }

    /// What SwiftUI hands back when text is measured against a bounded
    /// proposal: it wraps. This is how the old label pass measured, and it is
    /// half of why long names spilled — a name that "fits" a 30pt budget by
    /// wrapping onto five lines does not fit a wedge at all.
    static func wrapped(_ text: String, in proposal: CGSize) -> CGSize {
        let width = Double(text.count) * advance
        guard proposal.width > 0, width > proposal.width else {
            return CGSize(width: width, height: lineHeight)
        }
        let lines = (width / proposal.width).rounded(.up)
        return CGSize(width: proposal.width, height: lineHeight * lines)
    }
}

/// Names of the shape that actually breaks a label pass: caches and containers
/// whose members differ only in the middle.
enum FixtureNames {
    static let pool: [String] = [
        "C2296EE4-908B-4BDA-8176-CA8439D5016A",
        "C2296EE4-908B-4BDA-8176-CA8439D5017B",
        "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        "com.apple.MobileSoftwareUpdate.UpdateBrainService",
        "Xcode-15.4.0-Release-Candidate.xip",
        "node_modules",
        "Library",
        "Photos Library.photoslibrary",
        "iOS DeviceSupport",
        "a",
        "Caches",
        "com.google.Chrome.helper.plugin.dSYM",
    ]

    static func name(_ index: Int) -> String { pool[index % pool.count] }
}

enum TreemapFixture {
    /// Nested slice-and-dice. Not squarified — that is `TreemapLayouter`'s job,
    /// over in LoupeTree — but it satisfies everything the *renderer's* contract
    /// depends on: children strictly inside their parent, siblings disjoint,
    /// tiles emitted outermost-first.
    static func layout(levels: [Int], seed: UInt64 = 20_260_827,
                       generation: UInt64 = 1,
                       breadcrumb: [Breadcrumb] = [Breadcrumb(node: .directory(0), name: "Data"),
                                                   Breadcrumb(node: .directory(1), name: "Users")],
                       isComplete: Bool = true,
                       kindForDepth: (Int, Int) -> WedgeKind = { _, _ in .real }) -> TreemapLayout {
        var rng = SplitMix64(seed: seed)
        var tiles: [TreemapTile] = []
        var slot: UInt32 = 100
        var parents: [(frame: TreemapRect, seed: UInt16, horizontal: Bool)] =
            [(TreemapRect(x: 0, y: 0, width: 1, height: 1), 0, true)]

        for (depth, count) in levels.enumerated() {
            var next: [(frame: TreemapRect, seed: UInt16, horizontal: Bool)] = []
            for parent in parents {
                var weights: [Double] = []
                for _ in 0..<count { weights.append(Double.random(in: 0.3...4, using: &rng)) }
                let total = weights.reduce(0, +)
                var cursor = parent.horizontal ? parent.frame.x : parent.frame.y
                let span = parent.horizontal ? parent.frame.width : parent.frame.height
                for (child, weight) in weights.enumerated() {
                    let isLast = child == weights.count - 1
                    let extent = span * weight / total
                    let end = isLast
                        ? (parent.horizontal ? parent.frame.maxX : parent.frame.maxY)
                        : cursor + extent
                    let frame = parent.horizontal
                        ? TreemapRect(x: cursor, y: parent.frame.y,
                                      width: end - cursor, height: parent.frame.height)
                        : TreemapRect(x: parent.frame.x, y: cursor,
                                      width: parent.frame.width, height: end - cursor)
                    let hue = depth == 0 ? UInt16(child) : parent.seed
                    tiles.append(TreemapTile(node: .directory(slot), frame: frame,
                                             depth: UInt8(depth),
                                             physicalBytes: UInt64((frame.area * 1_000_000_000).rounded()),
                                             logicalBytes: UInt64((frame.area * 3_000_000_000).rounded()),
                                             itemCount: UInt32(child + 1),
                                             name: FixtureNames.name(Int(slot)),
                                             kind: kindForDepth(depth, child),
                                             colorSeed: hue))
                    next.append((frame, hue, !parent.horizontal))
                    slot += 1
                    cursor = end
                }
            }
            parents = next
        }

        return TreemapLayout(generation: generation,
                             focus: .directory(0),
                             focusPath: "/System/Volumes/Data/Users",
                             breadcrumb: breadcrumb,
                             tiles: tiles,
                             totalPhysicalBytes: 1_000_000_000,
                             totalLogicalBytes: 3_000_000_000,
                             scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             isComplete: isComplete)
    }

    /// An exact `columns` × `rows` grid at one depth. Hand-checkable, so the
    /// navigator's idea of "the tile to the left" can be asserted against
    /// arithmetic rather than against another implementation of itself.
    static func grid(columns: Int, rows: Int) -> TreemapLayout {
        var tiles: [TreemapTile] = []
        var slot: UInt32 = 100
        let width = 1.0 / Double(columns), height = 1.0 / Double(rows)
        for row in 0..<rows {
            for column in 0..<columns {
                tiles.append(TreemapTile(
                    node: .directory(slot),
                    frame: TreemapRect(x: Double(column) * width, y: Double(row) * height,
                                       width: width, height: height),
                    depth: 0, physicalBytes: 1_000, logicalBytes: 1_000, itemCount: 1,
                    name: "r\(row)c\(column)", kind: .real, colorSeed: UInt16(column)))
                slot += 1
            }
        }
        return TreemapLayout(generation: 1, focus: .directory(0), focusPath: "/",
                             breadcrumb: [Breadcrumb(node: .directory(0), name: "Root")],
                             tiles: tiles, totalPhysicalBytes: 1_000_000,
                             totalLogicalBytes: 1_000_000,
                             scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             isComplete: true)
    }

    static func metrics(width: Double = 900, height: Double = 600) -> TreemapMetrics {
        TreemapMetrics(bounds: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
