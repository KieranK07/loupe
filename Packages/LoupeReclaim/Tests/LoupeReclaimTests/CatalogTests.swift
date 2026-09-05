import Foundation
import LoupeCore
import Testing
@testable import LoupeReclaim

@Suite("Catalog")
struct CatalogTests {

    static let specIDs = [
        "xcode-derived-data", "xcode-device-support", "coresimulator-runtimes-unusable",
        "coresimulator-devices-orphaned", "homebrew-cache", "npm-cache", "pnpm-store",
        "yarn-cache", "pip-cache", "uv-cache", "docker-desktop-disk-image",
        "ios-device-backups", "mail-downloads", "trash", "browser-cache-safari",
        "browser-cache-chromium", "browser-cache-firefox", "stale-downloads",
        "dormant-node-modules",
    ]

    /// Words that promise something Loupe cannot measure, or that belong to the
    /// product category this app exists to be an alternative to.
    static let forbiddenWords = ["faster", "optimize", "optimise", "boost", "junk",
                                 "clean up your mac", "speed up", "supercharge",
                                 "recommended", "safe to remove"]

    private let sample = CleanupCatalog(home: URL(filePath: "/Users/u", directoryHint: .isDirectory))

    private func userFacingStrings() -> [(String, String)] {
        var strings: [(String, String)] = []
        for entry in sample.entries {
            strings.append((entry.id, entry.target.displayName))
            strings.append((entry.id, entry.target.whatBreaks))
            strings.append((entry.id, entry.target.regeneration))
            strings.append(contentsOf: entry.notes.map { (entry.id, $0) })
            if let copy = entry.mechanismCopy {
                strings.append((entry.id, copy.explanation))
                if let command = copy.command { strings.append((entry.id, command)) }
            }
        }
        return strings
    }

    @Test("All nineteen spec entries are present, once each, in order")
    func nineteenEntries() {
        #expect(sample.entries.count == 19)
        #expect(sample.entries.map(\.id) == Self.specIDs)
        #expect(Set(sample.entries.map(\.id)).count == 19)
    }

    @Test("Every entry says what breaks and how it comes back, in real sentences")
    func noPlaceholderProse() {
        for entry in sample.entries {
            let breaks = entry.target.whatBreaks
            let regeneration = entry.target.regeneration
            #expect(breaks.count > 40, "\(entry.id): whatBreaks is too short to be a real sentence")
            #expect(breaks.hasSuffix("."), "\(entry.id): whatBreaks must be one sentence")
            #expect(regeneration.count > 40, "\(entry.id): regeneration is too short")
            #expect(regeneration.hasSuffix("."), "\(entry.id): regeneration must end as a sentence")
            for weasel in ["various", "TODO", "TBD", "and more", "etc.", "some files", "junk"] {
                #expect(!breaks.localizedCaseInsensitiveContains(weasel),
                        "\(entry.id): whatBreaks contains \(weasel)")
                #expect(!regeneration.localizedCaseInsensitiveContains(weasel),
                        "\(entry.id): regeneration contains \(weasel)")
            }
        }
    }

    @Test("No user-facing string promises speed or calls anything junk")
    func noForbiddenWords() {
        for (id, text) in userFacingStrings() {
            for word in Self.forbiddenWords {
                #expect(!text.localizedCaseInsensitiveContains(word), "\(id): \"\(word)\" in \(text)")
            }
        }
        for rule in BlocklistRule.allCases {
            for word in Self.forbiddenWords {
                #expect(!rule.explanation.localizedCaseInsensitiveContains(word), "\(word)")
            }
        }
        for level in SafetyLevel.allCases {
            for word in Self.forbiddenWords {
                #expect(!level.label.localizedCaseInsensitiveContains(word), "\(word)")
            }
        }
    }

    @Test("Every pattern is absolute and anchored where the entry says it is")
    func patternsAreAbsolute() {
        for entry in sample.entries {
            #expect(!entry.target.patterns.isEmpty, "\(entry.id)")
            for pattern in entry.target.patterns {
                #expect(pattern.hasPrefix("/"), "\(entry.id): \(pattern) is not absolute")
                #expect(!pattern.contains("~"), "\(entry.id): \(pattern) still contains a tilde")
                #expect(!pattern.contains(".."), "\(entry.id): \(pattern) contains ..")
                if entry.target.isPerUser {
                    let anchored = pattern.hasPrefix("/Users/u/") || pattern.hasPrefix("/Volumes/")
                    #expect(anchored, "\(entry.id): \(pattern) is not under the home it was built for")
                }
            }
        }
    }

    @Test("The home a pattern is anchored at comes from the password database")
    func homeIsNotAnEnvironmentVariable() {
        let resolved = UserHome.resolved().path(percentEncoded: false)
        #expect(resolved.hasPrefix("/"))
        // Not asserting equality with $HOME — the point is that they need not be
        // the same, and the catalog uses the one an attacker cannot set.
        let live = CleanupCatalog()
        let npmPattern = live["npm-cache"]?.target.patterns.first ?? ""
        #expect(npmPattern.hasPrefix(resolved))
    }

    @Test("Each entry sits at the level the spec assigns it")
    func levelsMatchTheSpec() {
        func level(_ id: String) -> SafetyLevel? { sample[id]?.safety }

        // L1 — rebuilt from local CPU, no network.
        #expect(level("xcode-derived-data") == .rebuildsLocally)

        // L2 — nothing breaks, but the bytes come back over the network.
        for id in ["homebrew-cache", "npm-cache", "yarn-cache", "pip-cache", "uv-cache",
                   "mail-downloads", "browser-cache-safari", "browser-cache-chromium",
                   "browser-cache-firefox"] {
            #expect(level(id) == .redownloads, "\(id)")
        }

        // L3 — gigabytes, or a manual step in another tool.
        for id in ["xcode-device-support", "coresimulator-runtimes-unusable",
                   "coresimulator-devices-orphaned", "pnpm-store", "dormant-node-modules"] {
            #expect(level(id) == .redownloadsLarge, "\(id)")
        }

        #expect(level("docker-desktop-disk-image") == .losesLocalState)
        #expect(level("ios-device-backups") == .losesLocalState)
        #expect(level("trash") == .userData)
        #expect(level("stale-downloads") == .userData)

        // pnpm is the one that looks like its neighbours and is not: its store
        // is hardlinked into every installed project, so losing it costs an
        // explicit reinstall in each.
        #expect(level("pnpm-store") ?? .rebuildsLocally > level("npm-cache") ?? .userData)
    }

    @Test("Only the two levels that cost time rather than data allow select-all")
    func selectAllIsGatedByLevel() {
        #expect(SafetyLevel.rebuildsLocally.allowsSelectAll)
        #expect(SafetyLevel.redownloads.allowsSelectAll)
        #expect(!SafetyLevel.redownloadsLarge.allowsSelectAll)
        #expect(!SafetyLevel.losesLocalState.allowsSelectAll)
        #expect(!SafetyLevel.userData.allowsSelectAll)
        // Nothing that requires typed confirmation may also be swept in one click.
        for level in SafetyLevel.allCases where level.requiresTypedConfirmation {
            #expect(!level.allowsSelectAll, "\(level)")
        }
    }

    @Test("Level 4 and above require typed confirmation")
    func typedConfirmation() {
        let destructive = Set(sample.entries.filter(\.safety.requiresTypedConfirmation).map(\.id))
        let expected: Set<String> = ["docker-desktop-disk-image", "ios-device-backups",
                                     "trash", "stale-downloads"]
        #expect(destructive == expected)
        #expect(SafetyLevel.losesLocalState.requiresTypedConfirmation)
        #expect(SafetyLevel.userData.requiresTypedConfirmation)
        #expect(!SafetyLevel.redownloadsLarge.requiresTypedConfirmation)
        #expect(!SafetyLevel.rebuildsLocally.requiresTypedConfirmation)
        // Select-all is permitted only where being wrong costs time, not data.
        #expect(SafetyLevel.rebuildsLocally.allowsSelectAll)
        #expect(SafetyLevel.redownloads.allowsSelectAll)
        #expect(!SafetyLevel.redownloadsLarge.allowsSelectAll)
        #expect(!SafetyLevel.losesLocalState.allowsSelectAll)
    }

    @Test("The level-5 entries are never bulk-selectable, and neither are the delegated ones")
    func mechanismsMatchTheSpec() {
        #expect(sample["trash"]?.mechanism == .revealInFinder)
        #expect(sample["stale-downloads"]?.mechanism == .reviewOnly)
        #expect(sample["coresimulator-runtimes-unusable"]?.mechanism == .delegatedToTool)
        #expect(sample["homebrew-cache"]?.mechanism == .trash)

        // Every level-5 entry must be out of the bulk flow, by construction.
        for entry in sample.entries where entry.safety == .userData {
            #expect(!entry.target.isDeletableByLoupe, "\(entry.id)")
        }
        // And every entry Loupe steps aside from says why, in its own words.
        for entry in sample.entries {
            #expect((entry.mechanismCopy == nil) == entry.target.isDeletableByLoupe,
                    "\(entry.id)")
        }
        let delegated = sample["coresimulator-runtimes-unusable"]?.mechanismCopy
        #expect(delegated?.command == "xcrun simctl runtime delete <id>")
        #expect(sample["trash"]?.mechanismCopy?.command == nil)
    }

    @Test("The entries the spec names as needing a quit say so")
    func quitRequirements() {
        func refuses(_ id: String, _ name: String) -> Bool {
            sample[id]?.target.refuseWhileRunning.contains(name) ?? false
        }
        // Bundle identifiers and bare executable names in the same list.
        #expect(refuses("xcode-derived-data", "com.apple.dt.Xcode"))
        #expect(refuses("xcode-derived-data", "xcodebuild"))
        #expect(refuses("mail-downloads", "com.apple.mail"))
        #expect(refuses("browser-cache-safari", "com.apple.Safari"))
        #expect(refuses("docker-desktop-disk-image", "com.docker.docker"))
        #expect(refuses("docker-desktop-disk-image", "com.docker.backend"))
        #expect(refuses("homebrew-cache", "brew"))
        // The CoreSimulator helpers, which have no bundle identifier at all and
        // are the spec's own proof that an application list is not enough.
        #expect(refuses("coresimulator-devices-orphaned",
                        "com.apple.CoreSimulator.CoreSimulatorService"))
        #expect(refuses("coresimulator-devices-orphaned", "simdiskimaged"))

        // The one entry a list on the target still cannot express: eight
        // browsers, and Opera GX being open must not block Chrome's cache.
        #expect(sample["browser-cache-chromium"]?.target.refuseWhileRunning.isEmpty == true)
        #expect(sample["browser-cache-chromium"]?.perPathQuitRules.count == 8)
    }

    @Test("The Chromium exclusions are enforced, not merely omitted")
    func chromiumExclusions() {
        let excluded = sample["browser-cache-chromium"]?.excludedComponents ?? []
        for name in ["Extensions", "IndexedDB", "Local Storage", "Cookies", "History",
                     "Login Data", "Service Worker", "Sessions"] {
            #expect(excluded.contains(name), "\(name) must be a hard exclusion")
        }
        // And no include pattern reaches Application Support at all.
        for pattern in sample["browser-cache-chromium"]?.target.patterns ?? [] {
            #expect(!pattern.contains("Application Support"), "\(pattern)")
        }
    }

    @Test("Deliberately excluded paths appear in no pattern")
    func excludedPathsAreAbsent() {
        let allPatterns = sample.entries.flatMap(\.target.patterns)
        for forbidden in ["/Users/u/Library/Mail/V10", "/Users/u/Library/Logs",
                          "/Users/u/Library/Application Support/Steam", "Caskroom",
                          "/Users/u/Library/Safari"] {
            let hit = allPatterns.contains { $0.contains(forbidden) }
            #expect(!hit, "\(forbidden) is excluded by the spec and must not be globbed")
        }
        // ~/Library/Caches is never a bulk target: no pattern stops there.
        #expect(!allPatterns.contains("/Users/u/Library/Caches/*"))
        #expect(!allPatterns.contains("/Users/u/Library/Caches"))
    }

    @Test("Presence has five distinct sentences and only one of them counts")
    func presenceWording() {
        let cases: [TargetPresence] = [
            .absent,
            .configuredButUnused(tool: "uv", location: "/usr/local/bin/uv"),
            .presentButEmpty,
            .present(matches: 3),
            .locationUnknown(reason: "Loupe could not read the setting."),
        ]
        let sentences = cases.map { $0.summary(displayName: "uv cache") }
        #expect(Set(sentences).count == 5, "absent, unused, empty and unknown are different facts")
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(cases.filter(\.contributesToTotals).count == 1)
        #expect(TargetPresence.absent.summary(displayName: "x") == "Not present on this Mac.")
    }

    @Test("The Trash caveat is the spec's sentence, verbatim")
    func trashCaveat() {
        let expected = "Moving items to the Trash does not free space until the Trash is emptied."
        #expect(ReclaimPlan.trashCaveat == expected)

        let outcome = ReclaimOutcome(trashed: [URL(filePath: "/private/tmp/x")],
                                     bytesMoved: 4096, failures: [:])
        #expect(outcome.summary.contains("moved to the Trash"))
        #expect(!outcome.summary.localizedCaseInsensitiveContains("reclaimed"))
        #expect(!outcome.summary.localizedCaseInsensitiveContains("freed"))
    }
}
