import CoreGraphics
import Foundation
import LoupeCore
@testable import LoupeUI

/// Hand-built packs.
///
/// LoupeUI deliberately does not depend on LoupeTree, so these are not the
/// packer's output — they are geometry chosen to satisfy exactly what the
/// *renderer's* contract depends on: circles wholly inside their parents,
/// siblings disjoint, emitted shallowest-first. `BubblePackTests` over in
/// LoupeTree is what proves the real packer produces the same shape.
enum BubbleFixture {

    static func circle(slot: UInt32, x: Double, y: Double, r: Double, depth: UInt8,
                       seed: UInt16, hasChildren: Bool = false,
                       kind: WedgeKind = .real, name: String? = nil) -> BubbleCircle {
        BubbleCircle(node: .directory(slot), centerX: x, centerY: y, radius: r, depth: depth,
                     physicalBytes: UInt64((r * r * 4_000_000_000).rounded()),
                     logicalBytes: UInt64((r * r * 12_000_000_000).rounded()),
                     itemCount: UInt32(slot),
                     name: name ?? FixtureNames.name(Int(slot)),
                     kind: kind, colorSeed: seed, hasChildren: hasChildren)
    }

    static func layout(_ circles: [BubbleCircle], focus: NodeRef = .directory(0),
                       generation: UInt64 = 1,
                       breadcrumb: [Breadcrumb] = [Breadcrumb(node: .directory(0), name: "Data"),
                                                   Breadcrumb(node: .directory(1), name: "Users")],
                       isComplete: Bool = true) -> BubbleLayout {
        BubbleLayout(generation: generation, focus: focus,
                     focusPath: "/System/Volumes/Data/Users",
                     breadcrumb: breadcrumb, circles: circles,
                     totalPhysicalBytes: 4_000_000_000,
                     totalLogicalBytes: 12_000_000_000,
                     scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                     isComplete: isComplete)
    }

    /// Four balls in the focus disc, each holding three of its own, each of
    /// those holding one. Every circle is strictly inside its parent and no two
    /// siblings touch — checked by `BubbleFixtureTests`, because a fixture that
    /// quietly breaks the contract makes every test that uses it meaningless.
    static func nested(kindForDepth: (Int, Int) -> WedgeKind = { _, _ in .real }) -> BubbleLayout {
        var circles: [BubbleCircle] = []
        var slot: UInt32 = 100
        let quadrants = [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)]

        var level1: [(UInt32, Double, Double, Double, UInt16)] = []
        for (i, quadrant) in quadrants.enumerated() {
            let x = 0.5 + quadrant.0 * 0.2, y = 0.5 + quadrant.1 * 0.2
            circles.append(circle(slot: slot, x: x, y: y, r: 0.18, depth: 0,
                                  seed: UInt16(i), hasChildren: true,
                                  kind: kindForDepth(0, i)))
            level1.append((slot, x, y, 0.18, UInt16(i)))
            slot += 1
        }

        var level2: [(UInt32, Double, Double, Double, UInt16)] = []
        for (parentIndex, parent) in level1.enumerated() {
            for spoke in 0..<3 {
                let angle = Double(spoke) * 2 * .pi / 3
                let x = parent.1 + cos(angle) * 0.09
                let y = parent.2 + sin(angle) * 0.09
                circles.append(circle(slot: slot, x: x, y: y, r: 0.055, depth: 1,
                                      seed: parent.4, hasChildren: true,
                                      kind: kindForDepth(1, parentIndex * 3 + spoke)))
                level2.append((slot, x, y, 0.055, parent.4))
                slot += 1
            }
        }

        for (index, parent) in level2.enumerated() {
            circles.append(circle(slot: slot, x: parent.1, y: parent.2, r: 0.03, depth: 2,
                                  seed: parent.4, hasChildren: false,
                                  kind: kindForDepth(2, index)))
            slot += 1
        }
        return layout(circles)
    }

    /// An exact `columns` × `rows` lattice of equal circles at one depth.
    /// Hand-checkable, so the navigator's idea of "the circle to the left" can
    /// be asserted against arithmetic rather than against another implementation
    /// of itself.
    static func grid(columns: Int, rows: Int) -> BubbleLayout {
        var circles: [BubbleCircle] = []
        var slot: UInt32 = 100
        let stepX = 1.0 / Double(columns), stepY = 1.0 / Double(rows)
        let radius = min(stepX, stepY) * 0.45
        for row in 0..<rows {
            for column in 0..<columns {
                circles.append(BubbleCircle(
                    node: .directory(slot),
                    centerX: (Double(column) + 0.5) * stepX,
                    centerY: (Double(row) + 0.5) * stepY,
                    radius: radius, depth: 0,
                    physicalBytes: 1_000, logicalBytes: 1_000, itemCount: 1,
                    name: "r\(row)c\(column)", kind: .real,
                    colorSeed: UInt16(column), hasChildren: false))
                slot += 1
            }
        }
        return BubbleLayout(generation: 1, focus: .directory(0), focusPath: "/",
                            breadcrumb: [Breadcrumb(node: .directory(0), name: "Root")],
                            circles: circles, totalPhysicalBytes: 1_000_000,
                            totalLogicalBytes: 1_000_000,
                            scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            isComplete: true)
    }

    /// The layout you would get by zooming into `focus`, if the packer were an
    /// exact similarity — which it is up to the absolute padding and radius
    /// floor, and exactly which is the assumption `BubbleAnimation` is built on.
    ///
    /// Every descendant of `focus` is carried into the new container and every
    /// depth drops by one; the focus itself becomes the container and is not
    /// emitted, as the contract requires.
    static func zoomed(_ layout: BubbleLayout, into focus: BubbleCircle) -> BubbleLayout {
        let scale = 0.5 / focus.radius
        var circles: [BubbleCircle] = []
        for circle in layout.circles where circle.depth > focus.depth {
            let dx = circle.centerX - focus.centerX, dy = circle.centerY - focus.centerY
            guard (dx * dx + dy * dy).squareRoot() + circle.radius <= focus.radius + 1e-9 else {
                continue
            }
            circles.append(BubbleCircle(
                node: circle.node,
                centerX: 0.5 + dx * scale, centerY: 0.5 + dy * scale,
                radius: circle.radius * scale,
                depth: circle.depth - focus.depth - 1,
                physicalBytes: circle.physicalBytes, logicalBytes: circle.logicalBytes,
                itemCount: circle.itemCount, name: circle.name, kind: circle.kind,
                colorSeed: circle.colorSeed, hasChildren: circle.hasChildren))
        }
        circles.sort { $0.depth < $1.depth }
        return BubbleLayout(generation: layout.generation + 1, focus: focus.node,
                            focusPath: layout.focusPath + "/" + focus.name,
                            breadcrumb: layout.breadcrumb
                                + [Breadcrumb(node: focus.node, name: focus.name)],
                            circles: circles,
                            totalPhysicalBytes: focus.physicalBytes,
                            totalLogicalBytes: focus.logicalBytes,
                            scannedAt: layout.scannedAt, isComplete: layout.isComplete)
    }

    static func metrics(width: Double = 900, height: Double = 600) -> BubbleMetrics {
        BubbleMetrics(bounds: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
