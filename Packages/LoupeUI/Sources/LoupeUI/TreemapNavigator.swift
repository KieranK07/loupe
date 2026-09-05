import CoreGraphics
import Foundation
import LoupeCore

/// Keyboard movement over a treemap, computed from tile geometry alone.
///
/// The sunburst's arrows mean "next sibling round the ring" and "one level in
/// or out", which is the natural reading of a chart whose depth *is* a
/// direction. A treemap has no such axis — depth is stacking, not position — so
/// the arrows mean what they look like they mean: move to the nearest tile that
/// way, at the level you are already on.
public struct TreemapNavigator: Sendable {
    public enum Move: Sendable, Hashable, CaseIterable {
        case left, right, up, down
        /// Into the largest tile nested inside this one. Not on an arrow key by
        /// itself — the four arrows are spatial here — but the deeper levels
        /// have to stay reachable without a pointer.
        case deeper
        /// Back out to the tile this one sits inside.
        case shallower
    }

    public let index: TreemapIndex
    /// Width ÷ height of the drawn map. Normalised coordinates are unit-free,
    /// so without this "nearest" would mean nearest in a squashed space and the
    /// arrows would feel wrong in any window that is not square.
    public let aspectRatio: Double

    /// How much a candidate is penalised for not lining up with the tile you
    /// are leaving. Three is enough that a tile straight across a wide gap
    /// still beats a nearer one in the next row up, which is what the eye does.
    static let strayWeight: Double = 3

    /// A gentler pull towards whatever is most nearly level. Two tiles in
    /// neighbouring rows both *touch* the row you are on, so the gap term reads
    /// zero for both and cannot separate them; without this, "right" from the
    /// middle of a grid could step diagonally.
    static let alignmentWeight: Double = 0.25

    public init(index: TreemapIndex, aspectRatio: Double = 1) {
        self.index = index
        self.aspectRatio = aspectRatio > 0 ? aspectRatio : 1
    }

    /// Where the keyboard lands when the map is focused with nothing selected:
    /// the biggest thing at the outermost level, which is where the eye already is.
    public func initialFocus() -> TreemapPosition? {
        for depth in 0..<index.depthCount {
            if let position = largest(atDepth: depth) { return position }
        }
        return nil
    }

    public func largest(atDepth depth: Int) -> TreemapPosition? {
        guard index.depthRanges.indices.contains(depth) else { return nil }
        let range = index.depthRanges[depth]
        guard !range.isEmpty else { return nil }
        var best = range.lowerBound
        for i in range where index.tiles[i].frame.area > index.tiles[best].frame.area { best = i }
        return TreemapPosition(depth: depth, offset: best - range.lowerBound)
    }

    public func destination(from position: TreemapPosition, move: Move) -> TreemapPosition? {
        switch move {
        case .deeper: largestChild(of: position)
        case .shallower: index.parent(of: position)
        default: nearest(from: position, move: move)
        }
    }

    public func largestChild(of position: TreemapPosition) -> TreemapPosition? {
        guard let parent = index.tileIndex(of: position) else { return nil }
        let depth = position.depth + 1
        guard index.depthRanges.indices.contains(depth) else { return nil }
        var best: Int?
        for i in index.depthRanges[depth] where index.parentIndex(of: i) == parent {
            if best == nil || index.tiles[i].frame.area > index.tiles[best!].frame.area { best = i }
        }
        return best.flatMap { index.position(at: $0) }
    }

    /// Nearest tile at the same depth in the given direction.
    ///
    /// Scored on two numbers: how far it is along the direction of travel, and
    /// how far it strays across it. The stray term is a *gap*, not a difference
    /// of centres — a tall neighbour whose span still overlaps the tile you are
    /// leaving counts as straight ahead, however far its middle is from yours.
    private func nearest(from position: TreemapPosition, move: Move) -> TreemapPosition? {
        guard let currentIndex = index.tileIndex(of: position) else { return nil }
        let current = index.tiles[currentIndex].frame
        let range = index.depthRanges[position.depth]
        let horizontal = move == .left || move == .right

        let cx = (current.x + current.width / 2) * aspectRatio
        let cy = current.y + current.height / 2

        var bestScore = Double.greatestFiniteMagnitude
        var best: Int?
        for i in range where i != currentIndex {
            let frame = index.tiles[i].frame
            let fx = (frame.x + frame.width / 2) * aspectRatio
            let fy = frame.y + frame.height / 2

            let travelled: Double
            let stray: Double
            let drift: Double
            if horizontal {
                travelled = move == .right ? fx - cx : cx - fx
                stray = max(0, max(current.y - frame.maxY, frame.y - current.maxY))
                drift = abs(fy - cy)
            } else {
                travelled = move == .down ? fy - cy : cy - fy
                stray = max(0, max(current.x - frame.maxX, frame.x - current.maxX)) * aspectRatio
                drift = abs(fx - cx)
            }
            // Strictly in the direction asked for. A tile whose middle is level
            // with yours is not "to the left" of anything.
            guard travelled > 1e-9 else { continue }

            let score = travelled + Self.strayWeight * stray + Self.alignmentWeight * drift
            // Ties break towards the earlier tile so the same keypress always
            // goes the same way.
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        return best.flatMap { index.position(at: $0) }
    }

    /// The chain from this tile outwards. Used to light up the ancestry on
    /// hover, which is what makes a nested treemap readable at depth.
    public func ancestors(of position: TreemapPosition) -> [TreemapPosition] {
        var chain: [TreemapPosition] = []
        var current = position
        while let next = index.parent(of: current), chain.count <= index.depthCount {
            chain.append(next)
            current = next
        }
        return chain
    }
}
