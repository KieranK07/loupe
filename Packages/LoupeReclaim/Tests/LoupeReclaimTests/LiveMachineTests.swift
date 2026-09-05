import Foundation
import LoupeCore
import Testing
@testable import LoupeReclaim

extension Tag {
    /// Runs against the real machine rather than a fixture. Asserts invariants
    /// that must hold whatever is installed, and prints what it found instead of
    /// asserting a size no other machine would reproduce.
    @Tag static var live: Self
}

@Suite("Live machine", .tags(.live))
struct LiveMachineTests {

    @Test("A survey of this Mac holds every invariant, whatever is installed")
    func liveSurvey() async throws {
        let catalog = CleanupCatalog()
        let safety = SafetyEngine()
        let planner = ReclaimPlanner(catalog: catalog, safety: safety)
        let surveys = await planner.survey()
        #expect(surveys.count == 19)

        var summary: [String] = []
        for survey in surveys {
            let entry = survey.entry
            summary.append("\(entry.id): \(survey.presence)"
                           + " — \(survey.candidates.count) selectable,"
                           + " \(survey.reviewItems.count) to review,"
                           + " \(survey.blocked.count) refused,"
                           + " \(ByteFormat.string(survey.totalBytes + survey.reviewBytes))")

            if !entry.target.isDeletableByLoupe {
                #expect(survey.candidates.isEmpty, "\(entry.id) must not be bulk-selectable")
            }
            if case .absent = survey.presence {
                #expect(survey.totalBytes == 0, "\(entry.id)")
                #expect(survey.reviewBytes == 0, "\(entry.id)")
            }

            let scope = planner.scope(for: entry)
            for candidate in survey.candidates + survey.reviewItems {
                let verdict = safety.evaluate(candidate.url, scope: scope)
                #expect(verdict.isAllowed,
                        "\(candidate.url.path) survived the plan but not a re-check")
                let canonical = try #require(verdict.canonical)
                #expect(scope.contains(canonical.components,
                                       caseInsensitive: canonical.caseInsensitive),
                        "\(candidate.url.path) is outside \(entry.id)")
                let identity = try #require(FileIdentity.lstat(candidate.url))
                #expect(candidate.deviceID == identity.device && candidate.inode == identity.inode,
                        "\(candidate.url.path) was recorded without its identity")
            }
            // Every refusal names a rule that can explain itself to a person.
            for blocked in survey.blocked {
                #expect(!blocked.rule.explanation.isEmpty)
                #expect(survey.refusalDetails[blocked.url.path] != nil,
                        "\(blocked.url.path) was refused without a stated reason")
            }
        }
        print("Loupe reclaim survey of this Mac:\n  " + summary.joined(separator: "\n  "))
    }

    /// The single largest opportunity in the app to inflate a number by 279x.
    @Test("A sparse disk image is reported at its allocated size, not its reserved one")
    func sparseFileIsNotInflated() async throws {
        let catalog = CleanupCatalog()
        let safety = SafetyEngine()
        let planner = ReclaimPlanner(catalog: catalog, safety: safety)
        let survey = try #require(
            await planner.survey(targetIDs: ["docker-desktop-disk-image"]).first)
        guard let candidate = survey.candidates.first ?? survey.reviewItems.first else {
            #expect(!survey.presence.contributesToTotals,
                    "no Docker disk image here, so nothing should be counted")
            return
        }
        let identity = try #require(FileIdentity.lstat(candidate.url))
        #expect(candidate.physicalBytes == identity.physicalBytes)
        if identity.logicalBytes > identity.physicalBytes {
            #expect(candidate.physicalBytes < identity.logicalBytes,
                    "the reported figure must be the blocks on disk, never the reserved size")
            print("Docker.raw: \(ByteFormat.string(identity.physicalBytes)) on disk, "
                  + "\(ByteFormat.string(identity.logicalBytes)) reserved")
        }
    }

    @Test("The firmlink table on this machine names the paths the guard depends on")
    func firmlinkTableIsReal() {
        let table = FirmlinkTable.load()
        let systemPaths = Set(table.entries.map { PathComponents.join($0.system) })
        for expected in ["/Users", "/Applications", "/private", "/usr/local", "/Volumes"] {
            #expect(systemPaths.contains(expected), "\(expected) should be a firmlink")
        }
    }

    /// Answers the spec's open question 4, which lists this as unverified in
    /// Swift. It works, without root, and costs milliseconds.
    @Test("Open file handles across the whole machine are readable at plan cost")
    func openFileIndexIsAffordable() {
        let start = ContinuousClock.now
        let index = OpenFileIndex.snapshot()
        let elapsed = start.duration(to: .now)
        #expect(index.processesInspected > 0)
        #expect(index.openPathCount > 100)
        print("open-file index: \(index.openPathCount) paths from "
              + "\(index.processesInspected) processes in \(elapsed) "
              + "(\(index.processesRefused) refused)")
    }
}
