import SwiftUI
import LoupeCore
import LoupeUI

/// Live scan state, floating over the chart.
///
/// The only place the app said a scan was running was the window subtitle,
/// which is the least looked-at text on screen — so a scan of a large volume
/// felt like the app had stopped. This is the same facts, where the eye already
/// is.
///
/// The counts are the walker's real ones. There is no percentage here on
/// purpose: total entry count is unknown until the walk finishes, so any
/// progress bar would be a bar whose end moves, and a bar that jumps backwards
/// is worse than no bar. Counting up is honest; a fake denominator is not.
struct ScanProgressPill: View {
    let progress: ScanProgress

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            beacon
            Text("\(progress.entriesSeen.formatted()) items")
                .contentTransition(.numericText(value: Double(progress.entriesSeen)))
                .monospacedDigit()
            Text("·").foregroundStyle(.tertiary)
            Text(ByteFormat.string(progress.physicalBytes))
                .contentTransition(.numericText(value: Double(progress.physicalBytes)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Through LoupeUI's helper rather than calling `.glassEffect` directly,
        // so this pill gets the same opaque fallback as every other floating
        // surface when the user has asked for reduced transparency. Glass
        // applied ad hoc is exactly how an app ends up with one panel that
        // ignores an accessibility setting the other five respect.
        .chartGlassCapsule(tint: .blue.opacity(0.16))
        .animation(.smooth(duration: 0.4), value: progress.entriesSeen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanning. \(progress.entriesSeen.formatted()) items so far, "
                            + "\(ByteFormat.string(progress.physicalBytes)) on disk.")
    }

    /// A breathing dot. Deliberately not a spinner: a spinner is the system's
    /// word for "waiting", and this is not waiting — it is finding things, and
    /// the numbers next to it are already moving to prove it.
    private var beacon: some View {
        Circle()
            .fill(Color.blue.gradient)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.35 : 0.85)
            .opacity(pulse ? 1 : 0.55)
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                       value: pulse)
            .onAppear { pulse = true }
    }
}
