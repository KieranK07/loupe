import CoreGraphics
import Foundation
import SwiftUI

/// The font a chart label is drawn in, as a value that can key a cache.
///
/// A `Font` is opaque and not `Hashable`, so the cache is keyed by the two
/// things that actually decide a system font's metrics.
public struct LabelFont: Sendable, Hashable {
    public enum Weight: Sendable, Hashable {
        case regular, medium, semibold

        var swiftUI: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            }
        }
    }

    public let size: Double
    public let weight: Weight

    public init(size: Double, weight: Weight) {
        self.size = size
        self.weight = weight
    }

    public var font: Font { .system(size: size, weight: weight.swiftUI) }
}

/// Measured text sizes, kept across frames.
///
/// Resolving and measuring text inside a `Canvas` is not free: it crosses into
/// Core Text and allocates. A label pass that re-measured a few hundred strings
/// on every frame would spend more time asking how wide names are than drawing
/// the chart, and it would not hold 120 Hz. The set of strings on screen barely
/// changes between frames, so one dictionary lookup replaces all of it.
///
/// Main-actor isolated and shared, deliberately: the sunburst and the treemap
/// label the same names in the same font, so a zoom or a view toggle starts
/// warm. Keyed by string and font only — a `.system(size:)` font is not scaled
/// by Dynamic Type and its metrics do not depend on the display scale, so
/// nothing else in the environment can move the answer.
@MainActor
final class LabelTextCache {
    static let shared = LabelTextCache()

    private struct Key: Hashable {
        let text: String
        let font: LabelFont
    }

    /// Roughly one screenful of distinct names per ring, times a few zoom
    /// levels. Past this the cache is holding names nobody is looking at any
    /// more, and dropping the lot is cheaper than tracking ages.
    private let capacity = 8192
    private var sizes: [Key: CGSize] = [:]

    private(set) var hits = 0
    private(set) var misses = 0

    func size(of text: String, font: LabelFont, in context: GraphicsContext) -> CGSize {
        let key = Key(text: text, font: font)
        if let cached = sizes[key] {
            hits += 1
            return cached
        }
        misses += 1
        let resolved = context.resolve(Text(verbatim: text).font(font.font))
        // Effectively unbounded: we do our own truncation, so what is wanted
        // here is the intrinsic one-line width, not what SwiftUI would wrap the
        // name to inside a wedge-sized box.
        let measured = resolved.measure(in: CGSize(width: 100_000, height: 100_000))
        if sizes.count >= capacity { sizes.removeAll(keepingCapacity: true) }
        sizes[key] = measured
        return measured
    }

    func removeAll() {
        sizes.removeAll(keepingCapacity: true)
        hits = 0
        misses = 0
    }
}
