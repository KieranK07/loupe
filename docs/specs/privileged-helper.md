# Loupe privileged helper — design spec

Status: draft, spec-only. No implementation exists.
Target: macOS 26.0 minimum. Verified against SDK **MacOSX26.5.sdk**, Swift 6.3.2, Xcode 26.5, on macOS 26.5.2 (25F84).
Scope: the root LaunchDaemon that backs exactly two Loupe security checks.

> **Framing.** The decision to ship a root helper in v1 is made and is not reopened here. This spec's
> only job is to make the helper's capability surface as close to zero as the two requirements allow,
> and to make that surface auditable by a reader in one sitting.

---

## 0. Verification log

Everything asserted below is tagged. `[V]` = verified on this machine against this SDK. `[U]` = unverified.

| # | Claim | Evidence | Tag |
|---|---|---|---|
| 1 | `SMAppService.daemon(plistName:)` exists, macOS 13+ | `ServiceManagement.framework/Headers/SMAppService.h`: `+ daemonServiceWithPlistName:` `NS_SWIFT_NAME(daemon(plistName:))` `API_AVAILABLE(macos(13.0))` | V |
| 2 | Daemon plist must live in `Contents/Library/LaunchDaemons` | same header, `daemonServiceWithPlistName:` discussion | V |
| 3 | Apps containing LaunchDaemons **must be notarized** | same header, class discussion | V |
| 4 | Daemon is not bootstrapped until an **admin approves** in System Settings | same header, `registerAndReturnError:` discussion | V |
| 5 | Changing the plist or executable requires re-registration; unregister first if the executable changed | same header, class discussion | V |
| 6 | `SMAppServiceStatus` = `.notRegistered/.enabled/.requiresApproval/.notFound` | `SMAppService.h` | V |
| 7 | `kSMError*` numeric codes 2…12 | `SMErrors.h` | V |
| 8 | `SMAppServiceErrorDomain` is **macOS 15+** | `SMAppService.h`, `API_AVAILABLE(macos(15.0))` | V |
| 9 | `NSXPCListener.setConnectionCodeSigningRequirement(_:)` exists, macOS 13+, rejects **before consulting the delegate**, works on `initWithMachServiceName:` listeners, throws on malformed requirement | `Foundation.framework/Headers/NSXPCConnection.h:161` + doc comment | V |
| 10 | `NSXPCConnection.setCodeSigningRequirement(_:)` exists, macOS 13+; invalidates the connection if **new messages** stop matching; **XPC error to call more than once** | `NSXPCConnection.h:118` + doc comment | V |
| 11 | `NSXPCConnection` exposes **no** public `auditToken` | grep of `NSXPCConnection.h` — only `auditSessionIdentifier`, `processIdentifier`, `effectiveUserIdentifier`, `effectiveGroupIdentifier` | V |
| 12 | `xpc_connection_get_audit_token` is **not** in the public SDK | grep `audit_token` across `$SDK/usr/include/xpc/*.h` → no hits | V |
| 13 | `SecCodeCreateWithXPCMessage` exists in SDK 26.5, takes a raw `xpc_object_t` message, **no availability annotation in the header** | `Security.framework/Headers/SecCode.h:210`; symbol present in `Security.tbd` | V (existence) / U (minimum OS) |
| 14 | `SecCodeCopyGuestWithAttributes`, `kSecGuestAttributeAudit`, `kSecGuestAttributePid`, `SecCodeCheckValidity`, `SecRequirementCreateWithString` all public | `SecCode.h`, `SecRequirement.h` | V |
| 15 | `NSXPCConnectionPrivileged = 1<<12` is the option for daemons in the privileged bootstrap | `NSXPCConnection.h:42-45` | V |
| 16 | `BundleProgram` is app-bundle-relative and **only supported for plists installed via SMAppService** | `man 5 launchd.plist` | V |
| 17 | `AssociatedBundleIdentifiers` controls which app the job is shown under in the Login Items UI | `man 5 launchd.plist` | V |
| 18 | launchd-managed daemons **are subject to TCC** | `man 5 launchd.plist`, CAVEATS | V |
| 19 | `SMAuthorizedClients` / `SMPrivilegedExecutables` live in `smd`'s **SMJobBless** code path, not its SMAppService path | `strings /usr/libexec/smd`: those keys sit adjacent to `"Could not copy executable to staging area"`, `"com.apple.ServiceManagement.blesshelper"`, `"com.apple.private.xpc.unauthenticated-bless"`; the SMAppService path is a disjoint string cluster (`SMAppServiceFactory`, `"Bootstrapping SMAppService daemons"`, `com.apple.xpc.smd.smappservice-queue`) | V (strings) / U (that smd never consults them for SMAppService) |
| 20 | `register()` must be called from the app's **main executable** | `strings /usr/libexec/smd`: `"pid: %d is not the main executable of bundle: %s. Rejecting request to enable SMAppService."` | V |
| 21 | `/usr/bin/profiles list -all` and `show -all` **hard-require root** | ran both as user → `profiles: this command requires root privileges`; `-output stdout-xml` → `Must be running as root` | V |
| 22 | `profiles status -type enrollment` does **not** need root | ran as user → printed `Enrolled via DEP: No / MDM enrollment: No` | V |
| 23 | `/usr/bin/profiles` holds unobtainable private entitlements | `codesign -d --entitlements -`: `com.apple.private.configurationprofiles.readwrite`, `com.apple.private.security.storage.ConfigurationProfilesPrivate`, `com.apple.rootless.storage.ConfigurationProfilesPrivate` | V |
| 24 | `/private/var/db/ConfigurationProfiles/Store` is a **datavault** (`drwx------ root:wheel datavault`); parent has `sunlnk` | `ls -lOd`; `ls` and `xattr` as user → Permission denied | V |
| 25 | `/usr/bin/sfltool` holds unobtainable private entitlements | `codesign -d --entitlements -`: `com.apple.private.coreservices.canaccessanysharedfilelist=read-only`, `com.apple.private.coreservices.canmanagebackgroundtasks`, `com.apple.private.sharedfilelist.export` | V |
| 26 | `sfltool dumpbtm` as non-root demands the `system.privilege.admin` Authorization right and fails without it | ran as user → `Error obtaining right system.privilege.admin … errAuthorizationCanceled`, `authorization failed`, exit 1 | V |
| 27 | `sfltool` verbs: `csinfo dumpbtm archive clear resetbtm resetlist list list-info`; `dumpbtm` takes **no options** | `sfltool` usage line; `sfltool dumpbtm -h` → `invalid option -- h` | V |
| 28 | The BTM store is an `NSKeyedArchiver` of **private classes** and is **version-stamped in the filename** | `/private/var/db/com.apple.backgroundtaskmanagement/` contains `BackgroundItems-v13.btm` (Jan 2026) and `BackgroundItems-v16.btm` (Aug 2026); `plutil -p` shows `$classname` values `Storage`, `ItemRecord`, `BTMUserSettings` | V |
| 29 | The `.btm` file itself is POSIX-world-readable (`-rw-r--r-- root:wheel`) and its directory carries no restricted flag | `ls -lO`; a non-root read of the header succeeded from a Full-Disk-Access shell | V |
| 30 | This machine has **only** `Apple Development: kieranjokelly@icloud.com (PX7CJUB7QF)` — no Developer ID | `security find-identity -v -p codesigning` → 1 identity | V |
| 31 | This machine has **SIP disabled** | `csrutil status` → `System Integrity Protection status: disabled.` | V |

Consequences of #30 and #31 are collected in §7.

Team ID for all requirement strings below: **`PX7CJUB7QF`** (from #30; the Developer ID cert, when issued, will carry the same OU).

---

## 1. Why root is required at all — and only here

| Capability | Root needed? | Basis |
|---|---|---|
| Disk walk, size roll-up | No | Full Disk Access |
| Deletion / reclaim | No | user ownership |
| codesign / notarization checks | No | `SecStaticCode*` is unprivileged |
| FileVault / SIP / Gatekeeper / firewall status | No | `fdesetup status`, `csrutil status`, `spctl`, `socketfilterfw`, all readable |
| **BTM login-item enumeration** | **Yes** | #25, #26 — `sfltool` needs entitlements no third party can hold, and refuses to run without `system.privilege.admin` |
| **Full configuration-profile enumeration** | **Yes** | #21, #23, #24 — the store is a kernel-enforced datavault; root alone is insufficient without `com.apple.rootless.storage.ConfigurationProfilesPrivate`, which only `/usr/bin/profiles` has |

Two capabilities. Two XPC selectors. Nothing else ever gets added to this helper; a third requirement is a third helper or a rejected feature.

### 1.1 Why not read the stores directly

- **Profiles**: impossible. The datavault (#24) is enforced by the kernel against the `com.apple.rootless.storage.*` entitlement class, not against uid 0. Executing `/usr/bin/profiles` is the *only* path. `ConfigurationProfiles.framework` is a PrivateFramework — not linkable in a notarized third-party binary and not stable.
- **BTM**: technically possible — the `.btm` is world-readable (#29) — but the payload is an `NSKeyedArchiver` graph of Apple-private classes whose schema version bumped **v13 → v16 in about seven months on this one machine** (#28). Decoding it means either `NSKeyedUnarchiver` against private classes (an unbounded deserialization surface, and the exact gadget class of bug we are trying to avoid) or a hand-rolled bplist walker that breaks every OS release. `sfltool dumpbtm` is the maintained interface.

Both facts are load-bearing for §2.4 (why a subprocess is unavoidable) and both are verified, not assumed.

---

## 2. Registration, packaging, and the XPC interface

### 2.1 Identifiers

Placeholders, to be fixed once in a single `.xcconfig` and referenced everywhere else:

| Symbol | Value |
|---|---|
| `APP_BUNDLE_ID` | `com.loupe.Loupe` |
| `TEAM_ID` | `PX7CJUB7QF` |
| `HELPER_LABEL` | `com.loupe.Loupe.Helper` |
| Mach service name | `com.loupe.Loupe.Helper` (identical to the label — one name, one endpoint) |
| Plist filename | `com.loupe.Loupe.Helper.plist` (identical to the label; convention, and it keeps `SMAppService.daemon(plistName:)` call sites unambiguous) |

### 2.2 Bundle layout

```
Loupe.app/
  Contents/
    Info.plist                                       CFBundleIdentifier = com.loupe.Loupe
    MacOS/
      Loupe                                          the app
      com.loupe.Loupe.Helper                         the daemon — a plain Mach-O, NOT a bundle,
                                                     with an embedded __TEXT,__info_plist
    Library/
      LaunchDaemons/
        com.loupe.Loupe.Helper.plist                 [V #2]
    _CodeSignature/
```

The helper executable is a flat Mach-O in `Contents/MacOS/`, reached by the relative `BundleProgram`
path. It is sealed by the app's signature — there is no separate installed copy anywhere on disk, ever.
It carries an embedded `__TEXT,__info_plist` with `CFBundleIdentifier`, `CFBundleVersion`,
`CFBundleShortVersionString` so that `codesign -dvvv` and the version-skew check in §4.2 have something
to read.

### 2.3 launchd plist

```xml
<key>Label</key>                        <string>com.loupe.Loupe.Helper</string>
<key>BundleProgram</key>                <string>Contents/MacOS/com.loupe.Loupe.Helper</string>
<key>MachServices</key>
  <dict><key>com.loupe.Loupe.Helper</key><true/></dict>
<key>AssociatedBundleIdentifiers</key>  <string>com.loupe.Loupe</string>
```

| Key | Present? | Rationale |
|---|---|---|
| `Label` | yes | required; matches filename and Mach service name |
| `BundleProgram` | yes | app-relative; survives the user moving Loupe.app [V #16]. Prefer over `Program`/`ProgramArguments`, which would hard-code an absolute path |
| `MachServices` | yes, exactly one entry | the sole ingress. On-demand launch: launchd spawns the helper on the first message and not before |
| `AssociatedBundleIdentifiers` | yes | makes the entry read "Loupe" in Login Items & Extensions instead of a bare label [V #17] |
| `RunAtLoad` | **absent** | the helper must not run unless asked |
| `KeepAlive` | **absent** | the helper must not be resident |
| `ProgramArguments` | **absent** | no argv means no argv to get wrong |
| `EnvironmentVariables` | **absent** | nothing injected into a root process |
| `StandardOutPath` / `StandardErrorPath` | **absent** | a root daemon must not open writable paths; logging is `os_log` only |
| `Sockets`, `LaunchEvents`, `WatchPaths`, `QueueDirectories`, `StartInterval`, `StartCalendarInterval` | **absent** | no ingress other than the one Mach service |
| `UserName` / `GroupName` | **absent** | system daemons run as root by default; setting them adds nothing and invites a mistake |
| `ProcessType` | optional `Background` | scheduling hint only; no security effect |

Anything not in the "present" list is a spec violation. A build-phase script should diff the shipped
plist against this exact key set and fail the build on any addition.

### 2.4 The XPC protocol

**Zero caller-controlled input.** Both selectors take no arguments. There is no path parameter, no
command parameter, no filter, no limit, no options dictionary, no callback endpoint. The helper's
entire externally-reachable behaviour is: *"produce report A"* or *"produce report B"*. There is no
input to validate, no input to sanitise, and no input an attacker can steer.

```swift
@objc(LPHelperProtocol)
public protocol LPHelperProtocol {
    func backgroundItemsReport(withReply reply: @escaping (NSData) -> Void)
    func configurationProfilesReport(withReply reply: @escaping (NSData) -> Void)
}
```

Design notes, each deliberate:

| Choice | Reason |
|---|---|
| Two selectors, zero arguments each | The strongest available position. Nothing to abuse. |
| Reply is a single `NSData` | A binary property list. Confines all structure to one leaf class over the wire. |
| **No `NSError` in the reply** | `NSError` carries an `NSSecureCoding` `userInfo` dictionary — an unnecessary decode surface in *both* directions. Errors are encoded as `status` inside the plist instead. |
| Reply is non-optional | There is always a well-formed report, even for failures. No `nil` branch, no ambiguity between "failed" and "nothing installed". |
| No version selector | Version skew is handled by the `helperVersion` key inside each report (§4.2), keeping the protocol at exactly two selectors. |
| No method returns an `NSXPCListenerEndpoint` | An endpoint is a transferable capability. The helper hands out none. |
| No `oneway` / fire-and-forget methods | Every call has a bounded reply, so every call can be timed out and rate-limited. |
| Helper sets `remoteObjectInterface = nil` | The helper can never call *into* the app. Traffic is request/reply only. |
| App sets `exportedInterface = nil`, `exportedObject = nil` | The app exposes nothing to the root process. |

**Allowed-class whitelist.** Configured on both sides from one shared factory so they cannot drift:

```
let i = NSXPCInterface(with: LPHelperProtocol.self)
i.setClasses([NSData.self], for: #selector(LPHelperProtocol.backgroundItemsReport(withReply:)),
             argumentIndex: 0, ofReply: true)
i.setClasses([NSData.self], for: #selector(LPHelperProtocol.configurationProfilesReport(withReply:)),
             argumentIndex: 0, ofReply: true)
```

The whitelist is `{NSData}` and nothing else. No collections, no `NSError`, no custom classes, no
`NSURL`, no `NSDate` over the wire.

**Deserialisation rule (app side).** The reply `NSData` is parsed with
`PropertyListSerialization.propertyList(from:options:format:)` and `.immutable` only. `NSKeyedUnarchiver`
is **forbidden** anywhere in Loupe's helper path — it is the one API that would reintroduce an object-graph
gadget surface. Add a CI grep asserting `NSKeyedUnarchiver` appears in neither the helper target nor the
app's helper-client file.

### 2.5 Report payloads

Both reports are binary property lists whose top level is a dictionary of plist primitives only.

Common envelope:

| Key | Type | Notes |
|---|---|---|
| `schema` | Int | `1`. Bumped only on breaking change; app refuses unknown values |
| `helperVersion` | String | helper's `CFBundleVersion`; drives §4.2 |
| `generatedAt` | Date | helper's clock |
| `status` | Int | `0` ok · `1` toolMissing · `2` toolSignatureInvalid · `3` timeout · `4` nonZeroExit · `5` outputTooLarge · `6` parseFailed · `7` rateLimited · `8` permissionDenied |
| `truncated` | Bool | true if the item list was capped (§3.4) |

`backgroundItemsReport` adds `items: [ [String: plist] ]`, each with the reduced keys
`uuid`, `name`, `developerName`, `typeRaw`, `flagsRaw`, `dispositionRaw`, `identifier`, `url`,
`generation`, `embeddedIdentifiers: [String]`.

`configurationProfilesReport` adds `scopes: [ [String: plist] ]`, each `{ scope: String, profiles: [...] }`,
each profile with `identifier`, `uuid`, `displayName`, `organization`, `profileDescription`,
`installDate`, `removalDisallowed`, `verificationState`, and `payloads: [ { type, identifier, uuid, displayName } ]`.

**The helper is a reducer, not a pipe.** `profiles show -all` prints full payload bodies — certificates,
Wi-Fi PSKs, MDM enrolment material, VPN shared secrets. The helper **must** apply a strict key allowlist
and **must** drop `PayloadContent` and every key not named above before serialising. Two reasons: the app
has no need for the secrets, and a root process that never hands secrets to a user-level process is a root
process whose compromise is worth less. This is the single most valuable line of code in the helper and
should be commented as such.

### 2.6 Subprocess invocation — fixed argv, no shell, ever

There is no public API for either capability (§1.1), so the helper execs two Apple binaries. Rules:

| Rule | Detail |
|---|---|
| No shell | Never `/bin/sh`, never `-c`, never `Process(shell:)`, never string interpolation into any argument. CI greps the helper target for `/bin/sh`, `/bin/bash`, `-c`, and string interpolation inside any `arguments` literal. |
| Absolute executable path | `executableURL` set to a literal absolute path. `PATH` is never consulted. |
| Argv is a compile-time constant | Two `let` arrays, no parameters, no concatenation. |
| Pre-exec verification | Before each spawn: `open(O_RDONLY \| O_NOFOLLOW)`, `fstat` → regular file, `uid == 0`, `gid == 0`, no group/other write bits; then `SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` against `anchor apple and identifier "com.apple.profiles"` (resp. `"com.apple.sfltool"`). On any failure → `status = 2`, no spawn. This is not paranoia theatre: SIP is off on the current dev machine (#31), and users can disable it too. |
| Environment | Explicitly `["PATH": "/usr/bin:/bin"]` and nothing else. Never inherited. No `DYLD_*`, no `HOME`, no locale that changes output formatting. |
| stdin | `/dev/null` |
| stdout / stderr | pipes, drained concurrently with a hard byte cap (§3.4) |
| cwd | `/` |

Exact invocations — this table is the helper's complete list of things it can execute:

| Selector | Executable | argv (after argv[0]) |
|---|---|---|
| `backgroundItemsReport` | `/usr/bin/sfltool` | `["dumpbtm"]` |
| `configurationProfilesReport` | `/usr/bin/profiles` | `["show", "-type", "configuration", "-all", "-output", "stdout-xml"]` |

`dumpbtm` accepts no options at all (#27), so there is nothing to pass even if we wanted to.
`profiles` is given `-output stdout-xml` so the helper parses an XML property list rather than
scraping human-readable text.

---

## 3. Hardening

### 3.1 Client authentication — normative

Use **`NSXPCListener.setConnectionCodeSigningRequirement(_:)`**, set once, on the listener, before
`activate()`.

Requirement string (release):

```
identifier "com.loupe.Loupe"
and anchor apple generic
and certificate leaf[subject.OU] = "PX7CJUB7QF"
and certificate 1[field.1.2.840.113635.100.6.2.6] exists
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
```

| Clause | Pins |
|---|---|
| `identifier "com.loupe.Loupe"` | the specific app, not just the team |
| `anchor apple generic` | chains to Apple's root |
| `certificate leaf[subject.OU] = "PX7CJUB7QF"` | this Developer ID team |
| `certificate 1[field.1.2.840.113635.100.6.2.6] exists` | Developer ID **CA** marker OID on the intermediate |
| `certificate leaf[field.1.2.840.113635.100.6.1.13] exists` | Developer ID **Application** marker OID on the leaf |

Optional belt-and-braces, `[U]` on syntax acceptance by the current requirement compiler — validate it at
build time before shipping it: `and !(entitlement["com.apple.security.get-task-allow"] exists)`, which
excludes a locally-signed debuggable build. The Developer ID clauses above already exclude it, so this is
redundancy, not the primary defence.

Handling rules:

1. The requirement is a `static let` string literal in the helper. It is **never** read from a file, a plist, or `Bundle.main`.
2. At startup, before creating the listener, compile it with `SecRequirementCreateWithString`. If that fails, `os_log(.fault)` and `exit(1)`. **Do not activate a listener you could not protect.**
3. `setConnectionCodeSigningRequirement` throws an Objective-C exception on a malformed string. Because step 2 already validated the string, reaching the throw means the binary is corrupt — let it crash, do not `try?`.
4. Call it **once**, on the listener. Do **not** additionally call `NSXPCConnection.setCodeSigningRequirement` on the accepted connection: that API documents it as an XPC error to call more than once [V #10], and whether listener-level plus connection-level counts as "more than once" is `[U]`. One gate, correctly placed, beats two gates and an exception.
5. The `NSXPCListenerDelegate` is retained, but only for **non-security** policy: connection-count cap (§3.4), interface wiring, invalidation bookkeeping. It performs no identity check, because by the time it runs the identity check has already passed [V #9]. This is stated in a comment so a future reader does not "helpfully" add a PID check.

The app side symmetrically calls `NSXPCConnection.setCodeSigningRequirement(_:)` on its outbound
connection with:

```
identifier "com.loupe.Loupe.Helper"
and anchor apple generic
and certificate leaf[subject.OU] = "PX7CJUB7QF"
and certificate 1[field.1.2.840.113635.100.6.2.6] exists
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
```

Registering a name in the privileged bootstrap already requires root, so name-squatting is not the
realistic threat; this is defence in depth against a *different* root process answering, and it costs
one line.

Connection setup, app side: `NSXPCConnection(machServiceName: "com.loupe.Loupe.Helper", options: .privileged)` [V #15].

### 3.2 The rejected alternative: audit-token + `SecCodeCopyGuestWithAttributes`

Failure modes, in the order they bite:

1. **You cannot get the audit token from public API.** `NSXPCConnection` exposes none [V #11] and `xpc_connection_get_audit_token` is absent from the public XPC headers [V #12]. Every shipping implementation of this pattern reaches for SPI — a private `auditToken` property via KVC, or a `dlsym`'d `xpc_connection_get_audit_token`. Putting undeclared SPI on the authentication path of a root daemon is exactly the wrong trade.
2. **`SecCodeCreateWithXPCMessage` does not help here.** It exists [V #13] but takes the raw `xpc_object_t` *message*, which NSXPC never hands you. It is for servers built on `xpc_connection_t` directly. Adopting it would mean abandoning NSXPC — a much larger rewrite for no gain over #3.1, plus an unverified minimum-OS annotation.
3. **It is a one-shot check.** You validate at `shouldAcceptNewConnection` and then trust the connection for its lifetime. `setConnectionCodeSigningRequirement`'s sibling documents continuous enforcement — "if new messages do not match the requirement, the connection is invalidated" [V #10] — which is strictly stronger.
4. **Two easy, silent mistakes.** (a) The attribute value must be a `CFData` of exactly `sizeof(audit_token_t)`; a wrong length yields `errSecCSInvalidAttributeValues`, and code that only checks for `nil` will sail past it. (b) `SecCodeCopyGuestWithAttributes` returns a `SecCodeRef` — it does **not** validate anything. You must then call `SecCodeCheckValidity(code, [], requirement)`. Omitting the second call is a well-trodden bug that produces code which looks like it authenticates and does not.
5. **You own the requirement-compilation lifecycle** and every error path in it, in a root process, instead of handing the whole problem to Foundation.

Verdict: `setConnectionCodeSigningRequirement` is normative. The audit-token path is not to be
implemented, and this paragraph exists so nobody re-adds it as "extra safety".

### 3.3 Why PID-based validation is unsafe

Never use `NSXPCConnection.processIdentifier`, and never use `kSecGuestAttributePid`.

- **PID reuse.** A pid is a small recyclable integer. Between the moment the connection is established and the moment you resolve the pid to a code object, the legitimate client can exit and the kernel can hand that pid to an attacker-controlled process. You then validate the attacker's signature and, finding it fine or not, attribute the *connection* to the wrong process. The attacker controls the timing and can spin fork/exit to land on a chosen pid.
- **`execve` at a stable pid.** A process keeps its pid across `exec`. An attacker can connect as a benign, correctly-signed binary and then `exec` something else at the same pid — or arrange the reverse — so that the image you inspect is not the image that opened the connection.
- **There is no "check it again" fix.** Both races are TOCTOU; re-checking just adds another window.
- Audit tokens exist precisely because they identify a *process instance* (pid plus a generation counter) rather than a reusable integer. Since we cannot get one from public API (§3.2), we delegate the whole problem to the kernel/XPC via the listener requirement, which uses the peer's audit token internally.
- Corollary: `effectiveUserIdentifier` and `auditSessionIdentifier` are also not authentication. They describe *who*, never *what*. They may be logged; they may not gate anything.

### 3.4 Bounded work, rate limits, timeouts, malformed data

There is no caller-controlled input, so the classic "validate the input" section is empty by construction.
What remains is bounding the work a permitted caller can induce, and treating the subprocesses' output as
untrusted.

| Control | Value | Enforcement |
|---|---|---|
| Concurrent connections accepted | 4 | delegate returns `false` beyond; counter decremented in the invalidation handler |
| Concurrent executions per selector | 1 | a second request while one is in flight **coalesces** onto the same result rather than spawning again |
| Snapshot cache TTL | 30 s | a repeat request inside the TTL is served from cache with no spawn |
| Minimum interval between fresh spawns, per selector | 5 s | inside the window, serve cache; if no cache, reply `status = 7` (rateLimited) |
| Token bucket | 12 spawns/min, burst 4, process-wide across both selectors | exceeded → `status = 7` |
| Wall-clock timeout | `sfltool dumpbtm` 10 s · `profiles show -all` 20 s | `SIGTERM`, then `SIGKILL` after 2 s; reply `status = 3` |
| stdout cap | 8 MiB | drain incrementally; on exceed → kill, `status = 5` |
| stderr cap | 64 KiB | surplus discarded; stderr is logged, never parsed, never returned |
| Parsed item cap | 4096 background items · 512 profiles · 256 payloads per profile | excess dropped, `truncated = true` |
| String field cap | 1024 UTF-8 bytes | truncated on a scalar boundary |
| Serialised reply cap | 4 MiB | if exceeded after reduction, drop items until under, set `truncated = true` |
| Idle exit | 30 s with zero connections and no in-flight work → `exit(0)` | launchd relaunches on the next message |
| Total spawns per helper lifetime | 240 | a backstop against a slow-drip amplification loop; on exceed, reply `status = 7` until idle exit resets the process |

Malformed-data behaviour — the only untrusted bytes in the system are the two subprocesses' stdout:

- Parsing is **total**. No `try!`, no `as!`, no force-unwrap, no array subscript without a bounds check, anywhere in the helper target. CI greps for these.
- `sfltool dumpbtm` emits human-readable text with no stability guarantee. The parser is line-oriented, caps line count and line length, tolerates unknown fields by ignoring them, and tolerates missing fields by omitting the key. A parse that yields zero items when the process exited 0 is reported as `status = 6` (parseFailed) rather than as "you have no background items" — a security tool must never render a parse failure as a clean bill of health.
- `profiles -output stdout-xml` is parsed with `PropertyListSerialization`, `.immutable`, XML format only. Any thrown error → `status = 6`.
- Non-zero exit → `status = 4`, stdout discarded entirely. Never parse partial output from a failed tool.
- Adversarial strings reaching the parser are possible (a profile's `PayloadDisplayName` is attacker-chosen if the attacker can install a profile). Memory-safe Swift plus the length caps above bound this; the reduced reply then means those strings only ever reach the app as capped, plist-typed strings.
- The helper never writes a file, never opens a socket, never resolves a hostname, never loads a plugin, never `dlopen`s anything.

### 3.5 Hardened runtime and entitlements

| Setting | App | Helper |
|---|---|---|
| Hardened Runtime | **on** | **on** |
| App Sandbox | **off** — a sandboxed app cannot register a LaunchDaemon, and Loupe needs FDA. Not App Store anyway. | **off** |
| `com.apple.security.get-task-allow` | **absent** in Release | **absent** in Release |
| `com.apple.security.cs.disable-library-validation` | absent | **absent — non-negotiable.** Library validation is what stops a root process loading a foreign dylib |
| `com.apple.security.cs.allow-dyld-environment-variables` | absent | **absent** |
| `com.apple.security.cs.allow-unsigned-executable-memory` | absent | absent |
| `com.apple.security.cs.allow-jit` | absent | absent |
| `com.apple.security.cs.debugger` | absent | absent |
| `com.apple.security.automation.apple-events` | absent unless a specific check needs it | absent |
| Entitlements file | minimal | **ideally none at all** — the helper's power comes from being root, not from entitlements. Shipping an empty entitlement set makes `codesign -d --entitlements -` a one-line audit |
| `--timestamp` | required | required |
| Notarization | required for the whole app [V #3] | covered by the app's submission |

Signing order: sign the helper executable **first**, then the app, so the app's seal covers it. Verify with
`codesign --verify --deep --strict --verbose=4 Loupe.app` and `spctl -a -vvv -t exec Loupe.app`.

Release-gate assertions (CI, not optional):

```
codesign -d --entitlements - Loupe.app/Contents/MacOS/com.loupe.Loupe.Helper   # expect empty
codesign -dvvv Loupe.app/Contents/MacOS/com.loupe.Loupe.Helper 2>&1 | grep 'flags=.*runtime'
codesign -dvvv Loupe.app 2>&1 | grep 'TeamIdentifier=PX7CJUB7QF'
otool -L Loupe.app/Contents/MacOS/com.loupe.Loupe.Helper   # expect only /usr/lib and /System
```

### 3.6 Auditability budget

The point of this design is that a reader can hold the whole helper in their head.

| Constraint | Limit | Check |
|---|---|---|
| Helper target source | ≤ 500 lines | CI fails the build above it |
| Helper dependencies | **zero** — no SPM package, not even Loupe's own `LoupeCore` | CI asserts the target's dependency list is empty |
| Helper linked libraries | Foundation, Security, os only | `otool -L` assertion above |
| Protocol selectors | exactly 2 | CI asserts the protocol declaration has 2 methods and that neither has a non-reply parameter |
| Executable paths in the helper | exactly the 2 in §2.6 | CI greps for any other absolute path literal |

Publish the helper's `cdhash` in each release's notes so a user can independently verify the binary they
have is the one that was reviewed.

---

## 4. Lifecycle

### 4.1 Install / enable

The feature is **off by default and opt-in.** Loupe never registers at launch.

1. User opens Security → Background & Profiles. The section is visibly disabled, with the explainer from §6.
2. User presses **Enable**. Preflight, all of which must pass:
   - `Bundle.main.bundleURL` is under `/Applications` (Apple recommends this for daemon-containing apps [V #1 discussion]).
   - The app is **not translocated** (`SecTranslocateIsTranslocatedURL`). A quarantined app on a randomized read-only mount must never register a daemon.
   - The app's own signature validates against the release requirement of §3.1.
   Any failure → explain and stop. Do not call `register()`.
3. `SMAppService.daemon(plistName: "com.loupe.Loupe.Helper.plist").register()`, called on the main thread **from the app's main executable** [V #20] — not from a helper tool, XPC service, or embedded framework's own process.
4. Re-read `.status` and drive the UI from it, not from `register()`'s boolean.

| `register()` outcome | code | `.status` after | UI |
|---|---|---|---|
| Success | `true` | `.requiresApproval` (expected for daemons [V #4]) | "Approve Loupe in System Settings" + button calling `SMAppService.openSystemSettingsLoginItems()` |
| Success, already approved | `true` | `.enabled` | proceed; attempt first connection |
| Already registered | `kSMErrorAlreadyRegistered` = 12 | re-read | treat as success |
| User declined | `kSMErrorLaunchDeniedByUser` = 11 | `.requiresApproval` | explain, offer Settings, allow retry |
| Bad signature | `kSMErrorInvalidSignature` = 3 | `.notFound` | hard stop: "This copy of Loupe is damaged." Do not retry, do not offer a workaround |
| Plist missing / invalid | `kSMErrorJobPlistNotFound` = 8 / `kSMErrorInvalidPlist` = 10 | `.notFound` | build bug; hard stop |
| `smd` unavailable | `kSMErrorServiceUnavailable` = 7 | — | transient; offer retry |
| Anything else | `kSMErrorInternalFailure` = 2 etc. | — | show code + domain verbatim, offer retry |

Codes are from `SMErrors.h` [V #7]. **`[U]`: which `NSError` *domain* `register()` populates.**
`SMAppServiceErrorDomain` only exists from macOS 15 [V #8]; historically these codes have also surfaced in
`NSOSStatusErrorDomain` and `NSCocoaErrorDomain`. Match on `code`, log `domain` verbatim, and never
`switch` exhaustively on domain.

First connection after enabling: the app connects, calls one selector, and expects either a report or a
timeout. If the connection is invalidated immediately, re-read `.status` — `.requiresApproval` means the
user has not approved yet, which is the common case, not an error.

### 4.2 Update and version skew

The header is explicit [V #5]: changing the plist **or** the executable requires re-registration, and
unregistering first is recommended when the executable changed. Every Loupe update changes the executable.

Rules:

1. The app records `lastRegisteredHelperBuild` (the app's `CFBundleVersion` at registration time) in `UserDefaults`.
2. On every launch: if `status != .notRegistered` **and** `lastRegisteredHelperBuild != CFBundleVersion`, run `unregisterWithCompletionHandler:` → await → `register()` → update the stored build. Use the async variant so the old process is actually reaped before re-registering.
3. Independently and belt-and-braces: every report carries `helperVersion` (§2.5). If it does not equal the app's `CFBundleVersion`, the app **discards the report** and shows "Loupe's helper needs updating" with a Re-register button. **Fail closed** — never render security findings from a helper of unknown vintage.
4. `schema` mismatch is treated identically.
5. If Loupe ships with an in-app updater (Sparkle or similar), the whole bundle is replaced atomically, so the re-registration in rule 2 happens on the next launch. No separate updater hook is needed, and the updater must **never** touch the helper independently.
6. `[U]` whether re-registration re-prompts for admin approval. Assume it may; the UI copy for the update path should say "macOS may ask you to approve Loupe again" rather than promising it will not.

The helper is never updated in place, never staged, never copied out of the bundle. There is exactly one
copy of that binary on the disk and it is the one inside `Loupe.app`.

### 4.3 Uninstall — and the "dragged to the Trash" problem

**Yes, the registration survives deleting the app.** An `SMAppService` daemon is recorded in the
Background Task Manager database, keyed to the app; deleting `Loupe.app` leaves a registered job whose
`BundleProgram` no longer resolves. It cannot *run* — launchd has nothing to spawn — so it is not a live
root process, but the entry persists and the user has an orphan in Login Items & Extensions.

`[U]`: modern macOS appears to detect and offer removal of items whose bundle has vanished. **Do not rely
on it.** Loupe's obligations, in order of how likely they are to actually fire:

| Trigger | Behaviour |
|---|---|
| User toggles the Background & Profiles feature off | Immediately `unregisterWithCompletionHandler:`, await, assert `status == .notRegistered`, then report the result in the UI. Turning the feature off and leaving the daemon registered is not acceptable. |
| **Loupe → Uninstall Loupe…** (ship this menu item) | Unregister, await completion, verify `.notRegistered`, then reveal `Loupe.app` in Finder with a sheet saying the helper is removed and the app can now be dragged to the Trash. The app cannot reliably delete itself; it can guarantee it leaves nothing privileged behind. |
| App launch, feature never used for 90 days | Offer, once, to unregister. Unused root is still root. |
| App quit | **Nothing.** The helper is on-demand and idle-exits in 30 s; unregistering at quit would re-prompt for approval at every launch. |

Manual verification and removal — surface this verbatim in a "Remove Loupe's helper manually" disclosure
and in the README, because a user who has already trashed the app has no other route:

```
# Is it registered?
System Settings → General → Login Items & Extensions → "Allow in the Background" → look for Loupe
# Is it loaded?
sudo launchctl print system/com.loupe.Loupe.Helper
# Is it in the background-task database?
sudo sfltool dumpbtm | grep -B2 -A8 -i loupe
```

Two things the copy must say explicitly, because users will otherwise go looking and be confused:

- **There is no file to delete in `/Library/LaunchDaemons`.** `SMAppService` daemons live inside the app bundle; nothing is installed into `/Library`.
- `sudo sfltool resetbtm` exists [V #27] and would clear the entry — **but it wipes every application's background items, not just Loupe's.** Mention it only as a last resort, with that warning attached.

The correct removal, if the app is already gone, is to re-download Loupe, run Uninstall Loupe…, and then
delete it — or to remove the entry from Login Items & Extensions.

This whole section is why the feature is opt-in and default-off.

---

## 5. Threat model

### 5.1 Complete ingress inventory

Everything an attacker can reach in the helper, exhaustively:

1. The Mach service `com.loupe.Loupe.Helper` in the privileged bootstrap — reachable by any local process, but every connection is rejected by XPC before Loupe's code runs unless the peer is signed by team `PX7CJUB7QF` with identifier `com.loupe.Loupe` and a Developer ID chain (§3.1).
2. NSXPC decoding of two zero-argument selectors. No arguments means no decode gadgets.
3. Two `posix_spawn`s of fixed, signature-verified, absolute-path Apple binaries with a fixed environment.
4. In-process parsing of those binaries' stdout.

Surface 4 is the largest and deserves an honest note: an attacker who can install a configuration profile
or a background item controls some of the strings that reach the parser (a `PayloadDisplayName`, a
developer name). Mitigation is memory-safe Swift, the length and count caps of §3.4, and the fact that the
parser produces only plist primitives.

### 5.2 What compromise buys

| | Attacker owns the **app** (user privileges + FDA) | Attacker owns the **helper** (root) |
|---|---|---|
| Baseline reach without the helper | All user data; every file readable with Full Disk Access; the ability to delete the user's files | Whole machine except SIP-protected and datavault-protected stores |
| **Marginal gain from the XPC interface** | A BTM listing (already obtainable — the `.btm` is world-readable [V #29]) and a profile listing with payload bodies stripped (**genuinely new**, but it is management *metadata*, not secrets — §2.5's allowlist is what makes this true) | n/a |
| Arbitrary file read as root | **No** — no path parameter exists | Yes |
| Arbitrary file write / delete as root | **No** — no write or delete method exists | Yes |
| Arbitrary code execution as root | **No** — no command parameter; argv is a compile-time constant | Yes |
| Persistence | User-level only. The helper installs nothing, writes nothing, and has no install path to abuse | Root LaunchDaemon — but note the attacker must first get code execution inside the helper, which means finding a memory-safety or logic bug in ≤ 500 lines of dependency-free Swift whose only untrusted input is Apple-binary stdout |
| Capability escalation via XPC | **No** — the helper never returns an `NSXPCListenerEndpoint`, never calls back into the app (`remoteObjectInterface = nil`) | n/a |
| Resource amplification | Bounded: ≤ 12 spawns/min, ≤ 4 connections, coalesced, 30 s cache (§3.4) | n/a |
| Secret exfiltration through the helper | **No** — `PayloadContent` and every non-allowlisted key are dropped before serialisation | n/a |

The read-only design's actual contribution: **an attacker who fully owns Loupe.app gains essentially
nothing from the root helper's existence.** The interface hands them two listings, one of which they
already had. That is the whole point of the zero-input design, and it is the property to protect in every
future change.

### 5.3 Residual risks that cannot be designed away

| Risk | Note |
|---|---|
| The helper's existence | Any future memory-safety or logic bug in it is a root bug. Mitigated only by keeping it tiny (§3.6) and by refusing to add a third capability. |
| `/Applications` is group-writable by `admin` | Any admin user can replace `Loupe.app` without authenticating. `[U]` but strongly expected: `smd`/launchd re-verify the signature of `BundleProgram` at spawn, so a bundle re-signed by a different Developer ID would fail the launch and, separately, would fail §3.1's requirement in both directions. This should be **tested** once a Developer ID cert exists. |
| SIP disabled | On a SIP-off machine (#31), `/usr/bin/profiles` and `/usr/bin/sfltool` can be replaced. §2.6's pre-exec `SecStaticCodeCheckValidity` is the mitigation, and it is the reason that check is normative rather than optional. |
| TCC attribution of the subprocess | See §7. |
| Supply chain | Zero third-party dependencies in the helper target (§3.6) is the mitigation. |

---

## 6. What Loupe tells the user

Shown **before** the first `register()` call, in the Background & Profiles section — not a modal the user
dismisses reflexively, but inline content next to a disabled toggle.

> ### Two checks need a system helper
>
> Loupe can show you which apps are allowed to run in the background, and which configuration profiles
> are installed on this Mac by an employer, school, or MDM service. macOS keeps both of these lists in
> places that only the system administrator account can read. There is no other way to get at them.
>
> If you turn this on, Loupe installs a small background program that runs with administrator rights.
> Here is everything it can do:
>
> - **Produce a list of your background login items.** That is one fixed request; Loupe cannot change what it asks for.
> - **Produce a list of your installed configuration profiles,** with the contents of each profile removed — Loupe reads the names and sources, never the certificates, passwords, or Wi-Fi keys inside them.
>
> And here is what it cannot do:
>
> - It cannot read your files. It has no way to be told a file path.
> - It cannot delete or change anything. It has no write or delete function at all.
> - It cannot run any other program. The two system commands it runs are fixed when Loupe is built.
> - It cannot be told to do anything else. It only answers those two requests, and nothing more can be added without a new version of Loupe that you install yourself.
>
> It only runs while Loupe is asking it something, and quits about 30 seconds later. Only Loupe can talk
> to it — other apps on your Mac are refused. Nothing is sent anywhere; Loupe has no network code.
>
> macOS will ask you to approve this in System Settings. You can turn it off here at any time, or in
> **System Settings → General → Login Items & Extensions**.
>
> [ Enable ]   [ How to remove this later ]

Persistent status row once enabled, always visible in the same section:

> **System helper: enabled** · last used 3 minutes ago · runs only on request
> [ Show exactly what it runs ]   [ Remove helper ]

**Show exactly what it runs** opens a disclosure that literally prints the two selector names and the two
argv arrays from §2.6, plus the helper's `cdhash`. A user who wants to check our claim can, without
reading source.

Copy rules:

- Never say "safe", "secure", or "sandboxed" about the helper. It runs as root; say so, plainly, every time.
- Never bury the approval step. Tell the user before they press Enable that System Settings will ask.
- Never present a `status = 6` parse failure as "no items found". Say "Loupe could not read this list."
- The removal instructions must be reachable *before* enabling, not only after.

---

## 7. What cannot be tested until a Developer ID certificate exists

This machine holds only `Apple Development: kieranjokelly@icloud.com (PX7CJUB7QF)` [V #30], and SIP is
disabled [V #31]. The following are blocked or unrepresentative:

| Item | Why blocked | Interim |
|---|---|---|
| The release requirement string of §3.1 | Development-signed builds carry neither Developer ID marker OID, so a development build would be rejected by its own helper | Ship **two** requirement strings selected by build configuration: a Debug one pinning `certificate leaf[subject.CN] = "Apple Development: …"` plus `subject.OU = "PX7CJUB7QF"`, and the Release one from §3.1. A build-phase script must fail any Release build that embeds the Debug string. This is the single most dangerous piece of conditional code in the project and needs a test. |
| Notarization, and therefore whether the daemon bootstraps at all [V #3] | needs Developer ID | none |
| `register()` behaviour and exact error domain for a properly signed app | needs Developer ID | §4.1 handles all codes and logs the domain verbatim |
| The approval UX in Login Items & Extensions (wording, whether admin auth is demanded, whether re-registration re-prompts) | needs a registered daemon | copy hedges (§4.2 rule 6) |
| Whether launchd re-verifies `BundleProgram`'s signature at spawn (§5.3) | needs Developer ID | assume it does **not** and rely on §3.1 in both directions |
| Whether a SIP-enabled machine blocks the helper's read paths differently | SIP is off here | must be re-verified on a clean SIP-enabled machine before release |
| **Whether the helper needs its own Full Disk Access grant** | launchd daemons are subject to TCC [V #18]. The helper execs `sfltool`, and TCC attribution for a daemon's child normally lands on the daemon. A daemon has no UI, so a TCC prompt cannot be shown — the denial would be **silent**. | The helper must map a suspicious result (exit 0 with zero items, or a permission-shaped error) to `status = 8` (permissionDenied), and the app must then tell the user to add the helper to Full Disk Access. This path must be exercised on a SIP-enabled machine before release. |
| Whether `sfltool dumpbtm` under a root daemon returns *all* UIDs' records | cannot run as root here (no `sudo` in this workstream) | assume yes; verify |

---

## Open questions

Ordered by how much they could change the design.

1. **Does the helper need its own Full Disk Access grant, and does it fail silently without one?** [V #18] says launchd daemons are TCC-subject; a daemon cannot show a TCC prompt. If `sfltool dumpbtm` is silently denied under the helper, the BTM feature does not work at all and the entire helper reduces to the profiles capability — which would change the cost/benefit of shipping it. This must be tested on a clean, SIP-enabled machine early, before any other work.
2. **The Debug/Release requirement-string split (§7).** A build that ships the permissive development requirement would accept any process signed by any Apple Development cert on the machine. This is the highest-severity foot-gun in the design and I am not confident a build-phase grep is sufficient enforcement. Alternative worth exploring: no Debug requirement at all — the helper simply refuses to run in Debug builds, and the two features are stubbed with fixtures during development.
3. **Does `smd` consult `SMAuthorizedClients` for `SMAppService` daemons?** [U #19]. The strings in `/usr/libexec/smd` place those keys firmly in the SMJobBless path, so this spec omits them and relies entirely on §3.1. If they *are* consulted, omitting them costs nothing (they are additive); if a future macOS starts requiring them, registration would fail loudly rather than silently, which is the acceptable failure direction. Low risk, but unverified.
4. **`NSError` domain from `register()`.** [U] — `SMAppServiceErrorDomain` is macOS 15+ [V #8], but I could not confirm it is what `register()` actually populates on macOS 26. §4.1 is written to be domain-agnostic; if that turns out to be over-cautious, it can be tightened.
5. **Stability of `sfltool dumpbtm`'s text output.** It is a debugging tool with a man page that does not even document `dumpbtm` [V: `man sfltool` covers only `archive`]. The format can change in any minor OS release. §3.4's "parse failure is reported as failure, never as an empty list" is the mitigation, but the feature will need re-testing every macOS release, and that maintenance cost should be acknowledged now.
6. **Whether the profiles key-allowlist (§2.5) is complete enough to be useful.** I designed it to exclude everything sensitive; I have not seen a real `profiles show -all` output (root-only, and this machine is unmanaged with zero profiles), so the reduced schema is inferred from the man page and payload conventions rather than from an observed sample. It will need adjusting against a genuinely MDM-enrolled machine.
7. **`SecCodeCreateWithXPCMessage`'s minimum OS.** [U #13] — present in SDK 26.5 with no availability annotation. Not needed by this design, but if a future rewrite moves off NSXPC, this needs pinning down.
8. **Whether idle-exit at 30 s races with an in-flight connection.** launchd relaunches on the next message, and the app is specified to retry once on `NSXPCConnectionInterrupted`, but I have not thought through whether a message can be lost rather than delayed in the window between the helper's `exit(0)` decision and the kernel tearing down the Mach port. Worth a stress test.
9. **`entitlement["..."] exists` in the requirement language (§3.1).** I did not verify the current requirement compiler accepts it. It is optional in this design; validate with `csreq` before shipping it, and drop it if it does not compile.
