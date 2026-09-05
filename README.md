# Loupe

A macOS disk-usage visualiser and cache cleaner. It walks an entire APFS volume with a
hand-written parallel `getattrlistbulk` reader — two million files in six seconds — draws
the result as a sunburst, treemap or bubble chart, and cleans up after nineteen specific,
named caches, showing you the exact list of paths before anything moves to the Trash.

macOS 26 or newer. Swift 6 with strict concurrency, SwiftUI + AppKit. Not sandboxed,
no network code of any kind, no account, no telemetry.

## Why I built it

My disk kept filling up and nothing would give me a number I believed. Finder's
"Available" disagreed with `df`, which disagreed with `du`, and most of the difference
was parked in a bucket labelled "System Data". The two available answers were a
`du | sort` (correct, slow, unreadable) or one of the App Store cleaner apps, which
mostly work by deleting the whole of `~/Library/Caches` — 226 unrelated, app-owned
directories on this machine — and calling that maintenance.

So the rule for the whole project became: every number on screen has to be one the app
can defend. Report physical *and* logical bytes and label which is which. Explain the
free-space gap instead of bucketing it. And if something is going to be deleted, name
it, say what breaks, and put it in the Trash where it can be dragged back out.

## How the walk works

Getting a size out of `FileManager.enumerator` or `fts(3)` costs a `stat` per entry.
`getattrlistbulk(2)` returns a whole batch of directory entries *with their attributes*
in one syscall, which is the difference between a walk you wait for and one you watch
happen. The catch is that the kernel hands back a packed, variable-layout buffer:
attributes come in ascending bit order, groups are absent per-entry depending on object
type, and consuming a field the returned-attrs mask says isn't there desynchronises every
remaining entry in the buffer.

So the decode lives in a small C target, `CLoupeFS`, and Swift never touches the raw
buffer — it gets a flat `loupe_entry_t` per file. The C side decodes and reports; it takes
no policy decisions. Two things there are load-bearing:

- `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, OFF)`
  is called once before any walking. Without it, walking a normal home directory
  downloads the user's entire iCloud Drive — there were 132,390 dataless placeholders in
  mine. This is the single most dangerous line in the app and it is a one-liner.
- Directories are opened `O_NOFOLLOW`, so a symlink pointing at a directory is never
  enumerated through. That, plus refusing to push any path that `snprintf` truncated,
  is what stops the walk from cycling. The C prototype hung on exactly this: a truncated
  deep Xcode path resolved to one of its own *ancestors*, and the walk ran forever.

`getattrlistbulk` is a blocking syscall, so the walk cannot run on Swift Concurrency's
cooperative pool — a fixed-width pool has no idea a thread is parked in the kernel, and
parking eight of them starves everything else in the process, including the UI. The
walker therefore owns `clamp(activeProcessorCount - 2, 4, 8)` dedicated `Thread`s (two
cores left free so the compositor stays smooth), each with its own 256 KiB read buffer,
pulling directory work items off a shared LIFO stack. The stack is seeded breadth-first
for the first three levels so the inner rings of the chart fill immediately, then goes
depth-first per worker for locality.

Entries land in two arenas of POD structs — `FileNode` is 32 bytes, `DirNode` is 56 —
rather than a graph of class nodes, because ARC traffic and allocator pressure for four
million nodes would cost more than the walk itself. A `NodeRef` is a tagged index: high
bit picks the arena, low 31 bits the slot. Because `getattrlistbulk` returns a whole
directory, the walker reads one completely, partitions it into files and subdirectories,
and appends each group as one contiguous run — so a directory needs only a start index
and a count per group, with no sibling pointers, and one mutex acquisition per
*directory* rather than per entry.

Structure is append-only and totals only ever increase, which is what lets a reader walk
the arena while the writer is still filling it and see a consistent-if-incomplete tree.
That is the whole reason progressive rendering is safe without copying anything.

### Numbers

Measured on an M-series Mac (4P + 6E), macOS 26, APFS, release builds:

| target | entries | threads | elapsed | entries/sec |
|---|---:|---:|---:|---:|
| `$HOME` | 1,965,464 | 1 | 30.38 s | 64,696 |
| `$HOME` | 1,965,464 | 8 | 6.29 s | 312,588 |
| `$HOME` | 2,017,155 | 8 | 5.95 s | 339,049 |
| `/Applications` | 377,919 | 8 | 0.62 s | 611,773 |

Single-threaded misses a 30-second budget, so the parallelism is the feature, not an
optimisation. The knee is at 6–8 threads; j=12 buys another 0.6 s and costs the UI its
headroom. The arena held 108 MB at two million entries.

The same walk is where most of the app's design came from. Logical size was 770.0 GiB
against 251.4 GiB physical — a 3.06x gap, so reporting one number would have been a lie.
74,701 files were hard-linked, and not de-duplicating them overcounts `Xcode.app` alone
by 5.6%. Maximum tree depth was 25, which is why keyboard navigation exists. And two
successive runs disagreed by two entries, which is why the UI always says "as of <time>"
rather than implying a snapshot.

`ATTR_CMNEXT_PRIVATESIZE` — the bytes a file uniquely owns, and the only way to tell an
APFS clone from an ordinary file — works, and costs 3.6x in the kernel (`/Applications`
drops from 905k to 245k entries/sec), so it is off by default and surfaced as a deliberate
"measure clone-aware sizes (slower)" choice rather than silently spending someone's time.

### Volumes, and why the numbers won't match Finder

Loupe scans `/System/Volumes/Data` directly rather than `/`. Walking from `/` means
traversing firmlinks back into the Data volume, which double-counts; scanning the Data
root sidesteps the whole class of bug, and the sealed system volume is presented as one
honest "sealed, read-only" entry instead. Belt and braces: entries carrying `SF_FIRMLINK`
are never traversed, and every entry's device id is compared against the scan root's.

Local APFS snapshots — usually the reason free space doesn't add up — come from
`fs_snapshot_list(2)`, a public syscall. Not `diskutil`: **every** `diskutil` invocation,
including a read-only `apfs listSnapshots`, goes to `authd` and requests privileged
rights, which produced real admin password prompts during development. A read-only
inspection tool must never do that, so there is no `Process` call anywhere in the app.

### The UI cannot reach the filesystem

`LoupeUI` deliberately does not depend on `LoupeFS` or `LoupeTree`, so a violation is a
compile error rather than a code-review note. It renders small immutable `Sendable`
projections and has no route to a syscall or an arena. A projection step runs off the main
actor at about 10 Hz with `.bufferingNewest(1)`, so a slow frame drops stale work instead
of queueing it. Ring depth is capped and anything under ~0.35° is merged into a synthetic
aggregate wedge, which holds a layout to 2–4k wedges regardless of tree size — a 4M-entry
volume and a 40k-entry folder produce layouts of the same order. The charts are hand-rolled
SwiftUI `Canvas`, and hit testing is analytic: a point becomes `(r, θ)`, `r` picks the ring,
and a binary search over that ring's wedges finds the target. No `CGPath` containment tests.

## The cleaner, and what it refuses to do

This part deletes user files, so the mechanism matters more than the feature list.

**One primitive.** The only call in `LoupeReclaim` that changes the disk is
`FileManager.trashItem(at:resultingItemURL:)`. There is no `unlink`, no `removeItem`, no
shell, no `Process`. A test (`BannedSymbolTests`) greps every source file in the module —
with comments stripped, so a comment saying "never call unlink" doesn't pass for the real
thing — asserts none of the alternatives appear, and asserts `trashItem(at:` appears in
exactly one file. Trashing is recoverable by dragging the item back, and every guard in
the package is ultimately backstopped by that.

**Nineteen named targets, no pattern matching.** Xcode DerivedData, Homebrew's download
cache, npm/pnpm/yarn/pip/uv caches, the Docker Desktop disk image, Safari/Chromium/Firefox
caches, iOS device backups, and so on. Every entry states what breaks and how it comes
back, in one sentence each, shown verbatim. There is deliberately no rule that means
"find anything cache-shaped" and no bulk entry for `~/Library/Caches`. Sixteen of the
nineteen are deletable by Loupe; the other three are listed, sized and explained but hand
off — the Trash itself is reveal-in-Finder, stale Downloads is review-only, and unusable
simulator runtimes are delegated to `xcrun simctl`, which is the tool that actually
removes them.

**A closed-by-default safety engine.** `SafetyEngine.evaluate` returns `.allowed` only
after a path survives all of:

1. canonicalisation — `realpath` plus APFS firmlink normalisation;
2. a lexical deny table matched by whole path component;
3. an identity walk: `lstat` every ancestor and check its `(dev, ino)` against the
   resolved deny roots, which catches a hardlink whose name says nothing about where its
   inode lives;
4. filesystem flags on the candidate and every ancestor — `SF_RESTRICTED`,
   `UF_DATAVAULT`, `SF_DATALESS`, `SF_FIRMLINK`, `SF_NOUNLINK`, `SF_IMMUTABLE`,
   `UF_IMMUTABLE`;
5. running processes: a `(dev, ino)`-keyed index of bundle roots plus a snapshot of every
   open file on the machine (950 processes, 6,586 resolved vnode paths, 18 ms), because
   `NSWorkspace.runningApplications` listed neither Xcode nor Simulator while
   `CoreSimulatorService` and `simdiskimaged` were both live;
6. the volume — read-only, or the candidate is itself a mount point;
7. the target's own scope, its exclusions, and its refuse-while-running list.

Steps 2 and 3 are redundant on purpose: lexical matching can't see through a hardlink, and
the identity walk can't cover a rule whose root doesn't exist on this machine. Either one
denying is a denial, and there is no ordering of the checks and no argument a caller can
pass that turns a refusal into permission.

Refused outright: `/System`, `/usr` except `/usr/local`, `/Library/Apple`, both keychain
directories, `~/Library/Group Containers`, `/bin`, `/sbin`, `/etc`, `/private/var` and
everything under it, the TCC privacy database, and any path containing a `.git` component.
Refused as items but not as subtrees — they are containers, not caches — the volume root,
`/Users`, `/Volumes`, `/Applications`, `/Library`, `~`, `~/Library`, `~/Library/Containers`.
Also refused: anything flagged `SF_DATALESS`, because trashing an iCloud placeholder
removes the file from iCloud everywhere, and that is the worst single mistake this app
could make.

**The confirmation flow.** Nothing is ever pre-selected, and selection is cleared on every
re-survey because what was on screen may no longer be what is on disk. Deleting always
goes through a dry run, and the confirmation sheet lists the exact paths and per-item byte
counts — not a summary or a count — alongside every path that was refused and the rule
that refused it. Cancel is the default action and the destructive button deliberately is
not, so Return never deletes anything. Targets at or above the "destroys local state"
safety level require typing `move to trash` to enable the button.

At execution time the plan is re-validated from scratch against a fresh process snapshot —
a plan is a proposal about a filesystem that has moved on since — and the report says
"Moved N items (X GB) to the Trash. No disk space has been freed yet", because until the
Trash is emptied that is the truth.

Here is `LiveMachineTests` surveying this Mac while Xcode, node and Docker were running:

```
xcode-derived-data:  present(11)  — 0 selectable, 11 refused
npm-cache:           present(21)  — 0 selectable, 21 refused
homebrew-cache:      present(134) — 134 selectable, 1.81 GB
docker-desktop-disk-image: present(1) — 1 selectable, 1.77 GB
stale-downloads:     present(289) — 0 selectable, 289 to review, 1.72 GB
trash:               present(5)   — 0 selectable, 5 to review
```

## Layout

Five local SPM packages, assembled into an app target by XcodeGen. The boundaries are
enforced by the package graph.

| package | what it owns |
|---|---|
| `LoupeCore` | `Sendable` value types shared by everything: `NodeRef`, `SizeBasis`, the chart contracts, `ScanEvent`, byte formatting. Zero dependencies. |
| `LoupeFS` | The `CLoupeFS` C target plus the walker, the thread pool, volume enumeration and snapshot accounting. |
| `LoupeTree` | The arenas, roll-up, and the sunburst/treemap/bubble layout maths. Pure and deterministic — no filesystem access at all, which is why it is the most heavily tested package. |
| `LoupeUI` | Every view and the hand-rolled `Canvas` charts. Depends only on `LoupeCore`. |
| `LoupeReclaim` | Catalog, safety engine, blocklist, dry-run planner, trash executor. |

`App/` is wiring only: the composition root, the Full Disk Access gate, and the
controllers that bridge the engine to `@MainActor` state.

## Running it

Needs macOS 26+, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
There are no external Swift dependencies.

```sh
brew install xcodegen
xcodegen generate          # project.yml -> Loupe.xcodeproj (gitignored)
open Loupe.xcodeproj       # then Run
```

Full Disk Access is optional. Loupe detects it by attempting to read a TCC-protected
directory — there is no API to ask — and without it, scans your home directory and says
plainly which parts of the machine it cannot see. Note that TCC keys the grant to the
code-signing identity, and local builds sign ad-hoc, so the grant has to be re-added after
a rebuild.

The packages test independently and need no Xcode project. Use release — two of the
`LoupeTree` tests assert a performance budget that a `-Onone` build cannot meet:

```sh
for p in LoupeCore LoupeTree LoupeFS LoupeReclaim LoupeUI; do
  (cd Packages/$p && swift test -c release)
done
```

`LoupeFS` and `LoupeReclaim` both include tests that run against the real machine —
a throughput benchmark over `/Applications` and a full reclaim survey of your home
directory. They read and print; they do not delete. Together they take a couple of
minutes.

`Tools/adversarial/build-hostile-tree.sh` builds a decoy tree under `/private/tmp` —
near-miss names like `usr/localfoo` and `.git-backup`, hardlinks, symlink cycles — for
exercising the safety engine. Everything in it is a decoy; nothing real is linked in a way
that could be destroyed. `Tools/prototypes/` holds the throwaway C that validated the walk
before any Swift was written.

## Status

The disk pillar and the cleaner both work end to end on my machine, and the app target
builds clean on macOS 26.6 with Xcode 26.5 / Swift 6.3.2. What is not done:

- **The security pillar is a placeholder pane.** `LoupeSecurity` has no source in it and
  `Helper/` is empty; the config-posture and trust-audit work is designed
  (`docs/specs/security-probes.md`, `docs/specs/privileged-helper.md`) and not built. The
  privileged-helper design may not survive contact with reality at all — a launchd daemon
  can't present a TCC prompt, so a denial would be silent — and that spike hasn't been run.
- **Not notarized.** This machine has an Apple Development certificate but no Developer ID
  Application certificate, so builds are ad-hoc signed and the real distribution path
  (Developer ID + hardened runtime + notarization) is untested.
- **The destructive-path tests have never run on a SIP-enabled Mac.** SIP is disabled on
  my development machine, so `SF_RESTRICTED` is set but not enforced there — Loupe's own
  blocklist is the only thing standing between a bug and a system file. A passing safety
  test on that box proves less than it looks like it does.
- **Tests:** 522 across the five packages, and all 522 pass under `swift test -c release`.
  Under the default debug build, two `LoupeTree` tests fail: they assert that a 200k-node
  arena lays out in under 100 ms, and `-Onone` takes 235 ms and 291 ms. In release the same
  two take 0.33 ms and 0.57 ms. So the budget holds by three orders of magnitude and the
  tests are simply missing a configuration guard — a bug in the tests, not the layout code,
  but `swift test` with no flags does report two failures.
- Version is 0.1.0. Single-window, English only, no accessibility pass yet.

`docs/ARCHITECTURE.md` has the full design, the measured foundations, the ranked risk
list, and a section recording a recommendation of mine that got overruled. It predates
some of the implementation in places — it still describes snapshot enumeration as shelling
out to `tmutil`, for instance, where the shipped code uses the `fs_snapshot_list` syscall
and shells out to nothing.

## Licence

MIT. See [LICENSE](LICENSE).
