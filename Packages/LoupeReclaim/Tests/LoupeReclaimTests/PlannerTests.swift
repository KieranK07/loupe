import Foundation
import LoupeCore
import Testing
@testable import LoupeReclaim

@Suite("Planner")
struct PlannerTests {

    struct Harness {
        let tree: TempTree
        let home: URL
        let catalog: CleanupCatalog
        let safety: SafetyEngine
        let planner: ReclaimPlanner
    }

    /// A catalog and engine rooted at a throwaway home, so the nineteen real
    /// entries can be exercised without touching the real one.
    private func harness(_ label: String) throws -> Harness {
        let tree = try TempTree(label)
        let home = try tree.directory("home")
        let catalog = CleanupCatalog(home: home)
        let safety = SafetyEngine(home: home)
        return Harness(tree: tree, home: home, catalog: catalog, safety: safety,
                       planner: ReclaimPlanner(catalog: catalog, safety: safety, environment: [:]))
    }

    @Test("An absent target reports absent, never zero bytes")
    func absentIsNotEmpty() async throws {
        let harness = try harness("absent")
        // pnpm and Yarn are the two entries whose tool is not installed here, so
        // "absent" is the whole truth about them. npm's cache directory is also
        // missing from this throwaway home, but npm itself is installed, and
        // that is a different sentence — see the next test.
        let surveys = await harness.planner.survey(targetIDs: ["pnpm-store", "yarn-cache"])
        try #require(surveys.count == 2)
        for survey in surveys {
            #expect(survey.presence == .absent, "\(survey.entry.id)")
            #expect(survey.candidates.isEmpty)
            #expect(!survey.presence.contributesToTotals)
            let sentence = survey.presence.summary(displayName: survey.entry.target.displayName)
            #expect(sentence == "Not present on this Mac.")
        }
    }

    @Test("A directory that exists and holds nothing is empty, which is a different fact")
    func presentButEmpty() async throws {
        let harness = try harness("empty")
        try harness.tree.directory("home/.npm/_cacache")
        let survey = try #require(await harness.planner.survey(targetIDs: ["npm-cache"]).first)
        #expect(survey.presence == .presentButEmpty)
        #expect(survey.candidates.isEmpty)
        #expect(survey.totalBytes == 0)
    }

    @Test("An installed tool with no cache directory says exactly that")
    func configuredButUnused() async throws {
        let tree = try TempTree("unused")
        let home = try tree.directory("home")
        let catalog = CleanupCatalog(home: home)
        let probe = try #require(catalog["uv-cache"]?.toolProbe)
        // uv is installed on this machine and its cache directory does not exist
        // in this throwaway home — the exact case R7's generic wording is
        // insufficient for.
        try #require(probe.installedLocation() != nil,
                     "this test needs uv installed; it is the spec's own example")

        let planner = ReclaimPlanner(catalog: catalog, safety: SafetyEngine(home: home),
                                     environment: [:])
        let survey = try #require(await planner.survey(targetIDs: ["uv-cache"]).first)
        guard case .configuredButUnused(let tool, let location) = survey.presence else {
            Issue.record("expected configuredButUnused, got \(survey.presence)")
            return
        }
        #expect(tool == "uv")
        #expect(location.hasSuffix("/uv"))
        let sentence = survey.presence.summary(displayName: "uv cache")
        #expect(sentence.contains("has not been created yet"))
        #expect(sentence != "Not present on this Mac.")
        #expect(survey.candidates.isEmpty)
    }

    @Test("The tool probe looks for a file and runs nothing")
    func toolProbeIsAnExistenceCheck() throws {
        let tree = try TempTree("probe")
        let binary = try tree.file("bin/faketool", bytes: 4)
        let found = ToolProbe(name: "faketool",
                              searchPaths: ["/private/tmp/loupe-no-such-tool",
                                            binary.path(percentEncoded: false)])
        #expect(found.installedLocation() == binary.path(percentEncoded: false))

        let missing = ToolProbe(name: "faketool", searchPaths: ["/private/tmp/loupe-no-such-tool"])
        #expect(missing.installedLocation() == nil)
    }

    @Test("Candidates carry physical bytes, an item count and a date")
    func candidatesAreMeasured() async throws {
        let harness = try harness("measure")
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/one/blob.bin", bytes: 5_000)
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/one/two.bin", bytes: 5_000)
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/loose.tar.gz", bytes: 900)

        let survey = try #require(await harness.planner.survey(targetIDs: ["homebrew-cache"]).first)
        #expect(survey.presence.contributesToTotals)
        #expect(survey.candidates.count == 2)

        let directory = try #require(survey.candidates.first { $0.url.lastPathComponent == "one" })
        #expect(directory.physicalBytes >= 8_192, "two 5 KB files occupy at least two blocks")
        #expect(directory.itemCount >= 2)
        #expect(directory.lastModified != nil)
        #expect(directory.targetID == "homebrew-cache")

        let name = "loose.tar.gz"
        let file = try #require(survey.candidates.first { $0.url.lastPathComponent == name })
        #expect(file.physicalBytes == 4_096, "a 900-byte file occupies one block")
        #expect(file.itemCount == 1)
        #expect(survey.totalBytes == directory.physicalBytes + file.physicalBytes)

        // Identity is recorded at plan time so the executor can prove, when it
        // acts, that the file is still the file.
        for candidate in survey.candidates {
            let identity = try #require(FileIdentity.lstat(candidate.url))
            #expect(candidate.deviceID == identity.device, "\(candidate.url.path)")
            #expect(candidate.inode == identity.inode, "\(candidate.url.path)")
            #expect(candidate.inode != 0)
        }
    }

    @Test("A refusal inside a target is surfaced in the plan, not dropped")
    func refusalsAreSurfaced() async throws {
        let harness = try harness("refusals")
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/good/blob.bin")
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/.git/config")

        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        #expect(plan.candidates.count == 1)
        #expect(plan.blocked.count == 1)
        let blocked = try #require(plan.blocked.first)
        #expect(blocked.rule == .gitDirectory)
        #expect(blocked.url.lastPathComponent == ".git")
        #expect(!blocked.rule.explanation.isEmpty)
    }

    @Test("A pattern match that resolves outside its own target is refused")
    func outsideTargetScope() async throws {
        let harness = try harness("scope")
        try harness.tree.directory("home/Library/Caches/Homebrew/downloads")
        let elsewhere = try harness.tree.directory("elsewhere")
        let precious = try harness.tree.file("elsewhere/precious.txt")
        _ = try harness.tree.symlink("home/Library/Caches/Homebrew/downloads/escape",
                                     to: elsewhere.path(percentEncoded: false))

        let plan = await harness.planner.plan(targetIDs: ["homebrew-cache"])
        #expect(plan.candidates.isEmpty)
        #expect(plan.blocked.map(\.rule) == [.outsideTargetScope])
        #expect(FileIdentity.lstat(precious) != nil)
    }

    @Test("Entries Loupe does not delete produce review items, never candidates")
    func reviewOnlyEntries() async throws {
        let harness = try harness("review")
        try harness.tree.file("home/.Trash/old.dmg", bytes: 2_000)
        try harness.tree.file("home/Downloads/installer.pkg", bytes: 2_000)

        let surveys = await harness.planner.survey(targetIDs: ["trash", "stale-downloads"])
        try #require(surveys.count == 2)
        for survey in surveys {
            #expect(survey.candidates.isEmpty, "\(survey.entry.id) must not be bulk-selectable")
            #expect(survey.reviewItems.count == 1, "\(survey.entry.id)")
            #expect(survey.reviewBytes > 0)
        }
        let plan = await harness.planner.plan(targetIDs: ["trash", "stale-downloads"])
        #expect(plan.candidates.isEmpty)
        #expect(plan.totalBytes == 0, "review-only bytes never reach a headline total")
    }

    @Test("A plan never contains a candidate from a delegated entry")
    func delegatedEntriesNeverReachThePlan() async throws {
        let harness = try harness("delegated")
        let plan = await harness.planner.plan()
        for candidate in plan.candidates {
            let entry = try #require(harness.catalog[candidate.targetID])
            #expect(entry.target.isDeletableByLoupe, "\(entry.id)")
        }
    }

    @Test("An entry with no marker file is absent, not empty")
    func markerFileGatesTheEntry() async throws {
        let harness = try harness("firefox")
        try harness.tree.file("home/Library/Caches/Firefox/Profiles/abc.default/cache2/entry")
        var survey = try #require(
            await harness.planner.survey(targetIDs: ["browser-cache-firefox"]).first)
        #expect(survey.presence == .absent, "no profiles.ini means no Firefox row at all")

        try harness.tree.file("home/Library/Application Support/Firefox/profiles.ini")
        survey = try #require(
            await harness.planner.survey(targetIDs: ["browser-cache-firefox"]).first)
        #expect(survey.presence.contributesToTotals)
        #expect(survey.candidates.count == 1)
    }

    @Test("A relocated cache is honoured only where a cache plausibly lives")
    func relocationIsValidated() throws {
        let home = URL(filePath: "/Users/u", directoryHint: .isDirectory)
        let unset = ConfiguredLocations.uvCacheDirectory(home: home, environment: [:])
        #expect(unset == .default)

        let moved = ConfiguredLocations.uvCacheDirectory(
            home: home, environment: ["UV_CACHE_DIR": "/Users/u/.cache/uv-alt"])
        #expect(moved == .relocated("/Users/u/.cache/uv-alt"))

        // The whole reason this is validated: an environment variable is
        // something another process can set.
        let hostile = ConfiguredLocations.uvCacheDirectory(
            home: home, environment: ["UV_CACHE_DIR": "/Users/u/Documents"])
        guard case .unusable = hostile else {
            Issue.record("a cache pointed at Documents must not be honoured")
            return
        }
        let relative = ConfiguredLocations.uvCacheDirectory(
            home: home, environment: ["UV_CACHE_DIR": "cache"])
        guard case .unusable = relative else {
            Issue.record("a relative UV_CACHE_DIR must not be honoured")
            return
        }
    }

    @Test("Pattern expansion matches whole names and never joins a path to match it")
    func expansion() throws {
        let tree = try TempTree("glob")
        let root = try tree.directory("cache")
        try tree.file("cache/a.bottle.tar.gz")
        try tree.file("cache/b.bottle.tar.gz.part")
        try tree.file("cache/notabottle")
        try tree.directory("cache/sub/deeper")

        let base = root.path(percentEncoded: false)
        let bottles = PatternExpander.expand(pattern: base + "/*.bottle.tar.gz")
        #expect(bottles.rootExists)
        let names = bottles.matches.map { ($0 as NSString).lastPathComponent }
        #expect(names == ["a.bottle.tar.gz"])

        let missing = PatternExpander.expand(pattern: base + "/nowhere/*")
        #expect(!missing.rootExists)
        #expect(missing.matches.isEmpty)

        let literal = PatternExpander.expand(pattern: base + "/notabottle")
        #expect(literal.matches.count == 1)
    }

    @Test("A ** search stops at the configured depth and never enters node_modules")
    func recursiveExpansion() throws {
        let tree = try TempTree("recursive")
        try tree.directory("Projects/app/node_modules/dep/node_modules")
        try tree.directory("Projects/nested/one/two/three/app2/node_modules")
        let base = tree.realRoot.appending(path: "Projects").path(percentEncoded: false)

        let found = PatternExpander.expand(pattern: base + "/**/node_modules", maximumDepth: 6)
        let parents = found.matches.map { ($0 as NSString).deletingLastPathComponent }
        #expect(found.matches.count == 2)
        #expect(parents.contains { $0.hasSuffix("/Projects/app") })
        #expect(parents.contains { $0.hasSuffix("/app2") })
        let nested = found.matches.contains { $0.contains("node_modules/dep") }
        #expect(!nested, "a nested dependency tree is not a separate project")
    }

    @Test("The dormancy gates are all conjunctive, and each says why it refused")
    func dormancyGates() throws {
        let tree = try TempTree("dormancy")
        let project = try tree.directory("Projects/app")
        try tree.directory("Projects/app/node_modules")
        let heuristic = DormancyHeuristic(thresholdDays: 180, now: .now)
        let old = Date().addingTimeInterval(-400 * 86_400)

        func verdict(_ newest: Date?) -> DormancyHeuristic.Verdict {
            heuristic.evaluate(projectRoot: project, newestSource: newest,
                               excludedPrefixes: [], caseInsensitive: true)
        }

        guard case .notOffered(let noLock) = verdict(old) else {
            Issue.record("a project with no lockfile must not be offered")
            return
        }
        #expect(noLock.contains("lockfile"))

        try tree.file("Projects/app/package-lock.json")
        try tree.file("Projects/app/package.json")

        guard case .notOffered(let recent) = verdict(Date()) else {
            Issue.record("a project edited today must not be offered")
            return
        }
        #expect(recent.contains("days ago"))

        guard case .dormant(let age) = verdict(old) else {
            Issue.record("expected dormant")
            return
        }
        #expect(age > 180)

        // A repository whose index Loupe cannot read is never offered.
        try tree.directory("Projects/app/.git")
        guard case .notOffered(let noIndex) = verdict(old) else {
            Issue.record("a repository with no readable index must not be offered")
            return
        }
        #expect(noIndex.contains("uncommitted"))

        // An index older than the newest source means work that was never
        // staged: the proxy for `git status --porcelain`, without running git.
        let index = try tree.file("Projects/app/.git/index")
        let indexPath = index.path(percentEncoded: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-500 * 86_400)],
            ofItemAtPath: indexPath)
        guard case .notOffered(let dirty) = verdict(old) else {
            Issue.record("work newer than the index must not be offered")
            return
        }
        #expect(dirty.contains("staged or committed"))

        // And a repository whose index is newer than everything in it is clean.
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: indexPath)
        guard case .dormant = verdict(old) else {
            Issue.record("a clean, old repository is the one case this entry is for")
            return
        }

        // Caches own their own node_modules.
        let treeComponents = PathComponents.normalizedComponents(
            of: tree.realRoot.path(percentEncoded: false))
        let inCache = heuristic.evaluate(projectRoot: project, newestSource: old,
                                         excludedPrefixes: [treeComponents],
                                         caseInsensitive: true)
        guard case .notOffered(let owned) = inCache else {
            Issue.record("a node_modules inside another entry's cache belongs to that entry")
            return
        }
        #expect(owned.contains("belongs to another entry"))
    }

    @Test("The dormancy threshold cannot be set below the floor")
    func dormancyFloor() {
        #expect(DormancyHeuristic(thresholdDays: 1).thresholdDays == 90)
        #expect(DormancyHeuristic().thresholdDays == 180)
    }

    @Test("The planner writes nothing")
    func plannerIsReadOnly() async throws {
        let harness = try harness("readonly")
        try harness.tree.file("home/Library/Caches/Homebrew/downloads/blob.bin")
        let path = harness.tree.root.path(percentEncoded: false)
        let before = try FileManager.default.subpathsOfDirectory(atPath: path).sorted()
        _ = await harness.planner.plan(targetIDs: ["homebrew-cache", "npm-cache", "trash"])
        let after = try FileManager.default.subpathsOfDirectory(atPath: path).sorted()
        #expect(before == after)
    }
}
