import SwiftUI
import LoupeCore

/// Explains why Finder's "Available" disagrees with everything else.
///
/// The rule this view exists to honour: show the pieces and name the residual.
/// A number the user cannot check is worth less than an admission that we cannot
/// see something — so there is no bucket called "Other" here.
struct StorageSummary: View {
    let breakdown: SpaceBreakdown

    private var volume: VolumeDescriptor { breakdown.volume }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bar
            legend
            if let explanation = breakdown.systemDataExplanation {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            if breakdown.unaccountedBytes > 0 {
                Text(breakdown.unaccountedExplanation)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !breakdown.snapshots.isEmpty { snapshotList }
        }
        .padding(16)
    }

    /// The three segments, each with its own fill.
    ///
    /// "Measured" is the only one that gets a real colour. The other two are a
    /// hatched grey and an empty channel on purpose: this bar is an accounting
    /// of what Loupe can and cannot see, and giving "not visible" a cheerful
    /// colour of its own would make an admission look like a category.
    private var segments: [(label: String, bytes: UInt64, style: AnyShapeStyle)] {
        [("Measured by Loupe", breakdown.scannedBytes,
          AnyShapeStyle(LinearGradient(colors: [Color(hue: 0.58, saturation: 0.78, brightness: 0.95),
                                                Color(hue: 0.72, saturation: 0.72, brightness: 0.88)],
                                       startPoint: .leading, endPoint: .trailing))),
         ("Not visible to Loupe", breakdown.unaccountedBytes,
          AnyShapeStyle(Color.secondary.opacity(0.55))),
         ("Free", breakdown.freeBytes,
          AnyShapeStyle(Color(nsColor: .quaternaryLabelColor)))]
    }

    private var bar: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments, id: \.label) { segment in
                    let fraction = volume.totalCapacity > 0
                        ? Double(segment.bytes) / Double(volume.totalCapacity) : 0
                    Rectangle().fill(segment.style)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .clipShape(.rect(cornerRadius: 5))
            // The measured segment grows as the scan proceeds, so the bar is
            // animated on the byte count rather than left to jump on each tick.
            .animation(.smooth(duration: 0.45), value: breakdown.scannedBytes)
        }
        .frame(height: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityLabel("\(ByteFormat.string(volume.totalCapacity)) total, "
                            + "\(ByteFormat.string(breakdown.freeBytes)) free")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(segments, id: \.label) { segment in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(segment.style)
                        .frame(width: 10, height: 10)
                    Text(segment.label).font(.callout)
                    Spacer()
                    Text(ByteFormat.string(segment.bytes))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    private var snapshotList: some View {
        DisclosureGroup("\(breakdown.snapshots.count) local snapshot\(breakdown.snapshots.count == 1 ? "" : "s")") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(breakdown.snapshots) { snapshot in
                    HStack {
                        Text(snapshot.name).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        if let date = snapshot.createdAt {
                            Text(date, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // Sizes need root, and Loupe does not guess.
                Text("Snapshot sizes are not readable without administrator access, so Loupe does not estimate them.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 3)
            }
            .padding(.top, 5)
        }
        .font(.callout)
    }
}
