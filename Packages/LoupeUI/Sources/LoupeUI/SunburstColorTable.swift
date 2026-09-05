import Foundation
import LoupeCore
import SwiftUI

/// Every colour the chart can draw, resolved once.
///
/// A wedge's colour is a function of `(colorSeed, ring, kind, highlighted)` and
/// nothing else, and all four are small: ten seeds, nine rings, three kinds, two
/// states. That is at most 540 distinct colours for a chart of six thousand
/// wedges — so they are all built up front and the draw loop only ever does an
/// array subscript. No colour arithmetic and no allocation per frame.
struct SunburstColorTable: Sendable {
    static let ringSlots = Int(SunburstGeometry.maximumRings) + 1
    private static let kindSlots = 3
    private static let stateSlots = 2

    let palette: SunburstPalette
    let scheme: ColorScheme

    private let seedCount: Int
    private let swatches: [SunburstSwatch]
    private let colors: [Color]

    init(palette: SunburstPalette, scheme: ColorScheme) {
        self.palette = palette
        self.scheme = scheme
        let seeds = max(1, palette.swatchCount(scheme))
        seedCount = seeds

        var builtSwatches: [SunburstSwatch] = []
        var builtColors: [Color] = []
        let total = seeds * Self.ringSlots * Self.kindSlots * Self.stateSlots
        builtSwatches.reserveCapacity(total)
        builtColors.reserveCapacity(total)
        for seed in 0..<seeds {
            for ring in 0..<Self.ringSlots {
                for kind in 0..<Self.kindSlots {
                    for state in 0..<Self.stateSlots {
                        let swatch = palette.swatch(seed: UInt16(seed), ring: UInt8(ring),
                                                    kind: Self.kind(at: kind), scheme: scheme,
                                                    highlighted: state == 1)
                        builtSwatches.append(swatch)
                        builtColors.append(swatch.color)
                    }
                }
            }
        }
        swatches = builtSwatches
        colors = builtColors
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
        // A layout should never exceed `maximumRings`, but a clamp here is
        // cheaper than an out-of-bounds crash if a projector ever slips.
        let ringIndex = min(Int(ring), Self.ringSlots - 1)
        let kindIndex = Self.slot(for: kind)
        return ((seedIndex * Self.ringSlots + ringIndex) * Self.kindSlots + kindIndex)
            * Self.stateSlots + (highlighted ? 1 : 0)
    }

    func color(for wedge: Wedge, highlighted: Bool = false) -> Color {
        colors[offset(seed: wedge.colorSeed, ring: wedge.ring, kind: wedge.kind, highlighted: highlighted)]
    }

    func swatch(for wedge: Wedge, highlighted: Bool = false) -> SunburstSwatch {
        swatches[offset(seed: wedge.colorSeed, ring: wedge.ring, kind: wedge.kind, highlighted: highlighted)]
    }

    // `TreemapTile.depth` mirrors `Wedge.ring` by contract — depth 0 is the
    // focus's direct children in both — and the two carry the same `colorSeed`
    // for the same node. So the treemap reads this table unchanged, which is
    // what stops toggling between the views recolouring the machine.
    func color(for tile: TreemapTile, highlighted: Bool = false) -> Color {
        colors[offset(seed: tile.colorSeed, ring: tile.depth, kind: tile.kind, highlighted: highlighted)]
    }

    func swatch(for tile: TreemapTile, highlighted: Bool = false) -> SunburstSwatch {
        swatches[offset(seed: tile.colorSeed, ring: tile.depth, kind: tile.kind, highlighted: highlighted)]
    }
}
