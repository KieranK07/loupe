import Foundation
import LoupeCore

/// The nineteen places worth looking, from §3 and §4 of the reclaim spec.
///
/// Every entry is a specific, named thing with a stated consequence. There is no
/// rule here that means "find anything cache-shaped", and there is deliberately
/// no bulk entry for `~/Library/Caches`: it is 226 unrelated app-owned
/// directories on the development machine, and sweeping it is the behaviour
/// Loupe exists to be an alternative to.
///
/// `whatBreaks` is one sentence, shown verbatim, and says what stops working.
/// `regeneration` says how it comes back and what that costs. Neither is ever a
/// placeholder; an entry that cannot say both does not belong in the catalog.
///
/// Levels follow `SafetyLevel`'s ordering — the cost of being wrong. A cache
/// that rebuilds from local CPU ranks below one that has to come back over the
/// network, which ranks below one that costs gigabytes or a manual step in
/// another app.
public struct CleanupCatalog: Sendable {

    public let home: URL
    public let entries: [CatalogEntry]

    public var targets: [CleanupTarget] { entries.map(\.target) }

    public subscript(id: String) -> CatalogEntry? { entries.first { $0.id == id } }

    public init(home: URL = UserHome.resolved()) {
        self.home = home
        let h = home.path(percentEncoded: false)
        func path(_ relative: String) -> String {
            relative.hasPrefix("/") ? relative : h + "/" + relative
        }

        // A tool's usual homes on macOS, checked by existence only.
        func toolPaths(_ name: String) -> [String] {
            ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name,
             h + "/.local/bin/" + name, h + "/.cargo/bin/" + name,
             "/usr/bin/" + name, "/opt/homebrew/opt/node/bin/" + name]
        }

        var entries: [CatalogEntry] = []

        // MARK: 1 — Xcode build products
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "xcode-derived-data",
                displayName: "Xcode build products (DerivedData)",
                patterns: [path("Library/Developer/Xcode/DerivedData/*")],
                safety: .rebuildsLocally,
                whatBreaks: "Your next build of each affected project starts from scratch instead of reusing compiled output.",
                regeneration: "Automatically, on your next build, with no network — a full clean build takes minutes to tens of minutes per project.",
                refuseWhileRunning: ["com.apple.dt.Xcode", "xcodebuild", "swift-frontend", "swiftc"]),
            notes: [
                "Xcode can be pointed at a custom DerivedData location. Loupe reads IDECustomDerivedDataLocation before assuming the default, and reports the location as unknown rather than scanning the default if it cannot.",
                "Directories named Unsaved_Xcode_Document-* are build products of unsaved scratch documents. The row shows the folder name literally so you can recognise it."
            ]))

        // MARK: 2 — Xcode device symbol caches
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "xcode-device-support",
                displayName: "Xcode device symbol caches",
                patterns: [path("Library/Developer/Xcode/iOS DeviceSupport/*"),
                           path("Library/Developer/Xcode/watchOS DeviceSupport/*"),
                           path("Library/Developer/Xcode/tvOS DeviceSupport/*"),
                           path("Library/Developer/Xcode/visionOS DeviceSupport/*")],
                safety: .redownloadsLarge,
                whatBreaks: "Debugging or symbolicating a crash from a device running that exact OS build will require Xcode to copy the symbols off the device again before it can show you readable stack traces.",
                regeneration: "Not automatic: it needs the physical device on that OS build connected over USB with Xcode open, which takes 2 to 15 minutes — and if you no longer have that device, these symbols cannot be recreated at all.",
                refuseWhileRunning: ["com.apple.dt.Xcode", "xcodebuild", "devicectl",
                                     "DTDeviceKitBase"]),
            notes: [
                "Deleting the entry for a device you still own costs about ten minutes. Deleting the entry for a device you have sold or updated is permanent. Loupe marks the ones matching a device you still have."
            ]))

        // MARK: 3 — Simulator runtimes not usable by installed Xcode
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "coresimulator-runtimes-unusable",
                displayName: "Simulator runtimes not usable by installed Xcode",
                // The runtime images themselves, not the scaffolding beside
                // them: Images/ also holds Inbox, mnt and images.plist, which
                // are CoreSimulator's own bookkeeping and are not runtimes.
                patterns: ["/Library/Developer/CoreSimulator/Images/*.dmg",
                           "/Library/Developer/CoreSimulator/Cryptex/Images/*.dmg",
                           "/Library/Developer/CoreSimulator/Profiles/Runtimes/*.simruntime"],
                safety: .redownloadsLarge,
                whatBreaks: "You cannot run the simulator for that OS version until you download the runtime again.",
                regeneration: "A 4 to 8 GB download from Apple taking 5 to 40 minutes, started from Xcode's Components settings — and Apple no longer offers every older runtime, so some cannot be downloaded again at all.",
                refuseWhileRunning: ["com.apple.dt.Xcode",
                                     "com.apple.CoreSimulator.CoreSimulatorService",
                                     "simdiskimaged", "SimulatorTrampoline", "simctl"],
                mechanism: .delegatedToTool, isPerUser: false),
            mechanismCopy: MechanismCopy(
                command: "xcrun simctl runtime delete <id>",
                explanation: "A runtime is registered in images.plist and in cryptex state. Removing the files leaves the registration pointing at something that is gone, so this is a job for Xcode's own tool rather than for Loupe."),
            notes: [
                "These files are owned by root. Loupe never asks for an administrator password, so it shows the command and lets you run it.",
                "/Library/Developer/CoreSimulator/Volumes holds mounted runtime volumes and is never touched."
            ]))

        // MARK: 4 — Simulator devices with no runtime
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "coresimulator-devices-orphaned",
                displayName: "Simulator devices with no runtime",
                // A device directory is named for its UDID. Matching the shape
                // rather than everything keeps .DS_Store and any future sibling
                // file out of a list that claims to be a list of devices.
                patterns: [path("Library/Developer/CoreSimulator/Devices/????????-????-????-????-????????????"),
                           path("Library/Developer/CoreSimulator/Caches/*"),
                           path("Library/Developer/CoreSimulator/Temp/*")],
                safety: .redownloadsLarge,
                whatBreaks: "That simulated device and everything installed inside it — apps, databases, granted permissions, screenshots — is gone, and you get a factory-fresh device the next time one is created.",
                regeneration: "Xcode recreates the empty device automatically once the matching runtime is installed, but its contents never come back: every app has to be installed and set up again by hand.",
                refuseWhileRunning: ["com.apple.iphonesimulator",
                                     "com.apple.CoreSimulator.CoreSimulatorService",
                                     "simdiskimaged", "SimulatorTrampoline", "simctl"]),
            notes: [
                "\"Unavailable\" is a current state, not a permanent one. Reinstalling the runtime makes these devices usable again with their contents intact.",
                "xcrun simctl delete unavailable is the tidier route because it also updates device_set.plist. Moving the folder to the Trash leaves a stale entry there until CoreSimulator next reconciles."
            ]))

        // MARK: 5 — Homebrew download cache
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "homebrew-cache",
                displayName: "Homebrew download cache",
                patterns: [path("Library/Caches/Homebrew/downloads/*"),
                           path("Library/Caches/Homebrew/api/*"),
                           path("Library/Caches/Homebrew/bootsnap/*"),
                           path("Library/Caches/Homebrew/*.bottle.tar.gz"),
                           path("Library/Caches/Homebrew/portable-ruby-*.tar.gz")],
                safety: .redownloads,
                whatBreaks: "Nothing on your Mac stops working; the next brew install or brew upgrade downloads the package again instead of reusing the copy on disk.",
                regeneration: "Automatically on the next install or upgrade, over the network, taking seconds to minutes per formula.",
                refuseWhileRunning: ["brew"]),
            toolProbe: ToolProbe(name: "Homebrew", searchPaths: toolPaths("brew")),
            notes: [
                "The Caskroom is not part of this entry. It holds the installer payloads Homebrew needs in order to uninstall casks.",
                "Two Homebrew prefixes can coexist — /usr/local and /opt/homebrew — sharing one cache directory. Loupe enumerates both rather than trusting whichever one is on PATH."
            ]))

        // MARK: 6 — npm content cache
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "npm-cache",
                displayName: "npm content cache",
                patterns: [path(".npm/_cacache/*"), path(".npm/_logs/*"), path(".npm/_npx/*")],
                safety: .redownloads,
                whatBreaks: "Nothing breaks; your next npm install fetches packages from the registry instead of from disk, so it takes longer and needs a connection.",
                regeneration: "Automatically on the next install, over the network, adding roughly 10 to 60 seconds to a cold install.",
                refuseWhileRunning: ["node", "npm"]),
            toolProbe: ToolProbe(name: "npm", searchPaths: toolPaths("npm")),
            notes: [
                "_cacache/tmp holds work left behind by interrupted installs. Loupe lists it separately because it is genuinely abandoned, unlike the rest of the cache."
            ]))

        // MARK: 7 — pnpm store
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "pnpm-store",
                displayName: "pnpm content-addressable store",
                patterns: [path("Library/pnpm/store/v3/*"),
                           path(".local/share/pnpm/store/v3/*"),
                           path("Library/Caches/pnpm/*")],
                // Not a download cache. Every installed project on the machine
                // is hardlinked into this store, so losing it costs an explicit
                // reinstall in each of them — the spec's L3, not its L2.
                safety: .redownloadsLarge,
                whatBreaks: "Every pnpm project on this Mac loses the hardlinks its node_modules points at, so each one needs pnpm install again before it will run.",
                regeneration: "Not automatic and not transparent: it needs a network connection and an explicit pnpm install in every affected project, taking minutes per project.",
                refuseWhileRunning: ["node", "pnpm"]),
            toolProbe: ToolProbe(name: "pnpm", searchPaths: toolPaths("pnpm")),
            notes: [
                "pnpm's store is not a cache. Installed node_modules trees are hardlinks into it, so removing it breaks projects that are already installed."
            ]))

        // MARK: 8 — Yarn cache
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "yarn-cache",
                displayName: "Yarn cache",
                patterns: [path("Library/Caches/Yarn/v6/*"), path(".cache/yarn/*"),
                           path(".yarn/berry/cache/*")],
                safety: .redownloads,
                whatBreaks: "Nothing breaks; the next yarn install downloads packages again instead of reading them from disk.",
                regeneration: "Automatically on the next install, over the network, taking seconds to minutes.",
                refuseWhileRunning: ["node", "yarn"]),
            toolProbe: ToolProbe(name: "Yarn", searchPaths: toolPaths("yarn")),
            notes: [
                "Project-local .yarn/cache directories are excluded. Yarn Berry repositories often commit theirs, and deleting one breaks a checked-in build and shows hundreds of deletions in git status."
            ]))

        // MARK: 9 — pip cache
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "pip-cache",
                displayName: "pip wheel and download cache",
                patterns: [path("Library/Caches/pip/wheels/*"),
                           path("Library/Caches/pip/http-v2/*"),
                           path("Library/Caches/pip/http/*")],
                safety: .redownloads,
                whatBreaks: "Nothing breaks; the next pip install downloads packages again, and any package that had to be compiled from source is compiled again.",
                regeneration: "Automatically over the network — seconds for a ready-built wheel, but minutes and a working compiler for anything built from source.",
                refuseWhileRunning: ["pip", "pip3", "python", "python3"]),
            toolProbe: ToolProbe(name: "pip", searchPaths: toolPaths("pip3")),
            notes: [
                "wheels and http are separate rows with separate sizes. http is free to lose; wheels may hold the only compiled build of a package that no longer compiles on this machine's current toolchain."
            ]))

        // MARK: 10 — uv cache
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "uv-cache",
                displayName: "uv cache",
                patterns: [path(".cache/uv/*")],
                safety: .redownloads,
                whatBreaks: "Nothing breaks; uv downloads and unpacks packages again on its next command.",
                regeneration: "Automatically over the network, and quickly — uv refills its cache more readily than the other package managers here.",
                refuseWhileRunning: ["uv"]),
            toolProbe: ToolProbe(name: "uv", searchPaths: toolPaths("uv")),
            notes: [
                "uv respects UV_CACHE_DIR. Loupe reads it before falling back to the default location."
            ]))

        // MARK: 11 — Docker Desktop disk image  (level 4)
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "docker-desktop-disk-image",
                displayName: "Docker Desktop disk image",
                patterns: [path("Library/Containers/com.docker.docker/Data/vms/*/data/*.raw")],
                safety: .losesLocalState,
                whatBreaks: "Every Docker image, container and named volume on this Mac is destroyed, including any database or file that lives only inside a volume.",
                regeneration: "Docker Desktop recreates an empty disk image on its next launch in seconds, but the contents do not come back: images can be pulled again if they still exist in a registry, and volume data cannot be recovered from anywhere.",
                refuseWhileRunning: ["com.docker.docker", "com.docker.backend",
                                     "com.docker.virtualization", "vpnkit", "docker", "dockerd",
                                     "qemu-system-aarch64", "qemu-system-x86_64"]),
            toolProbe: ToolProbe(name: "Docker", searchPaths: toolPaths("docker")),
            notes: [
                "This file is sparse. Finder and ls report the size Docker reserved, not the space it uses; Loupe reports only the blocks actually on disk.",
                "It stays sparse after being moved, so the Trash will show the reserved size too.",
                "docker system prune removes unused images and build cache without destroying your volumes, and is the less destructive option when it is enough."
            ]))

        // MARK: 12 — iPhone and iPad backups  (level 4)
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "ios-device-backups",
                displayName: "iPhone and iPad backups",
                patterns: [path("Library/Application Support/MobileSync/Backup/*")],
                safety: .losesLocalState,
                whatBreaks: "If this Mac holds the only copy of that backup, the photos, messages and app data captured in it are gone permanently.",
                regeneration: "Not possible from Loupe: a new backup needs the physical device, a cable and 10 to 60 minutes or more, and a backup of a device you no longer own cannot be recreated at all.",
                refuseWhileRunning: ["AMPDeviceDiscoveryAgent", "MobileDeviceUpdater",
                                     "com.apple.AMPDevicesAgent", "Apple Devices"]),
            notes: [
                "Each row shows the device name, model, iOS version and last backup date read from the backup's own Info.plist. A row that says only \"iPhone backup\" is not enough to decide on a permanent loss.",
                "The device's data may also be in iCloud Backup. Loupe has no way to check that and does not imply it does.",
                "Finder is always running, so this entry is guarded by an open handle on the backup itself rather than by whether Finder is open.",
                "Some people move this folder elsewhere and leave a symlink. Loupe shows the real location when it differs."
            ]))

        // MARK: 13 — Mail attachment downloads
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "mail-downloads",
                displayName: "Mail attachment downloads",
                patterns: [path("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*"),
                           path("Library/Mail Downloads/*"),
                           path("Library/Containers/com.apple.mail/Data/Library/Caches/*")],
                safety: .redownloads,
                whatBreaks: "Attachments you previously opened are removed from disk; Mail downloads them from the server again the next time you open that message.",
                regeneration: "Automatically when you next open the message, over the network — but only if the message is still on the server, so an attachment on a message deleted server-side or held in a POP account is gone.",
                refuseWhileRunning: ["com.apple.mail"]),
            notes: [
                "The mail store itself, ~/Library/Mail, is not part of this entry at any level. It holds messages, not copies of them."
            ]))

        // MARK: 14 — Trash  (level 5, informational)
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "trash",
                displayName: "Trash",
                patterns: [path(".Trash/*"), "/Volumes/*/.Trashes/*"],
                safety: .userData,
                whatBreaks: "Everything you previously put in the Trash is permanently deleted, including anything you put there by mistake.",
                regeneration: "None. Emptying the Trash is the last step, and there is nothing after it.",
                mechanism: .revealInFinder),
            mechanismCopy: MechanismCopy(
                explanation: "Loupe only ever moves items to the Trash; emptying it is by definition the one operation Loupe does not implement. The row shows the true size and opens the Trash in Finder, where the system asks for its own confirmation."),
            notes: [
                "Emptying the Trash is the step that frees space. Until then these bytes are still allocated."
            ]))

        // MARK: 15 — Safari cache
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "browser-cache-safari",
                displayName: "Safari cache",
                patterns: [path("Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari/*"),
                           path("Library/Containers/com.apple.Safari/Data/Library/Caches/WebKit/*"),
                           path("Library/Caches/com.apple.Safari/*")],
                safety: .redownloads,
                whatBreaks: "Pages you have visited load a little slower the next time because their images and scripts are fetched again; you stay logged in everywhere.",
                regeneration: "Automatically as you browse, over the network, at a cost per page too small to notice.",
                // Not a blanket refusal on the WebKit helpers: they are shared
                // with every app that shows a web view, so "WebKit is running"
                // is true almost always and says nothing about Safari's cache.
                // The spec's condition is an *open handle inside the tree*,
                // which the planner checks per candidate against the open-file
                // index.
                refuseWhileRunning: ["com.apple.Safari"]),
            excludedComponents: ["LocalStorage", "Databases", "Safari", "History", "Cookies"],
            notes: [
                "History, bookmarks, reading list and site data are in ~/Library/Safari and in the container's own Safari folder. None of it is part of this entry, which is why you stay logged in."
            ]))

        // MARK: 16 — Chromium-family browser caches
        let chromiumVendors: [(root: String, name: String, apps: [String])] = [
            (path("Library/Caches/Google/Chrome"), "Google Chrome", ["com.google.Chrome"]),
            (path("Library/Caches/Chromium"), "Chromium", ["org.chromium.Chromium"]),
            (path("Library/Caches/BraveSoftware/Brave-Browser"), "Brave", ["com.brave.Browser"]),
            (path("Library/Caches/Microsoft Edge"), "Microsoft Edge", ["com.microsoft.edgemac"]),
            (path("Library/Caches/Vivaldi"), "Vivaldi", ["com.vivaldi.Vivaldi"]),
            (path("Library/Caches/company.thebrowser.Browser"), "Arc",
             ["company.thebrowser.Browser"]),
            (path("Library/Caches/com.operasoftware.Opera"), "Opera",
             ["com.operasoftware.Opera"]),
            (path("Library/Caches/com.operasoftware.OperaGX"), "Opera GX",
             ["com.operasoftware.OperaGX"]),
        ]
        let chromiumSubpaths = ["Cache", "Code Cache", "image_cache", "GPUCache",
                                "GraphiteDawnCache", "DawnWebGPUCache", "ShaderCache"]
        var chromiumPatterns: [String] = []
        for vendor in chromiumVendors {
            for subpath in chromiumSubpaths {
                chromiumPatterns.append("\(vendor.root)/\(subpath)")
                chromiumPatterns.append("\(vendor.root)/*/\(subpath)")
            }
        }
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "browser-cache-chromium",
                displayName: "Chromium-family browser caches",
                patterns: chromiumPatterns,
                safety: .redownloads,
                whatBreaks: "Sites reload their images and scripts from the network next time; your tabs, logins, extensions and history are untouched.",
                regeneration: "Automatically as you browse, over the network, at a cost per page too small to notice.",
                // Deliberately empty. Listing all eight browsers here would mean
                // one of them being open blocks the other seven's caches; the
                // answer is per vendor directory, in perPathQuitRules.
                refuseWhileRunning: []),
            excludedComponents: ["Extensions", "IndexedDB", "Local Storage",
                                 "Local Extension Settings", "Service Worker", "Sessions",
                                 "History", "Cookies", "Login Data", "Web Applications",
                                 "Shared Dictionary"],
            perPathQuitRules: chromiumVendors.map {
                PathQuitRule(pathPrefix: $0.root, refuseWhileRunning: $0.apps,
                             displayName: $0.name)
            },
            notes: [
                "One row per browser profile Loupe finds, because the answer to \"is it safe\" depends on which browser is open.",
                "Chromium keeps cache-shaped data in both Caches and Application Support. Loupe touches only the cache root; the exclusion list above is enforced by the safety engine, not merely omitted from the patterns.",
                "Chromium helper processes live inside the parent application bundle and hold cache files open, so detection looks at every process, not only at the application list."
            ]))

        // MARK: 17 — Firefox cache
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "browser-cache-firefox",
                displayName: "Firefox cache",
                patterns: [path("Library/Caches/Firefox/Profiles/*/cache2/*"),
                           path("Library/Caches/Firefox/Profiles/*/startupCache/*"),
                           path("Library/Caches/Firefox/Profiles/*/thumbnails/*"),
                           path("Library/Caches/Mozilla/*")],
                safety: .redownloads,
                whatBreaks: "Pages reload their images and scripts from the network next time; your tabs, logins, extensions and history are untouched.",
                regeneration: "Automatically as you browse, over the network, at a cost per page too small to notice.",
                refuseWhileRunning: ["org.mozilla.firefox", "firefox", "plugin-container"]),
            requiredMarkerFile: path("Library/Application Support/Firefox/profiles.ini"),
            notes: [
                "Profiles come from profiles.ini, not from globbing the directory. With no profiles.ini there is no Firefox row at all rather than an empty category.",
                "The profile itself — places.sqlite, cookies.sqlite, logins.json, extensions — lives in Application Support and is never touched."
            ]))

        // MARK: 18 — Older items in Downloads  (level 5, review-only)
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "stale-downloads",
                displayName: "Older items in Downloads",
                patterns: [path("Downloads/*")],
                safety: .userData,
                whatBreaks: "A file you chose to save is deleted; if it came from a link that has since expired or a site you no longer have access to, you cannot get it back.",
                regeneration: "None. Getting it back means finding the original source again, which may no longer exist.",
                mechanism: .reviewOnly),
            mechanismCopy: MechanismCopy(
                explanation: "There is no age at which Loupe checks a box in Downloads. A file's modification date is when it finished downloading and never changes again, so it says nothing about whether you still use the file. This is a sorted, annotated list with a per-item review action."),
            notes: [
                "Sorted by size, not by age: \"what large thing am I finished with\" is a question Loupe can help with, and \"is this stale\" is a guess.",
                "Where Loupe can tell, the row says where the file came from and which app downloaded it — a fact you can act on, unlike a number of days.",
                "Only the top level of Downloads is listed. Loupe never reaches inside a folder you downloaded to pick out individual files."
            ]))

        // MARK: 19 — node_modules in untouched projects
        let searchRoots = ["Projects", "Developer", "Documents", "Desktop", "src", "code"]
        entries.append(CatalogEntry(
            target: CleanupTarget(
                id: "dormant-node-modules",
                displayName: "node_modules in projects you have not edited",
                patterns: searchRoots.map { path("\($0)/**/node_modules") },
                safety: .redownloadsLarge,
                whatBreaks: "That project will not build or run until you reinstall its dependencies.",
                regeneration: "Not automatic: it needs npm ci, pnpm install or yarn install in that directory, over the network, taking 20 seconds to 5 minutes per project — and only if every package it names is still published."),
            excludedComponents: [".git"],
            discoveryDepth: 6,
            notes: [
                "Loupe can tell that nobody has edited this project in months. It cannot tell whether you still run it.",
                "Dormancy is measured from the newest file the human edits, not from node_modules' own date, which reflects the last install and is rewritten by unrelated tooling.",
                "A project with uncommitted changes is never offered, however old its files are.",
                "A running dev server is caught by its open files rather than by a process name, since the process is just node.",
                "If the project compiled native code, reinstalling may need build tools you no longer have."
            ]))

        self.entries = entries
    }
}
