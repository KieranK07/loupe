# Loupe — Pillar 3: Security Probes (Design Spec)

**Status:** draft v1
**Scope:** config posture, privacy/permissions, trust & persistence audit
**Target:** macOS 26.0+, SwiftUI, Swift 6 strict concurrency, Developer ID + notarized, not App Store
**Author verification host:** macOS 26.5.2 (25F84), Xcode 26.5 (17F42), Apple silicon `Mac16,13`

---

## 0. What this pillar is and is not

Loupe performs a **persistence and trust audit**. It answers: *what is configured to run on this
machine, who signed it, and what has it been granted?* It does not scan file contents for known-bad
patterns, does not maintain signatures, and does not remove anything.

**Non-goals, hard:**

- No homegrown signature or heuristic detection engine. Loupe reports *provenance and configuration*,
  never a verdict on intent.
- No CVE / NVD / CPE matching. Cut from v1 by the orchestrator. An app **inventory** still ships
  because the trust audit needs it (bundle id, version, team id, path, signing status) — but nothing
  is matched against a vulnerability corpus.
- No mutation. Every probe in this document is read-only. No probe writes, sets, enables, disables,
  or quarantines. Remediation is "here is the System Settings pane" plus a copyable command the user
  runs themselves.

**Forbidden vocabulary (lint rule).** The strings `antivirus`, `anti-virus`, `malware removal`,
`virus`, `infected`, `clean your Mac`, `threat detected` must not appear in any localizable string,
button label, notification, or export. Add a CI check over `Localizable.xcstrings` and any
`String(localized:)` literal. Engineering docs and code comments are exempt; user-facing strings are
not.

---

## 1. Verification log

Everything below was run read-only on the host named above during authoring. Nothing was changed.
Items not in this table are marked **unverified** wherever they appear.

| Claim | Result |
|---|---|
| `SecAssessment.h` in public SDK | **Absent.** Confirmed missing from `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/Security.framework/Headers/`. `SecAssessmentCreate` is off-limits. |
| Public codesign path exists | **Confirmed.** `SecStaticCodeCreateWithPath`, `SecRequirementCreateWithString`, `SecStaticCodeCheckValidity`, `SecStaticCodeCheckValidityWithErrors`, `SecCodeCopySigningInformation`, `kSecCSDefaultFlags`, `kSecCSRequirementInformation`, `kSecCSSigningInformation`, `errSecCSUnsigned` all present in public headers. |
| Signing-info keys public | **Confirmed.** `kSecCodeInfoFlags`, `kSecCodeInfoTeamIdentifier`, `kSecCodeInfoIdentifier`, `kSecCodeInfoCertificates`, `kSecCodeInfoStapledNotarizationTicket`, `kSecCodeInfoRuntimeVersion`, `kSecCodeInfoEntitlementsDict`, `kSecCodeInfoTrust` all in `SecCode.h`. |
| Adhoc/linker flags public | **Confirmed.** `CSCommon.h`: `kSecCodeSignatureAdhoc = 0x0002`, `kSecCodeSignatureLinkerSigned = 0x20000`. `errSecCSUnsigned = -67062`, `errSecCSReqFailed = -67050`, `errSecCSSignatureFailed = -67061`, `errSecCSUnsignedNestedCode = -67022`. |
| Trust classification empirically | **Confirmed.** `/System/Applications/Calculator.app` and `/usr/bin/sfltool`: `anchor apple` PASS, `notarized` fail, TeamIdentifier not set. `Google Chrome.app` (EQHXZ8M8AV) and `Claude.app` (Q6L2SF6YDW): `notarized` PASS, `anchor apple generic` PASS, `anchor apple` fail. `eDEX-UI.app`: all fail, `flags=0x20002(adhoc,linker-signed)`, TeamIdentifier not set. `cool-retro-term.app`: `code object is not signed at all`. |
| `st_flags` bits | **Confirmed** in `$SDK/usr/include/sys/stat.h`: `SF_RESTRICTED 0x00080000`, `SF_FIRMLINK 0x00800000`, `SF_DATALESS 0x40000000`, `SF_IMMUTABLE 0x00020000`, `UF_HIDDEN 0x00008000`. `stat -f %f /usr/bin` → `524288` (= `SF_RESTRICTED`). `/etc/hosts` → `0`. |
| `sys/csr.h` in public SDK | **Absent.** But `csr_check` and `csr_get_active_config` **are** exported in `$SDK/usr/lib/libSystem.tbd`. Symbol without header ⇒ SPI. Do not use. |
| `csrutil status` without root | **Works.** Returned `System Integrity Protection status: disabled.` (this is a dev host). |
| `spctl --status` without root | **Works.** Returned `assessments enabled`. |
| `fdesetup status` without root | **Works.** Returned `FileVault is On.` |
| `diskutil info -plist /` without root | **Works.** Returns `FileVault => true`, `Encryption => true`, `Sealed => "Yes"`. |
| `socketfilterfw --getglobalstate` without root | **Works.** `Firewall is disabled. (State = 0)`; `--getstealthmode`, `--getblockall` also work. |
| `/Library/Preferences/com.apple.alf.plist` | **Does not exist** on macOS 26.5. The legacy read-the-plist approach is dead. `com.apple.security.firewall` domain also does not exist. `strings socketfilterfw` still references the alf path — it appears to be created lazily on first configuration. Firewall state must come from the tool. |
| `system_profiler -json SPiBridgeDataType` | **Works, no root, 0.18 s.** Keys: `ibridge_sb_sip`, `ibridge_sb_ssv`, `ibridge_secure_boot`, `ibridge_sb_ctrr`, `ibridge_sb_boot_args`, `ibridge_sb_other_kext`, `ibridge_sb_device_mdm`, `ibridge_sb_manual_mdm`. |
| `system_profiler -json SPConfigurationProfileDataType` | **Works, no root, 0.06 s.** Fields `spconfigprofile_verification_state`, `spconfigprofile_RemovalDisallowed`, `spconfigprofile_install_source`, `spconfigprofile_payload_identifier`. Only **User (501)** scope appeared — no device-scope profile installed here, so device-scope visibility to a non-root caller is **unverified**. |
| `profiles list -all` without root | **Fails:** `this command requires root privileges`. |
| `/private/var/db/ConfigurationProfiles/Store` | `drwx------ root` — **not readable** without root. |
| TCC databases | Both exist. `PRAGMA schema_version` = 22, `user_version` = 0. Tables: `access, access_overrides, active_policy, admin, expired, integrity_flag, policies`. |
| `?immutable=1` read is side-effect free | **Confirmed.** After many `sqlite3 "file:...?immutable=1"` reads, no `-wal`, `-shm`, or `-journal` files were created in either TCC directory. |
| TCC `access` columns (26.5) | `service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified, pid, pid_version, boot_uuid, last_reminded`. PK = `(service, client, client_type, indirect_object_identifier)`. |
| System TCC services present | `kTCCServiceAccessibility`, `kTCCServiceScreenCapture`, `kTCCServiceSystemPolicyAllFiles`, `kTCCServiceListenEvent`, `kTCCServicePostEvent`, `kTCCServiceDeveloperTool`. User TCC: `kTCCServiceCamera`, `kTCCServiceMicrophone`, `kTCCServiceAppleEvents`, `kTCCServiceSystemPolicyDesktopFolder`/`DocumentsFolder`/`DownloadsFolder`/`RemovableVolumes`/`NetworkVolumes`/`AppBundles`/`AppData`, `kTCCServiceBluetoothAlways`, `kTCCServicePhotos`, `kTCCServiceMediaLibrary`, `kTCCServiceUbiquity`, `kTCCServiceLiverpool`, `kTCCServiceFocusStatus`, `kTCCServiceFileProviderDomain`, `kTCCServiceWebBrowserPublicKeyCredential`. |
| `client_type` observed | `0` = bundle identifier, `1` = absolute path (both forms seen in `kTCCServiceSystemPolicyAllFiles`). |
| `auth_value` observed | `0` and `2` only on this host. `2` = allowed, `0` = denied. `1` (unknown) and `3` (limited) are **unverified** here. |
| `sfltool dumpbtm` without root | **Works.** Dumped UID `-2`, `0`, and `501` records; 70 items. (Host shell had Full Disk Access; behavior without FDA is **unverified**.) |
| BTM store files | `/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v16.btm` (and `-v13`), `-rw-r--r-- root`, `bplist00` + `NSKeyedArchiver` with top-level keys `itemsByUserIdentifier`, `mdmPaloadsByIdentifier` *(sic, Apple's typo)*, `userSettingsByUserIdentifier`. |
| Legacy SFL login items | `~/Library/Application Support/com.apple.sharedfilelist/` contains only `Favorite*`/`Recent*` lists — **no** `com.apple.LSSharedFileList.SessionLoginItems.sfl*`. Fully migrated to BTM on 26.5. |
| `/var/db/SystemPolicy`, `ExecPolicy`, `KextPolicy` | All `-rw-------` root. **Not readable** without root. `sqlite3` open fails. |
| `launchctl print-disabled system` without root | **Works.** Returns explicit overrides only. Matches `plutil -p /var/db/com.apple.xpc.launchd/disabled.plist`. |
| Sharing detection corroborator | `netstat -an -p tcp \| grep LISTEN` showed `*.22` listening; `com.openssh.sshd => enabled` in `disabled.plist`. Consistent. |
| Guest account | `sysadminctl -guestAccount status` → `Guest account disabled.` (no root needed). `defaults read /Library/Preferences/com.apple.loginwindow GuestEnabled` → `0`. |
| Admin enumeration | `dscl . -read /Groups/admin GroupMembership` → `root kierankelly _mbsetupuser` (no root needed). OpenDirectory.framework is **public** (`ODSession.h`, `ODNode.h`, `ODQuery.h`, `ODRecord.h`) — prefer it over `dscl`. |
| `systemsetup -getremotelogin` | **Fails** without root. Do not use. |
| XProtect | `XProtect.bundle` `CFBundleShortVersionString` = `5356`; `Contents/Resources/*` mtime `2026-08-14`; `XProtect.app` (Remediator) version `157`; `MRT.app` version `1.93`. `pkgutil --pkgs \| grep -i XProtect` lists `com.apple.pkg.XProtectPlistConfigData_10_15.16U4444` etc. |
| `bputil -d` | **Fails** without root. Use `SPiBridgeDataType` instead. |
| `systemextensionsctl list` without root | **Works.** Gives teamID, bundleID, version, name, `[state]` per extension category. |
| Perf: cheap signing-info read | 36 apps in `/Applications` via `codesign -dv`: **1.23 s total (~34 ms/app)**. |
| Perf: full validity check | Same 36 apps via `codesign -v -R "=notarized"`: **20.8 s total**. `Xcode.app` alone: **6.2 s wall / 21.7 s CPU**. |
| Chrome | `~/Library/Application Support/Google/Chrome/Default/Extensions/<id>/<version>/manifest.json` readable. `Default/Secure Preferences` is `-rw-------` user-owned (readable by us, but is an integrity-protected blob). `NativeMessagingHosts/` present with 3 manifests. |
| Safari | `~/Library/Containers/com.apple.Safari/Data/Library/Safari/WebExtensions` and `.../AppExtensions` exist. `pluginkit -m -p com.apple.Safari.web-extension` returned no matches (none installed here) — enumeration path **unverified**. |
| Other Chromium browsers present | Microsoft Edge, Brave, Arc, Vivaldi, Chromium, Opera GX. |

---

## 2. Shared model

### 2.1 Finding record

Every probe emits zero or more `Finding` values. The shape is fixed so ranking, dedup, and export
are uniform.

```
Finding
  probeID        : String            // e.g. "CFG-04"
  severity       : Severity          // see 2.2
  confidence     : Confidence        // see 2.3
  subject        : Subject           // path / bundle id / service label / user
  title          : String            // user-facing, ≤ 70 chars, no period
  detail         : String            // user-facing, 1–3 sentences
  cannotProve    : String            // user-facing, REQUIRED, non-empty
  evidence       : [EvidenceLine]    // raw values shown verbatim in a disclosure triangle
  remediation    : Remediation?      // settings pane deep-link + copyable argv, never auto-run
  firstSeen      : Date
  probeVersion   : Int
```

`cannotProve` is **non-optional and non-empty**. A probe that cannot articulate its limits is not
shippable. Enforce with a unit test that asserts every `Finding` produced by every probe fixture has
`!cannotProve.isEmpty`.

### 2.2 Severity model

Severity encodes **how much the machine's security posture changes if this finding is real**, not how
scary it sounds. Four levels, deliberately few.

| Level | Definition | Ceiling rule |
|---|---|---|
| **Critical** | A protection the whole model depends on is off, or an unsigned/ad-hoc executable is wired into automatic startup at root scope. | Reserved for: FileVault off; SIP disabled; unsigned or ad-hoc binary launched by a `LaunchDaemon`; an unexpected device-scope configuration profile that is non-removable. |
| **Attention** | A meaningful protection is weakened, or a high-power grant is held by something that is not a normal Developer ID app. | Firewall off; Gatekeeper assessments disabled; unsigned/ad-hoc binary in a user LaunchAgent or login item; Screen Recording / Accessibility / Full Disk Access held by an unsigned or ad-hoc client. |
| **Review** | Normal, common, and legitimate in most cases, but worth the user knowing. Most inventory rows land here. | Sharing service on; extra admin user; `/etc/hosts` has custom entries; XProtect data older than the staleness threshold; Developer ID app holding a high-power TCC grant. |
| **Informational** | Inventory. No implied judgement. | The app list, the launchd list, the extension list, secure-boot level on a machine the user deliberately configured. |

**Ranking within a level.** Sort by, in order: (1) scope — system/root before user before per-app;
(2) power — root-executing before TCC grant before configuration flag; (3) confidence descending;
(4) subject path, lexicographic, for stability across runs.

**Severity is capped by confidence.** A finding at `low` confidence cannot be rendered above
**Review**, no matter its nominal severity. This is the single most important rule in the model: it
is what prevents an unstable schema read from producing a red banner.

**No score.** Loupe does not compute a 0–100 "security score" or a letter grade. Aggregate scores
invite users to optimise the number rather than understand the machine, and they force false
precision onto probes whose confidence genuinely differs. The summary view shows counts per severity
and nothing else.

### 2.3 Confidence model

| Level | Meaning |
|---|---|
| `high` | Read via a public API or a documented tool contract that has been stable for years, and the value is unambiguous. |
| `medium` | Read via a tool whose output format is not API-stable, or via a plist key that is not documented, but parsed defensively with a known-good fallback. |
| `low` | Read from an undocumented store (TCC schema, BTM archive) where the shape could change in a point release, or inferred rather than observed. |

Confidence is a property of *the read*, assigned by the probe at emit time, not a constant per probe.
A TCC probe that successfully validated the expected column set emits `medium`; the same probe on a
schema it did not recognise emits `low` or degrades to a `ProbeUnavailable` state (§2.6).

### 2.4 Subprocess policy

Prefer a read-only public API. Where a subprocess is unavoidable, all of the following are mandatory:

1. **`argv` array only.** `Process.executableURL` is an absolute `URL(fileURLWithPath:)` to a
   hardcoded literal path. `Process.arguments` is a literal `[String]`. **String interpolation into a
   shell is forbidden, always.** No `/bin/sh -c`, no `NSAppleScript`, no `bash -lc`, no user or
   filesystem data concatenated into an argument string. Where a probe must pass a path as an
   argument (only `diskutil info -plist /` does, and its argument is the literal `"/"`), the path is
   a compile-time constant.
2. **Absolute paths, no `PATH` lookup.** Every tool is invoked by full path. `Process.environment`
   is set explicitly to a minimal dictionary; the inherited environment is not passed through.
3. **Structured output preferred.** Where the tool offers `-plist`, `-json`, or `-xml`, use it and
   decode. Only fall back to line scraping where no structured mode exists (`socketfilterfw`,
   `csrutil`, `spctl`, `sysadminctl`, `sfltool`).
4. **Timeout and cancellation.** Every invocation runs under a task with a deadline (default 5 s,
   `system_profiler` 15 s). On timeout the process is terminated and the probe reports
   `ProbeUnavailable(.timedOut)`, never a guessed value.
5. **Verify what you exec.** Before first invocation in a session, each tool path is checked with
   `SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` against `anchor apple`. A tool that
   fails is not run, and the probes depending on it report `ProbeUnavailable(.toolNotTrusted)` —
   which is itself a **Critical** finding, since a replaced system binary is exactly what this pillar
   exists to notice.
6. **Never parse localized text.** `socketfilterfw --getglobalstate` prints
   `Firewall is disabled. (State = 0)`. Parse the `State = N` integer, not the English sentence. Where
   no numeric token exists (`csrutil status`), match on a stable substring and treat any unmatched
   output as `ProbeUnavailable(.unrecognizedOutput)` rather than defaulting to "OK".

Rule 6 has a corollary worth stating separately: **absence of evidence is never rendered as good
news.** A probe that cannot read its source reports "not checked", never "fine".

### 2.5 The trust classifier (used by §5, defined once here)

A single `CodeTrust` classifier is shared by every probe that touches an executable. It is the only
place in Loupe that talks to the Security framework.

Public API, in order:

1. `SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code)`
2. `SecCodeCopySigningInformation(code, kSecCSSigningInformation | kSecCSRequirementInformation, &info)`
   — cheap (~34 ms/app measured); yields `kSecCodeInfoIdentifier`, `kSecCodeInfoTeamIdentifier`,
   `kSecCodeInfoFlags`, `kSecCodeInfoCertificates`, `kSecCodeInfoStapledNotarizationTicket`.
3. `SecRequirementCreateWithString` + `SecStaticCodeCheckValidityWithErrors(code, flags, req, &err)`
   for the requirement tests below. Use `WithErrors` — the `CFError` carries
   `kSecCFErrorResourceAltered` / `kSecCFErrorResourceAdded` / `kSecCFErrorResourceMissing`, which is
   how "this bundle was modified after signing" is distinguished from "this bundle was never signed".

Requirement strings (literal constants, never built from input):

| Requirement | Meaning |
|---|---|
| `anchor apple` | Signed by Apple's own signing CA — an OS binary. **Verified:** Calculator.app, `/usr/bin/sfltool`. |
| `anchor apple generic` | Chains to the Apple Root CA — true for both OS binaries and Developer ID. |
| `notarized` | Carries a valid notarization. **Verified:** true for Chrome and Claude, false for every Apple OS binary tested. |

Classification ladder, evaluated top to bottom:

| Result | Class | Default severity contribution |
|---|---|---|
| `errSecCSUnsigned` (-67062) | `.unsigned` | Critical in a LaunchDaemon, Attention elsewhere |
| Valid, `flags & kSecCodeSignatureAdhoc` | `.adHoc` (further tagged `.linkerSigned` if `flags & 0x20000`) | Attention |
| Satisfies `anchor apple` | `.applePlatform` | Informational |
| Satisfies `notarized` **and** has a `TeamIdentifier` | `.developerIDNotarized(teamID)` | Informational |
| Satisfies `anchor apple generic`, has a TeamIdentifier, but not `notarized` | `.developerIDNotNotarized(teamID)` | Review |
| Valid signature, no Apple anchor at all (self-signed / private CA) | `.selfSigned` | Attention |
| `errSecCSSignatureFailed` (-67061) or `kSecCFErrorResourceAltered` | `.modifiedAfterSigning` | Critical |

**Two-tier evaluation, mandatory for performance.** The measured cost gap is 17× (1.23 s vs 20.8 s for
the same 36 apps; `Xcode.app` alone is 6.2 s wall). Therefore:

- **Tier 1 (always):** `SecCodeCopySigningInformation` only. Populates the inventory and gives team id,
  identifier, and the adhoc/linker flags. Enough to classify `.unsigned`, `.adHoc`, and to read team
  id. Budget: whole-machine app inventory under 2 s.
- **Tier 2 (selective):** full `SecStaticCodeCheckValidityWithErrors` against the requirement set.
  Run **only** for binaries that are referenced from a persistence location (launchd plist
  `Program`/`ProgramArguments`, BTM item, login item, system extension, native messaging host) plus
  anything Tier 1 already flagged. This is typically 20–60 binaries, not 400.
- Tier 2 results are cached keyed by `(path, inode, size, mtime, cdhash)` and invalidated when any
  component changes. Never cache on path alone.
- Tier 2 uses `kSecCSDefaultFlags` for the common case. Do **not** add `kSecCSCheckNestedCode` by
  default — it is what makes `Xcode.app` cost 21 s of CPU, and its findings are dominated by
  false positives from apps that ship legitimately unsigned resources. Offer it as an explicit
  per-item "deep check" action the user triggers on one binary.

### 2.6 Degradation

Every probe has a fourth outcome besides *pass / finding / error*: `ProbeUnavailable(reason)`, with
reasons `notPermitted(.fullDiskAccess)`, `notPermitted(.root)`, `schemaUnrecognized`, `pathAbsent`,
`toolNotTrusted`, `unrecognizedOutput`, `timedOut`.

`ProbeUnavailable` renders in the UI as a distinct neutral state — a row that says what could not be
read and why, adjacent to the section it belongs to. It never renders as a pass, never as a finding,
and never contributes to any count. Sections where more than half of the probes are unavailable
display a section-level banner instead of per-row noise.

---

## 3. Section 1 — Config posture

The highest-confidence section. Almost every value here is a boolean or small enum read from a tool
Apple ships and supports, and the correct answer is unambiguous.

### 3.1 Probe table

| id | what it reports | exact API / path / argv | root? | FDA? | public API or subprocess | stability risk | what it CANNOT prove |
|---|---|---|---|---|---|---|---|
| **CFG-01** | FileVault enabled on the boot volume; whether the volume is currently unlocked | subprocess `["/usr/sbin/diskutil", "info", "-plist", "/"]` → `FileVault` (Bool), `Encryption`, `Sealed`. Corroborate with `["/usr/bin/fdesetup", "status"]` | no | no | subprocess (no public FileVault API exists) | **medium** — plist keys undocumented but long-stable; `fdesetup` text output is localized, parse only `diskutil` | Does not prove the recovery key is safe, that it is not escrowed to an institution, or that the disk is encrypted *at rest right now* — an unlocked, running Mac has the volume key in memory regardless |
| **CFG-02** | Secure-boot policy bundle: SIP, Signed System Volume, secure-boot level, Kernel CTRR, boot-arg filtering, third-party kext allowance, MDM boot policy | subprocess `["/usr/sbin/system_profiler", "-json", "SPiBridgeDataType"]` → `ibridge_sb_sip`, `ibridge_sb_ssv`, `ibridge_secure_boot`, `ibridge_sb_ctrr`, `ibridge_sb_boot_args`, `ibridge_sb_other_kext`, `ibridge_sb_device_mdm`, `ibridge_sb_manual_mdm` | no | no | subprocess | **medium** — key names undocumented; **Apple silicon only**, absent or differently shaped on Intel/T2 (**unverified on Intel**) | Does not prove the firmware itself is unmodified; reports the *policy* the system believes is in force, read from the running OS |
| **CFG-03** | System Integrity Protection on/off | subprocess `["/usr/bin/csrutil", "status"]`. Cross-check against CFG-02 `ibridge_sb_sip` and against `st_flags & SF_RESTRICTED (0x00080000)` on `/usr/bin` via `lstat` | no | no | subprocess. **`csr_check()` is SPI** — `sys/csr.h` is absent from the public SDK even though the symbol is exported by libSystem. Do not declare it | **low–medium** — output text has been stable for a decade but is a sentence, not a code | Does not prove no kernel-level compromise. SIP being *on* does not mean nothing privileged is running; SIP off is common and deliberate on developer machines |
| **CFG-04** | Application firewall global state (0 off / 1 on / 2 essential-only) | subprocess `["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"]`, parse the integer in `State = N` | no | no | subprocess | **medium–high** — `/Library/Preferences/com.apple.alf.plist` **does not exist** on 26.5 (verified), so the plist shortcut is gone; the tool is the only path and its output is an English sentence | Does not prove inbound traffic is blocked. The ALF governs listening *processes*, not packets; a VPN, a NetworkExtension content filter, or a router NAT changes the real exposure entirely |
| **CFG-05** | Stealth mode on/off | subprocess `["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getstealthmode"]` | no | no | subprocess | medium–high (same as CFG-04) | Does not make the machine invisible. Stealth mode suppresses ICMP echo and some closed-port responses; any service that is actually listening still answers |
| **CFG-06** | "Block all incoming connections" on/off | subprocess `["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getblockall"]` | no | no | subprocess | medium–high | Same limits as CFG-04; also does not affect outbound |
| **CFG-07** | Gatekeeper assessment policy enabled/disabled | subprocess `["/usr/sbin/spctl", "--status"]`, match on `assessments enabled` / `assessments disabled` | no | no | subprocess. **`SecAssessmentCreate` is SPI** (verified: `SecAssessment.h` absent from the SDK) — must not be linked | **high** — `spctl` is explicitly documented as not-for-scripting and its flags have churned; `/var/db/SystemPolicy` is root-only so there is no readable fallback | Does not prove that everything currently installed passed Gatekeeper. Gatekeeper evaluates at first launch of quarantined code; anything installed before it was disabled, or delivered without a quarantine flag, was never assessed |
| **CFG-08** | XProtect data version | read `/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist` → `CFBundleShortVersionString` (observed `5356`) | no | no | **public** — `CFPropertyList` / `PropertyListDecoder` on a world-readable file | **low** — stable location since Catalina | The version number alone says nothing about whether protection is *active*; it is a data-file version |
| **CFG-09** | XProtect data freshness | `stat()` mtime of `.../XProtect.bundle/Contents/Resources/` (observed `2026-08-14`); corroborate with subprocess `["/usr/sbin/pkgutil", "--pkgs"]` filtered to `com.apple.pkg.XProtect*` and the highest `16Uxxxx` receipt | no | no | public read + optional subprocess | **medium** — the bundle directory's own mtime differs from its Resources' mtime (observed `2026-05-29` vs `2026-08-14`); use **Resources**, never the bundle | Cannot prove the data is *current* — Loupe has no network and no publication feed. It can only report the age of what is on disk. Staleness is a hint about the update mechanism, not a statement about coverage |
| **CFG-10** | XProtect Remediator and MRT versions | read `Info.plist` of `/Library/Apple/System/Library/CoreServices/XProtect.app` (observed `157`) and `.../MRT.app` (observed `1.93`) | no | no | public | low | Presence and version only. Loupe does not read their logs, does not invoke them, and makes no claim about what they have or have not acted on |
| **CFG-11** | Automatic update settings: `AutomaticCheckEnabled`, `AutomaticDownload`, `AutomaticallyInstallMacOSUpdates`, `CriticalUpdateInstall`, `ConfigDataInstall` | `CFPreferencesCopyAppValue(key, "com.apple.SoftwareUpdate")` against the host domain, and `AutoUpdate` in `com.apple.commerce` | no | no | **public** (`CFPreferences`) | **low–medium** — keys are documented in Apple's MDM payload reference; a key that is *absent* means "system default", not "off" | Does not prove updates are actually installing. `ConfigDataInstall = 1` with a 6-month-old XProtect (CFG-09) is precisely the interesting disagreement, and Loupe should surface it as one finding, not two |
| **CFG-12** | OS version currency: running build vs. the newest build the machine has a record of having been *offered* | `ProcessInfo.processInfo.operatingSystemVersion` + `/Library/Preferences/com.apple.SoftwareUpdate` `FirstOfferDateDictionary` / `AutoInstallProductKeys` | no | no | public | **medium** — these keys are undocumented; treat as a hint only | **Cannot tell you whether a newer macOS exists.** Loupe is offline by design. It reports only what the machine itself has previously been offered and not installed |
| **CFG-13** | Which sharing services are enabled: Remote Login, Screen Sharing, File Sharing (SMB), Remote Management, Printer Sharing, Content Caching, Internet Sharing | Read `/var/db/com.apple.xpc.launchd/disabled.plist` (public plist read) **plus** subprocess `["/bin/launchctl", "print-disabled", "system"]`. Map labels: `com.openssh.sshd`, `com.apple.screensharing`, `com.apple.smbd`, `com.apple.RemoteDesktop.PrivilegeProxy`, `org.cups.cupsd`, `com.apple.AssetCache.builtin`, `com.apple.InternetSharing` | no | no | mixed: public plist read + subprocess corroboration | **medium** — `disabled.plist` records **overrides only**; a label absent from it is at its *default* state, which differs per label. Never infer "on" from absence | Does not prove the service is reachable. A service can be enabled but firewalled, bound to loopback, or on a network with no peers |
| **CFG-14** | Corroboration for CFG-13: which ports are actually listening | subprocess `["/usr/sbin/netstat", "-an", "-p", "tcp"]`, filter `LISTEN`, map 22/445/5900/3283/631 | no | no | subprocess | **medium** — output columns are stable but positional. **Verified:** `*.22` LISTEN on this host, matching `com.openssh.sshd => enabled` | Shows the socket is open, not who can reach it. Does not identify the owning process without root |
| **CFG-15** | Guest account enabled/disabled | subprocess `["/usr/sbin/sysadminctl", "-guestAccount", "status"]` (**verified: no root needed**, but it writes its answer to **stderr** with a timestamp prefix — read stderr). Corroborate `GuestEnabled` in `/Library/Preferences/com.apple.loginwindow` via `CFPreferences` | no | no | subprocess + public plist | **medium** — stderr output and localized text | Does not cover the separate "Allow guests to connect to shared folders" SMB guest setting, which is a different mechanism |
| **CFG-16** | Local user accounts and which hold admin | **public** `OpenDirectory.framework`: `ODSession.default()` → `ODNode(session:name:"/Local/Default")` → `ODQuery` for `kODRecordTypeUsers` (filter `UniqueID >= 500`) and read `kODRecordTypeGroups`/`admin` `GroupMembership`. Fallback subprocess `["/usr/bin/dscl", ".", "-read", "/Groups/admin", "GroupMembership"]` | no | no | **public** (OpenDirectory) — verified present in SDK | **low** — OpenDirectory is a stable public framework | Cannot tell a legitimate second admin from an unwanted one. Loupe reports the set and lets the user recognise it. `_mbsetupuser` and `root` are expected members and are annotated, not flagged |
| **CFG-17** | Automatic login configured for a user | `autoLoginUser` in `/Library/Preferences/com.apple.loginwindow` via `CFPreferences`; presence of `/etc/kcpassword` via `lstat` | no | no | **public** | low | Presence of `/etc/kcpassword` is strong evidence but its readability requires root; Loupe checks existence only, never contents |
| **CFG-18** | Screen lock: whether a password is required after sleep/screen saver, and the grace period | `askForPassword` / `askForPasswordDelay` in `com.apple.screensaver` (per-host domain) via `CFPreferences` | no | no | public | **high** — **verified absent on 26.5**: `defaults -currentHost read com.apple.screensaver` returned only `CleanExit` and `tokenRemovalAction`. The key has moved and Loupe cannot currently locate it. **Ship as `ProbeUnavailable(.schemaUnrecognized)` in v1** rather than guessing | Absent keys mean "system default", which is *lock enabled* on modern macOS — so an absent key must never be reported as "no password required" |
| **CFG-19** | Whether the Mac is MDM-enrolled / supervised, and whether enrollment is user-approved | existence of `/private/var/db/ConfigurationProfiles/Settings/.cloudConfigNoActivationRecord` and `.profilesAreInstalled` (both world-readable, **verified**); `ibridge_sb_device_mdm` / `ibridge_sb_manual_mdm` from CFG-02 | no | no | public file existence + subprocess | **medium** — dot-file markers are entirely undocumented | Marker files indicate the *absence of a DEP activation record*, not the absence of MDM. A definitive answer needs the root-only profile store (see PRV-10 / helper) |

### 3.2 Ranking within Config posture

Config posture findings are ranked by **blast radius × reversibility**:

1. Protections whose absence invalidates other findings, first. FileVault off and SIP off are
   listed above everything else, because with SIP off the trustworthiness of several *other* probes
   in this document degrades — Loupe should say so explicitly rather than silently continuing.
2. Then network-reachable state (firewall, sharing services, remote login).
3. Then account state (guest, extra admins, auto-login).
4. Then update and data freshness.

Within a tie, a setting the user can flip in System Settings in one click sorts above one that needs
a reboot to Recovery, because the actionable one is worth reading first.

### 3.3 Avoiding false alarms in Config posture

| Trap | Rule |
|---|---|
| SIP off on a developer machine | Extremely common and deliberate. Detect corroborating signals — Xcode present, `SPiBridgeDataType` reporting `Permissive Security`, `ibridge_sb_boot_args` disabled — and **soften the wording**, not the severity. The finding still says SIP is off; it does not imply the user was attacked. Offer a one-click "I turned this off on purpose" that suppresses the finding permanently with a stored reason. |
| Firewall off | The macOS ALF is off by default on a fresh install and many users never turn it on. This is `Attention`, never `Critical`. Never imply the machine has been remotely accessed. |
| Absence read as "off" | `disabled.plist` contains overrides only; a missing `com.apple.alf.plist` (verified missing on 26.5) means unconfigured, not disabled. Every absent-key path must map to an explicit `.default` or `ProbeUnavailable`, never to `false`. Enforce by making the parse functions return `Tristate` (`.on` / `.off` / `.unknown`) with no default case. |
| Remote Login on | Very common for developers and for anyone using `ssh` or remote VS Code. `Review`, corroborated by CFG-14. Say who it is on for if `AllowedUsers` is knowable; do not speculate. |
| `_mbsetupuser` and `root` in the admin group | Expected on every Mac. Allow-list them explicitly, and annotate them in the evidence pane so the user sees the probe *knew* about them rather than missing them. |
| XProtect "stale" | Requires a threshold, and any threshold is arbitrary. Use **30 days** on the `Resources` mtime, express it as an observation ("data on disk is 41 days old"), and pair it with CFG-11 so the finding is about *the update mechanism*, not about coverage. A machine that has been powered off for a month is not compromised. |
| Managed machines | If CFG-19 indicates MDM, mark the whole Config section "some settings on this Mac are managed by an administrator" and downgrade to `Informational` any setting for which a matching profile payload is visible in PRV-10. The user cannot change these and should not be nagged. |

### 3.4 Wording style

Rules for every user-facing string in this pillar:

- **State the observation, then the consequence.** Never lead with the consequence.
- **Name the specific thing.** "Remote Login is on" beats "a sharing service is enabled".
- **No second person imperative in the title.** Titles describe; remediation prescribes.
- **No urgency vocabulary.** No "immediately", "urgent", "at risk", "exposed", "vulnerable",
  "dangerous". No exclamation marks. No red-alert iconography above `Attention`.
- **Numbers where you have them, silence where you don't.** "41 days old" not "very out of date".
- **The `cannotProve` line always uses the frame "This does not show…"** so it reads as a scope
  statement rather than a hedge.

Three examples, verbatim as they would ship:

> **FileVault is off on the startup disk**
> Files on this Mac are readable by anyone who can boot from another disk or remove the drive. Turning
> FileVault on encrypts the volume; macOS will give you a recovery key to store somewhere safe.
> *This does not show whether anyone has actually read the disk. It reports the encryption setting only.*

> **The firewall is off (State = 0)**
> macOS's built-in firewall is not filtering incoming connections. It ships off by default, so this is
> often just the original setting rather than something that changed.
> *This does not show that anything has connected to this Mac. It also does not cover a VPN or a
> third-party network filter, which may be doing this job instead.*

> **XProtect data on this Mac is 41 days old (version 5356)**
> macOS updates this data in the background. Automatic update settings are on, so a gap this size
> usually means the Mac was asleep or offline rather than that anything is wrong.
> *This does not show whether the data is the newest Apple has published — Loupe never goes online.
> It reports the version and date of the files on this disk.*

---

## 4. Section 2 — Privacy and permissions

### 4.1 Probe table

| id | what it reports | exact API / path / argv | root? | FDA? | public API or subprocess | stability risk | what it CANNOT prove |
|---|---|---|---|---|---|---|---|
| **PRV-01** | Camera and Microphone grants: which clients hold them, allowed vs denied, and when last changed | SQLite read-only of `~/Library/Application Support/com.apple.TCC/TCC.db` via URI `file:<percent-encoded path>?immutable=1`; `SELECT service, client, client_type, auth_value, auth_reason, flags, last_modified FROM access WHERE service IN ('kTCCServiceCamera','kTCCServiceMicrophone')` | no | **yes** | subprocess-free but **undocumented store**; use the system SQLite via a thin Swift wrapper, never the `sqlite3` binary | **high** — undocumented schema; `PRAGMA schema_version` = 22 on 26.5 | Does not show whether the camera or microphone has ever been *used*, or is on right now. It shows which apps are permitted to ask |
| **PRV-02** | Screen Recording grants | same technique on **`/Library/Application Support/com.apple.TCC/TCC.db`**, `service = 'kTCCServiceScreenCapture'`. **Verified:** 10 rows on this host, all `auth_value = 2` | no | **yes** | as PRV-01 | high | Does not show that any recording occurred. Screen Recording permission also covers window-title and window-list enumeration, which is worth saying |
| **PRV-03** | Accessibility grants — the highest-power grant on macOS, since it permits synthetic input and control of other apps | system TCC db, `service IN ('kTCCServiceAccessibility','kTCCServicePostEvent','kTCCServiceListenEvent')`. **Verified:** 14 / 2 / 6 rows | no | **yes** | as PRV-01 | high | Does not show what an app did with it. Also does not distinguish an app that needs it for a legitimate feature (window managers, text expanders, remote-support tools) from one that does not |
| **PRV-04** | Full Disk Access grants | system TCC db, `service = 'kTCCServiceSystemPolicyAllFiles'`. **Verified:** 8 rows, mixed bundle-id and absolute-path clients | no | **yes** | as PRV-01 | high | Does not show which files were read. Note that Loupe itself will appear in this list — say so in the UI rather than filtering it out |
| **PRV-05** | Per-folder and category grants: Desktop, Documents, Downloads, Removable/Network volumes, Photos, Contacts, Calendars, Reminders, Bluetooth, Apple Events (automation), App Bundle modification | user TCC db, remaining `kTCCService*` values. **Verified present:** `SystemPolicyDesktopFolder`, `SystemPolicyDocumentsFolder`, `SystemPolicyDownloadsFolder`, `SystemPolicyRemovableVolumes`, `SystemPolicyNetworkVolumes`, `SystemPolicyAppBundles`, `SystemPolicyAppData`, `AppleEvents`, `Photos`, `MediaLibrary`, `BluetoothAlways`, `Ubiquity`, `Liverpool`, `FocusStatus`, `FileProviderDomain`, `WebBrowserPublicKeyCredential` | no | **yes** | as PRV-01 | high | Same as above. `kTCCServiceLiverpool` (Location, 72 rows here) and `kTCCServiceUbiquity` are dominated by Apple system daemons and should be collapsed by default |
| **PRV-06** | Schema-guard meta-probe: validates the TCC schema before any of PRV-01…05 runs | `PRAGMA table_info(access)`; assert the presence of the required column set; record `PRAGMA schema_version` (observed **22**) | no | yes | — | — | Not a user-facing probe. Its job is to convert an unrecognized schema into `ProbeUnavailable(.schemaUnrecognized)` instead of a wrong answer |
| **PRV-07** | Login items and background items as macOS actually models them today (BTM), per user, including disabled and "not notified" states | subprocess `["/usr/bin/sfltool", "dumpbtm"]`. **Verified: works without root**, dumping UID `-2`, `0`, `501`; 70 items on this host. Fields per item: `UUID`, `Name`, `Developer Name`, `Type` (e.g. `developer (0x20)`), `Flags`, `Disposition` (e.g. `[disabled, allowed, not notified] (0x2)`), `Identifier`, `URL`, `Generation`, `Embedded Item Identifiers` | no | **probably** (**unverified without FDA** — the authoring shell held FDA) | subprocess | **high** — `sfltool` is undocumented, unsupported, and its output is free-form text with no structured mode | Does not prove an item *runs*. A BTM record with `Disposition: disabled` is registered but not launching. Also cannot prove the list is complete for other users' sessions |
| **PRV-08** | Direct read of the BTM store as a cross-check on PRV-07 | `/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v16.btm` (**verified** `bplist00` / `NSKeyedArchiver`, `-rw-r--r-- root`; top-level keys `itemsByUserIdentifier`, `mdmPaloadsByIdentifier`, `userSettingsByUserIdentifier`) | no | no (world-readable) | public `PropertyListSerialization` — but the payload is an `NSKeyedArchiver` graph of **private Apple classes** | **very high** — the `-v16` suffix is a format version that has already gone v13 → v16 within a couple of releases. Do **not** attempt `NSKeyedUnarchiver` against private classes | **Be honest in the UI:** Loupe reads only the outermost structure of this file (item count, the per-UID grouping, the format version). The item *details* come from `sfltool` in PRV-07. If the format version is one Loupe does not recognise, it says the login-item list may be incomplete rather than showing a shortened list as if it were complete |
| **PRV-09** | Legacy shared-file-list login items | `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.SessionLoginItems.sfl*` | no | no | public file enumeration; **do not unarchive** | **high** — **verified absent on 26.5**; this host has only `Favorite*`/`Recent*` lists, i.e. login items are fully migrated to BTM | Its absence is the expected modern state. Report presence only; never report "no legacy login items" as a security pass |
| **PRV-10** | Configuration profiles: identifier, payload types, install source, signed/unsigned, removable or not | subprocess `["/usr/sbin/system_profiler", "-json", "SPConfigurationProfileDataType"]`. **Verified without root, 0.06 s.** Fields: `spconfigprofile_profile_identifier`, `spconfigprofile_payload_identifier`, `spconfigprofile_payload_data`, `spconfigprofile_verification_state`, `spconfigprofile_RemovalDisallowed`, `spconfigprofile_install_source`, `spconfigprofile_install_date` | **partly** — see note | no | subprocess | **medium** — undocumented JSON keys | **Only User-scope profiles were observed** on this host (none device-scope installed), so device-scope visibility to a non-root caller is **unverified**. `/private/var/db/ConfigurationProfiles/Store` is `drwx------ root` and `profiles list -all` **fails without root** (verified). If device-scope proves invisible, this probe reports "user-scope profiles only" and the helper supplies the rest. Does not prove a profile is malicious — a profile is how every managed Mac is configured |
| **PRV-11** | Chromium-family browser extensions: id, name, version, requested permissions, `update_url`, and whether the extension was force-installed by policy | enumerate `~/Library/Application Support/<Browser>/<Profile>/Extensions/<id>/<version>/manifest.json` and decode. **Verified present:** Google Chrome (10 extensions in `Default`), Microsoft Edge, Brave, Arc, Vivaldi, Chromium, Opera GX | no | no (own home dir) | **public** — plain JSON file reads | **medium** — manifest v2/v3 differ; per-browser profile layouts differ; a profile named other than `Default` must be discovered from `Local State` | Does not show whether the extension is enabled — the enabled bit lives in `Default/Secure Preferences`, an integrity-protected blob Loupe deliberately does not parse. Loupe reports **installed**, not **active**, and says so. Also cannot prove what an extension does at runtime |
| **PRV-12** | Safari extensions | enumerate `~/Library/Containers/com.apple.Safari/Data/Library/Safari/WebExtensions` and `.../AppExtensions` (**verified present**); corroborate with subprocess `["/usr/bin/pluginkit", "-mAvvv", "-p", "com.apple.Safari.web-extension"]` | no | **yes** (another app's container) | mixed | **high** — `pluginkit` returned **no matches** on this host (no Safari extensions installed), so the enumeration path is **unverified** | Safari extensions ship inside host apps; the containing app's signature (via §5) is the meaningful trust signal, not the extension folder |
| **PRV-13** | Native messaging hosts — a browser-extension-to-native-binary bridge and a genuine persistence/escalation path | enumerate `~/Library/Application Support/<Browser>/NativeMessagingHosts/*.json` and `/Library/<Vendor>/<Browser>/NativeMessagingHosts/*.json`; each manifest names a `path` to a native executable, which is fed to the §5 classifier. **Verified:** 3 manifests present in the Chrome user directory | no | no | **public** JSON reads | **medium** | Does not prove the bridge is used. Reports that a browser extension is permitted to invoke a specific local binary |
| **PRV-14** | System extensions and their approval state (network extensions/content filters, endpoint security, camera extensions, driver extensions) | subprocess `["/usr/bin/systemextensionsctl", "list"]`. **Verified without root**; yields `enabled`, `active`, `teamID`, `bundleID (version)`, `name`, `[state]` per category | no | no | subprocess | **medium** — tabular text, no structured mode | A network extension is the single highest-power privacy item on the list and deserves prominence — but a VPN client legitimately installs one. Does not prove traffic is being inspected or logged |
| **PRV-15** | Loaded third-party kernel extensions | subprocess `["/usr/bin/kmutil", "showloaded", "--list-only"]`, filter out `com.apple.*`. Note `/var/db/SystemPolicyConfiguration/KextPolicy` (user-approved kext list) is `-rw-------` root and **not readable** (verified) — the *approved* list needs the helper | no (loaded list) / **yes** (approved list) | no | subprocess | medium | The loaded list shows what is resident now, not what is approved to load at next boot. On Apple silicon with `Reduced Security` (see CFG-02 `ibridge_sb_other_kext`) the approval model differs |

### 4.2 TCC access discipline — normative

This is the part of Loupe most likely to be criticised, so the rules are strict.

1. **Read-only, always.** Open with the SQLite URI form and `?immutable=1`:
   `file:/Library/Application%20Support/com.apple.TCC/TCC.db?immutable=1`. **Verified:** repeated
   reads through this URI produced **no** `-wal`, `-shm`, or `-journal` files in either TCC directory.
   Additionally pass `SQLITE_OPEN_READONLY` and set `SQLITE_DBCONFIG_DEFENSIVE`. `immutable=1` tells
   SQLite the file will not change under it, which is what suppresses journal creation — it is
   therefore also a correctness statement, so the file's `(inode, size, mtime)` is captured before and
   after the read and a mismatch discards the result and retries once.
2. **Never open the sidecar files.** No `-wal`, no `-shm`, no recovery, no `PRAGMA journal_mode`, no
   `PRAGMA integrity_check`, no `VACUUM`, no `ATTACH`.
3. **Never shell out to `/usr/bin/sqlite3`.** Link the system SQLite directly. The CLI's default
   behaviour includes journal creation and its argument surface invites interpolation.
4. **Parameterized queries only.** Service names are compile-time constants bound with
   `sqlite3_bind_text`; no query is assembled by concatenation. There is no user input that reaches
   SQL in this design, and the rule exists so that stays true.
5. **Copy-then-read is explicitly rejected.** Copying `TCC.db` to a temp directory would create a
   second, unprotected copy of a privacy-sensitive database on disk. Loupe reads in place.
6. **The read is done in a short-lived actor** with the connection closed before the finding is
   emitted. No long-held handle on a system database.

**Degradation when the schema changes.** PRV-06 runs first and is the gate:

| Condition | Behaviour |
|---|---|
| `access` table absent | All of PRV-01…05 → `ProbeUnavailable(.schemaUnrecognized)`. Section shows one banner: "Loupe could not read the permissions database on this version of macOS." |
| `access` present, all required columns present (`service`, `client`, `client_type`, `auth_value`) | Normal path, `confidence = medium`. |
| Required columns present but **extra unknown columns** appeared | Normal path, `confidence = medium`, and a debug-log note. Extra columns are expected and harmless — never fail on them. |
| A required column is **missing or has changed type** | `ProbeUnavailable(.schemaUnrecognized)`. |
| `auth_value` contains a value outside `{0,1,2,3}` | That row renders as "granted state not recognised", `confidence = low`. The row is still shown — hiding it would be a silent false negative. |
| `PRAGMA schema_version` differs from the last-known-good baseline (22 on 26.5) | Not an error on its own. Log it, keep going, and mark the whole section `confidence = low` until the new value is added to the tested baseline set. |

Ship a small, versioned `TCCSchemaBaseline` table in the app (`schema_version → tested OS builds`) so
that the confidence downgrade is data-driven and can be corrected in a point release without code
changes. Also ship a fixture-based test suite with captured `TCC.db` files at each known schema
version — this is the only way to keep the degradation path honest as macOS moves.

**Full Disk Access UX.** Loupe requires FDA for PRV-01…05 and PRV-12 and for nothing else. That must
be said plainly at the point of the request, along with the fact that Loupe is asking for FDA
specifically in order to read *which apps hold permissions*. The FDA-dependent probes are grouped in
one section so that a user who declines loses one clearly-labelled section rather than seeing
scattered blanks. Detect the missing-FDA case by attempting the system TCC open and mapping
`SQLITE_CANTOPEN` / `EPERM` to `notPermitted(.fullDiskAccess)` — do not try to infer FDA state by
reading Loupe's own row out of the TCC database, which is circular.

### 4.3 Honesty about Background Task Manager

BTM is the modern store behind System Settings → General → Login Items & Extensions. What is and is
not readable, precisely:

- **Readable:** the raw `.btm` file is world-readable (`-rw-r--r-- root wheel`, verified), and its
  outer container is a plain `bplist00`. The top-level dictionary keys are visible without any
  private API: `itemsByUserIdentifier`, `mdmPaloadsByIdentifier`, `userSettingsByUserIdentifier`.
- **Not practically readable:** the item payloads are an `NSKeyedArchiver` object graph of private
  Apple classes. Unarchiving them requires either naming those classes (fragile and effectively
  private-API use) or hand-rolling a `$objects` graph walker (fragile in a different way). Loupe does
  neither.
- **The pragmatic path:** `sfltool dumpbtm`, which is **verified to work without root** on 26.5 and
  covers all UIDs. It is undocumented and unsupported. Loupe parses it defensively — key/value lines
  with a known key set, unknown keys ignored, unparseable records counted and reported as
  "N items Loupe could not read".
- **No public API exists for this.** `SMAppService` (public, verified in the SDK) manages **only the
  calling app's own** login items and helpers. It cannot enumerate other apps' background items. Any
  spec that claims otherwise is wrong.
- **What the UI must therefore say:** that the login-item list comes from a system tool Apple does not
  document, that it may be incomplete after a macOS update, and that System Settings is the
  authoritative view. Pair the list with a direct link to that pane.

### 4.4 Ranking within Privacy and permissions

Rank by **power of the grant × trust of the holder**, in that order:

1. **Grant power tiers.** Tier A: Accessibility / PostEvent / ListenEvent, Full Disk Access,
   Screen Recording, Endpoint Security or network system extension. Tier B: Camera, Microphone,
   Apple Events automation, App Bundle modification. Tier C: per-folder, Photos, Contacts, Bluetooth,
   Location.
2. **Holder trust,** from the §5 classifier: `.unsigned` / `.adHoc` / `.selfSigned` /
   `.modifiedAfterSigning` ≫ `.developerIDNotNotarized` ≫ `.developerIDNotarized` ≫ `.applePlatform`.

The product of the two is what sorts. Concretely: an ad-hoc-signed binary holding Accessibility is
the top row of this section; a notarized Developer ID app holding Camera is far down and is
`Review`; an Apple platform binary holding anything is `Informational` and collapsed by default.

A grant whose `client_type = 1` (absolute path rather than bundle id) is promoted one rank, because
path-keyed grants survive the binary at that path being replaced. This is a real, explainable
property — say it in the finding rather than treating it as a secret heuristic.

### 4.5 Avoiding false alarms in Privacy and permissions

| Trap | Rule |
|---|---|
| Apple daemons dominate the list | 72 `kTCCServiceLiverpool` rows and 29 `kTCCServiceUbiquity` rows on the authoring host are all Apple. Group and collapse every `.applePlatform` holder by default behind "N system components". Never surface them as findings. |
| `auth_value = 0` is a **denial** | Denied rows are the *good* case and must never be rendered as a grant. On this host 6 of 8 FDA rows and 6 of 14 Accessibility rows are denials. Getting this backwards would be the single worst bug in the pillar — cover it with an explicit test. |
| Loupe appears in its own FDA list | Expected. Show it, labelled "this is Loupe", rather than filtering it — silently hiding your own entry in a transparency tool is exactly the wrong instinct. |
| Legitimate ad-hoc apps | **Verified real example on this host:** `eDEX-UI.app` is `flags=0x20002(adhoc,linker-signed)` and is a well-known open-source project; `cool-retro-term.app` is entirely unsigned. Both are legitimate. Homebrew casks, locally-built tools, and anything the user compiled land here. The finding must describe *what is true* (no verifiable publisher) and never imply *what is intended*. |
| Stale TCC rows for deleted apps | A row whose `client` is an absolute path that no longer exists, or a bundle id with no installed app, is stale bookkeeping. Report as `Informational` "permission entry for an app that is no longer installed", never as `Attention`. |
| Browser extension inventory read as "active" | `Secure Preferences` holds the enabled bit and Loupe does not parse it. Every extension row is labelled **installed**; the section header says Loupe cannot tell installed from enabled. |
| Developer machines | A machine with Xcode, Homebrew, and Docker will have many `.developerIDNotNotarized` and `.adHoc` binaries. Provide a persistent "expected on this machine" acknowledgement per subject (stored locally, keyed by cdhash where available so that acknowledging a binary does not acknowledge a future replacement). |
| VPN and remote-support tools | Surfshark's network extension and a remote-support tool's Accessibility grant are the intended function of software the user installed. Where the holder is `.developerIDNotarized` and the team id is stable, describe the capability neutrally and do not escalate. |

### 4.6 Wording style

Same rules as §3.4. Three examples:

> **Karabiner-Elements has Accessibility access**
> Accessibility access lets an app read and generate keyboard and mouse input across every other app.
> Karabiner-Elements is signed by its publisher (Team ID `G43BCU2T37`) and this is the permission it
> needs to remap keys.
> *This does not show what the app has done with the access. Loupe reports the permission, not the
> behaviour.*

> **An unsigned program has Full Disk Access**
> `/Applications/Scarab.app/Contents/MacOS/run` is listed in the Full Disk Access database with no
> verifiable publisher. Full Disk Access covers Mail, Messages, Safari data, and Time Machine backups.
> The entry is currently set to **denied**, so it is not in effect.
> *This does not show that the program is harmful, or that it has read anything. Unsigned usually
> means locally built or distributed outside the normal channels.*

> **10 browser extensions are installed in Google Chrome**
> Loupe lists what is installed on disk. Two request permission to read and change data on every site.
> *This does not show which extensions are currently enabled, or what they do when they run — Chrome
> keeps the enabled setting in a protected file that Loupe does not open.*

---

## 5. Section 3 — Trust and persistence audit

### 5.1 Persistence surface enumerated in v1

Four launchd locations, plus the non-launchd vectors that matter:

| Location | Scope | Runs as | Notes |
|---|---|---|---|
| `/Library/LaunchDaemons` | system | **root** | Highest severity ceiling. **Verified:** 9 plists on this host. |
| `/Library/LaunchAgents` | system-installed, per-user session | user | **Verified:** 3 plists. |
| `~/Library/LaunchAgents` | current user | user | **Verified:** 7 plists. |
| `/System/Library/LaunchDaemons`, `/System/Library/LaunchAgents` | Apple | root / user | **Verified:** 422 and 465 plists. **Inventoried, never individually flagged** — they are SIP-protected (`SF_RESTRICTED` confirmed on `/System/Library/CoreServices`). Checked only in aggregate by TRS-06. |
| `~/Library/LaunchDaemons` | — | — | **Not a real location.** Verified absent; launchd does not read it. Loupe reports its *presence* as a finding if it ever exists, since something created it for a reason. |

### 5.2 Probe table

| id | what it reports | exact API / path / argv | root? | FDA? | public API or subprocess | stability risk | what it CANNOT prove |
|---|---|---|---|---|---|---|---|
| **TRS-01** | Trust class of any executable: Apple platform / Developer ID notarized / Developer ID not notarized / self-signed / ad-hoc / linker-signed / unsigned / modified-after-signing; plus team id, signing identifier, stapled ticket presence, hardened runtime | **public Security framework**, per §2.5: `SecStaticCodeCreateWithPath` → `SecCodeCopySigningInformation(kSecCSSigningInformation \| kSecCSRequirementInformation)` → `SecRequirementCreateWithString` + `SecStaticCodeCheckValidityWithErrors` against `anchor apple`, `anchor apple generic`, `notarized` | no | no (for paths already readable) | **public API** — no subprocess, no `codesign(1)` | **low** — these are long-stable public symbols; **`SecAssessmentCreate` is SPI and must not be used** | **The most important limit in the whole pillar.** A valid Developer ID notarization proves Apple checked the binary at submission time and that a real, revocable identity signed it. It does **not** prove the software is safe, well-behaved, or doing what it claims. Conversely, unsigned does **not** mean harmful — it usually means locally compiled |
| **TRS-02** | For every launchd job in the four locations: label, the resolved executable from `Program` / `ProgramArguments[0]`, `RunAtLoad`, `KeepAlive`, `StartInterval`, `WatchPaths`, and the **trust class of that executable** | `PropertyListDecoder` over each `.plist` (public), resolving the executable path, then TRS-01 on it (Tier 2) | no | no for `/Library/*` and `~/Library/*` | **public** | **medium** — launchd plist keys are documented (`launchd.plist(5)`) but the set grows | Does not prove the job is loaded or running. `launchctl print-disabled` (CFG-13) is the disabled-state cross-check; a plist on disk that is disabled is not executing |
| **TRS-03** | Launchd plists whose target executable is **missing**, is inside a user-writable directory, or lives in `/tmp`, `/var/tmp`, `~/Downloads`, or a mounted disk image | path resolution + `lstat` + writability check via `access(W_OK)` against the *directory*, evaluated for the real uid | no | no | **public** | low | A missing target is usually an incompletely uninstalled app, not sabotage. A user-writable target directory means the executable could be replaced without authentication — that is a real property, stated as such |
| **TRS-04** | Launchd plists that set `EnvironmentVariables` containing `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, or `LD_PRELOAD` | plist decode (public) | no | no | **public** | low | These are legitimate in a handful of developer and instrumentation tools. Report the variable and its value verbatim and let the user judge; do not editorialise |
| **TRS-05** | Trust class of every binary behind a BTM/login item (PRV-07), native messaging host (PRV-13), and system extension (PRV-14) | resolve each `URL`/`path` to an executable, run TRS-01 Tier 2 | no | yes (transitively, for the BTM read) | mixed | inherits the source probe's risk | Inherits PRV-07's limits — a login item Loupe cannot parse is a binary it cannot classify, and it says so |
| **TRS-06** | Tamper indicators on SIP-protected paths: any file under `/System/Library/LaunchDaemons`, `/System/Library/LaunchAgents`, `/usr/bin`, `/usr/libexec` that lacks `SF_RESTRICTED`, plus the SSV seal state | `lstat()` → `st_flags & SF_RESTRICTED (0x00080000)` (**verified:** `/usr/bin` → `524288`; `/etc/hosts` → `0`); SSV from `diskutil apfs list` `Snapshot Sealed: Yes` (**verified**) and `csrutil authenticated-root status` (**verified:** `enabled`) | no | no | **public** `lstat` + subprocess for SSV | **low** for `st_flags`; **medium** for the SSV text parse | With SIP **disabled** (as on the authoring host) `SF_RESTRICTED` is still set on the files but is no longer enforced. Loupe must say that explicitly and downgrade this probe's confidence when CFG-03 reports SIP off. Absence of the flag on a file that should have it is a strong signal; presence proves nothing about enforcement |
| **TRS-07** | `/etc/hosts` modified from the OS default | read `/private/etc/hosts` (public); compare non-comment, non-blank lines against the known default set (`127.0.0.1 localhost`, `255.255.255.255 broadcasthost`, `::1 localhost`). **Verified default on this host:** 213 bytes, 9 lines, mtime `2026-06-24 22:29` (matching the OS install time). Report added entries verbatim, and specifically call out any line mapping a security-relevant domain (Apple software-update, notarization, or a security vendor) to a loopback or non-routable address | no | no | **public** file read | **low** — plain text, format fixed since forever | An edited `/etc/hosts` is far more often an ad-blocker, a developer's local-domain mapping, or a Docker artifact than anything hostile. Loupe shows the added lines and does not interpret them, with the one exception noted. Comparing byte-for-byte against a golden file is wrong — comments legitimately differ; compare the parsed entry set |
| **TRS-08** | Configuration profiles that are unexpected: unsigned, non-removable, or containing a payload that changes trust settings | PRV-10's decoded JSON; flag `spconfigprofile_verification_state != "signed"`, `spconfigprofile_RemovalDisallowed == "yes"`, or any payload in `com.apple.security.*`, `com.apple.systempolicy.*`, `com.apple.ManagedClient`, `com.apple.webcontent-filter`, `com.apple.vpn.managed`, `com.apple.SystemConfiguration` (proxy/DNS), or a `com.apple.security.root` / `com.apple.security.pkcs12` certificate payload | partly (see PRV-10) | no | subprocess | medium | An unsigned profile is normal — **verified on this host:** the ScreenTime-installed profile reports `verification_state: unsigned`. Managed Macs legitimately carry non-removable profiles. A certificate-installing profile is the one that genuinely warrants prominence, because it changes what the machine trusts |
| **TRS-09** | Trust anchors added to the system and login keychains: user-added root certificates and any certificate with an explicit trust override | **public** `SecTrustSettingsCopyCertificates(.admin / .user, &certs)` + `SecTrustSettingsCopyTrustSettings`, then `SecCertificateCopySubjectSummary` / `SecCertificateCopyValues` | no | no | **public API** (`SecTrustSettings.h` verified present in SDK) | **low** | **Unverified on this host** — no user-added roots present to test against. A corporate CA is normal on a managed machine. This does not prove interception is occurring; it proves the machine would trust a certificate issued by that authority |
| **TRS-10** | App inventory (the trust audit's substrate): bundle id, display name, version, build, path, team id, signing status, install date | `NSMetadataQuery` / `LSApplicationWorkspace`-free enumeration of `/Applications`, `/Applications/Utilities`, `~/Applications`, `/System/Applications`; per-app `Bundle(url:)` for `CFBundleIdentifier` / `CFBundleShortVersionString` / `CFBundleVersion`; TRS-01 **Tier 1 only** for team id and signing status | no | no | **public** | low | **No CVE matching in v1.** This list is inventory plus provenance. It does not say whether any version is affected by a known issue, and the UI must not imply otherwise |
| **TRS-11** | Quarantine / provenance of flagged binaries: whether the file carries `com.apple.quarantine` or `com.apple.provenance` extended attributes | `getxattr()` (public POSIX) on the main executable and bundle root | no | no | **public** | **medium** — `com.apple.provenance` is undocumented | Absence of `com.apple.quarantine` means the file did not arrive via a quarantine-aware app, or the attribute was stripped, or it was built locally. It is a weak signal and must be presented as context inside an existing finding, never as a finding of its own |

### 5.3 Ranking within Trust and persistence

The ranking function is a lattice over three axes, evaluated lexicographically:

1. **Execution scope.** root LaunchDaemon > system extension > user LaunchAgent > login item >
   native messaging host > installed-but-not-persistent app.
2. **Trust class.** `.modifiedAfterSigning` > `.unsigned` > `.adHoc` > `.selfSigned` >
   `.developerIDNotNotarized` > `.developerIDNotarized` > `.applePlatform`.
3. **Mutability.** Target directory user-writable > target on a removable or temp volume > target
   under `/Applications` or `/Library` > target SIP-protected.

The only `Critical` combination in this section is *(root scope) × (`.unsigned` | `.adHoc` |
`.modifiedAfterSigning`)*, plus `.modifiedAfterSigning` at any scope. Everything else caps at
`Attention`.

`.applePlatform` binaries in Apple-owned locations are never findings. They appear in inventory
counts only. The one exception is TRS-06: an Apple-location file *without* `SF_RESTRICTED`, which is
`Critical` because it should be structurally impossible on a sealed system.

### 5.4 Avoiding false alarms in Trust and persistence

| Trap | Rule |
|---|---|
| Homebrew | `homebrew.mxcl.*` LaunchDaemons and LaunchAgents (**verified present:** `homebrew.mxcl.openvpn.plist`, owned `root:admin` rather than `root:wheel`) point at unsigned binaries under `/opt/homebrew` or `/usr/local` by design. Detect the prefix and the label pattern, group them under one "installed by Homebrew" row, and describe the property (unsigned, user-writable prefix) without a severity escalation per item. |
| Locally built and open-source apps | **Verified real cases:** `eDEX-UI.app` (ad-hoc, linker-signed) and `cool-retro-term.app` (unsigned). Both legitimate. The wording must never bridge from "no verifiable publisher" to "suspicious". |
| Deep verification cost and its false positives | Do not enable `kSecCSCheckNestedCode` by default. Measured: `Xcode.app` alone takes 6.2 s wall / 21.7 s CPU with full validation, and nested-code failures are dominated by apps that legitimately ship unsigned resources. Offer it as an explicit per-item action. |
| Apps mid-update | An app being replaced while Loupe scans yields `errSecCSSignatureFailed` or a resource-altered error transiently. Re-verify once after a 2-second delay before emitting any `.modifiedAfterSigning` finding, and only emit if both attempts fail. This is `Critical` severity, so it must be right. |
| `/etc/hosts` | Compare parsed entries, not bytes. Ad-blocker hosts files with thousands of entries are common — collapse to a count plus the security-relevant subset, and never render 40 000 rows. |
| Every profile flagged | Unsigned profiles are normal (verified: ScreenTime's is unsigned). Flag on *payload capability*, not on signature state alone. |
| Disabled jobs | A launchd plist on disk that appears in `disabled.plist` as `true` is not executing. Cross-reference CFG-13 and label it "present but disabled", one severity level lower. |
| SIP-disabled hosts | When CFG-03 reports SIP off, TRS-06's `SF_RESTRICTED` results are advisory only. Add a section-level note and cap TRS-06 confidence at `low` — which, per §2.2, caps its severity at `Review`. |
| Path-only trust caching | Cache TRS-01 Tier 2 results on `(path, inode, size, mtime, cdhash)`. Caching on path alone would let a swapped binary inherit a clean verdict — the exact failure this pillar exists to prevent. |

### 5.5 Wording style

Same rules as §3.4. Three examples:

> **A startup item runs a program with no verifiable publisher**
> `/Library/LaunchDaemons/com.example.helper.plist` starts `/usr/local/bin/helper` as root at every
> boot. That program has no code signature, so macOS cannot tell you who produced it or whether it has
> changed since it was installed.
> *This does not show that the program is harmful. Programs installed by Homebrew or built on this Mac
> are normally unsigned too.*

> **`/etc/hosts` has 4 entries beyond the macOS defaults**
> This file overrides DNS for specific hostnames. The added entries are shown below. None of them
> point at an Apple software-update or notarization hostname.
> *This does not show who added them or when. Ad blockers, development setups, and Docker all edit
> this file routinely.*

> **A configuration profile installs a certificate authority**
> The profile "Corp Root" (identifier `com.corp.mdm.root`, installed 12 March 2026, signed) adds a
> certificate authority to this Mac's trusted roots. Software signed by that authority — and TLS
> connections it issues certificates for — will be trusted without further prompting.
> *This does not show that anything is being intercepted. This is how most managed work Macs are
> configured, and removing it may break access to internal services.*

---

## 6. Privileged helper dependencies

The helper is being designed elsewhere. This pillar declares only what it needs and why. Every item
below was **verified unreadable** as a normal user on the authoring host.

| Probe | Needs from the helper | Why root is genuinely required | Proposed read-only XPC call |
|---|---|---|---|
| **PRV-10 / TRS-08** (device-scope configuration profiles) | The device-scope profile list | `/private/var/db/ConfigurationProfiles/Store` is `drwx------ root` and `profiles list -all` fails with `this command requires root privileges` (both verified). `system_profiler SPConfigurationProfileDataType` returned **user-scope only** here, and device-scope visibility to a non-root caller is unverified | `listConfigurationProfiles() -> [ProfileSummary]` — returns identifier, payload type list, signed state, removable state, install date. **Never returns `spconfigprofile_payload_data`**, which can contain credentials |
| **PRV-15** (approved kernel extensions) | The user-approved kext list | `/var/db/SystemPolicyConfiguration/KextPolicy` is `-rw-------` root; `sqlite3` open fails (verified) | `listApprovedKernelExtensions() -> [(teamID, bundleID, allowed)]` |
| **CFG-07 fallback** (Gatekeeper policy, if `spctl` output ever becomes unparseable) | The Gatekeeper enable bit | `/var/db/SystemPolicy` is `-rw-------` root (verified) | `gatekeeperAssessmentEnabled() -> Bool`. **Optional** — do not build unless `spctl` parsing actually breaks |
| **CFG-17** (auto-login) | Confirmation that `/etc/kcpassword` is a real auto-login credential rather than a stray file | The file is root-only readable | `autoLoginConfigured() -> Bool`. **Optional** — the `autoLoginUser` preference plus file existence is sufficient for v1 |

Constraints this pillar imposes on the helper's interface, stated so the two specs agree:

- **Read-only.** No method in this list mutates anything. The helper should expose no setter this
  pillar can reach.
- **No path parameters.** Every call above takes zero arguments and reads a fixed, compile-time
  location. There is no method of the form `read(path:)`. This removes path traversal from the threat
  model entirely.
- **Typed returns, not blobs.** The helper decodes and returns a `Codable` summary. It never returns
  raw file bytes, raw SQLite rows, or profile payload data.
- **No secrets cross the boundary.** Profile payload data, certificate private material, and
  `/etc/kcpassword` contents are never returned — only booleans and identifiers derived from them.
- **Absence of the helper is not an error state.** Every probe above must degrade to
  `ProbeUnavailable(.notPermitted(.root))` and render as "not checked", not as a pass.

**Nothing in Sections 1 or 3 other than the above requires root.** Everything else was verified
readable as a normal user on macOS 26.5.

---

## 7. Performance budget

Derived from measurements in §1.

| Stage | Budget | Basis |
|---|---|---|
| Config posture (CFG-01…19) | **< 1.5 s** | Dominated by ~8 subprocess spawns. `SPiBridgeDataType` 0.18 s, `SPConfigurationProfileDataType` 0.06 s measured. Run the independent ones concurrently in a `TaskGroup` bounded to 4. |
| TCC reads (PRV-01…06) | **< 200 ms** | Two small SQLite files, ~130 KB total, single pass each. |
| Persistence enumeration (TRS-02…04) | **< 500 ms** | ~20 non-Apple plists in the three writable locations (verified 3 + 9 + 7). |
| App inventory, Tier 1 (TRS-10) | **< 2 s** | Measured 1.23 s for 36 apps via the equivalent metadata-only read. |
| Trust Tier 2 (TRS-01 on persistence targets) | **< 5 s** | 20–60 binaries at the measured full-validation cost, excluding `Xcode.app`-class bundles which are never Tier 2 targets. |
| **Full scan, warm** | **< 8 s** | Sum of the above with concurrency. |

Cold-cache first run will exceed this; show incremental results per section as each completes rather
than a single spinner. Every probe is cancellable and every subprocess has a deadline (§2.4).
Findings stream into the UI as they are produced; no probe blocks another section's rendering.

---

## 8. Open questions

Ordered by how much they could change the design.

1. **Device-scope configuration profiles without root.** `system_profiler -json
   SPConfigurationProfileDataType` returned only `User (501)` scope on the authoring host, which has
   no device-scope profile installed. It is genuinely unknown whether device-scope profiles are
   invisible to a non-root caller or simply absent here. This determines whether PRV-10 and TRS-08
   need the helper at all. **Needs testing on an MDM-enrolled or profile-carrying Mac before the
   helper interface is frozen.**
2. **Does `sfltool dumpbtm` require Full Disk Access?** It worked without root, but the authoring
   shell held FDA. If it needs FDA, the whole login-items feature moves behind the FDA gate and the
   UX grouping in §4.2 changes. Testable by running Loupe unsigned from a shell without FDA.
3. **`socketfilterfw` output stability and localization.** It is the only path to firewall state now
   that `/Library/Preferences/com.apple.alf.plist` is gone (verified), it prints English prose, and
   Apple has never committed to its output. The `State = N` token is the parse anchor, but whether
   that token survives localization on a non-English system is **untested**. If it does not, the
   firewall probes have no reliable source at all — this is the weakest load-bearing dependency in
   Section 1.
4. **Where did `askForPassword` go on macOS 26?** CFG-18 currently ships as `ProbeUnavailable`. The
   screen-lock grace period is genuinely valuable posture information and losing it is a real gap.
   Worth a targeted search of the `com.apple.screensaver` per-host domain and the
   `com.apple.MCX`/managed-preferences path on a machine where the setting has been explicitly
   changed from default.
5. **TCC `auth_value` values 1 and 3.** Only `0` and `2` were observed. The semantics of `1`
   (commonly documented as "unknown") and `3` ("limited", as used by Photos) are inferred, not
   verified. The rendering for those two values is therefore a guess.
6. **Safari extension enumeration.** `pluginkit -m -p com.apple.Safari.web-extension` returned no
   matches on a host with no Safari extensions installed, so the path is unverified end to end. The
   correct protocol string and whether `AppExtensions` vs `WebExtensions` need different handling are
   both open.
7. **`SPiBridgeDataType` on Intel.** CFG-02 is verified only on Apple silicon (`Mac16,13`). Intel
   Macs with a T2 report a different key set and pre-T2 Macs report nothing. The probe must degrade
   cleanly on both and currently has no tested fallback.
8. **Is `csrutil status` parsing acceptable long-term?** `csr_check` is exported by libSystem but
   `sys/csr.h` is not in the public SDK, making it SPI. Loupe therefore parses an English sentence
   for one of the most important booleans in the product. There is no better public option found;
   flagging it as an accepted risk rather than a solved problem.
9. **Whether TRS-09 (user-added trust anchors) belongs in v1.** The API is public and clean, but the
   probe was untestable on the authoring host (no user-added roots) and the false-positive surface on
   corporate machines is large. It may be better held for v1.1 with real test data.
10. **Acknowledgement persistence keyed by cdhash.** §4.5 proposes that "expected on this machine"
    acknowledgements be keyed by cdhash so they do not survive a binary being replaced. For
    `.unsigned` binaries there is no cdhash, so the key would have to be a content hash Loupe computes
    itself — which is expensive for large bundles and needs a decision on scope (main executable only
    vs. whole bundle).
