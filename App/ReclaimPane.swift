import SwiftUI
import LoupeCore

/// Pillar 2's surface. Every rule here exists because the alternative is a
/// cleaner app that lies:
///
/// - nothing is ever pre-selected, at any safety level;
/// - a dry run showing exact paths and a byte total precedes every deletion;
/// - the destructive button is never the default;
/// - the Trash caveat is always on screen, because "reclaimed 40 GB" is false
///   while the bytes are still sitting in the Trash.
struct ReclaimPane: View {
    @Environment(AppModel.self) private var model
    let controller: ReclaimController

    var body: some View {
        @Bindable var model = model
        Group {
            if model.catalog.isEmpty {
                ContentUnavailableView {
                    Label("Nothing scanned yet", systemImage: "arrow.up.bin")
                } description: {
                    Text("Loupe looks in a curated set of places rather than hunting for anything it thinks is disposable.")
                } actions: {
                    Button("Look for reclaimable space") { controller.survey() }
                }
            } else {
                targetList
            }
        }
        .navigationTitle("Reclaim")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Re-check", systemImage: "arrow.clockwise") { controller.survey() }
                    .disabled(model.isSurveying)
            }
            ToolbarItem {
                Button("Preview…") { controller.preview() }
                    .disabled(model.selectedTargetIDs.isEmpty)
            }
        }
        .sheet(item: $model.pendingPlan) { plan in
            ConfirmationSheet(plan: plan,
                              targets: model.catalog,
                              onCancel: { model.pendingPlan = nil },
                              onConfirm: { controller.execute(plan.plan) })
        }
        .safeAreaInset(edge: .bottom) { caveatBar }
    }

    private var subtitle: String {
        let found = model.catalog.filter { $0.foundBytes > 0 }
        guard !found.isEmpty else { return "Nothing found in the places Loupe checks" }
        let total = found.reduce(UInt64(0)) { $0 &+ $1.foundBytes }
        return "\(found.count) of \(model.catalog.count) places hold \(ByteFormat.string(total))"
    }

    private var targetList: some View {
        @Bindable var model = model
        return List {
            ForEach(SafetyLevel.allCases, id: \.self) { level in
                let rows = model.catalog.filter { $0.target.safety == level }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row in
                            TargetRow(row: row, isSelected: Binding(
                                get: { model.selectedTargetIDs.contains(row.id) },
                                set: { on in
                                    if on { model.selectedTargetIDs.insert(row.id) }
                                    else { model.selectedTargetIDs.remove(row.id) }
                                }))
                        }
                    } header: {
                        HStack(spacing: 7) {
                            Image(systemName: level.symbol)
                                .foregroundStyle(level.tint)
                                .imageScale(.small)
                                .frame(width: 16)
                            Text(level.label)
                            Spacer()
                            // The section's own total, so the cost of a whole
                            // safety level is visible before opening any row.
                            // Found bytes only — never a projection.
                            Text(ByteFormat.string(rows.reduce(0) { $0 + $1.foundBytes }))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        if level.requiresTypedConfirmation {
                            Text("Removing these destroys something that cannot be downloaded again. Loupe will ask you to type a confirmation.")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var caveatBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text(ReclaimPlan.trashCaveat).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.bar)
    }
}

/// One curated place. The safety rating, what breaks and the regeneration cost
/// are all on the row — the user should never have to click through to find out
/// what a checkbox costs them.
private struct TargetRow: View {
    let row: CatalogRow
    @Binding var isSelected: Bool

    /// Said plainly rather than hiding a disabled checkbox with no explanation.
    private var mechanismNote: String {
        switch row.target.mechanism {
        case .trash:           ""
        case .delegatedToTool: "Another tool owns removing this — Loupe will not."
        case .revealInFinder:  "Loupe will show you where this is and leave it to you."
        case .reviewOnly:      "Listed so you can see it. Loupe does not remove this."
        }
    }

    var body: some View {
        Toggle(isOn: $isSelected) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.target.displayName).font(.body)
                    Spacer()
                    Text(row.foundBytes > 0 ? ByteFormat.string(row.foundBytes) : "Not present")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(row.foundBytes > 0 ? .primary : .tertiary)
                }
                Text(row.target.whatBreaks).font(.caption).foregroundStyle(.secondary)
                Text(row.target.regeneration).font(.caption).foregroundStyle(.tertiary)
                if !row.target.isDeletableByLoupe {
                    Label(mechanismNote, systemImage: "hand.raised")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if !row.target.refuseWhileRunning.isEmpty {
                    Text("Skipped while in use.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.checkbox)
        // Three reasons a row is not a checkbox: nothing is there, or it is
        // there but another tool owns removing it, or it is shown purely for
        // review. Absent is not the same as empty, and neither is selectable.
        .disabled(row.foundBytes == 0 || !row.target.isDeletableByLoupe)
    }
}

/// The last thing between the user and the Trash. Cancel is the default action;
/// the destructive button never is.
private struct ConfirmationSheet: View {
    let plan: IdentifiablePlan
    let targets: [CatalogRow]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var typed = ""

    private var needsTyping: Bool {
        targets.contains { row in
            plan.plan.candidates.contains { $0.targetID == row.id }
                && row.target.safety.requiresTypedConfirmation
        }
    }
    private let phrase = "move to trash"
    private var canConfirm: Bool {
        !plan.plan.isEmpty && (!needsTyping || typed.lowercased() == phrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Move \(plan.plan.candidates.count.formatted()) items to the Trash?")
                    .font(.headline)
                Text(ByteFormat.string(plan.plan.totalBytes) + " on disk")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            // Exact paths. Not a summary, not a count — the actual list.
            List {
                Section("Will be moved to the Trash") {
                    ForEach(plan.plan.candidates) { candidate in
                        HStack {
                            Text(candidate.url.path(percentEncoded: false))
                                .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(ByteFormat.string(candidate.physicalBytes))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.plan.blocked.isEmpty {
                    Section("Refused by Loupe") {
                        ForEach(plan.plan.blocked) { blocked in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(blocked.url.path(percentEncoded: false))
                                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(blocked.rule.explanation)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label(ReclaimPlan.trashCaveat, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)

                if needsTyping {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("This includes items that cannot be downloaded again. Type **\(phrase)** to continue.")
                            .font(.caption)
                        TextField("", text: $typed, prompt: Text(phrase))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive, action: onConfirm)
                        .disabled(!canConfirm)
                    // Deliberately NOT .defaultAction: the destructive path must
                    // never be what Return does.
                }
            }
            .padding(20)
        }
        .frame(width: 620)
    }
}
