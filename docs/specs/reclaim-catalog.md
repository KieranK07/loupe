# Pillar 2 — Reclaiming space

**Status:** design spec, pre-implementation.
**Owning packages:** `LoupeReclaim` (catalog + scanner), `LoupeSecurity` (safety engine).
**Applies to:** macOS 26.0+, Swift 6 strict concurrency, Developer ID + notarized, non-sandboxed.
**Privilege:** this pillar runs entirely as the invoking user and never calls the privileged helper
(`docs/specs/privileged-helper.md`), which by its own spec exposes no write or delete method.
No background daemon, no schedule, no persistent index — scan on demand only.

Loupe scans on demand, shows what it found, explains it, and moves selected items to the
Trash. It does not schedule, does not index, does not run in the background, and does not
claim your Mac will be faster afterwards. The only claim Loupe ever makes about a number is
"this many bytes are currently allocated on disk here", and it must be true.

---

## 0. Measurement environment

Every size in this document marked *measured* was taken on the development machine on
**2026-08-27**. Anything not measurable here is marked **not present** or **unverified**.

| | |
|---|---|
| Host | Apple silicon (arm64, T8132), macOS 26.5.2 (25F84), Darwin 25.5.0 |
| SDK consulted | `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk` |
| Boot volume | APFS sealed snapshot at `/` (`disk3s1s1`, read-only); data at `/System/Volumes/Data` (`disk3s5`) |
| Data volume | 372.6 GB used, 98.7 GB container free |
| Local APFS snapshots | none present at scan time (`tmutil listlocalsnapshots`) |
| **SIP** | **disabled** (`csrutil status`) — see §B.6.1 |
| Authenticated Root | enabled (`csrutil authenticated-root status`) |
| Spotlight | indexing enabled on `/` and `/System/Volumes/Data` |

Method: `du -sk <path>` (1024-byte units, **allocated** blocks) for tree totals;
`os.lstat` `st_blocks * 512` for single files; `du -skA` for apparent size where the
distinction matters. Sizes below are converted to base-10 (GB = 10⁹ B) because that is
what Finder shows and Loupe must not disagree with Finder.

---

## 1. Units and honesty rules (normative, applies to the whole catalog)

These rules bind every entry. An entry that cannot satisfy them does not ship.

**R1 — Report allocated bytes, never apparent bytes.**
The reclaim figure for any node is `Σ (st_blocks × 512)` over the tree.
`st_size` is never summed and never displayed as a space figure. Measured proof of why:
`Docker.raw` on this machine has `st_size` = 494,384,709,632 B (494.38 GB) and
`st_blocks × 512` = 1,771,352,064 B (1.77 GB). A 279× error.

**R2 — Deduplicate by `(st_dev, st_ino)`.**
Hardlinked files inside a tree are counted once. A tree total that double-counts hardlinks
is an inflated number, which is a dark pattern.

**R3 — The estimate is an upper bound and must be labelled as one.**
Three mechanisms make actual freed space ≤ estimate, and Loupe discloses each when detected:

| Mechanism | Detection | Disclosure |
|---|---|---|
| APFS clones (shared blocks) | `getattrlist` `ATTR_CMNEXT_EXT_FLAGS` → `EF_MAY_SHARE_BLOCKS` (0x01), `EF_SHARES_ALL_BLOCKS` (0x40) — verified present in SDK `sys/stat.h` | "Some of these blocks are shared with other files. Deleting this may free less." |
| Time Machine local snapshots | `tmutil listlocalsnapshots /System/Volumes/Data` non-empty | "A local snapshot still references these blocks. Space returns when the snapshot expires (up to 24h)." |
| iCloud dataless files | `st_flags & SF_DATALESS` | counted as **0 bytes** — see R4 |

**R4 — Dataless (iCloud placeholder) files count as zero.**
Measured: `~/Library/Mobile Documents/com~apple~TextEdit/Documents/jimmyakin.txt` has
`st_size` = 50,226 but `st_blocks × 512` = **0** and `st_flags` = `0x40000060`
(`SF_DATALESS | UF_TRACKED | UF_COMPRESSED`). 29 of 274 items scanned under
`~/Library/Mobile Documents` were dataless. R1 already handles this correctly; R4 exists so
nobody "fixes" the size code to use `st_size`.

**R5 — Trash is not free space.**
Loupe deletes by moving to the Trash. Moving to the Trash frees **zero** bytes. Every screen
that shows a reclaim number, and the confirmation sheet, and the post-run report, carries
this sentence verbatim:

> Items moved to the Trash still use disk space. Your available space changes when you empty the Trash.

**R6 — Nothing is ever pre-selected.**
Every checkbox in the reclaim UI ships unchecked, at every safety level, with no
"Select all" affordance above level L2, and no "Recommended" preset. The headline number is
"found", never "recoverable", and never appears larger than the sum of what is selectable.

**R7 — Absent is reported as absent.**
An entry whose paths do not exist renders as a greyed row reading "Not present on this Mac",
not as 0 B, and does not contribute to any total. The user learns the category exists and
that they don't have it. That is the teaching function.

**R8 — Free-space figure must name itself.**
When Loupe shows available space it uses
`URLResourceKey.volumeAvailableCapacityForImportantUsageKey` and labels it "Available
(including purgeable)", because that is the number Finder shows and it is not the same as
`volumeAvailableCapacityKey`.

---

## 2. Safety scale

Five ordinal levels. Level is assigned by a **mechanical test**, not judgement. A category's
level is the **maximum** over its members; it is never rounded down for a nicer UI.

| Level | Name | Mechanical test | UI treatment |
|---|---|---|---|
| **L1** | Regenerates silently, offline | After deletion, ordinary use of the owning app restores full function with **no user action** and **no network**. The only cost is CPU time. | Individually selectable. A scoped "Select all in this category" is permitted. Unchecked by default. |
| **L2** | Regenerates silently, needs network | As L1, but the bytes must be re-fetched over the network on next use. | Same as L1. Row shows a network glyph and the estimated re-download size. |
| **L3** | Regenerates only on explicit user action | A human must run a command or click something (`npm install`, "Download" in Xcode, re-add a simulator runtime). Function is **degraded until they do**. | Individually selectable only. No category-level select-all. Unchecked. Row shows the exact command that restores it. |
| **L4** | Does not regenerate; recovery depends on an off-machine copy Loupe cannot verify | Deletion destroys the only local copy. Whether anything is recoverable depends on a remote or external source whose existence Loupe has no way to check. | Individually selectable. Unchecked. Requires typed confirmation (§B.8). Row states the destroyed artifact class in nouns, not adjectives. |
| **L5** | User data | A file the user authored, downloaded deliberately, or chose to keep. Not derived from anything. | **Review only.** No checkbox in the bulk flow. Loupe lists, sorts and explains; deletion happens through a separate one-at-a-time review sheet, or in Finder. Never counted in any headline total. |

Rule L-max: if any path in an entry's glob set can match an L5 file, the entry is L5.

---

## 3. Catalog — summary table

`Scope`: **U** = per-user (under `~`), **S** = system-wide (needs admin; Loupe does not
escalate — see §B.9).
`Quit?`: must the owning process be stopped before deletion.
`Measured`: on this machine, 2026-08-27.

| # | `id` | Display name | Level | Scope | Quit? | Measured here |
|---|---|---|---|---|---|---|
| 1 | `xcode-derived-data` | Xcode build products (DerivedData) | L1 | U | Xcode | 2.45 GB |
| 2 | `xcode-device-support` | Xcode device symbol caches | L3 | U | Xcode | 6.08 GB (iOS only) |
| 3 | `coresimulator-runtimes-unusable` | Simulator runtimes not usable by installed Xcode | L3 | S | Xcode + CoreSimulator | not present (0 runtimes installed) |
| 4 | `coresimulator-devices-orphaned` | Simulator devices with no runtime | L3 | U | CoreSimulator | 5.25 GB; all **11** devices orphaned |
| 5 | `homebrew-cache` | Homebrew download cache | L2 | U | — | 1.48 GB (1.40 GB in `downloads/`) |
| 6 | `npm-cache` | npm content cache | L2 | U | — | 5.15 GB |
| 7 | `pnpm-store` | pnpm content-addressable store | L3 | U | — | not present |
| 8 | `yarn-cache` | Yarn cache | L2 | U | — | not present |
| 9 | `pip-cache` | pip wheel/HTTP cache | L2 | U | — | 2.12 GB |
| 10 | `uv-cache` | uv cache | L2 | U | — | not present (configured at `~/.cache/uv`) |
| 11 | `docker-desktop-disk-image` | Docker Desktop disk image | **L4** | U | Docker | 1.77 GB on disk / 494.38 GB apparent |
| 12 | `ios-device-backups` | iPhone & iPad backups | **L4** | U | Finder / Apple Devices | present, empty (0 B) |
| 13 | `mail-downloads` | Mail attachment downloads | L2 | U | Mail | 26.0 MB |
| 14 | `trash` | Trash | **L5** | U | — | 0 B (empty) |
| 15 | `browser-cache-safari` | Safari cache | L2 | U | Safari | 294 MB |
| 16 | `browser-cache-chromium` | Chromium-family browser caches | L2 | U | that browser | 568 MB (Chrome) |
| 17 | `browser-cache-firefox` | Firefox cache | L2 | U | Firefox | not present |
| 18 | `stale-downloads` | Older items in Downloads | **L5** | U | — | 1.32 GB / 236 items; 13 older than 90d |
| 19 | `dormant-node-modules` | node_modules in untouched projects | L3 | U | — | 32 dirs found; **0 meet the dormancy bar** |

Aggregate of L1–L3 entries measured present, excluding simulator devices: **18.16 GB**. Loupe never displays a
grand total that mixes levels; this line exists for spec review only.

### 3.1 Deliberately excluded

Named here so a future contributor does not "helpfully" add them.

| Path | Why excluded |
|---|---|
| `~/Library/Caches` (as a bulk target) | 19.0 GB here, but it is 226 unrelated app-owned entries. Bulk-deleting it is exactly the CleanMyMac behaviour Loupe exists to be an alternative to. Loupe lists specific known subdirectories only. |
| `~/Library/Mail/V10` | 5.55 GB here. This is the mail store, not a cache. Deleting it loses local-only messages. Not a target at any level. |
| `~/Library/Logs` | 162 MB. Too small to be worth a destructive UI, and it is the user's diagnostic history. |
| `~/Library/Application Support/Steam` | 12.07 GB here. Game installs are user data with a re-download cost measured in hours. Belongs to Pillar 1 (inspection), not this pillar. |
| `.gradle/caches`, `.cargo/registry`, `ms-playwright`, `.cache/huggingface`, JetBrains caches | Real and large (2.82 / 0.44 / 1.68 / 2.54 / 1.07 GB measured). Deferred to a v2 catalog, not silently omitted. Each needs the same per-entry research as the entries above; shipping them under-researched would violate "curated and explained". |

---

## 4. Catalog — per-entry detail

Each entry below gives, in fixed order: paths, level, **breakage sentence** (exactly one
sentence, shown verbatim in the UI), regeneration cost, quit requirement + detection, size,
honesty note.

---

### 1. `xcode-derived-data` — Xcode build products (DerivedData)

- **Paths (U):** `~/Library/Developer/Xcode/DerivedData/` — delete per-project subdirectories, not the container.
  - Per-project: `~/Library/Developer/Xcode/DerivedData/<Name>-<hash>/`
  - Shared caches, listed separately: `ModuleCache.noindex/`, `SDKStatCaches.noindex/`, `SymbolCache.noindex/`, `CompilationCache.noindex/`
  - Custom locations exist: read `IDECustomDerivedDataLocation` from `~/Library/Preferences/com.apple.dt.Xcode.plist` before assuming the default. **If a custom location is set and Loupe cannot read it, the entry reports "location unknown" rather than scanning the default.**
- **Level:** L1
- **Breakage:** Your next build of each affected project starts from scratch instead of reusing compiled output.
- **Regeneration:** Automatic, on next build. **No network.** Cost is a full clean build: minutes to tens of minutes per project depending on size. User action: none beyond building.
- **Quit first:** Yes — Xcode. Detection: `NSWorkspace.runningApplications` for `com.apple.dt.Xcode`. Also refuse while any `xcodebuild` process is alive (§B.7 stage 2, match executable basename `xcodebuild`).
- **Size:** measured **2,446,856,192 B (2.45 GB)** across 9 top-level directories: 5 project directories + 4 shared `.noindex` caches. `ModuleCache.noindex` alone held 446 entries.
- **Honesty note:** Two subdirectories here were named `Unsaved_Xcode_Document-*` and `Unsaved_Xcode_Document_2-*`. These are build products of unsaved playground/document scratch files, still L1 — but the row must display the folder name literally so the user can recognise it, never a prettified "Xcode Cache" label.

---

### 2. `xcode-device-support` — Xcode device symbol caches

- **Paths (U):**
  - `~/Library/Developer/Xcode/iOS DeviceSupport/*`
  - `~/Library/Developer/Xcode/watchOS DeviceSupport/*`
  - `~/Library/Developer/Xcode/tvOS DeviceSupport/*`
  - `~/Library/Developer/Xcode/visionOS DeviceSupport/*` *(unverified — not present here)*
  - Each child is one `<Model> <OSVersion> (<Build>)` directory, e.g. `iPhone18,1 26.5 (23F77)`.
- **Level:** L3
- **Breakage:** Debugging or symbolicating a crash from a device running that exact OS build will require Xcode to copy the symbols off the device again before it can show you readable stack traces.
- **Regeneration:** Not automatic. Requires the physical device on that OS build, connected over USB, with Xcode open; Xcode re-copies symbols. Typically 2–15 minutes per device. Network: no, but the **device** is required — if the user has since updated or sold the phone, these bytes are gone for good. User action: connect the device and wait.
- **Quit first:** Yes — Xcode, plus `com.apple.dt.Xcode` helper `DTDeviceKitBase`/`devicectl`. Detection as entry 1.
- **Size:** measured **6,084,628,480 B (6.08 GB)**, all in a single directory `iPhone18,1 26.5 (23F77)`. watchOS/tvOS directories: **not present**.
- **Honesty note:** Loupe must sort these by OS build and mark the ones matching a currently-paired device (`devicectl list devices`, or `MobileDevice` framework) as **"matches a device you still have"**. Deleting the entry for a device you still own is a 10-minute inconvenience; deleting the entry for a device you no longer own is permanent. Same bytes, completely different decision — so Loupe must show the difference rather than one flat size.

---

### 3. `coresimulator-runtimes-unusable` — simulator runtimes not usable by installed Xcode

- **Paths (S, root-owned):**
  - `/Library/Developer/CoreSimulator/Images/` + `images.plist` (modern, macOS 13+ cryptex-backed runtimes)
  - `/Library/Developer/CoreSimulator/Cryptex/Images/`
  - `/Library/Developer/CoreSimulator/Profiles/Runtimes/*.simruntime` (legacy bundle layout)
  - `/Library/Developer/CoreSimulator/Volumes/*` (mounted runtime volumes — never touch while mounted)
- **Level:** L3
- **Breakage:** You cannot run the simulator for that OS version until you download the runtime again.
- **Regeneration:** Network download from Apple, 4–8 GB per runtime, 5–40 minutes. User action: Xcode → Settings → Components → download, or `xcrun simctl runtime add <ipsw>`. **Older runtimes may no longer be offered by Apple**; Loupe must say so rather than implying every runtime is re-downloadable.
- **Quit first:** Yes. Detection is more than "is Xcode running" — see honesty note.
- **Size:** measured — `/Library/Developer/CoreSimulator/Images` = 4 KB, `Cryptex` = 0 B, `Profiles/Runtimes` **not present**. `xcrun simctl runtime list` reports **"Total Disk Images: 0 (0.0G)"**. So: **no runtimes installed on this machine.** Typical range elsewhere is 4–8 GB per runtime; **unverified** on this host.
- **Deletion mechanism:** Loupe does **not** delete these paths directly. It shells to `xcrun simctl runtime delete <id>`, because the runtime is registered in `images.plist` and cryptex state; removing the file leaves a dangling registration. If `simctl` is unavailable the entry is disabled with the reason shown. This is the one catalog entry where the delete is not `trashItem` — and therefore it is presented as "Ask Xcode to remove this runtime", not as a Loupe deletion. See §B.6.
- **Honesty note (detection):** On this machine `Simulator.app` and `Xcode.app` were **not** in `NSWorkspace.runningApplications`, yet three CoreSimulator processes were live:
  `com.apple.CoreSimulator.CoreSimulatorService`, `simdiskimaged`, and `SimulatorTrampoline`, all under `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/`. An NSWorkspace-only check would have reported "nothing is running" while simulator state was mounted and active. This is the concrete case that forces the `proc_listallpids` half of §B.7.

---

### 4. `coresimulator-devices-orphaned` — simulator devices with no runtime

- **Paths (U):** `~/Library/Developer/CoreSimulator/Devices/<UDID>/` — one directory per simulated device, containing its whole disk.
  - Also: `~/Library/Developer/CoreSimulator/Caches/`, `~/Library/Developer/CoreSimulator/Temp/`
- **Level:** L3
- **Breakage:** That simulated device and everything installed inside it — apps, databases, granted permissions, screenshots — is gone, and you get a factory-fresh device the next time one is created.
- **Regeneration:** The device *shell* is recreated automatically by Xcode/`simctl` when the matching runtime exists. Its **contents** never come back. No network for the shell; the runtime it needs is entry 3. User action: none for the shell, re-install and re-configure apps by hand for the contents.
- **Quit first:** Yes — Simulator.app and CoreSimulatorService (see entry 3 detection).
- **Size:** measured **5,248,532,480 B (5.25 GB)** across **11 device directories**. The distribution matters more than the total: two devices hold 96% of it — `D47EF8D2…` (iPhone 17) **2.83 GB** and `84183C9A…` (iPhone 17 Pro) **2.25 GB** — while the remaining nine are 18.3 MB stubs. A single "5.25 GB" row would hide that nine of the eleven rows are not worth the user's attention.
- **Selection heuristic:** offer only devices `xcrun simctl list devices` marks `(unavailable, runtime profile not found ...)`. Measured here: **all 11 devices on this machine are orphaned** under `com.apple.CoreSimulator.SimRuntime.iOS-26-5` (iPhone 17 Pro, 17 Pro Max, 17e, Air, 17; iPad Pro 13 M5, Pro 11 M5, mini A17 Pro, Air 13 M4, Air 11 M4, iPad A16) — orphaned because the iOS 26.5 runtime is not installed (entry 3).
- **Deletion mechanism:** `xcrun simctl delete unavailable` where available, same reasoning as entry 3. Direct `trashItem` on the UDID directory is the fallback and leaves a stale entry in `device_set.plist` — if used, Loupe must also run `xcrun simctl list` afterward to let CoreSimulator reconcile, and must say it did so.
- **Honesty note:** "Unavailable" is a *current* state, not a permanent one. If the user reinstalls the iOS 26.5 runtime, all 11 of these devices become usable again with their contents intact. The row must read "unavailable because the iOS 26.5 runtime is not installed" — never "orphaned" or "broken" in the UI copy.

---

### 5. `homebrew-cache` — Homebrew download cache

- **Paths (U):** `$(brew --cache)`, default `~/Library/Caches/Homebrew/`
  - `downloads/` — the bulk; fetched bottles and cask payloads
  - `api/` — formula/cask JSON index
  - `*.bottle.tar.gz`, `portable-ruby-*.tar.gz` at the top level
  - `bootsnap/` — Ruby bytecode cache for brew itself
  - **Not a target:** `$(brew --prefix)/Caskroom/` (822 MB measured) — this holds the installer payloads Homebrew uses to *uninstall* casks. Excluded.
- **Level:** L2
- **Breakage:** Nothing on your Mac stops working; the next `brew install` or `brew upgrade` re-downloads the package instead of reusing the copy on disk.
- **Regeneration:** Automatic on next install/upgrade. **Network required.** Seconds to minutes per formula. User action: none.
- **Quit first:** No app. Refuse if a `brew` process is running (§B.7 stage 2, executable basename `brew` or `ruby` under a Homebrew prefix) — a mid-install cache wipe produces confusing failures.
- **Size:** measured **1,476,964,352 B (1.48 GB)** total; `downloads/` = 1,403,682,816 B (1.40 GB); `api/` = 102.5 MB; `bootsnap/` = 18.4 MB.
- **Deletion mechanism:** prefer `brew cleanup` semantics for the *default* selection. `brew cleanup -n` is a real dry run and Loupe should surface it: on this machine it lists specific stale versions (`jadx--1.5.6` 69.3 MB, `qhull--2020.2` 2 MB, `portable-ruby-4.0.6...` 11.7 MB, …). Deleting only what `brew cleanup -n` names is the conservative default; deleting all of `downloads/` is a separate, clearly-labelled option.
- **Honesty note:** **Two Homebrew prefixes coexist on this machine** — `brew` on `PATH` resolves to `/usr/local/bin/brew` (Intel prefix, `/usr/local/Homebrew` present) while `/opt/homebrew/bin/brew` reports prefix `/opt/homebrew`. They share one cache directory. Loupe must enumerate both prefixes rather than trusting `PATH`, and must not present a single "Homebrew" identity when there are two installs.

---

### 6. `npm-cache` — npm content cache

- **Paths (U):** `$(npm config get cache)`, default `~/.npm`
  - `~/.npm/_cacache/` — the content-addressable store (the bytes)
  - `~/.npm/_logs/` — listed separately, tiny, L1
  - `~/.npm/_npx/` — cached `npx` package installs, L2
- **Level:** L2
- **Breakage:** Nothing breaks; your next `npm install` fetches packages from the registry instead of from disk, so it is slower and needs a connection.
- **Regeneration:** Automatic on next install. **Network required.** Adds roughly 10–60 s to a cold install. User action: none. `npm cache verify` rebuilds the index without re-downloading.
- **Quit first:** No app. Refuse while any `node`/`npm` process is running.
- **Size:** measured `~/.npm/_cacache` = **5,146,066,944 B (5.15 GB)** — the largest single L2 item on this machine.
- **Honesty note:** `_cacache` contains a `tmp/` directory that here held a **540 MB `git-clone99uHUd/node_modules`** left behind by an interrupted git-dependency install. Loupe must scan `_cacache/tmp/` separately and label it "leftover from an interrupted install" — it is genuinely abandoned, unlike the rest of the cache, and the user deserves to know the difference. `dormant-node-modules` (entry 19) must **not** also match it; that path is excluded from entry 19's globs.

---

### 7. `pnpm-store` — pnpm content-addressable store

- **Paths (U):** `$(pnpm store path)`; defaults on macOS are `~/Library/pnpm/store/v3` or `~/.local/share/pnpm/store/v3`; `~/Library/Caches/pnpm/` for metadata.
- **Level:** **L3** (not L2 — see note)
- **Breakage:** Every pnpm project on this Mac loses the hardlinks its `node_modules` points at, so each one needs `pnpm install` again before it will run.
- **Regeneration:** Not automatic and not transparent. **Network required**, plus an explicit `pnpm install` per affected project. Minutes per project.
- **Quit first:** No app. Refuse while `node`/`pnpm` is running.
- **Size:** **not present** on this machine (`pnpm` not installed; neither default path exists).
- **Honesty note:** pnpm is the one JS package manager whose "cache" is not a cache. Existing `node_modules` trees are **hardlinks into the store**; removing the store breaks already-installed projects that npm/yarn users would expect to be untouched. Classifying pnpm alongside npm as L2 would be a factual error. Row copy must state this explicitly.

---

### 8. `yarn-cache` — Yarn cache

- **Paths (U):**
  - Yarn 1: `$(yarn cache dir)`, typically `~/Library/Caches/Yarn/v6` or `~/.cache/yarn`
  - Yarn 2+ (Berry) global: `~/.yarn/berry/cache`
  - Yarn 2+ project-local: `<project>/.yarn/cache` — **excluded**, it is often committed to the repo (zero-installs) and deleting it can break a checked-in build
- **Level:** L2 (global paths only)
- **Breakage:** Nothing breaks; the next `yarn install` re-downloads packages instead of reading them from disk.
- **Regeneration:** Automatic, **network required**, seconds to minutes. User action: none.
- **Quit first:** No app. Refuse while `node`/`yarn` is running.
- **Size:** **not present** (`yarn` not installed; `~/.cache/yarn`, `~/Library/Caches/Yarn`, `~/.yarn` all absent).
- **Honesty note:** the project-local exclusion is load-bearing. A Berry repo with `.yarn/cache` committed will fail to build after deletion and `git status` will show hundreds of deletions. Loupe never globs `.yarn/cache` under a directory containing `.git`.

---

### 9. `pip-cache` — pip wheel and HTTP cache

- **Paths (U):** `$(python3 -m pip cache dir)`, default `~/Library/Caches/pip`
  - `wheels/` — locally built wheels; **rebuilding these can require a compiler toolchain**
  - `http-v2/` (or `http/`) — downloaded artifacts
- **Level:** L2
- **Breakage:** Nothing breaks; the next `pip install` downloads packages again, and any package that had to be compiled from source will be compiled again.
- **Regeneration:** Automatic, **network required**. Seconds for a pure wheel; **minutes and a working compiler** for a source build. User action: none, unless a source build now fails on a toolchain the user no longer has.
- **Quit first:** No app. Refuse while `pip`/`python` is running.
- **Size:** measured **2,116,014,080 B (2.12 GB)**.
- **Honesty note:** `wheels/` and `http/` must be shown as separate rows with separate sizes. `http/` is genuinely free to lose. `wheels/` may contain the only compiled artifact for a package that no longer builds on this machine's current toolchain. Same directory tree, different risk — a single "pip cache" row would hide that.

---

### 10. `uv-cache` — uv cache

- **Paths (U):** `$(uv cache dir)`, default `~/.cache/uv` on macOS. Honour `UV_CACHE_DIR`.
- **Level:** L2
- **Breakage:** Nothing breaks; uv re-downloads and re-unpacks packages on the next command.
- **Regeneration:** Automatic, **network required**, typically fast (uv is the quickest of these to refill). User action: none. `uv cache clean` is the supported command and Loupe should prefer it.
- **Quit first:** No app. Refuse while `uv` is running.
- **Size:** **not present.** `uv` **is** installed at `/usr/local/bin/uv` and reports its cache directory as `/Users/kierankelly/.cache/uv`, but that directory does not exist — uv has never populated it here.
- **Honesty note:** this is the "configured but never used" case. The row must read "uv is installed; its cache directory has not been created yet", **not** "not present" and **not** 0 B. Those are three different facts and R7's generic wording is insufficient here.

---

### 11. `docker-desktop-disk-image` — Docker Desktop disk image  ⚠️ L4

- **Paths (U):**
  - `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` (Docker Desktop, current layout)
  - `~/Library/Containers/com.docker.docker/Data/vms/*/data/*.raw` (glob for older/multiple VMs)
  - Related, **separate rows**: `~/Library/Containers/com.docker.docker/Data/` (1.81 GB here), `~/Library/Group Containers/group.com.docker/` (65 KB), `~/Library/Caches/Docker Desktop/` (8 KB), `~/.docker/`
  - Alternative runtimes checked and **not present**: `~/.colima`, `~/.orbstack`, `~/.rd` (Rancher Desktop)
- **Level:** **L4**
- **Breakage:** Every Docker image, container and named volume on this Mac is destroyed, including any database or file that lives only inside a volume.
- **Regeneration:** The empty disk image is recreated automatically by Docker Desktop on next launch (seconds). The **contents** do not come back. Images can be re-pulled if they still exist in a registry — **network required**, minutes to hours depending on how many. Volumes are not recoverable from anywhere. User action: `docker pull` per image, and manual restore for volume data.
- **Quit first:** **Mandatory.** Detection, all three required:
  1. `NSWorkspace.runningApplications` contains `com.docker.docker`;
  2. `proc_listallpids` → any `proc_pidpath` whose basename is `com.docker.backend`, `com.docker.virtualization`, `vpnkit`, `docker`, or `qemu-system-*`;
  3. an open file handle on the `.raw` itself (§B.7.3). Verified here that this can be checked from the shell (`lsof` present at `/usr/sbin/lsof`); in-process the equivalent is `proc_pidinfo(PROC_PIDLISTFDS)` + `PROC_PIDFDVNODEPATHINFO`, which works for same-uid processes without root. **Unverified in Swift.**
  - Measured state at scan time: Docker daemon **not running** (`Cannot connect to the Docker daemon`), no Docker processes found.
- **Size — the sparse-file problem:** measured on this machine:

  | Figure | Bytes | Human | Source |
  |---|---|---|---|
  | Apparent (`st_size`) | 494,384,709,632 | **494.38 GB** | `ls -l`, `stat -f %z`, `du -skA` |
  | On disk (`st_blocks × 512`) | 1,771,352,064 | **1.77 GB** | `stat -f %b`, `du -sk` |

  The file was created with a 494 GB *maximum* size and has 1.77 GB actually allocated.

- **How to report this honestly (normative):**
  1. The reclaim figure is the **on-disk** number, full stop. `1.77 GB`.
  2. The apparent size is shown as **secondary text**, never as a number the user could mistake for the reclaim: “Docker reserves up to 494.38 GB for this image but is currently using 1.77 GB of it.”
  3. Loupe must **never** display a figure sourced from `ls -l`, Finder's Get Info, or `st_size` for this entry, because all three report 494.38 GB. If the user has seen 494 GB in Finder, Loupe explains the discrepancy in-row rather than silently contradicting it: “Finder shows 494.38 GB because that is the size Docker reserved. Only 1.77 GB is on disk.”
  4. When Docker **is** running, prefer `docker system df` for the breakdown (images / containers / volumes / build cache) and offer `docker system prune` as a *less destructive alternative*, presented above the delete option. Deleting `Docker.raw` when `docker system prune` would have sufficed is a worse outcome for the user, and the UI must say so.
  5. After the file is trashed it keeps its sparseness through the rename, so the Trash will *also* show 494.38 GB in Finder. The confirmation sheet warns about this in advance.
- **Honesty note:** this entry is the single largest opportunity in the app to inflate a number by 279×, which is precisely why it is specified in this much detail. Any code path that sums `st_size` and reaches this file is a shipping blocker.

---

### 12. `ios-device-backups` — iPhone & iPad backups  ⚠️ L4

- **Paths (U):** `~/Library/Application Support/MobileSync/Backup/<40-hex-UDID or UUID>/`
  - Each backup contains `Info.plist`, `Manifest.plist`, `Manifest.db`, `Status.plist`, and hashed content directories `00`–`ff`.
  - Some users relocate this with a symlink; §B.3 canonicalisation resolves it, and the row must show the **real** location if it differs.
- **Level:** **L4**
- **Breakage:** If this Mac holds the only copy of that backup, the photos, messages and app data captured in it are gone permanently.
- **Regeneration:** Not automatic and not possible from Loupe. A new backup requires the physical device, a cable, and 10–60+ minutes. A backup of a device the user no longer owns cannot be recreated at all. **The device's data may also be in iCloud Backup — Loupe has no way to verify that and must not imply it does.**
- **Quit first:** Yes — Finder (device sync), `Apple Devices.app`, iTunes on older systems. Detection: `com.apple.finder` is always running, so the check must be for an **open handle** on the specific backup directory (§B.7.3), plus `proc_pidpath` matches for `AMPDeviceDiscoveryAgent`, `MobileDeviceUpdater`, `com.apple.AMPDevicesAgent`.
- **Size:** measured — `~/Library/Application Support/MobileSync/Backup/` **exists and is empty (0 B, no subdirectories)**. Typical range elsewhere is 5–150 GB per device; **unverified** on this host.
- **Honesty note:** parse `Info.plist` per backup and show **Device Name, Product Type, iOS version, and Last Backup Date** on the row. A row that says "iPhone backup, 47 GB" is not enough information to make a permanent-loss decision. A row that says “Kieran's iPhone — iPhone 17 Pro — iOS 26.5 — last backed up 14 March 2024” is. Also: the backup directory being present-but-empty (this machine) is worth surfacing as "no backups stored on this Mac", because users frequently believe they have local backups when they do not.

---

### 13. `mail-downloads` — Mail attachment downloads

- **Paths (U):**
  - `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/` (sandboxed Mail, current)
  - `~/Library/Mail Downloads/` (legacy, pre-sandbox)
  - `~/Library/Containers/com.apple.mail/Data/Library/Caches/`
  - **Explicitly not a target:** `~/Library/Mail/V10/` — the mail store itself, 5.55 GB measured.
- **Level:** L2
- **Breakage:** Attachments you previously opened are removed from disk; Mail re-downloads them from the server the next time you open that message.
- **Regeneration:** Automatic on next open. **Network required, and the message must still exist on the server** — an attachment on a message that has since been deleted server-side, or in a POP account with no server copy, is gone. Seconds per attachment.
- **Quit first:** Yes — Mail. Detection: `com.apple.mail` in `NSWorkspace.runningApplications`. Measured: **Mail was running at scan time**, so this entry would have been correctly blocked.
- **Size:** measured `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` = **26,030,080 B (26.0 MB)**. Legacy `~/Library/Mail Downloads`: **not present**.
- **Honesty note:** the POP-account and deleted-message cases mean this is not unconditionally safe, despite being small and cache-shaped. The row's regeneration text says "if the message is still on the server", not "always comes back". At 26 MB this entry will never be the reason someone uses Loupe; it stays in the catalog because omitting it would leave the user wondering, and explaining it is the product.

---

### 14. `trash` — Trash  ⚠️ L5, special handling

- **Paths (U):**
  - `~/.Trash/`
  - Per-volume: `/Volumes/<Name>/.Trashes/<uid>/` for every mounted writable volume
  - `/.Trashes/<uid>` on the boot volume (**not present** on this machine)
- **Level:** **L5**
- **Breakage:** Everything you previously put in the Trash is permanently deleted, including anything you put there by mistake.
- **Regeneration:** None. This is the terminal operation.
- **Quit first:** No.
- **Size:** measured `~/.Trash` = **0 B (empty)**. `/Volumes` contains only the boot-volume alias `Macintosh HD → /`; no external volumes, no `.Trashes` anywhere.
- **Loupe does not empty the Trash.** This is a deliberate architectural decision, not an omission:
  - Loupe's deletion invariant is "always `trashItem`, never `unlink`" (§B.6). Emptying the Trash is by definition an unlink. Implementing it would put the one unsafe primitive in the codebase, where it can be reached by a bug.
  - Instead the Trash row is **informational**: it shows the true on-disk size, the item count, and a single button **"Open Trash in Finder"** (`NSWorkspace.shared.open(trashURL)`). The user empties it with the system's own confirmation, which they already understand.
  - Rejected alternative: driving Finder's `empty trash` via AppleScript. It requires an Automation entitlement, triggers a TCC consent prompt users reasonably find alarming from a "disk inspector", and gives Loupe no additional safety over Finder doing it directly.
- **The Trash honesty rule (normative UI copy).** Because R5 binds the whole catalog, the following appear at these exact locations:

  | Location | Exact copy |
  |---|---|
  | Persistent footer on every reclaim screen | `Items moved to the Trash still use disk space. Your available space changes when you empty the Trash.` |
  | Confirmation sheet, above the buttons, non-dismissible | Same sentence. |
  | Post-run report, first line | `Moved N items (X GB) to the Trash. No disk space has been freed yet.` |
  | Trash row subtitle when non-empty | `X GB is sitting in the Trash right now. Emptying it is the step that frees the space.` |
  | Trash row subtitle when empty | `Your Trash is empty.` |
  | Headline "found" number | Must **exclude** the Trash's contents, since those bytes are already counted wherever the user sees "in the Trash". Double-counting them would be inflation. |

- **Honesty note:** the reclaim number Loupe shows before a run is a number of bytes that will *move*, not a number of bytes that will *free*. Every piece of copy in the pillar is written from that premise. This is the single most common dishonesty in this product category and the rule exists to make it structurally impossible here.

---

### 15. `browser-cache-safari` — Safari cache

- **Paths (U):**
  - `~/Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari/` — the bulk
  - `~/Library/Containers/com.apple.Safari/Data/Library/Caches/WebKit/`
  - `~/Library/Caches/com.apple.Safari/` — small, holds `WebKitCache/`, `OnboardingExtensionIconCache/`
  - **Not targets:** `~/Library/Safari/` (history, bookmarks, reading list), `~/Library/Containers/com.apple.Safari/Data/Library/Safari/`, any `LocalStorage`/`Databases` directory (site data ≠ cache; deleting it logs the user out of sites)
- **Level:** L2
- **Breakage:** Pages you have visited load a little slower the next time because their images and scripts are fetched again; you stay logged in everywhere.
- **Regeneration:** Automatic as you browse. **Network required.** Imperceptible per page. User action: none.
- **Quit first:** Yes — Safari. Detection: `com.apple.Safari` in `NSWorkspace.runningApplications`. Also refuse if any `com.apple.WebKit.Networking`/`com.apple.WebKit.WebContent` process has an open handle in the tree. Measured: Safari **not running** at scan time.
- **Size:** measured — container `Caches/com.apple.Safari` = **294,498,304 B (294 MB)**, container `Caches/WebKit` = 3.2 MB, `~/Library/Caches/com.apple.Safari` = 270 KB. Total **297,963,520 B (298 MB)**.
- **Honesty note:** the "stay logged in" clause is the whole point of the breakage sentence. Users conflate "clear cache" with "clear cookies and get logged out of everything" because most cleaners do both. Loupe touches only cache paths, and says so in the sentence rather than in a footnote.

---

### 16. `browser-cache-chromium` — Chromium-family browser caches

One entry, one row **per detected browser profile**. Chromium browsers split cache
(`~/Library/Caches/<Vendor>/`) from profile data (`~/Library/Application Support/<Vendor>/`),
and the split is not clean.

| Browser | Cache root | Profile root | Present here |
|---|---|---|---|
| Chrome | `~/Library/Caches/Google/Chrome/<Profile>/` | `~/Library/Application Support/Google/Chrome/<Profile>/` | **yes** |
| Arc | `~/Library/Caches/company.thebrowser.Browser/` | `~/Library/Application Support/Arc/` | profile only — cache dir absent |
| Edge | `~/Library/Caches/Microsoft Edge/` | `~/Library/Application Support/Microsoft Edge/` | no |
| Brave | `~/Library/Caches/BraveSoftware/Brave-Browser/` | `~/Library/Application Support/BraveSoftware/Brave-Browser/` | no |
| Opera / Opera GX | `~/Library/Caches/com.operasoftware.Opera*/` | `~/Library/Application Support/com.operasoftware.Opera*/` | profile only |
| Vivaldi | `~/Library/Caches/Vivaldi/` | `~/Library/Application Support/Vivaldi/` | no |

- **Targeted subpaths (cache root only):** `<Profile>/Cache/`, `<Profile>/Code Cache/`, `<Profile>/image_cache/`, `GPUCache/`, `GraphiteDawnCache/`, `DawnWebGPUCache/`, `ShaderCache/`
- **Excluded from the profile root, always:** `Extensions/`, `IndexedDB/`, `Local Storage/`, `Local Extension Settings/`, `Service Worker/`, `Sessions/`, `History`, `Cookies`, `Login Data`, `Web Applications/`, `Shared Dictionary/`
- **Level:** L2
- **Breakage:** Sites reload their images and scripts from the network next time; your tabs, logins, extensions and history are untouched.
- **Regeneration:** Automatic as you browse. **Network required.** User action: none.
- **Quit first:** Yes, the specific browser. Detection: bundle ID in `NSWorkspace.runningApplications`, **plus** `proc_pidpath` matching for the helper processes, which is essential here — Chromium helpers (`<Browser> Helper (Renderer).app`) live inside the parent bundle and keep cache files open. Measured example of exactly this shape on this machine: two `Claude Helper (Renderer)` processes under `/Applications/Claude.app/Contents/Frameworks/`. Measured: Chrome **not running**; Opera GX **was** running (`com.operasoftware.OperaGX`), so its row would have been correctly blocked.
- **Size:** measured Chrome `Default` cache = **568,344,576 B (568 MB)** → `Cache/` 485 MB, `Code Cache/` 83.2 MB, `Storage/` 20 KB, `image_cache/` 0 B.
- **Honesty note:** `~/Library/Application Support/Google/Chrome/Default/Extensions` is 515 MB here — nearly as large as the cache — and it is **not** a cache. Any tool that sweeps the profile root by size would take it. The exclusion list above is enforced in the safety engine as a per-entry deny list, not just left out of the include globs, so an include-glob bug cannot reach it.

---

### 17. `browser-cache-firefox` — Firefox cache

- **Paths (U):**
  - `~/Library/Caches/Firefox/Profiles/<hash>.<name>/` — including `cache2/`, `startupCache/`, `thumbnails/`
  - Legacy: `~/Library/Caches/Mozilla/`
  - **Not targets:** `~/Library/Application Support/Firefox/Profiles/<hash>.<name>/` — this is the profile (`places.sqlite`, `cookies.sqlite`, `logins.json`, extensions). Never touched.
  - Profile enumeration must come from `~/Library/Application Support/Firefox/profiles.ini`, not from directory globbing.
- **Level:** L2
- **Breakage:** Pages reload their images and scripts from the network next time; your tabs, logins, extensions and history are untouched.
- **Regeneration:** Automatic as you browse. **Network required.** User action: none.
- **Quit first:** Yes — Firefox (`org.mozilla.firefox`), plus `plugin-container` processes.
- **Size:** **not present** — neither `~/Library/Caches/Firefox`, `~/Library/Caches/Mozilla`, nor `~/Library/Application Support/Firefox` exists on this machine. Firefox has never run here.
- **Honesty note:** the Caches/Application Support split is inverted relative to what many users expect (Firefox puts the *cache* in `Caches` and the *profile* in `Application Support`, cleanly — unlike Chromium, which puts cache-like data in both). Loupe should not present a Firefox row at all when `profiles.ini` is absent, rather than showing an empty category.

---

### 18. `stale-downloads` — older items in Downloads  ⚠️ L5, review-only

- **Paths (U):** `~/Downloads/` — top level only, `maxdepth 1`. Loupe never descends into a downloaded folder to pick out individual files.
- **Level:** **L5.**
- **Breakage:** A file you chose to save is deleted; if it came from a link that has since expired or a site you no longer have access to, you cannot get it back.
- **Regeneration:** None automatic. Recovery means finding the original source again, which may not exist.
- **Quit first:** No.
- **Size:** measured **1,321,725,952 B (1.32 GB)** across **236 top-level items**.
- **Age distribution measured here:**

  | Filter | Count |
  |---|---|
  | `mtime` older than 90 days | 13 |
  | `mtime` older than 180 days | **0** |
  | `atime` older than 90 days | 7 |
  | Have a Spotlight `kMDItemLastUsedDate` at all | **21 of 60 sampled (35%)** |

- **How conservative the default must be, and why:**

  1. **The default is: nothing is ever selected, at any age.** There is no age threshold at which Loupe checks a Downloads box. The entry is a sorted, annotated *list* with a per-item review action, not a bulk operation. This is the only defensible default because every failure mode below is a permanent loss of user-authored-or-chosen data, and the upside is 1.3 GB on a machine with 98.7 GB free.
  2. **`mtime` does not mean "last used".** It is the download completion time and never changes again. A tax document downloaded in January and opened forty times since still has a January `mtime`. Sorting by `mtime` and calling the top "stale" is a factual claim Loupe cannot support.
  3. **`atime` is not a reliable substitute.** The Data volume is not mounted `noatime`, so `atime` does update — but Spotlight indexing, backup agents and antivirus scanners all touch it. It is a usable *positive* signal ("recently accessed, definitely keep") and a bad *negative* one.
  4. **`kMDItemLastUsedDate` is the only field that means what we want, and it is missing 65% of the time** (measured: 21/60). An age heuristic built on a field that is absent for two out of three files would silently mark unopened-but-precious files as stale. Loupe shows it when present and shows "no record of it being opened" when absent — it never infers staleness from absence.
  5. **Provenance is more useful than age, and it is available.** `kMDItemWhereFroms` is populated on this machine (sample value: a `cdn.discordapp.com` attachment URL), as is the `com.apple.quarantine` xattr, which records the downloading app and date (sample: `0081;6a655fe4;Opera GX;<uuid>`). Loupe shows **"Downloaded from discordapp.com via Opera GX on 26 July 2026"** on the row. That is a fact the user can act on. "247 days old" is not.
  6. **Sort by size, not by age.** The user's actual question is "what large thing am I done with", and size is a fact while staleness is a guess.
- **Honesty note:** the measured result on this machine — 0 items older than 180 days — is the expected and correct outcome of a conservative rule, not a failure of the feature. If a Downloads heuristic finds a lot, it is probably wrong.

---

### 19. `dormant-node-modules` — node_modules in untouched projects

- **Paths (U):** discovered, not fixed. Search roots default to `~/Projects`, `~/Developer`, `~/Documents`, `~/Desktop`, `~/src`, `~/code`, and any additional root the user adds. `maxdepth` 6 from each root.
- **Level:** L3
- **Breakage:** That project will not build or run until you reinstall its dependencies.
- **Regeneration:** Not automatic. Requires `npm ci` / `pnpm install` / `yarn install` in that directory. **Network required.** 20 s – 5 min per project. User action: run the command.
- **Quit first:** No app, but refuse if any `node` process's cwd or open files are inside the candidate (§B.7.3), and refuse if a `.pid`/lockfile indicates a dev server.
- **Size:** measured — **32** `node_modules` directories at depth ≤ 5 under `~`. Largest: `~/Projects/Inspectiod/node_modules` 572 MB, `~/Desktop/Class Royale/node_modules` 544 MB, `~/Projects/edex-ui-.../node_modules` 434 MB.

#### 19.1 The dormancy heuristic

**Never use `node_modules`' own mtime.** It reflects the last `npm install`, which is
uncorrelated with whether the project is in use, and is rewritten by unrelated tooling.

For each candidate project root `P` (a directory containing both `node_modules/` and a
manifest):

```
IGNORE = { node_modules, .git, .next, dist, build, out, .turbo,
           .venv, venv, target, coverage, .cache, .parcel-cache, .svelte-kit }

newest_source = max( lstat(f).st_mtime
                     for f in files under P, excluding any path containing an IGNORE component )

source_age_days = (now - newest_source) / 86400
```

`P` is offered as dormant only if **all** of the following hold:

| # | Gate | Rationale |
|---|---|---|
| G1 | `source_age_days > 180` (configurable, floor 90 — the UI will not accept a smaller value) | The signal is "the human has not touched this project", derived from files the human edits. |
| G2 | A lockfile exists (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`) | Without one, reinstall is not reproducible; the tree cannot be restored to what it was. Downgrade to review-only. |
| G3 | `P` is not inside another project's `node_modules` | Prevents nested double-counting. |
| G4 | `P` is not under `~/.npm`, `~/.cache`, `~/Library`, or any Loupe cache-entry path | Measured need: `~/.npm/_cacache/tmp/git-clone99uHUd/node_modules` (540 MB) belongs to entry 6, not here. |
| G5 | If `P` is a git repo, `git status --porcelain` is empty | Uncommitted work means the project is mid-flight regardless of file dates. |
| G6 | No process has an open file or cwd inside `P` | §B.7.3. |

**Measured against this machine.** Newest-source ages for the 8 discovered project roots:

| Project | newest source age (days) | `node_modules` mtime age (days) | size |
|---|---|---|---|
| `edex-ui-arm64-darwin-api-update` | 113.5 | 113.5 | 0.43 GB |
| `Zinger` | 27.8 | **75.6** | 0.11 GB |
| `badwebsitesearch` | 27.8 | 27.8 | 0.36 GB |
| `OSINT` | 27.8 | 27.8 | 0.26 GB |
| `rHUD` | 18.9 | 18.9 | 0.15 GB |
| `Inspectiod` | 5.9 | 6.5 | 0.58 GB |
| `Class Royale` | 1.6 | 1.7 | 0.55 GB |
| `gods-eye-view` | 0.8 | 0.9 | 0.28 GB |

At the 180-day default, **zero** projects qualify. At the 90-day floor, exactly one does
(`edex-ui`, 0.43 GB). Note `Zinger`, where `node_modules` is 76 days old but the sources are
28 days old — an mtime-of-node_modules heuristic would rank it as staler than it is. That
inversion is the reason for the rule.

#### 19.2 False-positive modes, stated plainly

1. **Finished but still used.** A tool the user wrote two years ago, runs weekly, and has
   never needed to edit looks identical to an abandoned project. Loupe will offer it. Deleting
   it breaks the tool until `npm ci`. **This is the primary false positive and it is not
   eliminable from file metadata alone.** The row copy says so: "Loupe can tell that nobody
   has *edited* this project in N months. It cannot tell whether you still *run* it."
2. **Rewritten mtimes.** `git clone`, `rsync` without `-t`, a Time Machine restore, an
   unarchive, or moving between machines rewrites source mtimes to *now*. This produces
   false **negatives** (a genuinely dead project looks fresh) — the safe direction — but a
   restore of an *old* archive with preserved times can also make an active project look dead.
3. **Reinstall may not reproduce.** `npm ci` restores what the lockfile names *if the registry
   still serves it*. Unpublished, yanked, or private-registry-behind-expired-credentials
   packages do not come back. G2 makes reinstall *deterministic*, not *guaranteed*. The row
   says "reinstalling needs those packages to still be published".
4. **Native builds.** A tree containing compiled `.node` binaries may need a toolchain the
   user no longer has. Loupe detects `node_modules/**/build/Release/*.node` and, when found,
   adds "this project compiled native code; reinstalling may need build tools" to the row.

---

## B. The safety engine

Package `LoupeSecurity`. Every deletion in the app passes through it. The catalog in Part A
is **input** to this engine, never a bypass of it — an entry whose path the engine denies is
denied, and that is a bug in the catalog, not an exception to be granted.

### B.1 Position in the pipeline

```
discover → canonicalise (B.3) → guard (B.4 lexical, B.5 identity, B.6 flags)
        → size (R1–R4) → present → user selects → re-guard → dry-run sheet (B.8)
        → confirm → trashItem (B.9) → verify → report
```

The guard runs **twice**: once at scan time and again immediately before each `trashItem`.
The second run is not redundant — the filesystem can change between scan and confirm.

### B.2 The blocklist

Deny rules, expressed as path-component arrays. `~` is the *invoking user's* home, resolved
via `getpwuid(getuid())->pw_dir`, not `NSHomeDirectory()` (which is container-relative under
sandboxing) and not `$HOME` (which is attacker-influenceable).

| Rule | Components | Kind |
|---|---|---|
| `/System` | `["System"]` | deny subtree |
| `/usr` | `["usr"]` | deny subtree |
| `/usr/local` | `["usr","local"]` | **allow**, overrides `/usr` |
| `/Library/Apple` | `["Library","Apple"]` | deny subtree |
| `~/Library/Keychains` | `[…,"Library","Keychains"]` | deny subtree |
| `~/Library/Group Containers` | `[…,"Library","Group Containers"]` | deny subtree |
| `/Library/Keychains`, `/private/var/db/SystemKey` | | deny subtree |
| `.git` | any component equal to `.git` | deny subtree, positional-anywhere |
| running app bundle | dynamic, §B.7 | deny subtree |
| dataless placeholder | dynamic, `SF_DATALESS`, §B.6 | deny item |
| volume roots, `/`, `/Users`, `~` itself, `~/Library` itself | | deny item (not subtree) |

Additional hard denies (defensive, beyond the assignment's list): `/bin`, `/sbin`, `/etc`,
`/var`, `/private/var/db`, `/private/var/folders`, `/Applications` *as an item*,
`~/Library/Containers` *as an item*, `~/Library/Application Support/com.apple.TCC`,
`/Volumes` *as an item*, and any path on a volume mounted read-only.

**Allow-rule semantics.** An allow rule cancels a deny rule only if it is **strictly longer**
(more components) and the deny rule is a component-prefix of it. `/usr/local` (2 components)
beats `/usr` (1). Nothing beats `/System`, because no allow rule for it exists. Allow rules
never *grant* deletion; they only remove one deny. Every other guard still runs.

**Measured justification that the blocklist cannot be derived from flags:**

| Path | `st_flags` | `SF_RESTRICTED`? |
|---|---|---|
| `/System` | `0x00080000` | yes |
| `/usr` | `0x00088000` | yes |
| `/usr/local` | `0x00100000` | **no** (`SF_NOUNLINK` only) |
| `/Library/Apple` | `0x00080000` | yes |
| `~/Library/Keychains` | `0x00000000` | **no** |
| `~/Library/Group Containers` | `0x00000000` | **no** |

Two of the six required blocklist entries carry **no** protective flag at all. Flags are a
tripwire (§B.6), not the blocklist. Conversely `/usr/local` carries a flag but must be
allowed. Neither mechanism subsumes the other; both run.

### B.3 Canonicalisation

Run in this order, before any matching.

1. **Reject** non-`file:` URLs, relative paths, empty paths, and paths containing a NUL.
2. **`realpath(3)`** on the full path (`URL.resolvingSymlinksInPath()` is *not* sufficient —
   it does not consult the filesystem for every component). Resolves `.`, `..`, and symlinks.
   Verified: `/etc → /private/etc`, `/var → /private/var`, `/tmp → /private/tmp`.
3. **Firmlink normalisation** — *this step is why `realpath` alone is not enough.*
4. **Split into components**, dropping the leading empty produced by the leading `/`.
5. **Normalise each component** with `precomposedStringWithCanonicalMapping` (NFC). APFS
   stores names normalisation-insensitively; comparing raw UTF-8 lets a decomposed
   `Library` bypass a precomposed rule.
6. **Case folding**, conditional: query `URLResourceKey.volumeSupportsCaseSensitiveNamesKey`
   on the containing volume. If the volume is case-**in**sensitive (the default for the boot
   volume), compare components case-insensitively. If case-sensitive, compare exactly.
   Hardcoding either behaviour is wrong.

#### B.3.1 APFS firmlinks — the correctness trap

`realpath()` **does not resolve firmlinks.** Measured on this machine:

```
lstat("/Users/kierankelly/.Trash")                            → dev=16777234 ino=681790
lstat("/System/Volumes/Data/Users/kierankelly/.Trash")        → dev=16777234 ino=681790   ← identical

realpath("/Users/kierankelly/.Trash")                  = "/Users/kierankelly/.Trash"
realpath("/System/Volumes/Data/Users/kierankelly/.Trash")
                                                       = "/System/Volumes/Data/Users/kierankelly/.Trash"
```

Same file. Two different canonical paths. The same holds for `/Users`, `/Applications`,
`/private/var`, and `/usr/local` (all verified identical `(dev, ino)` pairs across the two
prefixes). A purely lexical guard is therefore trivially bypassable by prefixing
`/System/Volumes/Data`.

**Algorithm.** Read `/usr/share/firmlinks` — verified present, tab-separated,
`<system-volume-absolute-path>\t<data-volume-relative-path>`. Its full measured contents on
this machine:

```
/AppleInternal          AppleInternal
/Applications           Applications
/Library                Library
/System/Library/Caches  System/Library/Caches
/System/Library/Assets  System/Library/Assets
/System/Library/PreinstalledAssets      System/Library/PreinstalledAssets
/System/Library/AssetsV2                System/Library/AssetsV2
/System/Library/PreinstalledAssetsV2    System/Library/PreinstalledAssetsV2
/System/Library/CoreServices/CoreTypes.bundle/Contents/Library  …/Contents/Library
/System/Library/Speech  System/Library/Speech
/Users                  Users
/Volumes                Volumes
/cores                  cores
/opt                    opt
/pkg                    pkg
/private                private
/usr/local              usr/local
/usr/libexec/cups       usr/libexec/cups
/usr/share/snmp         usr/share/snmp
```

Normalisation step:

```
if components starts with ["System","Volumes","Data"]:
    rest = components.dropFirst(3)
    for (systemPath, dataRelPath) in firmlinkTable:
        if rest starts with components(dataRelPath):
            return components(systemPath) + rest.dropFirst(count(dataRelPath))
    return rest            // fall back to bare prefix strip
```

Note `/usr/local` appearing in this table is exactly why the `/usr` deny needs a `/usr/local`
allow: `/usr` is on the sealed system volume, but `/usr/local` is a firmlink to writable Data
storage. The allow rule is not a convenience, it is a structural fact of the volume layout.

**Fallbacks and hardening:**
- If `/usr/share/firmlinks` is missing or unreadable (it lives on the sealed read-only
  system volume, and a future OS may relocate it), fall back to the bare
  `/System/Volumes/Data` prefix strip. Log the fallback; do not fail open.
- The table is read **once** at engine init and cached for the process lifetime.
- Normalisation is applied for **matching only**. The path passed to `trashItem` is the
  path the user was shown, which is the post-`realpath`, pre-firmlink-rewrite form.
- Also normalise `/System/Volumes/Data` with no trailing components (the Data volume root
  itself) to `/`, and deny it as an item.

### B.4 Matching by component — the algorithm

```
func matchesSubtree(candidate: [String], rule: [String]) -> Bool {
    guard candidate.count >= rule.count else { return false }
    for i in 0..<rule.count {
        if !componentsEqual(candidate[i], rule[i]) { return false }
    }
    return true
}
```

`componentsEqual` is NFC-normalised, case-folded per §B.3 step 6, **whole-component** string
equality. Never `hasPrefix`, never `contains`, never `range(of:)`, never a regex over the
joined path string, never `NSString.standardizingPath`.

**Required test vectors** (all must pass; these are the acceptance criteria for the matcher):

| Candidate | Rule `/usr/local` | Expected |
|---|---|---|
| `/usr/local` | | allow-match |
| `/usr/local/bin/foo` | | allow-match |
| `/usr/localfoo` | | **no match** — `"localfoo" != "local"` |
| `/usr/local-backup/x` | | **no match** |
| `/usr/localhost` | | **no match** |
| `/usr/Local/bin` | | match on case-insensitive volume; no match on case-sensitive |
| `/usr/loca` | | no match |

| Candidate | Rule `/System` | Expected |
|---|---|---|
| `/System` | | deny |
| `/System/Library/x` | | deny |
| `/Systemx` | | **no match** |
| `/System Volumes/x` | | **no match** |
| `/private/../System/Library` | | deny (after §B.3 step 2) |
| `/System/Volumes/Data/Users/u/.Trash` | | rewritten by §B.3.1 to `/Users/u/.Trash`, then evaluated against home rules — **not** matched against `/System` |

| Candidate | Rule `.git` (positional-anywhere) | Expected |
|---|---|---|
| `~/Projects/x/.git` | | deny |
| `~/Projects/x/.git/objects/ab` | | deny |
| `~/Projects/x/.github` | | **no match** |
| `~/Projects/x/.gitignore` | | **no match** |
| `~/Projects/.git-backup/y` | | **no match** |

`.git` is a **positional-anywhere** rule: deny if *any* component equals `.git`. It is not a
prefix rule. Measured: 25 `.git` directories at depth ≤ 5 under `~` on this machine, so this
rule is live, not theoretical.

### B.5 Identity matching — the backstop

Lexical matching alone cannot survive every aliasing route (firmlinks, hardlinked
directories, bind-mount-like constructs, a volume mounted at two points, TOCTOU renames).
Therefore, in addition to §B.4 and never instead of it:

1. At engine init, `lstat` each blocklist root that exists and record `(st_dev, st_ino)`.
2. For a candidate, walk from the candidate to `/`, `lstat`-ing each ancestor, and deny if
   any ancestor's `(st_dev, st_ino)` is in the denied set. Cost is O(depth) — the deepest
   realistic candidate here is ~12 components.
3. Cache ancestor stats per scan, keyed by canonical path; invalidate on re-guard.

This is immune to case, Unicode normalisation, symlinks, and firmlinks by construction —
verified above that the two firmlink aliases of `~/.Trash` share `(16777234, 681790)`.
It cannot cover rules whose root does not exist, which is why §B.4 also runs.

Denials from §B.4 and §B.5 are OR'd. Either one denies, the path is denied.

### B.6 Flag tripwires

`lstat` (never `stat` — do not follow the final symlink when deciding) the candidate **and
every ancestor**. All bit values verified in
`$(xcrun --sdk macosx --show-sdk-path)/usr/include/sys/stat.h` on this machine:

| Constant | Value | Header line | Meaning | Engine action |
|---|---|---|---|---|
| `SF_RESTRICTED` | `0x00080000` | 341 | entitlement required for writing (SIP) | **Deny subtree.** Present on `/System`, `/usr`, `/bin`, `/etc`, `/var`, `/tmp`, `/Library/Apple`, `/System/Applications` — all verified. |
| `SF_DATALESS` | `0x40000000` | 359 | file is a dataless object (iCloud placeholder) | **Deny item**, and report its size as 0 (R4). Verified on 29 files under `~/Library/Mobile Documents`, e.g. flags `0x40000060`. |
| `SF_NOUNLINK` | `0x00100000` | 342 | item may not be removed, renamed or mounted on | **Deny item.** Verified on `/`, `/Library`, `/Applications`, `/usr/local`, `/private/var`, `/System/Volumes/Data`. |
| `SF_IMMUTABLE` | `0x00020000` | 339 | file may not be changed (system-locked) | Deny item. |
| `UF_IMMUTABLE` | `0x00000002` | 312 | file may not be changed (user "Locked") | Deny item; offer to reveal in Finder instead. |
| `UF_DATAVAULT` | `0x00000080` | 326 | entitlement required for reading *and* writing | Deny subtree; do not even enumerate. |
| `SF_FIRMLINK` | `0x00800000` | 351 | file is a firmlink | Deny item (structural). |

#### B.6.1 SIP may not be enforcing — the guard cannot delegate to the kernel

`csrutil status` on this machine reports **`System Integrity Protection status: disabled.`**

The `SF_RESTRICTED` bits measured in §B.2 are still set on `/System`, `/usr`, `/bin` and the rest —
the flag is a filesystem attribute and survives SIP being turned off — but **the kernel will not
refuse the write.** On a machine configured like this one, a `trashItem` aimed at `/System/Library`
could plausibly succeed.

Consequences, normative:

1. Loupe's guard is the **only** protection on such a machine. It is never written as "SIP will
   stop us anyway"; every deny in §B.2–§B.6 must hold on its own.
2. Loupe **queries** SIP state at launch (`csrutil status`, or the `csr_check`/`SecTaskGetCodeSignStatus`
   route — **unverified** which is available to a non-entitled process) and, when SIP is off,
   shows a one-line, non-alarmist notice in the reclaim pane: *"System Integrity Protection is
   turned off on this Mac. Loupe's own safeguards are unchanged."* It does not offer to turn it on,
   does not nag, and does not degrade functionality.
3. Test builds must be exercised on a SIP-**enabled** machine before release, because a
   SIP-disabled development machine cannot demonstrate that the guard is doing the work — a passing
   test there proves nothing about which layer stopped the delete.
4. `Authenticated Root` is separately **enabled** here, so the sealed system snapshot at `/` is
   still read-only regardless. That is a second, independent reason `/System` writes fail on this
   host — and a third reason not to conclude from a passing test that the guard works.

Also read via `getattrlist` with `ATTR_CMNEXT_EXT_FLAGS` (verified in the same header):
`EF_MAY_SHARE_BLOCKS` `0x01`, `EF_IS_SPARSE` `0x10`, `EF_IS_PURGEABLE` `0x08`,
`EF_SHARES_ALL_BLOCKS` `0x40`. These are **not** deny conditions; they drive R3's disclosure
text and the `Docker.raw` sparse handling.

**Dataless handling caution.** Reading certain `URLResourceValues` on a dataless file can
trigger iCloud materialisation — the opposite of what a disk-inspection tool should do.
Enumerate with `lstat`/`getattrlist` and check `SF_DATALESS` **before** requesting any URL
resource value. Never `open()` a candidate. Whether specific `URLResourceKey`s materialise is
**unverified** — see Open Questions.

### B.7 "Inside a running app bundle"

`NSWorkspace.runningApplications` alone is insufficient. **Measured proof from this machine:**
neither `Xcode.app` nor `Simulator.app` appeared in the running-application list, while
`com.apple.CoreSimulator.CoreSimulatorService`, `simdiskimaged` and `SimulatorTrampoline`
were all live under `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/`. An
NSWorkspace-only guard would have reported the simulator as idle.

Three stages, unioned.

**Stage 1 — NSWorkspace.**
For each `NSRunningApplication`, take `bundleURL`, canonicalise (§B.3), record `(dev, ino)`.
Cheap, covers all GUI apps, misses everything without an app presence.

**Stage 2 — `proc_listallpids` + `proc_pidpath`.**
```
n = proc_listallpids(nil, 0)                       // size the buffer
pids = [pid_t](repeating: 0, count: n + 64)        // slack: the count can grow between calls
n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
for pid in pids[0..<n] {
    var buf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }   // 0 = EPERM / gone
    let exe = String(cString: buf)
    // walk UP to the nearest ancestor whose last component ends in a bundle extension
    for anc in ancestors(of: exe) where anc.hasSuffix(".app") || anc.hasSuffix(".xpc")
                                     || anc.hasSuffix(".framework") || anc.hasSuffix(".appex") {
        record(canonicalise(anc)); break
    }
    record(canonicalise(exe))       // also protect the bare executable path
}
```
The walk must handle `.framework` and `.xpc`, not just `.app` — verified necessary by the
CoreSimulator paths above, and by nested helpers such as
`/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/…` (measured),
which must resolve up to `/Applications/Claude.app`, not stop at the helper.

Failure modes, stated: `proc_pidpath` returns 0 with `EPERM` for processes owned by other
users when Loupe is not root, and for some platform-binary processes. Loupe is not root and
will not escalate. Consequence: a bundle in use *only* by another user's process may not be
detected. Disclosed in the Open Questions, not papered over.

**Stage 3 — open file handles (targeted, not global).**
For the specific entries that need it (`docker-desktop-disk-image`, `ios-device-backups`,
`dormant-node-modules`, browser caches), enumerate same-uid processes' open files with
`proc_pidinfo(pid, PROC_PIDLISTFDS, …)` then `PROC_PIDFDVNODEPATHINFO` per descriptor, and
deny if any resolved vnode path is inside the candidate. Also check `PROC_PIDVNODEPATHINFO`
for the process cwd. This is O(pids × fds) and must not run over the whole scan — it is
per-candidate, at confirm time only. `lsof` is present at `/usr/sbin/lsof` and is a valid
development cross-check but must not be shelled out to in the shipping app.
**Unverified in Swift** — needs a spike.

**The race is real and is disclosed, not hidden.** Between the final guard and `trashItem`
an app can launch. The window is milliseconds. There is no way to close it without a
kernel-level lock Loupe has no right to take. The mitigation is structural: Loupe only ever
*trashes*, so the worst case is recoverable by dragging the item back — which is a large part
of why §B.9 exists.

### B.8 Deletion primitive

**Deletion is always `FileManager.trashItem(at:resultingItemURL:)`.** There is no code path
in `LoupeReclaim` or `LoupeSecurity` that calls `unlink(2)`, `rmdir(2)`,
`removeItem(at:)`, `NSFileManager.removeItem`, or shells out to `rm`. This is enforced by:
- a compile-time deny: `removeItem` and `unlink` are added to a banned-symbol list checked in
  CI over the two package sources;
- a code-review rule: any PR introducing them is rejected regardless of justification.

The two documented exceptions, both of which are *not Loupe deleting*:
- `coresimulator-runtimes-unusable` / `coresimulator-devices-orphaned` delegate to
  `xcrun simctl`, and are presented in the UI as "Ask Xcode to remove this", with the exact
  command shown.
- `trash` opens Finder and lets the system empty it (§14).

#### `trashItem` real failure modes

| Failure | Cause | `NSError` (best current understanding) | Loupe's handling |
|---|---|---|---|
| Volume has no trash support | exFAT / FAT32 / most SMB and NFS mounts | `NSFeatureUnsupportedError` (**unverified code**) | Row is disabled at scan time via `volumeIsInternalKey` / `volumeIsLocalKey` + a probe; message: "This volume does not have a Trash. Delete it in Finder if you want it gone." Loupe never offers to unlink instead. |
| Read-only volume | mounted `ro`, or a sealed system volume | `NSFileWriteVolumeReadOnlyError` | Disabled at scan; blocklist already covers the sealed volume. |
| File owned by another user | root-owned or other-user files in a shared directory | `NSFileWriteNoPermissionError` (EACCES/EPERM) | Reported per item with the owner's name resolved via `getpwuid`. **Loupe does not prompt for admin credentials and does not use `SMJobBless`/`AuthorizationExecuteWithPrivileges` to work around it.** A disk-inspection tool that asks for your password to delete files is the thing this app is an alternative to. |
| Missing `.Trashes` on an external volume | never had one, or it was deleted | macOS normally creates `.Trashes/<uid>` on demand; fails if the volume is read-only or the user lacks write permission at the volume root | Surfaced verbatim; suggest Finder. |
| Item is already in the Trash | user selected inside `~/.Trash` | you cannot trash the Trash | Structurally prevented — `trash` is L5 and review-only (§14). |
| Item disappeared between guard and call | TOCTOU | `NSFileNoSuchFileError` | Not an error in the report; counted as "already gone". |
| Trash name collision | same filename already in Trash | macOS renames automatically | `resultingItemURL` is **always** captured and shown in the report, because the name in the Trash may differ from the name the user selected. |
| Sparse file | `Docker.raw` | rename preserves sparseness | Trash shows 494 GB in Finder Get Info. Warned in advance (§11). |

Cross-volume is **not** a failure mode for `trashItem` in the way it is for `moveItem`:
`trashItem` uses the *item's own* volume's trash, so it never copies across volumes and is an
O(1) rename regardless of tree size. This is a further reason it is the only primitive used —
a 6 GB `iOS DeviceSupport` directory is trashed instantly, with no partial-failure window.

Every call captures `resultingItemURL`. The post-run report lists, per item: original path,
resulting Trash path, on-disk bytes actually moved, and success or the real `NSError`
`localizedDescription` — never a generic "couldn't delete some items".

### B.9 Dry run and the confirmation sheet

The dry run is not a preview mode; it is the **only** mode. Selection never executes.
Pressing the action button opens the sheet; the sheet's action button executes.

**Sheet content, in order, all mandatory:**

1. **Title.** `Move 7 items to the Trash?` — literal count, no adjectives.
2. **Total.** `12.4 GB on disk` — computed under R1–R4 from the *current* selection, recomputed
   when the sheet opens (not carried from scan time). If any R3 caveat applies, the qualifier
   is appended inline: `12.4 GB on disk — some blocks are shared, so less may be freed`.
3. **The Trash sentence**, verbatim, always, undismissible:
   `Items moved to the Trash still use disk space. Your available space changes when you empty the Trash.`
4. **The list.** Every selected item, scrollable, never truncated, never summarised as
   "…and 12 more". Per row:
   - full path with `~` abbreviation, and the **real** path in secondary text if it differed
     before canonicalisation;
   - on-disk size for that item;
   - its safety level badge;
   - for L3 and L4, the entry's one-sentence breakage line, inline and always visible — not
     behind a disclosure triangle.
5. **The L4 block**, if any L4 item is selected — visually separated, above the buttons:
   - a plain list of what is destroyed in nouns: `All Docker images, containers and volumes.`
   - a text field: `Type "Docker Desktop disk image" to confirm.` The action button stays
     disabled until it matches exactly. One field per L4 item; no "confirm all".
6. **Quit-required warnings**, if any owning app is running: `Mail is open. Quit Mail before
   continuing.` with a **Quit** button that calls `NSRunningApplication.terminate()` (not
   `forceTerminate`) and a live indicator. The action button is disabled while any required
   app is running. Loupe never offers "quit for me and delete anyway".
7. **Buttons.** `Cancel` is the **default** button (Return) and Escape also cancels.
   `Move to Trash` carries `.destructive` role and is never the default. There is no
   "Don't ask again" checkbox anywhere in this pillar.

**Prohibited in this sheet:** progress-implying language before the fact, any figure larger
than the true selection total, "Recommended", "Safe to remove", green checkmarks, a countdown,
a pre-ticked box, or any comparison to a previous scan. If the selection is empty the action
button is disabled and the sheet does not open.

**Post-run report** replaces the sheet in place:

```
Moved 7 items (12.4 GB) to the Trash. No disk space has been freed yet.
Empty the Trash to free it.                                       [Open Trash]

  ✓ ~/Library/Developer/Xcode/DerivedData/Runner-cgnj…    1.9 GB
     → ~/.Trash/Runner-cgnjnixkswehcgbjoyeadwwxduid
  ✗ ~/Library/Containers/com.apple.mail/…/Mail Downloads  —
     Mail is still running.   (NSFileWriteNoPermissionError)
```

---

## C. Open questions

Things this spec does not settle, listed rather than guessed at.

1. **Exact `NSError` codes from `trashItem`.** The failure *causes* in §B.8 are real; the
   specific `NSCocoaErrorDomain` codes are from documentation and memory, not observation on
   macOS 26. Needs a spike against exFAT, SMB, and a root-owned file. **Unverified.**
2. **Detecting trash support before attempting.** There is no public
   `volumeSupportsTrashKey`. Current plan is a heuristic (`volumeIsLocalKey` +
   `volumeIsInternalKey` + filesystem type from `statfs.f_fstypename`) plus catching the
   failure. Is there a better signal? **Unverified.**
3. **Does reading `URLResourceValues` materialise a dataless file?** §B.6 assumes some keys
   do and routes around it with `lstat`/`getattrlist`. Which keys are safe needs testing
   against a live iCloud placeholder. This is the one open question that could cause Loupe to
   *cost* the user bandwidth, so it blocks release.
4. **`proc_pidinfo(PROC_PIDLISTFDS)` from Swift 6 under strict concurrency**, at acceptable
   cost, without root. Needs a spike (§B.7 stage 3). If it proves impractical, the L4 entries
   fall back to "quit the app" detection only, and the spec must be revised to say so rather
   than shipping a check that silently does nothing.
5. **Custom DerivedData locations.** Reading `IDECustomDerivedDataLocation` from Xcode's
   preferences may require a TCC prompt on macOS 26. If it does, entry 1 must degrade to
   "location unknown" rather than triggering a permissions dialog during a scan.
6. **Simulator runtime sizes.** This machine has zero runtimes installed, so the 4–8 GB
   figure for entry 3 is from general knowledge, not measurement. **Unverified.** Needs a
   machine with runtimes before that number appears in any UI.
7. **iOS backup sizes.** `MobileSync/Backup` is present but empty here. The 5–150 GB range is
   **unverified**.
8. **Are there other Docker Desktop disk-image layouts?** Only `vms/0/data/Docker.raw` was
   observed. Docker's VM backends have changed several times (`Docker.qcow2`, VirtioFS,
   Apple Virtualization framework variants). The glob in entry 11 is a guess at the general
   shape. **Unverified beyond this one layout.**
9. **Whether the `.git` deny should extend to bare repositories** (`*.git/` directories, or
   repos where `HEAD`/`objects`/`refs` sit at the top level with no `.git` component). The
   component rule misses those. Probably worth a content sniff, but it is a scan-cost tradeoff.
10. **The dormancy threshold.** 180 days is asserted, not derived. On this machine it yields
    zero candidates — which is arguably the correct result and arguably means the feature does
    not earn its complexity. Worth deciding whether entry 19 ships at all in v1.
11. **Multi-user machines.** Everything here is scoped to the invoking user. System-wide
    entries (3) are read-only for a non-admin. Loupe never escalates, so "system-wide" in the
    catalog really means "visible but possibly not actionable". The UI wording for that case
    is unresolved.
12. **Reading SIP state from inside the app.** §B.6.1 requires knowing whether SIP is enforcing.
    Shelling out to `csrutil` is unacceptable in a shipping app. `csr_check(CSR_ALLOW_UNRESTRICTED_FS)`
    is in `<sys/csr.h>` but its availability to a non-entitled Developer ID process on macOS 26 is
    **unverified**. If there is no supported route, drop the notice rather than shipping a
    heuristic that guesses wrong.
13. **Should `brew cleanup` be shelled out to at all?** It is the correct, safe, upstream
    thing to do, but it means Loupe executes a third-party binary that deletes files outside
    the `trashItem` invariant. The alternative — trashing what `brew cleanup -n` names —
    keeps the invariant but leaves Homebrew's own bookkeeping untouched. Not decided.
