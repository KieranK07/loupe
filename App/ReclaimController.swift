import Foundation
import SwiftUI
import LoupeCore
import LoupeReclaim

/// One curated place, plus what was actually found there.
///
/// `foundBytes == 0` means *absent*, and the UI must say "Not present" rather
/// than "0 bytes" — absent and empty are different facts and only one of them is
/// worth a checkbox.
struct CatalogRow: Identifiable, Sendable {
    let target: CleanupTarget
    let foundBytes: UInt64
    let candidates: [ReclaimCandidate]
    var id: String { target.id }
}

/// Wrapper so a plan can drive `.sheet(item:)`.
struct IdentifiablePlan: Identifiable {
    let plan: ReclaimPlan
    let id = UUID()
}

/// What the app needs from the reclaim engine.
///
/// Behind a protocol so the destructive implementation can be swapped for a
/// no-op in previews and tests. A UI bug must never be able to reach
/// `trashItem` by accident.
protocol ReclaimEngine: Sendable {
    func survey() async -> [CatalogRow]
    func plan(targetIDs: Set<String>, from catalog: [CatalogRow]) async -> ReclaimPlan
    func execute(_ plan: ReclaimPlan) async -> ReclaimOutcome
}

/// Stands in until the real engine is wired. Surveys nothing and refuses to
/// delete: an engine that cannot find anything is a safe default, and an empty
/// pane is a truthful one.
struct InertReclaimEngine: ReclaimEngine {
    func survey() async -> [CatalogRow] { [] }
    func plan(targetIDs: Set<String>, from catalog: [CatalogRow]) async -> ReclaimPlan {
        ReclaimPlan(candidates: [], blocked: [])
    }
    func execute(_ plan: ReclaimPlan) async -> ReclaimOutcome {
        ReclaimOutcome(trashed: [], bytesMoved: 0, failures: [:])
    }
}

@MainActor
final class ReclaimController {
    private weak var model: AppModel?
    private let engine: ReclaimEngine

    init(model: AppModel, engine: ReclaimEngine = InertReclaimEngine()) {
        self.model = model
        self.engine = engine
    }

    func survey() {
        guard let model, !model.isSurveying else { return }
        model.isSurveying = true
        Task { [engine] in
            let rows = await engine.survey()
            model.catalog = rows
            // Selection never survives a re-survey: what was on screen when the
            // user ticked a box may no longer be what is on disk.
            model.selectedTargetIDs = []
            model.isSurveying = false
        }
    }

    /// Dry run. Always precedes deletion; never deletes anything itself.
    func preview() {
        guard let model, !model.selectedTargetIDs.isEmpty else { return }
        Task { [engine] in
            let plan = await engine.plan(targetIDs: model.selectedTargetIDs, from: model.catalog)
            model.pendingPlan = IdentifiablePlan(plan: plan)
        }
    }

    func execute(_ plan: ReclaimPlan) {
        guard let model else { return }
        model.pendingPlan = nil
        Task { [engine] in
            let outcome = await engine.execute(plan)
            model.lastOutcome = outcome
            // Whatever happened, the on-disk truth has changed. Re-survey rather
            // than leaving stale numbers on screen.
            self.survey()
        }
    }
}

/// The real engine. Everything destructive lives behind this one type, so the
/// inert default above stays the thing that runs unless someone deliberately
/// swaps this in.
struct LiveReclaimEngine: ReclaimEngine {
    private func makeStack() -> (CleanupCatalog, SafetyEngine, ReclaimPlanner) {
        let catalog = CleanupCatalog()
        let safety = SafetyEngine()
        return (catalog, safety, ReclaimPlanner(catalog: catalog, safety: safety))
    }

    func survey() async -> [CatalogRow] {
        let (_, _, planner) = makeStack()
        return await planner.survey().map { survey in
            CatalogRow(target: survey.entry.target,
                       foundBytes: survey.totalBytes,
                       candidates: survey.candidates)
        }
    }

    func plan(targetIDs: Set<String>, from catalog: [CatalogRow]) async -> ReclaimPlan {
        let (_, _, planner) = makeStack()
        return await planner.plan(targetIDs: targetIDs)
    }

    func execute(_ plan: ReclaimPlan) async -> ReclaimOutcome {
        // A fresh stack, deliberately: the executor re-runs every guard against
        // the machine as it is now, not as it was when the plan was drawn.
        let (catalog, safety, planner) = makeStack()
        let executor = TrashExecutor(catalog: catalog, safety: safety, planner: planner)
        return await executor.execute(plan).outcome
    }
}
