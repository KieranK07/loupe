import Foundation
import LoupeCore
import Testing
@testable import LoupeReclaim

/// §B.4's acceptance criteria, one test per row.
///
/// These are the vectors that separate component matching from string
/// matching. Every "no match" row here is a path a `hasPrefix` or a `contains`
/// would have deleted.
@Suite("Component matching — spec §B.4 vectors")
struct PathMatchingTests {

    private func components(_ path: String) -> [String] {
        PathComponents.normalizedComponents(of: path)
    }

    private func matches(_ candidate: String, rule: String, caseInsensitive: Bool = true) -> Bool {
        PathComponents.matchesSubtree(candidate: components(candidate),
                                      rule: components(rule),
                                      caseInsensitive: caseInsensitive)
    }

    // MARK: - Rule /usr/local

    @Test("The /usr/local table, case-insensitive volume", arguments: [
        ("/usr/local", true),
        ("/usr/local/bin/foo", true),
        ("/usr/localfoo", false),
        ("/usr/local-backup/x", false),
        ("/usr/localhost", false),
        ("/usr/Local/bin", true),
        ("/usr/loca", false),
        ("/usr", false),
        ("/usr/local/", true),
    ])
    func usrLocalVectors(candidate: String, expected: Bool) {
        #expect(matches(candidate, rule: "/usr/local") == expected,
                "\(candidate) against /usr/local")
    }

    @Test("Case-sensitive volumes compare exactly")
    func caseSensitiveVolume() {
        #expect(matches("/usr/Local/bin", rule: "/usr/local", caseInsensitive: false) == false)
        #expect(matches("/usr/local/bin", rule: "/usr/local", caseInsensitive: false) == true)
    }

    // MARK: - Rule /System

    @Test("The /System table", arguments: [
        ("/System", true),
        ("/System/Library/x", true),
        ("/Systemx", false),
        ("/System Volumes/x", false),
        ("/Sys", false),
        ("/system/Library", true),
    ])
    func systemVectors(candidate: String, expected: Bool) {
        #expect(matches(candidate, rule: "/System") == expected, "\(candidate) against /System")
    }

    @Test("A .. that leaves the path is folded before matching, not after")
    func dotDotIsFoldedLexically() {
        #expect(components("/private/../System/Library") == ["System", "Library"])
        #expect(matches("/private/../System/Library", rule: "/System"))
        #expect(components("/a/b/../../c") == ["c"])
        // `..` at the root stays at the root, exactly as the kernel treats it.
        #expect(components("/../../etc") == ["etc"])
        #expect(components("/a/./b") == ["a", "b"])
        #expect(components("//a///b//") == ["a", "b"])
    }

    // MARK: - Rule .git, positional-anywhere

    @Test("The .git table", arguments: [
        ("/Users/u/Projects/x/.git", true),
        ("/Users/u/Projects/x/.git/objects/ab", true),
        ("/Users/u/Projects/x/.github", false),
        ("/Users/u/Projects/x/.gitignore", false),
        ("/Users/u/Projects/.git-backup/y", false),
        ("/Users/u/.git/config", true),
        ("/Users/u/Projects/git/x", false),
    ])
    func gitVectors(candidate: String, expected: Bool) {
        #expect(PathComponents.containsComponent(candidate: components(candidate),
                                                 name: ".git",
                                                 caseInsensitive: true) == expected,
                "\(candidate) against the .git rule")
    }

    // MARK: - Group Containers

    @Test("Group Containers is two components, not one squashed word")
    func groupContainersIsNotGroupContainers() {
        let home = "/Users/u"
        let list = Blocklist(home: URL(filePath: home, directoryHint: .isDirectory))
        let denied = list.firstDenial(components: components("\(home)/Library/Group Containers/g.x"),
                                      caseInsensitive: true)
        #expect(denied?.rule == .groupContainers)

        let notDenied = list.firstDenial(components: components("\(home)/Library/GroupContainers/g.x"),
                                         caseInsensitive: true)
        #expect(notDenied == nil, "GroupContainers is a different directory and must not match")
    }

    // MARK: - Item vs subtree

    @Test("An item rule stops at the item")
    func itemRulesDoNotReachChildren() {
        let home = URL(filePath: "/Users/u", directoryHint: .isDirectory)
        let list = Blocklist(home: home)
        #expect(list.firstDenial(components: components("/Users/u/Library"),
                                 caseInsensitive: true)?.rule == .protectedContainer)
        #expect(list.firstDenial(components: components("/Users/u/Library/Caches/Homebrew"),
                                 caseInsensitive: true) == nil)
        #expect(list.firstDenial(components: components("/Users/u"),
                                 caseInsensitive: true)?.rule == .protectedContainer)
        #expect(list.firstDenial(components: components("/Applications"),
                                 caseInsensitive: true)?.rule == .protectedContainer)
        // The startup volume's root is a volume root and says so; the folders
        // above are containers and now say that instead.
        #expect(list.firstDenial(components: [], caseInsensitive: true)?.rule == .volumeRoot)
    }

    // MARK: - Allow semantics

    @Test("An allow cancels one deny and grants nothing")
    func allowSemantics() {
        let list = Blocklist(home: URL(filePath: "/Users/u", directoryHint: .isDirectory))
        #expect(list.firstDenial(components: components("/usr/lib"),
                                 caseInsensitive: true)?.rule == .usrOutsideLocal)
        #expect(list.firstDenial(components: components("/usr/local/bin/tool"),
                                 caseInsensitive: true) == nil)
        // The near miss: still inside /usr, so still denied.
        #expect(list.firstDenial(components: components("/usr/localfoo"),
                                 caseInsensitive: true)?.rule == .usrOutsideLocal)
        // Nothing cancels /System, because no allow rule names it.
        #expect(list.allows.allSatisfy { $0.components.first != "System" })
    }

    @Test("Unicode normalisation is applied before comparison")
    func unicodeNormalisation() {
        let decomposed = "Li\u{0062}rar\u{0079}"      // plain ASCII control case
        #expect(PathComponents.normalize(decomposed) == "Library")
        let decomposedE = "cafe\u{0301}"               // e + combining acute
        let precomposed = "caf\u{00E9}"
        #expect(PathComponents.normalize(decomposedE) == PathComponents.normalize(precomposed))
        #expect(PathComponents.equal(PathComponents.normalize(decomposedE),
                                     precomposed, caseInsensitive: false))
    }

    @Test("Names containing a newline or a quote are single components")
    func awkwardNamesStayWhole() {
        #expect(components("/a/we\nird/b") == ["a", "we\nird", "b"])
        #expect(components("/a/qu\"ote/b") == ["a", "qu\"ote", "b"])
        #expect(components("/a/$(whoami)/b") == ["a", "$(whoami)", "b"])
        #expect(components("/a/; echo hi/b") == ["a", "; echo hi", "b"])
    }
}
