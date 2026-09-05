import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

/// Marks both charts draw the same way.
///
/// Hatching, readout plates and the label loop are shared rather than copied,
/// because "an aggregate looks like this" and "a label is drawn like this" are
/// promises the two views must not be able to break independently.

/// Aggregated shapes are hatched as well as desaturated. Two independent
/// signals, because one can be missed — and a merged group must never be
/// mistakable for one real item.
func drawDiagonalHatch(_ context: inout GraphicsContext, path: Path, ink: Color, step: Double = 5) {
    let box = path.boundingRect
    guard box.width > 2, box.height > 2 else { return }
    context.drawLayer { layer in
        layer.clip(to: path, style: FillStyle(eoFill: true))
        var hatch = Path()
        var x = box.minX - box.height
        while x < box.maxX {
            hatch.move(to: CGPoint(x: x, y: box.maxY))
            hatch.addLine(to: CGPoint(x: x + box.height, y: box.minY))
            x += step
        }
        layer.stroke(hatch, with: .color(ink), lineWidth: 1)
    }
}

/// The backing behind a label that has to sit over something other than its own
/// shape: the readout for whatever the pointer is on, and a treemap group
/// header written across its own children.
///
/// Deliberately inverted against the rest of the chart. A plated label is the
/// one label allowed outside the shape it names, so it has to be unmistakably a
/// piece of chrome about a shape rather than a name painted on one.
func drawLabelPlate(_ context: inout GraphicsContext, box: LabelBox) {
    let rect = CGRect(x: box.center.x - box.size.width / 2 - 6,
                      y: box.center.y - box.size.height / 2 - 3,
                      width: box.size.width + 12, height: box.size.height + 6)
    let shape = Path(roundedRect: rect, cornerRadius: 5)
    context.fill(shape, with: .color(Color.primary.opacity(0.88)))
    context.stroke(shape, with: .color(Color.primary.opacity(0.25)), lineWidth: 0.5)
}

/// Ink for text on a plate: the inverse of the plate's own semantic fill.
func plateInk(for scheme: ColorScheme) -> Color {
    Color(white: scheme == .dark ? 0.08 : 0.98)
}

/// Draw the labels a placement pass accepted. Rotation is applied in a layer
/// rather than by pre-rotating the text, because `GraphicsContext` has no
/// notion of a rotated text run.
func drawPlacedLabels(_ context: inout GraphicsContext, placed: [PlacedLabel],
                      font: LabelFont, scheme: ColorScheme, ink: (UInt32) -> Color?) {
    let onPlate = plateInk(for: scheme)
    for label in placed {
        guard let colour = label.needsPlate ? onPlate : ink(label.id) else { continue }
        if label.needsPlate { drawLabelPlate(&context, box: label.box) }
        let resolved = context.resolve(Text(verbatim: label.text)
            .font(font.font)
            .foregroundStyle(colour))
        if label.box.rotation == 0 {
            context.draw(resolved, at: label.box.center, anchor: .center)
        } else {
            context.drawLayer { layer in
                layer.translateBy(x: label.box.center.x, y: label.box.center.y)
                layer.rotate(by: .radians(label.box.rotation))
                layer.draw(resolved, at: .zero, anchor: .center)
            }
        }
    }
}

// MARK: - Dimensional fills

/// Every gradient the charts can fill a mark with, resolved once.
///
/// The sibling of `SunburstColorTable`, and indexed identically: a mark's fill
/// is a function of `(colorSeed, ring, kind, highlighted)` and nothing else, all
/// four small, so the whole space is a few hundred entries and the draw loop
/// does an array subscript instead of colour arithmetic. Built alongside the
/// colour table and thrown away with it when the ramp or the appearance changes.
///
/// This holds `Gradient`, not `GraphicsContext.Shading`, because a shading also
/// carries its *geometry* — where the centre is and which radii the stops land
/// on — and that changes per ring and per resize. Keeping the two apart is what
/// lets one cached gradient be painted down a fractional ring mid-zoom.
struct MarkGradientTable: Sendable {
    private static let kindSlots = 3
    private static let stateSlots = 2

    private let seedCount: Int
    private let gradients: [Gradient]

    init(palette: SunburstPalette, scheme: ColorScheme) {
        let seeds = max(1, palette.swatchCount(scheme))
        seedCount = seeds
        var built: [Gradient] = []
        built.reserveCapacity(seeds * SunburstColorTable.ringSlots * Self.kindSlots * Self.stateSlots)
        for seed in 0..<seeds {
            for ring in 0..<SunburstColorTable.ringSlots {
                for kind in 0..<Self.kindSlots {
                    for state in 0..<Self.stateSlots {
                        let shading = palette.shading(seed: UInt16(seed), ring: UInt8(ring),
                                                      kind: Self.kind(at: kind), scheme: scheme,
                                                      highlighted: state == 1)
                        built.append(Gradient(colors: shading.colors))
                    }
                }
            }
        }
        gradients = built
    }

    private static func kind(at slot: Int) -> WedgeKind {
        switch slot {
        case 1: .aggregated(count: 0)
        case 2: .stillScanning
        default: .real
        }
    }

    private static func slot(for kind: WedgeKind) -> Int {
        switch kind {
        case .real: 0
        case .aggregated: 1
        case .stillScanning: 2
        }
    }

    @inline(__always)
    private func offset(seed: UInt16, ring: UInt8, kind: WedgeKind, highlighted: Bool) -> Int {
        let seedIndex = Int(seed) % seedCount
        let ringIndex = min(Int(ring), SunburstColorTable.ringSlots - 1)
        return ((seedIndex * SunburstColorTable.ringSlots + ringIndex) * Self.kindSlots
                + Self.slot(for: kind)) * Self.stateSlots + (highlighted ? 1 : 0)
    }

    func gradient(for wedge: Wedge, highlighted: Bool = false) -> Gradient {
        gradients[offset(seed: wedge.colorSeed, ring: wedge.ring, kind: wedge.kind,
                         highlighted: highlighted)]
    }

    /// `TreemapTile.depth` mirrors `Wedge.ring` by contract, so a tile reads the
    /// same table a wedge does — which is what stops toggling between the views
    /// relighting the machine as well as recolouring it.
    func gradient(for tile: TreemapTile, highlighted: Bool = false) -> Gradient {
        gradients[offset(seed: tile.colorSeed, ring: tile.depth, kind: tile.kind,
                         highlighted: highlighted)]
    }
}
