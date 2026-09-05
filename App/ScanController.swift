import Foundation
import LoupeCore
import LoupeFS
import LoupeTree
import LoupeUI

/// Bridges the scan engine to the main actor.
///
/// The engine's arena is millions of nodes behind a lock; it must never cross to
/// the UI. This controller is the only place that touches both sides: it projects
/// under the arena lock on a background task, and hands the main actor nothing
/// but the small immutable `SunburstLayout` that comes out.
@MainActor
final class ScanController {
    private weak var model: AppModel?
    private var engine: ScanEngine?
    private var pump: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(model: AppModel) { self.model = model }

    func loadVolumes() {
        // VolumeCatalog does the filtering and naming: a stock Mac mounts six
        // nobrowse APFS helper volumes, and every volume in a container reports
        // the container's free space, so a raw mount table produces six entries
        // that each claim the whole disk.
        model?.volumes = VolumeCatalog.userVolumes()
        model?.selectedVolume = VolumeCatalog.defaultTarget()
    }

    func start(root: URL) {
        stop()
        generation &+= 1
        let generation = self.generation
        // Name the root after the volume, not after its mount point: the boot
        // volume's writable half is literally called "Data".
        let displayName = model?.volumes.first { $0.mountPoint == root }?.name
        let engine = ScanEngine(root: root,
                                configuration: ScanConfiguration(rootDisplayName: displayName))
        self.engine = engine

        let rootPath = root.path(percentEncoded: false)
        model?.scanState = .scanning(ScanProgress())
        model?.layout = .empty

        pump = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in engine.start() {
                switch event {
                case .started:
                    break

                case .progress(let progress):
                    await self?.reproject(engine: engine, rootPath: rootPath,
                                          generation: generation, at: .now,
                                          isComplete: false)
                    await self?.deliver(progress: progress)

                case .finished(let summary):
                    await self?.reproject(engine: engine, rootPath: rootPath,
                                          generation: generation, at: summary.finishedAt,
                                          isComplete: true)
                    await self?.complete(summary: summary)

                case .failed(let failure):
                    await self?.fail(failure)

                case .layout:
                    break   // the engine does not emit these; projection lives here
                }
            }
        }
    }

    /// Zooms without re-walking. Changing focus is a pure re-projection of an
    /// arena we already hold, so it costs a layout pass and no filesystem work.
    func focus(on node: NodeRef, basis: SizeBasis) {
        guard let engine, let model else { return }
        generation &+= 1
        let generation = self.generation
        let root = model.selectedVolume?.mountPoint.path(percentEncoded: false) ?? "/"
        let isComplete = if case .complete = model.scanState { true } else { false }
        Task { [weak self] in
            await self?.reproject(engine: engine, rootPath: root, generation: generation,
                                  at: .now, isComplete: isComplete, focus: node)
        }
    }

    func stop() {
        pump?.cancel(); pump = nil
        engine?.cancel(); engine = nil
    }

    // MARK: main-actor landings

    /// Projects whichever chart is on screen, under the arena lock and off the
    /// main actor, then hands the main actor the small immutable result.
    private func reproject(engine: ScanEngine, rootPath: String, generation: UInt64,
                           at date: Date, isComplete: Bool,
                           focus explicitFocus: NodeRef? = nil) async {
        let mode = model?.viewMode ?? .sunburst
        let basis = model?.basis ?? .physical
        let focus = explicitFocus ?? model?.currentFocus ?? .directory(0)
        let target = focus.isValid ? focus : .directory(0)

        switch mode {
        case .sunburst:
            let projector = SunburstProjector(rootPath: rootPath)
            let layout = engine.withArena {
                projector.project(arena: $0, focus: target, basis: basis,
                                  generation: generation, scannedAt: date,
                                  isComplete: isComplete)
            }
            model?.apply(layout)
        case .treemap:
            let layouter = TreemapLayouter(rootPath: rootPath)
            let layout = engine.withArena {
                layouter.layout(arena: $0, focus: target, basis: basis,
                                generation: generation, scannedAt: date,
                                isComplete: isComplete)
            }
            model?.apply(layout)
        case .bubbles:
            let packer = BubblePacker(rootPath: rootPath)
            let layout = engine.withArena {
                packer.pack(arena: $0, focus: target, basis: basis,
                            generation: generation, scannedAt: date,
                            isComplete: isComplete)
            }
            model?.apply(layout)
        }
    }

    /// Re-projects the active chart without re-walking — a view-mode switch or a
    /// basis change is a pure re-projection of an arena we already hold.
    func refresh() {
        guard let engine, let model else { return }
        generation &+= 1
        let root = model.selectedVolume?.mountPoint.path(percentEncoded: false) ?? "/"
        let isComplete = if case .complete = model.scanState { true } else { false }
        let generation = self.generation
        Task { [weak self] in
            await self?.reproject(engine: engine, rootPath: root, generation: generation,
                                  at: .now, isComplete: isComplete)
        }
    }

    private func deliver(progress: ScanProgress) {
        model?.scanState = .scanning(progress)
    }

    private func complete(summary: ScanSummary) {
        model?.scanState = .complete(summary)
        if let volume = model?.selectedVolume {
            model?.breakdown = SpaceReporter.breakdown(
                for: volume,
                scannedBytes: summary.progress.physicalBytes,
                unreadableCount: summary.progress.deniedCount)
        }
    }

    private func fail(_ failure: ScanFailure) {
        model?.scanState = .failed(failure)
    }
}
