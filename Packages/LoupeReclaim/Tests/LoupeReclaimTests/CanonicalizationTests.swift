import Darwin
import Foundation
import Testing
@testable import LoupeReclaim

@Suite("Canonicalisation — spec §B.3")
struct CanonicalizationTests {

    @Test("Non-paths are rejected before anything else looks at them")
    func rejections() {
        let canonicalizer = PathCanonicalizer()
        #expect(throws: PathRejection.empty) { try canonicalizer.canonicalize(path: "") }
        #expect(throws: PathRejection.notAbsolute) {
            try canonicalizer.canonicalize(path: "relative/path")
        }
        #expect(throws: PathRejection.containsNUL) {
            try canonicalizer.canonicalize(path: "/tmp/a\u{0000}b")
        }
        #expect(throws: PathRejection.notAFileURL) {
            try canonicalizer.canonicalize(URL(string: "https://example.com/x")!)
        }
    }

    @Test("realpath resolves the classic system symlinks")
    func systemSymlinks() throws {
        let canonicalizer = PathCanonicalizer()
        #expect(try canonicalizer.canonicalize(path: "/etc").realPath == "/private/etc")
        #expect(try canonicalizer.canonicalize(path: "/var").realPath == "/private/var")
        #expect(try canonicalizer.canonicalize(path: "/tmp").realPath == "/private/tmp")
    }

    @Test("A symlink in the middle of a path is resolved, which URL.resolvingSymlinksInPath does not guarantee")
    func middleSymlink() throws {
        let tree = try TempTree("mid")
        let real = try tree.directory("real/inner")
        try tree.file("real/inner/leaf.txt")
        _ = try tree.symlink("alias", to: real.deletingLastPathComponent()
                                            .path(percentEncoded: false))

        let canonicalizer = PathCanonicalizer()
        let viaAlias = try canonicalizer.canonicalize(
            path: tree.root.appending(path: "alias/inner/leaf.txt").path(percentEncoded: false))
        let direct = try canonicalizer.canonicalize(
            path: real.appending(component: "leaf.txt").path(percentEncoded: false))
        #expect(viaAlias.components == direct.components)
        #expect(viaAlias.exists)
    }

    @Test("A path that no longer exists still canonicalises, from its deepest surviving ancestor")
    func vanishedTail() throws {
        let tree = try TempTree("gone")
        let directory = try tree.directory("here")
        let missing = directory.appending(path: "not/there.txt")

        let canonicalizer = PathCanonicalizer()
        let canonical = try canonicalizer.canonicalize(path: missing.path(percentEncoded: false))
        #expect(!canonical.exists)
        #expect(canonical.components.suffix(3) == ["here", "not", "there.txt"])
    }

    // MARK: - Firmlinks

    /// The whole reason §B.3.1 exists. `realpath` returns both spellings
    /// unchanged, so a lexical guard that trusted it would refuse one and accept
    /// the other — while they are the same inode.
    @Test("realpath does not collapse a firmlink, and the two spellings share an inode")
    func firmlinkIsNotCollapsedByRealpath() throws {
        let direct = "/private/tmp"
        let viaData = "/System/Volumes/Data/private/tmp"
        guard let long = FileIdentity.lstat(viaData) else {
            Issue.record("this machine has no /System/Volumes/Data firmlink to test against")
            return
        }
        let short = try #require(FileIdentity.lstat(direct))
        #expect(InodeKey(short) == InodeKey(long), "same file, two spellings")

        #expect(PathCanonicalizer.resolveDeepest(viaData).path == viaData,
                "realpath leaves the long spelling alone — this is the trap")
    }

    @Test("Firmlink normalisation rewrites the long spelling to the short one")
    func firmlinkNormalisation() throws {
        let table = FirmlinkTable.load()
        try #require(!table.entries.isEmpty, "expected /usr/share/firmlinks on macOS 26")

        let canonicalizer = PathCanonicalizer(firmlinks: table)
        let viaData = try canonicalizer.canonicalize(path: "/System/Volumes/Data/private/tmp")
        #expect(viaData.components == ["private", "tmp"])
        #expect(viaData.realPath == "/System/Volumes/Data/private/tmp",
                "the path handed to trashItem stays the one the user was shown")

        let users = try canonicalizer.canonicalize(path: "/System/Volumes/Data/Users")
        #expect(users.components == ["Users"])

        // The Data volume root itself is the volume root, not a folder in /System.
        let dataRoot = try canonicalizer.canonicalize(path: "/System/Volumes/Data")
        #expect(dataRoot.components.isEmpty)
    }

    @Test("An unlisted Data-volume path falls back to a bare prefix strip")
    func firmlinkFallback() {
        let table = FirmlinkTable(entries: [(system: ["Users"], data: ["Users"])])
        let rewritten = table.normalized(["System", "Volumes", "Data", "somewhere", "else"],
                                         caseInsensitive: true)
        #expect(rewritten == ["somewhere", "else"])
    }

    @Test("A missing firmlink table degrades to the prefix strip rather than failing open")
    func missingFirmlinkTable() {
        let table = FirmlinkTable.load(from: "/private/tmp/loupe-no-such-firmlinks-file")
        #expect(table.entries.isEmpty)
        #expect(table.normalized(["System", "Volumes", "Data", "Users", "u"],
                                 caseInsensitive: true) == ["Users", "u"])
    }

    @Test("/usr/local really is a firmlink, which is why the allow rule exists")
    func usrLocalIsAFirmlink() throws {
        let table = FirmlinkTable.load()
        let hasEntry = table.entries.contains { $0.system == ["usr", "local"] }
        #expect(hasEntry, "the /usr allow rule is a structural fact of the volume layout")
    }

    // MARK: - Awkward names

    @Test("Unicode, newlines and quotes survive a round trip through canonicalisation")
    func awkwardNames() throws {
        let tree = try TempTree("names")
        let directory = try tree.directory("odd")
        let names = ["caf\u{00E9}", "caf\u{0065}\u{0301}", "line\nbreak", "quo\"te",
                     "back\\slash", "$(whoami)", "; echo pwned", "space  run", "emoji-\u{1F600}"]
        let canonicalizer = PathCanonicalizer()
        for name in names {
            let url = try tree.rawNamedFile(in: directory, name: name)
            let canonical = try canonicalizer.canonicalize(url)
            #expect(canonical.exists, "\(name.debugDescription) should exist")
            #expect(canonical.components.count == PathComponents.split(
                        tree.realRoot.path(percentEncoded: false)).count + 2)
            #expect(FileIdentity.lstat(canonical.realPath) != nil)
        }
    }

    @Test("A deep tree canonicalises without recursion")
    func deepTree() throws {
        let tree = try TempTree("deep")
        let relative = (0..<80).map { "level\($0)" }.joined(separator: "/")
        let deepest = try tree.directory(relative)
        try tree.file(relative + "/leaf.txt")

        let canonicalizer = PathCanonicalizer()
        let canonical = try canonicalizer.canonicalize(
            path: deepest.appending(component: "leaf.txt").path(percentEncoded: false))
        #expect(canonical.exists)
        #expect(canonical.components.suffix(2) == ["level79", "leaf.txt"])
    }
}
