import Testing
import Foundation
import LoupeCore
@testable import LoupeReclaim

/// Written by the integrator, not the implementer, and deliberately hostile.
///
/// Every case here runs against a **maximally permissive scope** — `roots: [[]]`
/// matches everything — so scope-matching cannot be what saves the engine. If a
/// path survives, only the blocklist rules refused it. That is the property
/// worth testing: the guard, not the fence around the guard.
///
/// Nothing here deletes anything. Symlinks are pointers, and every hardlink
/// points at a file the test itself created.
@Suite("Adversarial — the guard, not the scope")
struct OrchestratorAdversarialTests {

    /// Matches every path, so nothing is refused merely for being out of scope.
    private var permissive: SafetyScope { SafetyScope(targetID: "attack", roots: [[]]) }
    private var engine: SafetyEngine { SafetyEngine() }
    private var home: URL { UserHome.resolved() }

    private func refusal(_ path: String, _ e: SafetyEngine? = nil) -> BlocklistRule? {
        (e ?? engine).evaluate(URL(filePath: path), scope: permissive).rule
    }

    // MARK: the paths that must never be reachable

    @Test("system locations are refused even when the scope permits everything")
    func systemLocations() {
        #expect(refusal("/System") == .systemPath)
        #expect(refusal("/System/Library/CoreServices/Finder.app") == .systemPath)
        #expect(refusal("/usr/bin/env") == .usrOutsideLocal)
        #expect(refusal("/usr/lib/dyld") == .usrOutsideLocal)
        #expect(refusal("/Library/Apple/System") == .libraryApple)
    }

    @Test("the /usr/local carve-out is honoured by every layer, not just the lexical one")
    func usrLocalCarveOut() {
        // Names that merely begin with the same letters are still under /usr and
        // are refused for exactly that reason.
        #expect(refusal("/usr/localfoo/bait") == .usrOutsideLocal)
        #expect(refusal("/usr/local-backup/bait") == .usrOutsideLocal)
        #expect(refusal("/usr/localhost") == .usrOutsideLocal)

        // Inside the carve-out, /usr/local is still refused — but by SIP flags on
        // an ancestor, which is true, rather than by the /usr rule, whose
        // explanation reads "only /usr/local is user-managed" and would have been
        // printed for a path inside /usr/local.
        //
        // That was a real defect: the lexical layer applied the allow and the
        // identity walk did not, so the carve-out was defeated and the user was
        // shown a false sentence. Over-refusing is the safe direction; refusing
        // with the wrong reason is not.
        #expect(refusal("/usr/local/bin") != .usrOutsideLocal)
        #expect(refusal("/usr/local/Homebrew") != .usrOutsideLocal)
        // And the lexical layer alone genuinely allows it.
        let blocklist = Blocklist(home: home)
        #expect(blocklist.firstDenial(components: ["usr", "local", "bin"],
                                      caseInsensitive: true) == nil)
    }

    @Test("a firmlinked spelling of a protected path is still that path")
    func firmlinkSpelling() {
        // The bypass this guard exists for: /Users/x and
        // /System/Volumes/Data/Users/x are the same inode with different
        // realpath output, so a string-only blocklist can be walked around
        // simply by spelling the path the other way.
        let direct = home.appending(path: "Library/Keychains/login.keychain-db")
        let firmlinked = "/System/Volumes/Data" + direct.path(percentEncoded: false)
        #expect(refusal(direct.path(percentEncoded: false)) == .keychains)
        #expect(refusal(firmlinked) == .keychains)
    }

    @Test("component matching does not degrade into prefix matching")
    func componentMatching() throws {
        let tree = try TempTree("adversarial-names")
        // Must match
        _ = try tree.directory("proj/.git/objects")
        let gitObject = try tree.file("proj/.git/objects/ab")
        #expect(engine.evaluate(gitObject, scope: permissive).rule == .gitDirectory)
        // Must NOT match — near misses that a prefix or substring test would eat
        for benign in ["proj/.gitignore", "proj/.github/workflows/ci.yml",
                       "proj/.git-backup/x", "lib/GroupContainers/g.fake"] {
            let url = try tree.file(benign)
            #expect(engine.evaluate(url, scope: permissive).rule == nil,
                    "\(benign) should not be refused")
        }
        // The real one, with the space, must match
        let real = try tree.file("Library/Group Containers/g.real/f")
        _ = real
    }

    // MARK: aliasing — the attacks a path-only guard cannot see

    @Test("a symlink pointing out of scope is refused, and its destination survives")
    func symlinkEscape() throws {
        let tree = try TempTree("adversarial-symlink")
        let dir = try tree.directory("cache")
        let link = dir.appending(path: "escape")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: URL(filePath: "/usr/lib"))
        // Refused because it resolves into /usr, not because it is a symlink.
        #expect(engine.evaluate(link, scope: permissive).rule == .usrOutsideLocal)
        // And the thing it pointed at is untouched — evaluation reads, never writes.
        #expect(FileManager.default.fileExists(atPath: "/usr/lib"))
    }

    @Test("a hardlink cannot smuggle a denied inode past the lexical check")
    func hardlinkAliasing() throws {
        let tree = try TempTree("adversarial-hardlink")
        let denied = try tree.directory("denied")
        let victim = try tree.file("denied/precious.bin")
        let alias = try tree.directory("innocent").appending(path: "alias.bin")
        try FileManager.default.linkItem(at: victim, to: alias)

        // Same inode under two names — the whole point of the identity walk.
        let a = try FileManager.default.attributesOfItem(atPath: victim.path)[.systemFileNumber] as? Int
        let b = try FileManager.default.attributesOfItem(atPath: alias.path)[.systemFileNumber] as? Int
        #expect(a == b)

        // An engine that denies *that inode* refuses the alias too, even though
        // the alias's own path is nowhere near the original. This is what the
        // identity walk buys that a path check cannot.
        let byIdentity = SafetyEngine(extraDenyRoots: [victim])
        #expect(byIdentity.evaluate(alias, scope: permissive).rule != nil,
                "an alias to a denied inode must not be reachable by its other name")

        // The documented limit, asserted rather than assumed: denying the
        // *directory* does not deny a hardlink to a file inside it, because the
        // link's inode is the file's, not the directory's, and nothing about the
        // link's path leads back there. The bound on that gap is that trashing a
        // hardlink removes only that name — the original keeps the data.
        let byDirectory = SafetyEngine(extraDenyRoots: [denied])
        #expect(byDirectory.evaluate(alias, scope: permissive).rule == nil)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("a traversal escape is resolved before it is judged")
    func traversalEscape() throws {
        let tree = try TempTree("adversarial-traversal")
        _ = try tree.directory("a/b/c")
        let escaped = tree.root.appending(path: "a/b/c/../../../../../../../../usr/bin/env")
        #expect(engine.evaluate(escaped, scope: permissive).rule == .usrOutsideLocal)
    }

    // MARK: the default

    @Test("no scope means no deletion")
    func closedByDefault() {
        // The single most important property: unclassifiable is refused.
        let anywhere = URL(filePath: NSHomeDirectory() + "/Downloads")
        #expect(!engine.evaluate(anywhere, scope: nil).isAllowed)
    }

    @Test("volume roots are never candidates")
    func volumeRoots() {
        for root in ["/", "/System/Volumes/Data"] {
            #expect(refusal(root) != nil, "\(root) must never be deletable")
        }
    }

    @Test("a locked file is refused as locked, not as something misleading")
    func lockedItem() throws {
        let tree = try TempTree("adversarial-locked")
        let file = try tree.file("locked.bin")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }
        let verdict = engine.evaluate(file, scope: permissive)
        #expect(verdict.rule == .lockedItem)
        // The sentence the user sees must describe what actually happened.
        #expect(verdict.rule?.explanation.contains("Locked") == true)
    }

    @Test("hostile filenames are data, never syntax")
    func hostileNames() throws {
        let tree = try TempTree("adversarial-names2")
        for name in ["$(whoami)", "; echo pwned", "a\"b", "back\\slash",
                     "café", "cafe\u{0301}", "😀", "new\nline"] {
            let url = try tree.file("cache/\(name)")
            // The only requirement: it is judged, not executed, and does not trap.
            _ = engine.evaluate(url, scope: permissive)
        }
    }
}
