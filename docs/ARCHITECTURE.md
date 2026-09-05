# Loupe — Architecture

**Status:** design, pre-implementation. **Target:** macOS 26.0 minimum (26 + 27 when 27 ships).
**Toolchain:** Swift 6.3, strict concurrency, SwiftUI + AppKit interop. Distribution: Developer ID + notarized + hardened runtime.

Loupe shows you your machine. It does not optimize it. Every number it prints must
be one it can defend.

---

## 0. Measured foundations

Everything below is grounded in benchmarks run on this machine (M-series, 4 P-cores +
6 E-cores, macOS 26.5, APFS) with a prototype `getattrlistbulk` walker, not estimated.

### Walk throughput — `$HOME`, 1,965,464 entries

| threads | elapsed | entries/sec | speedup |
|--------:|--------:|------------:|--------:|
| 1  | 30.38 s | 64,696  | 1.00x |
| 2  | 16.13 s | 121,824 | 1.88x |
| 4  |  8.69 s | 226,207 | 3.50x |
| 6  |  7.08 s | 277,770 | 4.29x |
| 8  |  6.29 s | 312,588 | **4.83x** |
| 12 |  5.70 s | 344,688 | 5.33x |

### Shipped Swift implementation, measured

The Swift walker is *faster* than the C prototype it was derived from:

| target | entries | elapsed | entries/sec |
|---|---:|---:|---:|
| `/Applications` (release) | 377,919 | 0.62 s | 611,773 |
| `$HOME` (release) | 2,017,155 | 5.95 s | **339,049** |

Arena cost 108 MB at 2.0M entries, projecting to ~216 MB at 4M — inside the
300 MB budget with more room than the estimate predicted. 132,389 dataless
placeholders were seen and none materialised; the walk finishing in six seconds
is itself the proof.

**Single-threaded misses the 30 s target; parallelism is mandatory, not an optimization.**
The knee is at 6–8 threads. Pool size: `clamp(activeProcessorCount - 2, 4, 8)`.

Projected full 1 TB volume (~4M entries) at j=8: **~13 s**. Target met with margin.

### What the same walk revealed

| observation | measured | consequence |
|---|---|---|
| logical vs physical | 770.0 GiB vs 251.4 GiB (**3.06x**) | Reporting one number would be a lie. Report both, labelled. |
| dataless iCloud placeholders | **132,390 files** | Without `setiopolicy_np(...MATERIALIZE_DATALESS_FILES_OFF)` a scan downloads the user's entire iCloud Drive. This is the single most dangerous bug in the app. |
| hard links | 74,701 files in `$HOME` | On `Xcode.app` alone, not de-duplicating overcounts by 5.6% (5.06 GiB vs `du`'s 4.78 GiB). |
| max tree depth | 25 | `depth` fits in `UInt8`. Confirms keyboard navigation is a real need, not a checkbox. |
| filename bytes | 42.7 MiB total, avg 22.8 B, **0 names > 255 B** | `nameLen: UInt8` is safe with an escape hatch. |
| files >= 4 GiB | 10 | Sizes need > 32 bits. Block-encoding physical size is exact and free. |
| entry count across runs | drifted by 2 | A live filesystem is never a consistent snapshot. The UI must say "as of <time>", never imply exactness. |

### A bug worth recording

The prototype's first parallel version hung. Cause: a 256-byte path buffer truncated deep
Xcode paths, and a **truncated path can resolve to an ancestor directory**, creating an
infinite walk cycle. The fix is to detect truncation via `snprintf`'s return value and skip
the entry rather than push it. This is why the walker is risk #1 below: it is C-adjacent
code where a subtle mistake is an infinite loop or a wrong number, not a compiler error.

### API findings that shape the design

- `ATTR_CMNEXT_PRIVATESIZE`, `ATTR_CMNEXT_NOFIRMLINKPATH`, `ATTR_CMNEXT_EXT_FLAGS` all exist in the macOS 26.5 SDK.
- `SF_RESTRICTED` (0x00080000, SIP), `SF_DATALESS` (0x40000000), `SF_FIRMLINK` (0x00800000) confirmed in `sys/stat.h`.
- **`SecAssessment.h` is SPI — not in the public SDK.** `spctl`'s API is unavailable.
  The public replacement is `SecStaticCodeCreateWithPath` + `SecRequirementCreateWithString`
  + `SecStaticCodeCheckValidity`. Verified empirically:

  | requirement | third-party Developer ID app | Apple OS binary |
  |---|---|---|
  | `notarized` | satisfied | not satisfied |
  | `anchor apple` | not satisfied | satisfied |
  | `anchor apple generic` | satisfied | satisfied |

  So Pillar 3's trust audit needs **no `spctl` subprocess and no SPI**.

---

## 1. Module boundaries

Local SPM packages, assembled into an app target by XcodeGen. Boundaries are enforced by
the package graph, so a violation is a compile error rather than a code-review note.

```
                      ┌──────────────┐
                      │  Loupe (app) │  wiring, onboarding, FDA gate
                      └──────┬───────┘
              ┌──────────────┼──────────────┬───────────────┐
              ▼              ▼              ▼               ▼
        ┌──────────┐  ┌────────────┐  ┌───────────┐  ┌────────────┐
        │ LoupeUI  │  │LoupeReclaim│  │LoupeSecur.│  │LoupeHelper │
        │  views   │  │  catalog   │  │  probes   │  │  Protocol  │
        └────┬─────┘  └─────┬──────┘  └─────┬─────┘  └─────┬──────┘
             │              │               │              │  (shared XPC contract)
             ▼              ▼               ▼              ▼
        ┌──────────┐  ┌──────────────────────────┐   ┌───────────┐
        │LoupeTree │  │        LoupeFS           │   │  Helper   │
        │  arena   │◀─│  walker, volumes, snaps  │   │  (daemon) │
        │  layout  │  └────────────┬─────────────┘   └───────────┘
        └────┬─────┘               ▼
             │               ┌──────────┐
             │               │ CLoupeFS │  C shim: attr decode, iopolicy
             │               └──────────┘
             ▼
        ┌──────────┐
        │LoupeCore │  Sendable value types, byte formatting, paths, logging
        └──────────┘
```

| module | owns | must not |
|---|---|---|
| **LoupeCore** | `Sendable` value types shared across every layer, byte formatting, path canonicalisation, `Logger` categories. No dependencies. | import anything |
| **CLoupeFS** | C shim: `getattrlistbulk` attribute-buffer decode, `setiopolicy_np`, `getmntinfo_r_np`. Kept in C because the attribute buffer is a packed variable-layout blob and Swift buys nothing here. | contain policy |
| **LoupeFS** | Volume enumeration, the walker + thread pool, snapshot/purgeable accounting. Fills arenas. | import LoupeUI |
| **LoupeTree** | The arena, aggregation, projections, sunburst + treemap layout maths. Pure, deterministic, fully unit-testable with zero filesystem access. | import LoupeUI or LoupeFS |
| **LoupeReclaim** | Cleanup catalog, safety engine + blocklist, dry-run planner, trash executor. | delete anything without a dry-run plan |
| **LoupeSecurity** | Config posture, permissions, trust/persistence probes. | say "antivirus" or "malware" |
| **LoupeHelperProtocol** | The `@objc` XPC contract. Shared verbatim by app and daemon. | grow beyond read-only |
| **LoupeUI** | Every view, the hand-rolled sunburst `Canvas`, design tokens. | touch the filesystem or the arena |
| **Loupe** | Composition root, onboarding, Full Disk Access gate. | contain business logic |

**The load-bearing rule: `LoupeUI` cannot import `LoupeFS`.** The UI has no way to reach a
file, an arena, or a syscall. It can only render the small immutable projections described
in §3. That single constraint is what makes "the UI never blocks" structural rather than
aspirational.

---

## 2. How the tree is stored

Two arenas of POD structs, not a graph of class nodes. Reference-counted nodes would cost
more in ARC traffic and allocator pressure than the entire walk.

Files and directories live in **separate arenas** because they need different fields.
A `NodeRef` is a tagged index: high bit selects the arena, low 31 bits the slot.

```swift
struct FileNode {            //  32 bytes
    var nameOffset: UInt32   //   into the string arena
    var parentDir:  Int32
    var logicalBytes: UInt64 //   exact; sparse/dataless/compressed make this != physical
    var physBlocks: UInt32   //   allocated size / 4096 — exact, ceiling 16 TiB
    var mtime:      UInt32   //   epoch seconds
    var nameLen:    UInt8
    var flags:      UInt8    //   dataless | clone | hardlinkDuplicate | restricted
}

struct DirNode {             //  56 bytes
    var nameOffset:     UInt32
    var parentDir:      Int32
    var fileChildStart: UInt32, fileChildCount: UInt32   // one contiguous run
    var dirChildStart:  UInt32, dirChildCount:  UInt32   // a second contiguous run
    var subtreePhys:    UInt64  // rolled up
    var subtreeLogical: UInt64
    var subtreeItems:   UInt32
    var mtime:          UInt32
    var nameLen: UInt8, depth: UInt8, flags: UInt16      // denied | firmlink | crossedDevice
}
```

**Why children are contiguous.** `getattrlistbulk` hands back a whole directory in batches.
The walker reads a directory completely, partitions its entries into files and
subdirectories, then appends each group as one contiguous run. So a directory needs only a
start index and a count per group — no `nextSibling` pointers, and iterating a directory's
children is a linear scan over cache-friendly memory.

### Memory budget

| | measured `$HOME` (1.97M) | projected 1 TB volume (4M) |
|---|---:|---:|
| file nodes | 55 MB | 111 MB |
| dir nodes | 14 MB | 29 MB |
| string arena | 43 MB | 87 MB |
| **total** | **112 MB** | **227 MB** |

Against the 300 MB target that is roughly 25% headroom. Honest caveat: a pathological tree
(a machine full of `node_modules` farms) shifts the file/dir ratio and could erode it. The
escape hatch, if Phase 2 measurement demands it, is block-encoding `logicalBytes` and
accepting 4 KiB granularity on logical totals.

### Mutation rules

The arena is **append-only for structure**. Once a node's slot is written, its name, parent
and own-size never change. Only two things mutate afterwards:

1. **Roll-up.** When a directory's last child completes, its totals are added into its
   parent and the parent's outstanding-children counter is decremented; if that hits zero
   the parent completes and recurses. O(1) amortised per node. The `pendingChildren`
   counters live in a transient array sized to the directory count (~2 MB) and are freed
   when the walk ends.
2. **Hard-link attribution.** Only for entries with `linkCount > 1`, consulted against a
   64-way sharded `(dev, ino)` set. First sighting owns the bytes; later sightings are
   flagged `hardlinkDuplicate` and contribute zero. Volume totals stay correct; *attribution*
   is order-dependent, so the inspector must say "counted once here; also linked from N
   other places" rather than silently picking a winner.

Because structure is immutable and totals only ever increase, a reader can walk the arena
concurrently with the writer and see a consistent-if-incomplete tree. That is what makes
progressive rendering safe without copying anything.

---

## 3. Concurrency model

### The rule that drives the design

`getattrlistbulk` is a **blocking syscall**. Running blocking syscalls on Swift
concurrency's cooperative thread pool starves it — the pool has a fixed width and no way to
know a thread is parked in the kernel. So the walk does **not** run on `Task` or inside an
`actor`.

```
┌─ MainActor ───────────────────────────────────────────────┐
│  AppModel · SunburstLayout · InspectorState               │
│  small immutable values only; never sees an arena         │
└───────────────▲───────────────────────────────────────────┘
                │ AsyncStream<ScanEvent>  (~10 Hz, bufferingNewest(1))
┌───────────────┴───────────────────────────────────────────┐
│  actor ScanCoordinator                                    │
│  lifecycle, cancellation, projection requests             │
└───────────────▲───────────────────────────────────────────┘
                │ handle
┌───────────────┴───────────────────────────────────────────┐
│  final class ScanEngine: @unchecked Sendable              │
│    ├── Mutex<Arena>          bulk append, 1 lock per dir  │
│    ├── ShardedInodeSet        64 shards                   │
│    └── ScanThreadPool         N dedicated Threads         │
│         NOT the cooperative pool                          │
└───────────────────────────────────────────────────────────┘
```

- **Pool.** `clamp(activeProcessorCount - 2, 4, 8)` dedicated `Thread`s at `.userInitiated`,
  each with its own 256 KiB `getattrlistbulk` buffer. Leaving two cores free keeps the UI
  and the compositor responsive during a scan; the measured cost of j=8 vs j=12 is 0.6 s.
- **Work distribution.** A shared LIFO stack of directory work items behind one mutex.
  Depth-first per worker (good locality), but the stack is **seeded breadth-first for the
  first three levels** so the inner rings of the sunburst fill immediately.
- **Lock traffic.** One acquire per *directory*, not per entry — the whole child run is
  appended in a single critical section. ~520k acquires for a 4M-entry volume, well under
  50 ms total. Uncontended `Mutex` from the `Synchronization` module (verified available at
  the macOS 15 baseline, so comfortably fine at 26).
- **Cancellation.** One `Atomic<Bool>`, checked once per directory. Worst case latency is
  one directory read.
- **Pause / resume.** The work stack *is* the resume token. Pausing parks it; resuming
  re-dispatches. **In-session only** — "no persistent index bloating my drive" rules out
  writing a frontier to disk, so quitting the app discards it. A re-scan is ~13 s anyway.
  Flagging this as an interpretation of the constraint rather than a hidden decision.

### How the UI stays responsive

The UI never touches the arena. A **projection** step runs off-main and produces a small
immutable `Sendable` value containing only what is on screen:

```swift
struct SunburstLayout: Sendable {
    let generation: UInt64        // monotonic; stale layouts are dropped
    let focus: NodeRef            // current zoom root
    let wedges: [Wedge]           // bounded: a few thousand, never millions
    let scannedAt: Date           // the UI always shows "as of"
}
struct Wedge: Sendable {
    let node: NodeRef
    let a0, a1: Double            // radians
    let ring: UInt8
    let physical, logical: UInt64
    let name: String
    let kind: WedgeKind           // .real | .aggregated(count:) | .stillScanning
}
```

Three properties make this cheap:

1. **Ring depth is bounded.** A sunburst is legible for 6–8 rings. Deeper nodes are not laid
   out at all until the user zooms.
2. **Sub-pixel wedges are culled.** Anything below ~0.35° is merged into a synthetic
   `.aggregated(count:)` wedge. This caps the layout at 2–4k wedges *regardless of tree size* —
   a 4M-entry volume and a 40k-entry folder produce layouts of the same order.
3. **Crossing the actor boundary is a small array copy**, not a tree traversal.

During a scan the coordinator emits a fresh layout at ~10 Hz with
`.bufferingNewest(1)`, so a slow frame drops stale work instead of queueing it.

**Hit testing is analytic, never path-based.** A point becomes `(r, θ)`; `r` selects the
ring; a binary search over that ring's wedges (sorted by `a0`) finds the wedge. O(log n)
per hover, no `CGPath` containment tests.

---

## 4. Volumes, firmlinks, and the numbers Finder disagrees with

Verified on this machine: `/` is `disk3s1s1` (apfs, **sealed, read-only**), the writable Data
volume is `disk3s5` at `/System/Volumes/Data`, and `/usr/share/firmlinks` lists 19 firmlinks
(`/Users`, `/Applications`, `/Library`, `/private`, `/opt`, `/usr/local`, …).

**Loupe scans `/System/Volumes/Data` directly, not `/`.** Walking from `/` means traversing
firmlinks into the Data volume, which invites double-counting and device-boundary confusion.
Scanning the Data volume root sidesteps the whole class of bug. The System volume is then
presented as a single fixed, honest "macOS System (sealed, read-only)" entry rather than
being walked.

Belt and braces: entries carrying `SF_FIRMLINK` are never traversed, and every entry's
`ATTR_CMN_DEVID` is compared against the scan root's — Loupe never crosses a device
boundary. Other local mounts are discovered via `getmntinfo_r_np` filtered to `MNT_LOCAL`
and offered as *separate* scan targets, never silently included.

**Purgeable space** — the reason Finder's "Available" disagrees with everything else — is
derived from the gap between `volumeAvailableCapacity` and
`volumeAvailableCapacityForImportantUsage`. Local APFS snapshots are enumerated for display.
Loupe explains "System Data" in prose instead of dumping it into a bucket called Other.

Loupe will never exactly match Finder, and says so rather than pretending.

### Snapshots use a syscall, not a subprocess

`fs_snapshot_list(2)` is a public syscall that enumerates snapshots directly as
uid 501 — no `Process`, no argv, no text parsing, and therefore **no prompt
vector at all**. Verified: zero `authd` events. This is strictly better than the
`tmutil` fallback originally specified, which links `SFAuthorization`.

### `ATTR_CMNEXT_PRIVATESIZE` is opt-in, and off by default

The attribute works and reports honest clone-aware ownership (a `cp -c` clone
pair both report 0; an independently written file reports its full size). But
requesting it costs **3.6x** in the kernel, measured in pure C with nothing else
changed: `$HOME` goes from 6.53 s to 14.12 s. At 4M entries that is ~13 s versus
~28 s against a 30 s budget.

Physical totals come from `ATTR_FILE_ALLOCSIZE` regardless; the extended
attribute's only use is setting the `.clone` flag. So it is a
`ScanConfiguration` option, default off, surfaced to the user as a deliberate
"measure clone-aware sizes (slower)" choice rather than silently spending their
time.

### `diskutil` is banned, and this is why

Caught during development by an authorization-log watcher, after the machine's
owner reported repeated password prompts. **Every `/usr/sbin/diskutil`
invocation goes to `authd` and requests privileged rights** — observed live:

```
com.apple.private.storagekitd.destructive
com.apple.private.storagekitd.mountaudit
com.apple.private.diskmanagement.set-boot-device
com.apple.private.security.disk-device-access
system.hdd.smart
-> authd engine 2216: creating session credentials for 501
```

That is true even for a read-only query like `diskutil apfs listSnapshots`.

A read-only inspection tool must never raise an admin prompt. **Loupe shells out
to `diskutil` nowhere, for anything.** Local snapshots come from
`/usr/bin/tmutil listlocalsnapshots` instead, via `Process` with an argv array.
If a future capability appears to need `diskutil`, the answer is to report that
capability as unavailable, not to prompt the user.

This generalises into a rule the whole app is held to: **before adding any
subprocess, confirm it does not hit `authd`.**

    log show --last 1m --info --debug --predicate 'process == "authd"' | grep -i <tool>


---

## 5. Design language

Loupe should look like Disk Utility, Console and System Settings. `NavigationSplitView` with
a real sidebar, standard toolbar, `.inspector()` for detail, sheets for destructive
confirmation, `.searchable`. SF Symbols only, system font, system accent colour, semantic
colours throughout so dark mode is correct for free. Materials sparingly. No custom window
chrome, no reimplemented controls.

The sunburst is the one place to be beautiful. Everything else should be so conventional it
is invisible.

Sunburst colour: categorical hue keyed to the top-level ancestor (stable across zoom),
lightness modulated by ring depth, defined explicitly for light and dark rather than
derived. Alternate encodings — colour by file type, or by age — are a toggle.

**Keyboard navigation is a first-class feature**: `←`/`→` siblings, `↓` largest child, `↑`
parent, `Return` zoom in, `Esc` zoom out, `Space` toggle inspector. Measured max depth on
this machine is 25 levels; a mouse is genuinely miserable at that depth.

---

## 6. Onboarding and Full Disk Access

FDA cannot be granted programmatically. The flow:

1. **Detect** by attempting a read of a TCC-protected path (`~/Library/Application Support/com.apple.TCC/`). Success or failure is the signal — no prompting, no guessing.
2. **Explain in one sentence** why it is needed.
3. **Deep-link** to the exact pane: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
4. **Degrade gracefully.** Without FDA, Loupe scans the home directory and says plainly which
   parts of the machine it cannot see. It is useful on day one either way.

Developer-loop caveat, called out because it will bite daily: **TCC keys the FDA grant to the
binary's code-signing identity**, so rebuilds can invalidate the grant and force a re-add.
Mitigation is a stable signing identity across dev builds. See risk #6.

---

## 7. What was cut, and why

- **Known-vulnerability / NVD / CPE matching — cut from v1.** Most consumer Mac apps have no
  CPE entry at all, and name-based matching is mostly false positives. Shipping a noisy
  "vulnerable" list would undermine trust in the three pillars that *are* defensible. The app
  **inventory** survives, because the trust audit needs it anyway.
- **Real malware detection — never in scope.** Loupe does a persistence and trust audit and
  says so. No homegrown signature engine; the words "antivirus" and "malware removal" appear
  nowhere in the UI.

## 8. A recommendation that was overruled, recorded honestly

I recommended cutting the privileged helper from v1. The audit behind that: the disk walk,
deletion, codesign/notarization checks, and FileVault/SIP/Gatekeeper/firewall status all
work with **Full Disk Access alone**. Root is genuinely needed only for the Background Task
Manager login-item database and full configuration-profile enumeration — two checks, in
exchange for a permanent root attack surface, separate signing, XPC lifecycle and uninstall
burden.

**The product owner chose to ship it in v1.** That is a legitimate call — those two checks
are real gaps in a security-audit product. The design response is to make the helper as
close to zero-capability as possible: read-only, ideally taking *no caller-controlled input
at all*, with a client code-signing requirement enforced on every connection. Spec in
`docs/specs/privileged-helper.md`. It moves to risk #2.

## 9. Distribution

Developer ID + notarized + hardened runtime is correct and there is no better path. The Mac
App Store sandbox cannot express Full Disk Access, and a sandboxed build would be a
different, worse product. Nothing to reconsider here.

Current blocker: this machine has only an **Apple Development** identity (team `PX7CJUB7QF`),
no Developer ID Application certificate. Phase 1–5 develop fine against it; notarization and
the helper's real signing relationship cannot be exercised until that certificate exists.

---

## 10. File tree

```
Loupe/
├── project.yml                     XcodeGen spec -> Loupe.xcodeproj (generated, gitignored)
├── docs/
│   ├── ARCHITECTURE.md             this document
│   └── specs/
│       ├── reclaim-catalog.md      Pillar 2: 19 targets, safety scale, blocklist algorithm
│       ├── security-probes.md      Pillar 3: 45 probes, severity model, what each cannot prove
│       └── privileged-helper.md    SMAppService daemon, XPC surface, threat model
├── Tools/prototypes/               benchmarked C that validated the walk before any Swift
│   ├── walkbench.c                 single-threaded getattrlistbulk walker
│   ├── pwalk.c                     parallel walker (thread-scaling numbers in §0)
│   └── README.md                   the attribute decode order + the truncation-cycle bug
├── App/                            thin app target: wiring only, no business logic
│   ├── LoupeApp.swift
│   ├── AppModel.swift              @MainActor UI state
│   ├── ScanController.swift        bridges ScanEngine -> MainActor
│   ├── RootView.swift              NavigationSplitView + sidebar
│   ├── Onboarding/
│   │   ├── FullDiskAccessGate.swift    detect by probing a TCC-protected path
│   │   └── OnboardingView.swift
│   ├── Info.plist
│   └── Loupe.entitlements
├── Helper/                         SMAppService privileged daemon (Phase 5)
│   ├── main.swift
│   ├── HelperListener.swift        setConnectionCodeSigningRequirement, no audit-token SPI
│   └── Helper.entitlements
└── Packages/
    ├── LoupeCore/                  frozen contracts; zero dependencies
    │   └── Sources/LoupeCore/
    │       ├── NodeRef.swift              tagged index into one of two arenas
    │       ├── SizeBasis.swift            physical vs logical, with plain-language copy
    │       ├── SunburstContract.swift     SunburstLayout, Wedge, geometry constants
    │       ├── ScanEvent.swift            the engine -> UI channel
    │       ├── VolumeDescriptor.swift     volumes, purgeable, local snapshots
    │       └── LoupeLog.swift
    ├── LoupeTree/                  pure; no filesystem, no UI, fully unit-testable
    │   └── Sources/LoupeTree/
    │       ├── Arena.swift                FileNode (32B) / DirNode (56B), flags
    │       ├── ArenaStorage.swift         append-only storage, commit + roll-up
    │       └── Projection.swift           Arena -> bounded SunburstLayout
    ├── LoupeFS/                    the walk
    │   └── Sources/
    │       ├── CLoupeFS/                  C shim: attr decode, dataless io-policy
    │       └── LoupeFS/
    │           ├── ScanEngine.swift       dedicated Thread pool, NOT the cooperative pool
    │           ├── VolumeEnumerator.swift getmntinfo_r_np, MNT_LOCAL
    │           ├── HardlinkSet.swift      64-way sharded (dev, ino)
    │           └── SnapshotReader.swift   tmutil only — diskutil is banned, see §4
    ├── LoupeUI/                    depends ONLY on LoupeCore — no route to a syscall
    │   └── Sources/LoupeUI/
    │       ├── SunburstView.swift         hand-rolled Canvas
    │       ├── SunburstNavigator.swift    keyboard nav, pure geometry, testable
    │       ├── SunburstHitTest.swift      analytic (r, theta) + binary search
    │       └── Palette.swift              stable categorical hue, light/dark
    ├── LoupeReclaim/               Phase 3
    └── LoupeSecurity/              Phase 4
```

---

## 11. Ranked risks

Ordered by expected pain. Honest confidence stated, not implied.

| # | risk | why it is hard | confidence |
|---|---|---|---|
| 1 | **Walker edge cases** | C-adjacent code where mistakes are wrong numbers or infinite loops, not compile errors. Already bit us once: a truncated path resolved to an ancestor and hung the prototype forever. Still ahead: symlink loops, files vanishing mid-walk, permission-denied subtrees, exotic names, device boundaries. | Medium. The prototype works and is benchmarked, but "works on one machine's `$HOME`" is not "correct". |
| 2 | **The privileged helper may not work at all** | launchd daemons are TCC-subject and a daemon *cannot present a TCC prompt*. If Full Disk Access is denied to it, the denial is **silent**. The helper also execs `sfltool`, whose BTM output format churned v13 -> v16 in ~7 months and whose `dumpbtm` verb is undocumented. | **Low.** This needs testing on a clean SIP-enabled machine before a line of helper code is written. It may collapse to only the profiles capability. |
| 3 | **Debug/Release signing-requirement split** | A dev-signed build carries no Developer ID marker OIDs, so it would be rejected by its own helper — forcing a permissive Debug requirement. If that string ever ships in Release, **any** process signed by **any** Apple Development certificate can talk to a root daemon. | Low that we avoid it by discipline alone. A build-phase grep is not sufficient enforcement. |
| 4 | **Undocumented system formats** | TCC.db (`schema_version` 22 today) and the BTM store are both undocumented and both move. Mitigated by a schema-baseline gate that degrades to "unavailable" rather than guessing — but the maintenance cost is permanent, every macOS release. | Medium. The degradation strategy is sound; the churn is certain. |
| 5 | **Memory budget** | 227 MB projected at 4M entries against a 300 MB target — about 25% headroom. A machine full of `node_modules` shifts the file/dir ratio and erodes it. | Medium-high. Strides are pinned by a test, and there is a documented fallback. |
| 6 | **`socketfilterfw` is the only firewall source** | `/Library/Preferences/com.apple.alf.plist` **no longer exists on macOS 26.5** — the plist fallback is gone. The tool prints localized English prose, and the parse anchor is untested on a non-English system. | Low. If the anchor breaks, firewall and stealth-mode have no reliable source at all. |
| 7 | **Full Disk Access developer loop** | TCC keys the grant to code-signing identity, so rebuilds can invalidate it and force a re-add. Daily friction for the whole project, not a one-off. | High that it is annoying; low that it blocks anything. |
| 8 | **Sunburst throughput and zoom identity** | A few thousand `Canvas` arcs at 120 Hz plus animated interpolation keyed on stable wedge identity. Analytic hit testing removes the usual bottleneck. | Medium. Unmeasured until Phase 1 lands. |
| 9 | **Trash semantics** | `trashItem` fails in real ways: other volumes, files owned by another user, missing `.Trashes`. And trashing frees nothing until the Trash is emptied — which the UI must say plainly rather than claiming reclaimed bytes. | High confidence we handle it; it is fiddly, not deep. |
| 10 | **Purgeable never matches Finder** | Snapshots and purgeable caches mean the numbers cannot be reconciled exactly. Loupe explains the gap instead of pretending. | High confidence in the approach; guaranteed to generate "why doesn't this match?" questions anyway. |

**Where I am least confident overall:** risk #2. The helper was kept in v1 over my recommendation, and the strongest argument against it has since gotten stronger, not weaker — it may not be able to do the one job it exists for. See §8 and `docs/specs/privileged-helper.md`.

**A hazard specific to this machine:** **SIP is disabled** (`csrutil status: disabled`). `SF_RESTRICTED` flags are still set on `/System`, `/usr` and `/Library/Apple`, but the kernel will not enforce them here. So Loupe's own blocklist is the *only* thing standing between a bug and a destroyed system file on this box, and a passing delete-safety test proves nothing about a normal Mac. Every destructive-path test must be re-run on a SIP-enabled machine before release.

---

## 12. Phase plan

Every phase ends with an app that launches and does something real.

| phase | ships | done when |
|---|---|---|
| **1** | App skeleton, `NavigationSplitView` sidebar, FDA gate, the walk, the sunburst. | Launch, pick a volume, watch the sunburst fill in progressively, click and keyboard-navigate it. First wedges < 2 s, full volume < 30 s, < 300 MB resident. |
| **2** | `.inspector()` detail pane, treemap toggle, volume/purgeable/snapshot accounting, the "System Data" explainer, `.searchable`. | Every number on screen is labelled physical or logical, and the free-space discrepancy is explained rather than bucketed. |
| **3** | Reclaim: 19-target catalog, blocklist safety engine, dry-run planner, `trashItem` executor. | Nothing deletes without a dry run listing exact paths and a byte total. Nothing is pre-checked. Blocklist tests pass **on a SIP-enabled machine**. |
| **4** | Security pillar sections 1 and 2: config posture, permissions, persistence inventory, trust audit via `SecStaticCode` + `SecRequirement`. | Findings carry severity, confidence, and an explicit "what this cannot prove". No helper yet; root-only probes show as unavailable. |
| **5** | The privileged helper — **gated on the risk-#2 spike passing first**. | BTM login items and device-scope profiles enumerate, or the feature is honestly cut and the helper is dropped. Decide with data, not hope. |
| **6** | Onboarding polish, accessibility pass, perf hardening, Developer ID signing, notarization, release. | Requires a Developer ID Application certificate, which this machine does not yet have. |

**Deliberately not in v1:** cross-platform, menu bar agent, scheduled or automatic cleaning, accounts, cloud sync, any "system optimizer" claim, and known-vulnerability matching (cut — see §7).
