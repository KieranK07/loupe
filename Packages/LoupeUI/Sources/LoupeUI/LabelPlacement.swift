import CoreGraphics
import Foundation

/// One label opportunity, reduced to geometry and a string.
///
/// Deliberately knows nothing about wedges, tiles or `Canvas`: both charts
/// build these, one pure function decides which of them survive, and the
/// decision is testable without rendering a pixel.
public struct LabelSlot: Sendable, Hashable {
    /// The wedge or tile this belongs to — `Wedge.id` / `TreemapTile.id`.
    public let id: UInt32
    public let text: String
    /// Where the middle of the text goes.
    public let anchor: CGPoint
    /// Screen-space baseline rotation in radians. Zero reads horizontally.
    public let rotation: Double
    /// How far the text may run along its baseline before it leaves its own
    /// wedge or tile.
    public let widthBudget: Double
    /// How tall a line may be across it. Unlike width this cannot be recovered
    /// by truncating — a name too tall for its ring is not a label, it is a smear.
    public let heightBudget: Double
    /// Bigger wins. Both charts pass the drawn size of the shape, so the
    /// largest shapes claim their names and small ones go unlabelled rather
    /// than fighting over the same pixels.
    public let priority: Double
    /// The user is pointing at, or has the keyboard on, this one. Forced slots
    /// are considered first, so they always win their space, and they are drawn
    /// even where the geometry has no room — see `PlacedLabel.needsPlate`.
    public let isForced: Bool
    /// Draw this one on a plate whatever else happens. Used for a group header
    /// that sits over its own children: without a backing it would read as a
    /// label belonging to whichever child is underneath it.
    public let wantsPlate: Bool

    public init(id: UInt32, text: String, anchor: CGPoint, rotation: Double,
                widthBudget: Double, heightBudget: Double, priority: Double,
                isForced: Bool = false, wantsPlate: Bool = false) {
        self.id = id
        self.text = text
        self.anchor = anchor
        self.rotation = rotation
        self.widthBudget = widthBudget
        self.heightBudget = heightBudget
        self.priority = isForced ? .infinity : priority
        self.isForced = isForced
        self.wantsPlate = wantsPlate
    }
}

/// A label that survived the pass, with the exact string and box to draw.
public struct PlacedLabel: Sendable, Hashable {
    public let id: UInt32
    /// Possibly middle-truncated. Never the untruncated string when that would
    /// not have fitted.
    public let text: String
    public let box: LabelBox
    public let isTruncated: Bool
    /// True when the label had to claim more room than its own shape allows,
    /// because the user is pointing at it. The renderer backs these with a
    /// plate so they read as a readout attached to the shape rather than as a
    /// fill label that has escaped it — the one case where covering a
    /// neighbour is the honest answer, because the user asked about this one.
    public let needsPlate: Bool

    public init(id: UInt32, text: String, box: LabelBox, isTruncated: Bool, needsPlate: Bool) {
        self.id = id
        self.text = text
        self.box = box
        self.isTruncated = isTruncated
        self.needsPlate = needsPlate
    }
}

/// Which labels actually get drawn.
///
/// The whole of the decision lives here rather than inside a `Canvas` closure,
/// so "does this chart paint names on top of each other" is a question a test
/// can answer.
public enum LabelPlacement {
    public struct Configuration: Sendable, Hashable {
        /// A chart carrying more than about four dozen names has stopped being
        /// a chart, whatever the density of the data behind it.
        public var maximumLabels: Int
        /// A fragment shorter than this identifies nothing — `C22…16A` and
        /// `C22…D5A` are the same label to a reader. Below it, draw nothing.
        public var minimumVisibleCharacters: Int
        /// Clear space kept around every accepted label.
        public var padding: Double
        /// How many slots we are willing to measure. Measuring text is the
        /// expensive part of this pass and slots arrive largest-first, so
        /// everything past this point would have lost its collision anyway.
        public var candidateLimit: Int
        /// Cap on a forced label's plate, so a pathological name cannot run off
        /// the side of the view.
        public var maximumPlateWidth: Double

        public init(maximumLabels: Int = 48, minimumVisibleCharacters: Int = 4,
                    padding: Double = 3, candidateLimit: Int = 160,
                    maximumPlateWidth: Double = 220) {
            self.maximumLabels = maximumLabels
            self.minimumVisibleCharacters = minimumVisibleCharacters
            self.padding = padding
            self.candidateLimit = candidateLimit
            self.maximumPlateWidth = maximumPlateWidth
        }
    }

    public static let ellipsis = "\u{2026}"

    // MARK: - The pass

    /// Accepted labels, in the order they were accepted (largest first).
    ///
    /// `measure` returns the drawn size of a string in the label font. It is
    /// called at most a few hundred times and the callers cache it across
    /// frames, because re-measuring thousands of strings every frame will not
    /// hold 120 Hz.
    public static func place(slots: [LabelSlot],
                             configuration: Configuration = Configuration(),
                             measure: (String) -> CGSize) -> [PlacedLabel] {
        guard !slots.isEmpty, configuration.maximumLabels > 0 else { return [] }

        // Forced first, then descending size, then input order. The input-order
        // tiebreak is what makes the result deterministic for a layout with
        // many equal-sized shapes — otherwise the same chart could label
        // different wedges on two runs.
        let ordered = slots.enumerated()
            .sorted { a, b in
                if a.element.isForced != b.element.isForced { return a.element.isForced }
                if a.element.priority != b.element.priority { return a.element.priority > b.element.priority }
                return a.offset < b.offset
            }
            .map(\.element)

        var accepted: [PlacedLabel] = []
        var claimed: [LabelBox] = []
        accepted.reserveCapacity(min(configuration.maximumLabels, ordered.count))
        claimed.reserveCapacity(accepted.capacity)
        var measured = 0

        for slot in ordered {
            if accepted.count >= configuration.maximumLabels { break }
            if !slot.isForced {
                if measured >= configuration.candidateLimit { break }
                measured += 1
            }
            guard let fitted = fit(slot, configuration: configuration, measure: measure) else { continue }
            let box = LabelBox(center: slot.anchor, size: fitted.size, rotation: slot.rotation)
            let padded = box.inflated(by: configuration.padding)
            // Linear against the accepted set, which is capped at a few dozen —
            // so this is a few hundred separating-axis tests per frame at worst,
            // not a quadratic sweep over six thousand wedges.
            if claimed.contains(where: { $0.intersects(padded) }) { continue }
            claimed.append(padded)
            accepted.append(PlacedLabel(id: slot.id, text: fitted.text, box: box,
                                        isTruncated: fitted.isTruncated,
                                        needsPlate: fitted.needsPlate))
        }
        return accepted
    }

    private struct Fitted {
        let text: String
        let size: CGSize
        let isTruncated: Bool
        let needsPlate: Bool
    }

    private static func fit(_ slot: LabelSlot, configuration: Configuration,
                            measure: (String) -> CGSize) -> Fitted? {
        guard !slot.text.isEmpty else { return nil }
        let full = measure(slot.text)

        if full.height <= slot.heightBudget {
            if full.width <= slot.widthBudget {
                return Fitted(text: slot.text, size: full, isTruncated: false,
                              needsPlate: slot.wantsPlate)
            }
            if let shortened = truncate(slot.text, toWidth: slot.widthBudget,
                                        minimumVisibleCharacters: configuration.minimumVisibleCharacters,
                                        measure: measure) {
                return Fitted(text: shortened.text, size: shortened.size,
                              isTruncated: true, needsPlate: slot.wantsPlate)
            }
        }

        guard slot.isForced else { return nil }
        // Nothing fits, but the user is asking about this exact shape. Draw the
        // name on a plate instead of silently refusing to answer.
        if full.width <= configuration.maximumPlateWidth {
            return Fitted(text: slot.text, size: full, isTruncated: false, needsPlate: true)
        }
        guard let shortened = truncate(slot.text, toWidth: configuration.maximumPlateWidth,
                                       minimumVisibleCharacters: configuration.minimumVisibleCharacters,
                                       measure: measure) else {
            return Fitted(text: slot.text, size: full, isTruncated: false, needsPlate: true)
        }
        return Fitted(text: shortened.text, size: shortened.size, isTruncated: true, needsPlate: true)
    }

    // MARK: - Truncation

    /// `Very/long/path/component.framework` and
    /// `C2296EE4-908B-4BDA-8176-CA8439D5016A` both differ from their neighbours
    /// mostly in the *middle*, so a head-truncated fragment of either tells you
    /// nothing at all. Keep both ends and elide the centre.
    public static func middleTruncated(_ text: String, keeping visible: Int) -> String {
        let characters = Array(text)
        guard visible > 0, characters.count > visible else { return text }
        let head = (visible + 1) / 2
        let tail = visible - head
        let front = String(characters[0..<head])
        let back = tail > 0 ? String(characters[(characters.count - tail)...]) : ""
        return front + ellipsis + back
    }

    /// The longest middle-truncation of `text` that fits `width`, or nil when
    /// even the shortest legible fragment does not.
    ///
    /// Binary search over the number of characters kept. Advance widths are not
    /// strictly monotonic in a proportional font — dropping a wide character
    /// can shorten the string more than dropping two narrow ones — so this can
    /// land a character short of the true maximum. That is invisible; being
    /// wrong in the other direction would not be.
    public static func truncate(_ text: String, toWidth width: Double,
                                minimumVisibleCharacters: Int,
                                measure: (String) -> CGSize) -> (text: String, size: CGSize)? {
        guard width > 0 else { return nil }
        let count = Array(text).count
        guard count > minimumVisibleCharacters else { return nil }

        var low = minimumVisibleCharacters
        var high = count - 1
        var best: (text: String, size: CGSize)?
        while low <= high {
            let mid = (low + high) / 2
            let candidate = middleTruncated(text, keeping: mid)
            let size = measure(candidate)
            if size.width <= width {
                best = (candidate, size)
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}
