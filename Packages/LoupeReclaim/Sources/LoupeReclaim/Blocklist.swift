import Foundation
import LoupeCore

/// The static deny table from §B.2 of the reclaim spec.
///
/// Rules are component arrays, never strings, and the table is built against a
/// concrete home directory so a rule written as `~/Library/Keychains` protects
/// one real directory rather than anything that happens to end that way.
public struct Blocklist: Sendable {

    public enum Reach: Sendable, Hashable {
        /// The path and everything beneath it.
        case subtree
        /// The path itself. Children are unaffected — `~/Library` must never be
        /// deleted, but `~/Library/Caches/Homebrew/downloads` is the whole point
        /// of the app.
        case item
    }

    public struct Deny: Sendable, Hashable {
        public let components: [String]
        public let reach: Reach
        public let rule: BlocklistRule
        /// The precise reason, for logs and for the report. `BlocklistRule`
        /// carries the user-facing sentence; this carries the fact.
        public let detail: String
    }

    /// An allow rule cancels exactly one deny and grants nothing. Every other
    /// guard still runs after it.
    public struct Allow: Sendable, Hashable {
        public let components: [String]
        public let reason: String
    }

    public struct ComponentDeny: Sendable, Hashable {
        public let name: String
        public let rule: BlocklistRule
        public let detail: String
    }

    public let denies: [Deny]
    public let allows: [Allow]
    public let componentDenies: [ComponentDeny]

    public init(home: URL) {
        let h = PathComponents.normalizedComponents(of: home.path(percentEncoded: false))

        var denies: [Deny] = [
            // --- the six the assignment names -------------------------------
            Deny(components: ["System"], reach: .subtree, rule: .systemPath,
                 detail: "The sealed macOS system volume."),
            Deny(components: ["usr"], reach: .subtree, rule: .usrOutsideLocal,
                 detail: "A system directory; only /usr/local is user-managed."),
            Deny(components: ["Library", "Apple"], reach: .subtree, rule: .libraryApple,
                 detail: "Managed by macOS, including XProtect."),
            Deny(components: h + ["Library", "Keychains"], reach: .subtree, rule: .keychains,
                 detail: "Your keychains."),
            Deny(components: ["Library", "Keychains"], reach: .subtree, rule: .keychains,
                 detail: "The system keychains."),
            Deny(components: h + ["Library", "Group Containers"], reach: .subtree,
                 rule: .groupContainers,
                 detail: "Data shared between an app and its extensions."),

            // --- §B.2 "additional hard denies" ------------------------------
            Deny(components: ["bin"], reach: .subtree, rule: .systemPath,
                 detail: "A system directory."),
            Deny(components: ["sbin"], reach: .subtree, rule: .systemPath,
                 detail: "A system directory."),
            Deny(components: ["etc"], reach: .subtree, rule: .systemPath,
                 detail: "System configuration."),
            Deny(components: ["private", "etc"], reach: .subtree, rule: .systemPath,
                 detail: "System configuration; /etc resolves here."),
            Deny(components: ["var"], reach: .subtree, rule: .systemPath,
                 detail: "System state."),
            // /var resolves to /private/var, so this is the rule that actually
            // fires. It also subsumes the spec's /private/var/db and
            // /private/var/folders entries, which are kept below because a deny
            // list that states its own reasons is easier to audit than one that
            // relies on a reader noticing an implication.
            Deny(components: ["private", "var"], reach: .subtree, rule: .systemPath,
                 detail: "System state; /var resolves here."),
            Deny(components: ["private", "var", "db"], reach: .subtree, rule: .systemPath,
                 detail: "System databases."),
            Deny(components: ["private", "var", "db", "SystemKey"], reach: .subtree,
                 rule: .keychains, detail: "The system's own key material."),
            Deny(components: ["private", "var", "folders"], reach: .subtree, rule: .systemPath,
                 detail: "Per-user system caches and temporary state."),
            Deny(components: h + ["Library", "Application Support", "com.apple.TCC"],
                 reach: .subtree, rule: .systemPath,
                 detail: "The privacy database that records what you have allowed."),

            // --- containers that exist to hold other things -----------------
            // Item-only: these are structure, not content. Deleting the folder
            // takes everything in it; deleting something inside one is the job.
            Deny(components: [], reach: .item, rule: .volumeRoot,
                 detail: "The root of the startup volume."),
            Deny(components: ["Users"], reach: .item, rule: .protectedContainer,
                 detail: "The folder that holds every account on this Mac."),
            Deny(components: ["Volumes"], reach: .item, rule: .protectedContainer,
                 detail: "The folder every other volume is mounted into."),
            Deny(components: ["Applications"], reach: .item, rule: .protectedContainer,
                 detail: "The folder that holds your applications."),
            Deny(components: ["Library"], reach: .item, rule: .protectedContainer,
                 detail: "The system-wide Library folder."),
            Deny(components: h, reach: .item, rule: .protectedContainer,
                 detail: "Your home folder."),
            Deny(components: h + ["Library"], reach: .item, rule: .protectedContainer,
                 detail: "Your Library folder."),
            Deny(components: h + ["Library", "Containers"], reach: .item,
                 rule: .protectedContainer,
                 detail: "The folder that holds every sandboxed app's data."),
        ]
        denies.sort { $0.components.count > $1.components.count }
        self.denies = denies

        self.allows = [
            // /usr is on the sealed system volume; /usr/local is a firmlink to
            // writable Data storage. The allow is a structural fact of the
            // volume layout, not a convenience.
            Allow(components: ["usr", "local"],
                  reason: "/usr/local is a firmlink to user-managed storage on the Data volume.")
        ]

        self.componentDenies = [
            ComponentDeny(name: ".git", rule: .gitDirectory,
                          detail: "A Git repository's history.")
        ]
    }

    /// The static verdict for one canonical path.
    ///
    /// - Returns: the first rule that denies, or nil if none does. Nil is not
    ///   permission to delete — it means this table had nothing to say, and the
    ///   identity, flag, process and scope guards have yet to run.
    public func firstDenial(components: [String],
                            caseInsensitive: Bool) -> (rule: BlocklistRule, detail: String)? {
        for componentDeny in componentDenies
        where PathComponents.containsComponent(candidate: components, name: componentDeny.name,
                                               caseInsensitive: caseInsensitive) {
            return (componentDeny.rule, componentDeny.detail)
        }

        for deny in denies {
            let hit = switch deny.reach {
            case .subtree:
                PathComponents.matchesSubtree(candidate: components, rule: deny.components,
                                              caseInsensitive: caseInsensitive)
            case .item:
                PathComponents.matchesItem(candidate: components, rule: deny.components,
                                           caseInsensitive: caseInsensitive)
            }
            guard hit else { continue }
            if deny.reach == .subtree,
               isCancelled(deny: deny, components: components, caseInsensitive: caseInsensitive) {
                continue
            }
            return (deny.rule, deny.detail)
        }
        return nil
    }

    /// An allow cancels a deny only when it is **strictly longer** and the deny
    /// is a component-prefix of it, and only when the candidate is inside the
    /// allow as well. Nothing cancels `/System`, because no allow names it.
    private func isCancelled(deny: Deny, components: [String], caseInsensitive: Bool) -> Bool {
        isCancelled(denyComponents: deny.components, components: components,
                    caseInsensitive: caseInsensitive)
    }

    /// Same rule, keyed on the deny's components rather than the `Deny` value.
    ///
    /// The identity walk holds inodes, not `Deny`s, so it needs this form. Both
    /// layers must agree about cancellation: when the lexical layer allowed
    /// `/usr/local` but the identity walk did not, the carve-out was silently
    /// defeated for everything beneath it — and refused with the sentence
    /// "only /usr/local is user-managed", printed for a path inside /usr/local.
    func isCancelled(denyComponents: [String], components: [String],
                     caseInsensitive: Bool) -> Bool {
        allows.contains { allow in
            allow.components.count > denyComponents.count
                && PathComponents.matchesSubtree(candidate: allow.components,
                                                 rule: denyComponents,
                                                 caseInsensitive: caseInsensitive)
                && PathComponents.matchesSubtree(candidate: components,
                                                 rule: allow.components,
                                                 caseInsensitive: caseInsensitive)
        }
    }
}
