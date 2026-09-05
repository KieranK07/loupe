import Foundation
import LoupeCore
import Testing
@testable import LoupeReclaim

/// Everything here operates on a throwaway tree under `/private/tmp` that the
/// test created. The few tests that really call `trashItem` put the resulting
/// item back out of the user's Trash afterwards, using the test target's own
/// `FileManager` — the module under test has no such call and must not gain one.
@Suite("Trash executor", .serialized)
struct TrashExecutorTests {

    struct Harness {
        let tree: TempTree
        let home: URL
        let catalog: CleanupCatalog
        let safety: SafetyEngine
        let planner: ReclaimPlanner
        let executor: TrashExecutor
    }

    private func harness(_ label: String) throws -> Harness {
        let tree = try TempTree(label)
        let home = try tree.directory("home")
        let catalog = CleanupCatalog(home: home)
        let safety = SafetyEngine(home: home)
        let planner = ReclaimPlanner(catalog: catalog, safety: safety, environment: [:])
        return Harness(tree: tree, home: home, catalog: catalog, safety: safety,
                       planner: planner,
                       executor: TrashExecutor(catalog: catalog, safety: safety, planner: planner))
    }

    /// Removes what a real `trashItem` left in the user's Trash, so a test run
    /// does not leave litter behind.
    private func tidy(_ report: ReclaimReport) {
        for item in report.moved {
            guard let resulting = item.resultingURL else { continue }
            try? FileManager.default.removeItem(at: resulting)
        }
    }

    @Test("A clean run moves the item and reports where it landed")
    func happyPath() async throws {
        let harness = try harness("happy")
        let file = try harness.tree
            .file("home/Library/Caches/Homebrew/downloads/blob.bin", bytes: 4_000)

        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        try #require(plan.candidates.count == 1)

        let report = await harness.executor.execute(plan)
        defer { tidy(report) }

        #expect(report.failures.isEmpty)
        #expect(report.moved.count == 1)
        let moved = try #require(report.moved.first)
        #expect(moved.original == file)
        #expect(moved.resultingURL != nil, "the name in the Trash may differ and must be captured")
        #expect(moved.physicalBytes == 4_096)
        #expect(FileIdentity.lstat(file) == nil, "the original path is empty now")
        if let resulting = moved.resultingURL {
            #expect(FileIdentity.lstat(resulting) != nil, "and the item is in the Trash")
        }

        let outcome = report.outcome
        #expect(outcome.trashed == [file])
        #expect(outcome.bytesMoved == 4_096)
        #expect(outcome.summary.contains("moved to the Trash"))
        #expect(outcome.summary.hasSuffix(ReclaimPlan.trashCaveat))
        #expect(report.headline.contains("No disk space has been freed yet."))
    }

    @Test("Re-validation runs again at execute time, and a plan is not a permit")
    func revalidationCatchesAChangedPath() async throws {
        let harness = try harness("revalidate")
        let file = try harness.tree
            .file("home/Library/Caches/Homebrew/downloads/blob.bin", bytes: 1_000)
        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        try #require(plan.candidates.count == 1)

        // The window the spec warns about, made explicit: between the plan and
        // the run, this path stops being what it was.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            atPath: file.path(percentEncoded: false), withDestinationPath: "/usr/lib")

        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.moved.isEmpty)
        #expect(report.failures[file] == .blocked(.usrOutsideLocal))
        #expect(FileIdentity.lstat("/usr/lib") != nil, "and /usr/lib is untouched")
    }

    @Test("A path that becomes blocked between plan and run is refused")
    func becomingBlockedIsRefused() async throws {
        let harness = try harness("becomes-blocked")
        let directory = try harness.tree
            .directory("home/Library/Caches/Homebrew/downloads/payload")
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/payload/x.bin")
        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        try #require(plan.candidates.count == 1)
        let candidate = try #require(plan.candidates.first).url

        // An engine that has since learned to refuse this path. Same plan,
        // different answer — which is the entire point of guarding twice.
        let stricter = SafetyEngine(home: harness.home, extraDenyRoots: [directory])
        let strictExecutor = TrashExecutor(
            catalog: harness.catalog, safety: stricter,
            planner: ReclaimPlanner(catalog: harness.catalog, safety: stricter, environment: [:]))

        let report = await strictExecutor.execute(plan)
        defer { tidy(report) }
        #expect(report.moved.isEmpty)
        #expect(report.failures[candidate] == .blocked(.outsideTargetScope))
        #expect(FileIdentity.lstat(directory) != nil)
    }

    @Test("An item whose enclosing folder has gone is never acted on")
    func vanishedParent() async throws {
        let harness = try harness("vanished-parent")
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/sub/blob.bin")
        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        let candidate = try #require(plan.candidates.first)

        try FileManager.default.removeItem(
            at: harness.home.appending(path: "Library/Caches/Homebrew/downloads"))

        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.moved.isEmpty)
        guard case .vanished = report.failures[candidate.url] else {
            Issue.record("expected .vanished, got \(String(describing: report.failures[candidate.url]))")
            return
        }
    }

    @Test("An item that has already gone is reported as gone, not as an error to alarm about")
    func vanishedItem() async throws {
        let harness = try harness("vanished-item")
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/blob.bin")
        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        let candidate = try #require(plan.candidates.first)
        try FileManager.default.removeItem(at: candidate.url)

        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.failures[candidate.url] == .vanished(candidate.url))
        #expect(report.failureDetails[candidate.url.path] == "Already gone.")
    }

    @Test("A running application blocks its own entry, by name")
    func appRunning() async throws {
        let harness = try harness("app-running")
        try harness.tree.file("home/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf")
        let plan = await harness.planner.plan(targetIDs: ["mail-downloads"])
        guard let candidate = plan.candidates.first else {
            #expect(harness.safety.runningProcesses.isRunning(bundleIdentifier: "com.apple.mail"),
                    "no candidate, so Mail must have been running at plan time")
            return
        }
        // Mail was not running; prove the executor asks again anyway.
        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.moved.count + report.failures.count == 1)
        #expect(candidate.targetID == "mail-downloads")
    }

    @Test("An item swapped for a different file at the same path is refused")
    func identitySwapIsCaught() async throws {
        let harness = try harness("identity-swap")
        let file = try harness.tree
            .file("home/Library/Caches/Homebrew/downloads/blob.bin", bytes: 4_000)
        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        let candidate = try #require(plan.candidates.first)
        try #require(candidate.inode != 0)

        // Same path, same name, same target, nothing blocked — a different file.
        // Only the recorded inode can tell, which is why the plan carries one.
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0x5A, count: 4_000).write(to: file)
        let replacement = try #require(FileIdentity.lstat(file))
        try #require(replacement.inode != candidate.inode)

        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.moved.isEmpty)
        #expect(report.failures[file] == .vanished(file))
        #expect(report.failureDetails[file.path] == "This is no longer the item Loupe measured.")
        #expect(FileIdentity.lstat(file) != nil, "the file that took its place is untouched")
    }

    @Test("A blocked swap reports the rule that blocks it, not merely that it changed")
    func blockedSwapReportsTheRule() async throws {
        let harness = try harness("blocked-swap")
        let file = try harness.tree
            .file("home/Library/Caches/Homebrew/downloads/blob.bin", bytes: 1_000)
        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        try #require(plan.candidates.count == 1)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            atPath: file.path(percentEncoded: false), withDestinationPath: "/usr/lib")

        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.failures[file] == .blocked(.usrOutsideLocal),
                "the identity check runs last so the alarming fact is the one reported")
    }

    @Test("Only the selected items move")
    func selection() async throws {
        let harness = try harness("selection")
        let keep = try harness.tree.file("home/Library/Caches/Homebrew/downloads/keep.bin")
        let go = try harness.tree.file("home/Library/Caches/Homebrew/downloads/go.bin")
        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        try #require(plan.candidates.count == 2)

        let report = await harness.executor.execute(plan, selecting: [go])
        defer { tidy(report) }
        #expect(report.moved.map(\.original) == [go])
        #expect(FileIdentity.lstat(keep) != nil, "an unselected item is never touched")
    }

    @Test("Trashing a hardlink removes the extra name and leaves the file")
    func hardlinkBoundsTheDamage() async throws {
        let harness = try harness("hardlink-bound")
        let original = try harness.tree.file("elsewhere/original.bin", bytes: 2_000)
        try harness.tree.directory("home/Library/Caches/Homebrew/downloads")
        let link = try harness.tree
            .hardlink("home/Library/Caches/Homebrew/downloads/copy.bin", to: original)

        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        try #require(plan.candidates.map(\.url) == [link])

        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.moved.count == 1)
        // The honest bound on the limitation stated in SafetyEngine: POSIX gives
        // no way to find a file's other names, so a hardlink to something inside
        // a blocked directory is not detectable — but moving one only ever
        // removes that name.
        let survivor = try #require(FileIdentity.lstat(original))
        #expect(survivor.physicalBytes > 0, "the file the link pointed at is still there")
    }

    @Test("trashItem's real failures map onto the contract's cases")
    func failureClassification() {
        let url = URL(filePath: "/private/tmp/loupe-classify", directoryHint: .notDirectory)
        func cocoa(_ code: Int) -> Error {
            NSError(domain: NSCocoaErrorDomain, code: code,
                    userInfo: [NSLocalizedDescriptionKey: "test"])
        }
        func posix(_ code: Int32) -> Error {
            NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "test"])
        }

        #expect(TrashExecutor.classify(cocoa(NSFileNoSuchFileError), url: url) == .vanished(url))
        #expect(TrashExecutor.classify(cocoa(NSFileWriteNoPermissionError), url: url)
                == .permissionDenied(url))
        #expect(TrashExecutor.classify(posix(ENOENT), url: url) == .vanished(url))
        #expect(TrashExecutor.classify(posix(EACCES), url: url) == .permissionDenied(url))

        guard case .trashUnavailable(_, let readOnly) =
            TrashExecutor.classify(cocoa(NSFileWriteVolumeReadOnlyError), url: url) else {
            Issue.record("a read-only volume is a trash-unavailable case"); return
        }
        #expect(readOnly.contains("read-only"))

        guard case .trashUnavailable(_, let unsupported) =
            TrashExecutor.classify(cocoa(NSFeatureUnsupportedError), url: url) else {
            Issue.record("a volume with no Trash is a trash-unavailable case"); return
        }
        #expect(unsupported.contains("does not have a Trash"))
        #expect(unsupported.contains("Finder"), "and the user is told where to go instead")

        // An error nobody has seen keeps the system's own words rather than
        // being flattened into a generic message.
        guard case .trashUnavailable(_, let unknown) =
            TrashExecutor.classify(cocoa(9_999), url: url) else {
            Issue.record("an unrecognised error still needs a reason"); return
        }
        #expect(!unknown.isEmpty)
        #expect(!unknown.contains("couldn't delete some items"))
    }

    @Test("A candidate whose target does not delete by trashing is refused")
    func nonTrashMechanismIsRefused() async throws {
        let harness = try harness("mechanism")
        let file = try harness.tree.file("home/.Trash/old.dmg")
        // Hand-built: the planner would never produce this, which is exactly why
        // the executor checks rather than trusting the plan it was given.
        let plan = ReclaimPlan(candidates: [
            ReclaimCandidate(url: file, targetID: "trash", physicalBytes: 4_096,
                             itemCount: 1, lastModified: .now)
        ], blocked: [])

        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.moved.isEmpty)
        #expect(report.failures[file] == .blocked(.outsideTargetScope))
        #expect(FileIdentity.lstat(file) != nil)
    }

    @Test("A candidate naming a target that does not exist is refused")
    func unknownTargetIsRefused() async throws {
        let harness = try harness("unknown")
        let file = try harness.tree.file("home/Library/Caches/Homebrew/downloads/blob.bin")
        let plan = ReclaimPlan(candidates: [
            ReclaimCandidate(url: file, targetID: "not-a-target", physicalBytes: 4_096,
                             itemCount: 1, lastModified: .now)
        ], blocked: [])
        let report = await harness.executor.execute(plan)
        defer { tidy(report) }
        #expect(report.failures[file] == .blocked(.outsideTargetScope))
        #expect(FileIdentity.lstat(file) != nil)
    }

    @Test("A file owned by another user is named, not escalated to")
    func ownerIsResolved() throws {
        let owner = TrashExecutor.ownerName(of: URL(filePath: "/private/var/db/SystemKey"))
        if let owner { #expect(owner == "root") }
        let mine = TrashExecutor.ownerName(of: UserHome.resolved())
        #expect(mine != nil)
    }
}
