import Darwin
import Foundation
import LoupeCore
import Testing
@testable import LoupeReclaim

@Suite("Safety engine")
struct SafetyEngineTests {

    private func ownExecutablePath() -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        return decodePath(buffer, length: length)
    }

    private var permissive: SafetyScope { SafetyScope(targetID: "test", roots: [[]]) }

    // MARK: - Closed by default

    @Test("Without a target claiming it, nothing is deletable")
    func closedByDefault() throws {
        let tree = try TempTree("closed")
        let file = try tree.file("anything.txt")
        let verdict = SafetyEngine().evaluate(file, scope: nil)
        #expect(verdict.rule == .outsideTargetScope)
        #expect(!verdict.isAllowed)
    }

    @Test("A path inside a declared scope, breaking no rule, is allowed")
    func theHappyPath() throws {
        let tree = try TempTree("allow")
        let target = try tree.directory("cache")
        let file = try tree.file("cache/blob.bin")
        #expect(SafetyEngine().evaluate(file, scope: scope("t", roots: [target])).isAllowed)
    }

    // MARK: - The named rules, positively

    @Test("Every blocklist rule refuses its own subtree", arguments: [
        ("/System/Library/CoreServices", BlocklistRule.systemPath),
        ("/usr/lib", BlocklistRule.usrOutsideLocal),
        ("/usr/localfoo", BlocklistRule.usrOutsideLocal),
        ("/bin/sh", BlocklistRule.systemPath),
        ("/sbin/mount", BlocklistRule.systemPath),
        ("/private/var/db/SystemKey", BlocklistRule.keychains),
        ("/private/var/folders", BlocklistRule.systemPath),
    ])
    func absoluteRules(path: String, expected: BlocklistRule) {
        let url = URL(filePath: path, directoryHint: .inferFromPath)
        // A permissive scope is passed deliberately: the point is that the
        // blocklist refuses regardless of what a target claims.
        let actual = SafetyEngine().evaluate(url, scope: permissive).rule
        #expect(actual == expected, "\(path)")
    }

    @Test("The system directories carry SF_RESTRICTED, and the guard does not need it")
    func flagsAndBlocklistAreIndependent() throws {
        // §B.2's measured justification: two of the six required entries carry
        // no protective flag at all, and /usr/local carries one but must be
        // allowed. Neither mechanism subsumes the other.
        let system = try #require(FileIdentity.lstat("/System"))
        #expect(system.flags & ProtectionFlags.sfRestricted != 0)

        let usrLocal = try #require(FileIdentity.lstat("/usr/local"))
        let restricted = usrLocal.flags & ProtectionFlags.sfRestricted
        #expect(restricted == 0, "/usr/local must be reachable; hence the allow rule")

        let home = UserHome.resolved()
        if let keychains = FileIdentity.lstat(home.appending(path: "Library/Keychains")) {
            let flagged = keychains.flags & ProtectionFlags.sfRestricted
            #expect(flagged == 0, "the keychain directory has no flag; only the blocklist protects it")
        }
    }

    @Test("Home-relative rules are anchored at the real home, not at a string")
    func homeRules() throws {
        let tree = try TempTree("home")
        let home = try tree.directory("home")
        let engine = SafetyEngine(home: home)

        let keychain = try tree.file("home/Library/Keychains/login.keychain-db")
        let groups = try tree.file("home/Library/Group Containers/group.x/data.bin")
        let tcc = try tree.file("home/Library/Application Support/com.apple.TCC/TCC.db")
        let inScope = scope("t", roots: [home])

        #expect(engine.evaluate(keychain, scope: inScope).rule == .keychains)
        #expect(engine.evaluate(groups, scope: inScope).rule == .groupContainers)
        #expect(engine.evaluate(tcc, scope: inScope).rule == .systemPath)

        // Item rules: the folder is refused, its contents are the whole point.
        let library = home.appending(path: "Library")
        #expect(engine.evaluate(library, scope: inScope).rule == .protectedContainer)
        let cache = try tree.file("home/Library/Caches/Homebrew/downloads/bottle.tar.gz")
        #expect(engine.evaluate(cache, scope: inScope).isAllowed)
    }

    @Test("The .git rule denies .git and nothing that merely starts with it")
    func gitRule() throws {
        let tree = try TempTree("git")
        let project = try tree.directory("Projects/app")
        try tree.file("Projects/app/.git/config")
        try tree.file("Projects/app/.gitignore")
        try tree.file("Projects/app/.github/workflows/ci.yml")
        try tree.file("Projects/app/.git-backup/old")

        let engine = SafetyEngine()
        let inScope = scope("t", roots: [project])

        #expect(engine.evaluate(project.appending(path: ".git/config"), scope: inScope).rule == .gitDirectory)
        #expect(engine.evaluate(project.appending(path: ".git"), scope: inScope).rule == .gitDirectory)
        #expect(engine.evaluate(project.appending(path: ".gitignore"), scope: inScope).isAllowed)
        #expect(engine.evaluate(project.appending(path: ".github/workflows/ci.yml"), scope: inScope).isAllowed)
        #expect(engine.evaluate(project.appending(path: ".git-backup/old"), scope: inScope).isAllowed)
    }

    @Test("Group Containers is refused; GroupContainers is a different folder")
    func groupContainersNearMiss() throws {
        let tree = try TempTree("groups")
        let home = try tree.directory("home")
        let engine = SafetyEngine(home: home)
        let inScope = scope("t", roots: [home])

        let real = try tree.file("home/Library/Group Containers/group.x/data")
        let lookalike = try tree.file("home/Library/GroupContainers/group.x/data")
        #expect(engine.evaluate(real, scope: inScope).rule == .groupContainers)
        #expect(engine.evaluate(lookalike, scope: inScope).isAllowed,
                "a folder that is merely spelled similarly is not the protected one")
    }

    // MARK: - Aliasing

    @Test("A symlink inside a target that points at a blocked path is refused")
    func symlinkToBlocked() throws {
        let tree = try TempTree("symblock")
        let target = try tree.directory("cache")
        let evil = try tree.symlink("cache/evil", to: "/usr/lib")
        let verdict = SafetyEngine().evaluate(evil, scope: scope("t", roots: [target]))
        #expect(verdict.rule == .usrOutsideLocal)
    }

    @Test("A symlink that points out of the target's own scope is refused")
    func symlinkOutOfScope() throws {
        let tree = try TempTree("symscope")
        let target = try tree.directory("cache")
        let elsewhere = try tree.directory("elsewhere")
        let precious = try tree.file("elsewhere/precious.txt")
        let escape = try tree.symlink("cache/escape", to: elsewhere.path(percentEncoded: false))

        let verdict = SafetyEngine().evaluate(escape, scope: scope("t", roots: [target]))
        #expect(verdict.rule == .outsideTargetScope)
        #expect(FileIdentity.lstat(precious) != nil)
    }

    @Test("A .. that climbs out of the target is refused")
    func dotDotEscape() throws {
        let tree = try TempTree("dotdot")
        let target = try tree.directory("cache")
        let outside = try tree.file("outside/keepme.txt")
        let escaping = target.appending(path: "../outside/keepme.txt")

        let verdict = SafetyEngine().evaluate(escaping, scope: scope("t", roots: [target]))
        #expect(verdict.rule == .outsideTargetScope)
        #expect(FileIdentity.lstat(outside) != nil)
    }

    @Test("A hardlink to a denied file is refused by inode, not by name")
    func hardlinkIsCaughtByIdentity() throws {
        let tree = try TempTree("hardlink")
        let secret = try tree.file("blocked/secret.key")
        let target = try tree.directory("cache")
        let link = try tree.hardlink("cache/innocent.bin", to: secret)
        let inScope = scope("t", roots: [target])

        #expect(SafetyEngine().evaluate(link, scope: inScope).isAllowed,
                "nothing in the name of this path says what it points at")

        let guarded = SafetyEngine(extraDenyRoots: [secret])
        let verdict = guarded.evaluate(link, scope: inScope)
        #expect(!verdict.isAllowed, "the inode is the same file, whatever it is called")
        #expect(verdict.rule == .outsideTargetScope)

        // And the identity walk reaches ancestors too, not only the candidate.
        let byDirectory = SafetyEngine(extraDenyRoots: [target])
        #expect(!byDirectory.evaluate(link, scope: inScope).isAllowed)
    }

    @Test("A firmlinked spelling of a denied path is still denied")
    func firmlinkedSpellingIsDenied() {
        let engine = SafetyEngine()
        let home = UserHome.resolved().path(percentEncoded: false)
        let viaData = URL(filePath: "/System/Volumes/Data" + home + "/Library/Keychains",
                          directoryHint: .isDirectory)
        #expect(engine.evaluate(viaData, scope: permissive).rule == .keychains,
                "prefixing /System/Volumes/Data must not launder a blocked path")

        // And the reverse: the long spelling of an ordinary path is not treated
        // as part of /System.
        let ordinary = URL(filePath: "/System/Volumes/Data/private/tmp", directoryHint: .isDirectory)
        #expect(engine.evaluate(ordinary, scope: permissive).rule != .systemPath)
    }

    // MARK: - Flags

    @Test("The flag constants match the SDK's")
    func flagConstantsMatchDarwin() {
        #expect(ProtectionFlags.sfRestricted == UInt32(SF_RESTRICTED))
        #expect(ProtectionFlags.sfDataless == UInt32(SF_DATALESS))
        #expect(ProtectionFlags.sfNoUnlink == UInt32(SF_NOUNLINK))
        #expect(ProtectionFlags.sfImmutable == UInt32(SF_IMMUTABLE))
        #expect(ProtectionFlags.sfFirmlink == UInt32(SF_FIRMLINK))
        #expect(ProtectionFlags.ufImmutable == UInt32(UF_IMMUTABLE))
        #expect(ProtectionFlags.ufDataVault == UInt32(UF_DATAVAULT))
        #expect(ProtectionFlags.sfRestricted == 0x0008_0000)
        #expect(ProtectionFlags.sfDataless == 0x4000_0000)
    }

    @Test("Each flag refuses at the right reach", arguments: [
        (UInt32(SF_RESTRICTED), true, BlocklistRule.sipRestricted),
        (UInt32(UF_DATAVAULT), true, BlocklistRule.sipRestricted),
        (UInt32(SF_DATALESS), false, BlocklistRule.icloudPlaceholder),
        (UInt32(SF_NOUNLINK), false, BlocklistRule.protectedContainer),
        (UInt32(SF_FIRMLINK), false, BlocklistRule.volumeRoot),
        (UInt32(SF_IMMUTABLE), false, BlocklistRule.lockedItem),
        (UInt32(UF_IMMUTABLE), false, BlocklistRule.lockedItem),
    ])
    func flagReach(flag: UInt32, reachesAncestors: Bool, expected: BlocklistRule) {
        let identity = FileIdentity(device: 1, inode: 2, flags: flag, mode: UInt16(S_IFREG),
                                    uid: 501, physicalBytes: 0, logicalBytes: 0, modified: .now)
        let asCandidate = SafetyEngine.flagRefusal(identity: identity, isCandidate: true)
        #expect(asCandidate?.rule == expected)

        let asAncestor = SafetyEngine.flagRefusal(identity: identity, isCandidate: false)
        #expect((asAncestor != nil) == reachesAncestors)
        if reachesAncestors { #expect(asAncestor?.rule == expected) }
    }

    @Test("A locked file is refused end to end")
    func lockedFileIsRefused() throws {
        let tree = try TempTree("locked")
        let target = try tree.directory("cache")
        let file = try tree.file("cache/locked.bin")
        let path = file.path(percentEncoded: false)
        try #require(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(path, 0) }

        let verdict = SafetyEngine().evaluate(file, scope: scope("t", roots: [target]))
        #expect(verdict.rule == .lockedItem)
        #expect(verdict.detail?.contains("Locked") == true)
        #expect(verdict.rule?.explanation.contains("Get Info") == true,
                "a file the user locked is not a file macOS protected")
    }

    @Test("A dataless placeholder reports zero bytes, so R4 needs no separate arithmetic")
    func datalessCountsAsZero() {
        let identity = FileIdentity(device: 1, inode: 2, flags: UInt32(SF_DATALESS),
                                    mode: UInt16(S_IFREG), uid: 501,
                                    physicalBytes: 0, logicalBytes: 50_226, modified: .now)
        #expect(identity.physicalBytes == 0)
        let refusal = SafetyEngine.flagRefusal(identity: identity, isCandidate: true)
        #expect(refusal?.rule == .icloudPlaceholder)
    }

    // MARK: - Running processes

    @Test("The process index sees processes with no application presence")
    func processIndexSeesNonGUIProcesses() {
        let index = RunningProcessIndex.snapshot(canonicalizer: PathCanonicalizer())
        #expect(!index.occupiedRoots.isEmpty)
        #expect(index.executableNames.count > index.bundleIdentifiers.count,
                "there are always more processes than there are applications")
        #expect(index.executableNames.contains("launchd"))
    }

    @Test("A path belonging to a live process is refused")
    func liveProcessPathIsRefused() throws {
        let executable = ownExecutablePath()
        try #require(!executable.isEmpty)
        let url = URL(filePath: executable, directoryHint: .notDirectory)
        #expect(SafetyEngine().evaluate(url, scope: permissive).rule == .runningAppBundle)
    }

    @Test("A scope that names a running executable refuses everything in it")
    func scopeNamingRunningExecutable() throws {
        let tree = try TempTree("running")
        let target = try tree.directory("cache")
        let file = try tree.file("cache/blob.bin")
        let name = (ownExecutablePath() as NSString).lastPathComponent
        let guarded = scope("t", roots: [target], refusing: [name])
        #expect(SafetyEngine().evaluate(file, scope: guarded).rule == .runningAppBundle)
    }

    @Test("A scope that names a running application refuses everything in it")
    func scopeNamingRunningBundleID() throws {
        let tree = try TempTree("quit")
        let target = try tree.directory("cache")
        let file = try tree.file("cache/blob.bin")
        let engine = SafetyEngine()
        // The Finder is always running on a logged-in Mac; if it somehow is not,
        // the assertion would be about the wrong thing, so it is checked first.
        try #require(engine.runningProcesses.isRunning(bundleIdentifier: "com.apple.finder"))
        // One list, checked as a bundle identifier and as an executable name,
        // because the catalog cannot always tell which a given string is.
        let guarded = scope("t", roots: [target], refusing: ["com.apple.finder"])
        #expect(engine.evaluate(file, scope: guarded).rule == .runningAppBundle)
    }

    @Test("The bundle walk stops at the outermost bundle, not the innermost helper")
    func outermostBundle() {
        let nested = "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/helper"
        #expect(RunningProcessIndex.outermostBundle(of: nested) == "/Applications/Claude.app")

        let framework = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/service"
        let expected = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"
        #expect(RunningProcessIndex.outermostBundle(of: framework) == expected)
        #expect(RunningProcessIndex.outermostBundle(of: "/usr/bin/true") == nil)
    }

    @Test("Open file handles are found without root, for every process we own")
    func openFileIndex() throws {
        let tree = try TempTree("openfiles")
        let directory = try tree.directory("held")
        let file = try tree.file("held/locked.bin")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let index = OpenFileIndex.snapshot()
        #expect(index.openPathCount > 0)
        #expect(index.processesInspected > 0)

        let roots = PathComponents.normalizedComponents(
            of: PathCanonicalizer.resolveDeepest(directory.path(percentEncoded: false)).path)
        let occupant = index.occupant(of: roots, caseInsensitive: true)
        #expect(occupant != nil, "a file this process is holding open must be visible")
    }

    // MARK: - Scope

    @Test("A per-entry exclusion is enforced by the engine, not by the pattern")
    func excludedComponents() throws {
        let tree = try TempTree("excluded")
        let target = try tree.directory("Chrome")
        let extensions = try tree.file("Chrome/Default/Extensions/abc/manifest.json")
        let cache = try tree.file("Chrome/Default/Cache/data_0")
        let engine = SafetyEngine()
        let chromeScope = scope("browser-cache-chromium", roots: [target],
                                excluding: ["Extensions", "Cookies"])
        #expect(engine.evaluate(extensions, scope: chromeScope).rule == .outsideTargetScope)
        #expect(engine.evaluate(cache, scope: chromeScope).isAllowed)
    }

    // MARK: - Volumes

    @Test("Volume roots and read-only volumes are refused")
    func volumes() throws {
        let engine = SafetyEngine()
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let dataRoot = URL(filePath: "/System/Volumes/Data", directoryHint: .isDirectory)
        #expect(engine.evaluate(root, scope: permissive).rule == .volumeRoot)
        #expect(engine.evaluate(dataRoot, scope: permissive).rule == .volumeRoot)

        let sealed = try #require(VolumeFacts.of("/"))
        #expect(sealed.isReadOnly, "the sealed system volume is mounted read-only")
        #expect(sealed.mountPoint == "/")
    }

    @Test("Every BlocklistRule the engine can return has a user-facing sentence")
    func everyRuleExplainsItself() {
        for rule in BlocklistRule.allCases {
            #expect(!rule.explanation.isEmpty)
            #expect(rule.explanation.hasSuffix("."))
        }
    }
}
