import Foundation
import LoupeCore
import SwiftUI

/// One row of "this colour is that folder".
public struct ChartLegendEntry: Sendable, Hashable, Identifiable {
    public let id: UInt32
    public let name: String
    public let detail: String
    /// The reference colour, in the palette's sense: what ink was chosen
    /// against and what every contrast claim is measured on.
    public let swatch: SunburstSwatch
    /// And how the chart will actually fill that colour in. A legend drawn from
    /// the reference colour alone is a legend that does not match the chart —
    /// the key would be flat where every mark it names is dimensional, and the
    /// swatch is the one thing in the interface whose entire job is to be the
    /// same colour as something else.
    public let shading: SunburstShading

    public init(id: UInt32, name: String, detail: String, swatch: SunburstSwatch,
                shading: SunburstShading? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.swatch = swatch
        self.shading = shading ?? SunburstShading(flat: swatch)
    }
}

public extension ChartLegendEntry {
    /// The innermost ring, largest first. That ring *is* the categorical scale:
    /// one entry per top-level folder under the focus, which is exactly what
    /// `colorSeed` indexes.
    static func entries(for index: SunburstIndex, palette: SunburstPalette,
                        scheme: ColorScheme, basis: SizeBasis,
                        limit: Int = 12) -> [ChartLegendEntry] {
        index.wedges(inRing: 0)
            .sorted { $0.sweep > $1.sweep }
            .prefix(limit)
            .map { wedge in
                ChartLegendEntry(
                    id: wedge.id,
                    name: SunburstDescription.chartLabel(for: wedge),
                    detail: ByteFormat.string(wedge.bytes(basis), basis: basis),
                    swatch: palette.swatch(seed: wedge.colorSeed, ring: 0,
                                           kind: wedge.kind, scheme: scheme),
                    shading: palette.shading(seed: wedge.colorSeed, ring: 0,
                                             kind: wedge.kind, scheme: scheme))
            }
    }

    static func entries(for index: TreemapIndex, palette: SunburstPalette,
                        scheme: ColorScheme, basis: SizeBasis,
                        limit: Int = 12) -> [ChartLegendEntry] {
        index.tiles(atDepth: 0)
            .sorted { $0.frame.area > $1.frame.area }
            .prefix(limit)
            .map { tile in
                ChartLegendEntry(
                    id: tile.id,
                    name: SunburstDescription.chartLabel(for: tile.kind, name: tile.name),
                    detail: ByteFormat.string(tile.bytes(basis), basis: basis),
                    swatch: palette.swatch(seed: tile.colorSeed, ring: 0,
                                           kind: tile.kind, scheme: scheme),
                    shading: palette.shading(seed: tile.colorSeed, ring: 0,
                                             kind: tile.kind, scheme: scheme))
            }
    }
}

/// Which colour is which folder, floating over the chart.
///
/// The only place in the interface where a wedge colour appears outside the
/// chart, and the reason the ramp has to be stable across a re-projection: a
/// legend that reshuffles ten times a second during a scan is worse than none.
@MainActor
public struct ChartLegend: View {
    private let entries: [ChartLegendEntry]
    private let title: String
    private let maximumHeight: Double

    public init(entries: [ChartLegendEntry],
                title: String = "Largest here",
                maximumHeight: Double = 220) {
        self.entries = entries
        self.title = title
        self.maximumHeight = maximumHeight
    }

    public var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(entries) { row($0) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // The list runs under the glass edge rather than stopping dead
                // at it, so the panel reads as one object with content inside
                // it instead of a rectangle with a scroller cut into it.
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .frame(maxHeight: maximumHeight)
            }
            .padding(ChartGlassMetrics.contentPadding)
            .frame(width: 220)
            // The one piece of floating chrome that takes the pointer: it
            // scrolls under it. The rail's crumbs answer the cursor through
            // their own button style, and the readout answers it not at all.
            .chartGlass(in: RoundedRectangle(cornerRadius: ChartGlassMetrics.panelRadius,
                                             style: .continuous),
                        interactive: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title))
        }
    }

    private func row(_ entry: ChartLegendEntry) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                // Top-leading to bottom-trailing, which is where the chart puts
                // the lit end of a tile and near enough where it puts the lit
                // end of a wedge. A chip 11 points across cannot show the two
                // stops as a gradient anyway; what it shows is the same pair of
                // colours, so the key and the mark read as one material.
                .fill(LinearGradient(colors: entry.shading.colors,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 11, height: 11)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
            Text(entry.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(entry.detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(entry.name), \(entry.detail)"))
    }
}

#Preview("Legend") {
    let palette = SunburstPalette()
    ChartLegend(entries: (0..<6).map { seed in
        ChartLegendEntry(id: UInt32(seed),
                         name: ["System", "Users", "Library", "Applications", "private", "opt"][seed],
                         detail: "\(120 - seed * 17) GB on disk",
                         swatch: palette.swatch(seed: UInt16(seed), ring: 0, scheme: .light),
                         shading: palette.shading(seed: UInt16(seed), ring: 0, scheme: .light))
    })
    .padding(40)
}
