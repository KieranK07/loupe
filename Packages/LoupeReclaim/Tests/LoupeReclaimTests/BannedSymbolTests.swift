import Foundation
import Testing
@testable import LoupeReclaim

/// The build-phase check, expressed as a test so it runs on every machine
/// rather than only in CI.
///
/// §B.8 is absolute: deletion is always `FileManager.trashItem`, and no code
/// path in this module calls anything else. The list below is the one from the
/// spec plus every route to a subprocess, because "shell out to rm" is the same
/// mistake wearing a different hat.
@Suite("Banned symbols")
struct BannedSymbolTests {

    static let sourcesDirectory: URL = {
        URL(filePath: #filePath, directoryHint: .notDirectory)
            .deletingLastPathComponent()   // LoupeReclaimTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appending(path: "Sources/LoupeReclaim", directoryHint: .isDirectory)
    }()

    static let banned = [
        "unlink(", "rmdir(", "removeItem", "remove(atPath",
        "NSTask", "Process(", "posix_spawn", "popen(", "system(",
        "execve", "execvp", "execl(", "NSAppleScript",
        "/bin/sh", "/bin/bash", "/bin/zsh", "/bin/rm",
    ]

    static func swiftSources() throws -> [(url: URL, code: String)] {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: sourcesDirectory.path)
        return try names.filter { $0.hasSuffix(".swift") }.sorted().map { name in
            let url = sourcesDirectory.appending(component: name, directoryHint: .notDirectory)
            return (url, strippingComments(try String(contentsOf: url, encoding: .utf8)))
        }
    }

    /// Removes comments, keeping string literals.
    ///
    /// Comments are stripped because a comment that says "never call unlink" is
    /// the documentation this rule wants, not a violation of it. String literals
    /// are kept because a path assembled in one would be a real way to reach a
    /// shell.
    static func strippingComments(_ source: String) -> String {
        var output = ""
        let characters = Array(source)
        var index = 0
        var blockDepth = 0

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : "\0"

            if blockDepth > 0 {
                if character == "/" && next == "*" { blockDepth += 1; index += 2; continue }
                if character == "*" && next == "/" { blockDepth -= 1; index += 2; continue }
                if character == "\n" { output.append("\n") }
                index += 1
                continue
            }
            if character == "/" && next == "/" {
                while index < characters.count && characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/" && next == "*" { blockDepth = 1; index += 2; continue }
            if character == "\"" {
                output.append(character)
                index += 1
                while index < characters.count {
                    let inner = characters[index]
                    output.append(inner)
                    index += 1
                    if inner == "\\" && index < characters.count {
                        output.append(characters[index]); index += 1; continue
                    }
                    if inner == "\"" { break }
                }
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    @Test("No source file in this module names a destructive primitive")
    func noBannedSymbols() throws {
        let sources = try Self.swiftSources()
        try #require(sources.count > 10, "expected to find the module's sources")
        for source in sources {
            for symbol in Self.banned {
                #expect(!source.code.contains(symbol),
                        "\(source.url.lastPathComponent) contains \(symbol)")
            }
        }
    }

    @Test("trashItem is present, and in exactly one file")
    func trashItemIsTheOnlyPrimitive() throws {
        let sources = try Self.swiftSources()
        let callers = sources.filter { $0.code.contains("trashItem(at:") }
        #expect(callers.count == 1)
        #expect(callers.first?.url.lastPathComponent == "TrashExecutor.swift")
    }

    @Test("The comment stripper does what the rule depends on")
    func stripperBehaviour() {
        #expect(Self.strippingComments("let a = 1 // unlink(x)\n").contains("unlink") == false)
        #expect(Self.strippingComments("/* unlink( */ let a = 1").contains("unlink") == false)
        #expect(Self.strippingComments("/* a /* b */ unlink( */ let a = 1")
                    .contains("unlink") == false)
        #expect(Self.strippingComments("let a = \"unlink(\"").contains("unlink"),
                "a literal is code, not commentary")
        #expect(Self.strippingComments("let a = \"say \\\" then // not a comment\"")
                    .contains("not a comment"))
    }
}
