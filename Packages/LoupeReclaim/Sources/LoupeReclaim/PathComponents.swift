import Foundation

/// Whole-component path matching.
///
/// The single most important property of this file is what it does *not*
/// contain: no `hasPrefix`, no `contains`, no `range(of:)`, no regex over a
/// joined path string. Every one of those makes `/usr/localfoo` a match for
/// `/usr/local` and `.gitignore` a match for `.git`, and both of those mistakes
/// end with the app deleting something it was told not to touch.
public enum PathComponents {

    /// Splits an absolute POSIX path into components, dropping the empties that
    /// a leading, trailing or doubled separator produces, and folding away `.`
    /// and `..` lexically.
    ///
    /// The `..` folding is not a convenience. A candidate that spells its way
    /// out of its own target with `../../..` must be evaluated at the place it
    /// actually lands, and for a path that does not exist there is no
    /// `realpath` to do that for us.
    public static func split(_ path: String) -> [String] {
        var components: [String] = []
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
                // A `..` at the root stays at the root, exactly as the kernel
                // treats `/..`.
            default:
                components.append(String(piece))
            }
        }
        return components
    }

    /// NFC. APFS compares names normalisation-insensitively, so a decomposed
    /// "Library" and a precomposed "Library" are the same directory; comparing
    /// the raw UTF-8 would let one of them walk past a rule written with the
    /// other.
    public static func normalize(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping
    }

    public static func normalize(components: [String]) -> [String] {
        components.map(normalize)
    }

    /// Splits and normalises in one step. Callers that already hold a canonical
    /// path use this; everything else goes through `CanonicalPath`.
    public static func normalizedComponents(of path: String) -> [String] {
        normalize(components: split(path))
    }

    /// Whole-component equality under the volume's own case rules.
    ///
    /// Case sensitivity is a property of the filesystem, not of the code: the
    /// boot volume is case-insensitive, an external volume may not be, and
    /// hardcoding either answer is wrong in exactly half the cases.
    public static func equal(_ a: String, _ b: String, caseInsensitive: Bool) -> Bool {
        if caseInsensitive {
            return a.compare(b, options: [.caseInsensitive], range: nil, locale: nil) == .orderedSame
        }
        return a == b
    }

    /// True when `candidate` is `rule`, or lies beneath it.
    ///
    /// `candidate.count >= rule.count` plus component-wise equality — the whole
    /// algorithm. `/usr/localfoo` fails at component 1 because "localfoo" is not
    /// "local", which is precisely the property a prefix test throws away.
    public static func matchesSubtree(candidate: [String], rule: [String],
                                      caseInsensitive: Bool) -> Bool {
        guard candidate.count >= rule.count else { return false }
        for index in rule.indices {
            guard equal(candidate[index], rule[index], caseInsensitive: caseInsensitive) else {
                return false
            }
        }
        return true
    }

    /// True only for the item itself, never for anything under it.
    public static func matchesItem(candidate: [String], rule: [String],
                                   caseInsensitive: Bool) -> Bool {
        candidate.count == rule.count
            && matchesSubtree(candidate: candidate, rule: rule, caseInsensitive: caseInsensitive)
    }

    /// True when any component equals `name`.
    ///
    /// This is how `.git` is matched: positional-anywhere, whole-component. It
    /// denies `x/.git` and `x/.git/objects/ab` and refuses `.github`,
    /// `.gitignore` and `.git-backup` — all four of which a substring test gets
    /// wrong in the dangerous direction.
    public static func containsComponent(candidate: [String], name: String,
                                         caseInsensitive: Bool) -> Bool {
        candidate.contains { equal($0, name, caseInsensitive: caseInsensitive) }
    }

    /// Rejoins components into an absolute path. Used for display and for the
    /// identity walk, never for matching.
    public static func join(_ components: [String]) -> String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}
