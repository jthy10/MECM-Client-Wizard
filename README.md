# MECM Client Wizard

A dedicated, open-source troubleshooting utility for Microsoft Endpoint Configuration Manager
(MECM / SCCM / ConfigMgr) clients.

It finds out **why** a client is unhealthy, explains the failure in plain English, tells you which
repairs it wants to run and why — and then asks before it runs any of them.

Run it with no arguments and you get a menu. Run it with a command and it goes straight there.

```
mecmdoctor              the menu
mecmdoctor diagnose
mecmdoctor repair
mecmdoctor bundle
```

No agents, no dependencies, no telemetry. One folder of PowerShell you can drop on any endpoint.

---

## Why

Diagnosing a broken ConfigMgr client normally means opening six log files in CMTrace, recognising a
hex code you last saw eight months ago, and remembering which of a dozen half-documented repair
sequences applies. This tool does that part for you:

- **It knows the error codes.** `0x87D00692` becomes *"a Group Policy WSUS setting is overriding the
  MECM software update point — this is the classic 'updates never install' cause"*, along with the fix.
- **It reads the logs so you don't have to.** Both on-disk formats, rolled-over `.lo_` files included,
  with repeated lines collapsed so 900 lines of noise becomes six real problems.
- **It repairs what it diagnosed, not what it recognises.** One broken service means one service gets
  fixed, not the whole service table.
- **It asks first.** `repair` shows the plan and the finding behind each action, then asks whether to
  continue at the tier the diagnosis recommends. Destructive actions ask again, individually.
- **It never hides what it did.** Every run produces a plain-text transcript *and* a CMTrace-format
  copy, and anything it deletes is backed up first.

---

## Quick start

```
git clone https://github.com/jthy10/MECM-Client-Wizard.git
cd MECM-Client-Wizard
mecmdoctor
```

That opens the menu. Double-clicking `mecmdoctor.bat` in Explorer does the same thing, so there is a
path through this tool that needs no command line at all.

`mecmdoctor.bat` handles execution policy and requests elevation for you. If you would rather call
PowerShell directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\MECMDoctor.ps1 diagnose
```

**Requirements:** Windows PowerShell 5.1 (shipped with Windows 8.1 / Server 2012 R2 and later).
No modules to install. Administrator rights are required for repairs and for several checks.

---

## Commands

| Command | What it does |
|---|---|
| `mecmdoctor` | The menu. This is what you get when you name no command. |
| `mecmdoctor diagnose` | Read-only health check across thirteen areas, plus log analysis. Changes nothing. |
| `mecmdoctor repair` | Diagnose, explain what is recommended and why, ask, then apply exactly the repairs the diagnosis implicated. |
| `mecmdoctor logs` | Parse `C:\Windows\CCM\Logs` and translate every error found. |
| `mecmdoctor bundle` | Diagnose, then build a timestamped support ZIP for someone else to read. |
| `mecmdoctor reinstall` | Remove and reinstall the client, using your `ClientReinstall.ps1` when you supply one. |
| `mecmdoctor help` | Full usage, including every repair action id. |
| `mecmdoctor version` | Print the version. |

---

## The menu

Typing `mecmdoctor` with no command opens a menu, so nobody has to know the flags to get a result:

```
=========================================================================
   M E C M   C L I E N T   W I Z A R D
   mecmdoctor v1.2.0  --  main menu
=========================================================================

  Computer         : WKS-4471   (CONTOSO)
  Windows          : Microsoft Windows 11 Enterprise (10.0.26100)   23H2
  Client           : installed   5.00.9128.1008
  Site / MP        : AB1   /   mp01.contoso.com
  Running as       : CONTOSO\jsmith   (elevated)

  WHAT DO YOU WANT TO DO?

    1   Diagnose        Read-only health check. Changes nothing.
    2   Repair          Diagnose, explain, ask, then fix what is broken.
    3   Bundle          Build a support ZIP for someone else to read.
    4   Logs            Read the CCM logs and translate every error.
    5   Reinstall       Remove and reinstall the client. Last resort.
    6   Help            Full usage, every option and every repair id.
    7   Log folder      Open the folder the transcripts are written to.
    Q   Quit

   Select:
```

Pick a command and you get its options as questions rather than flags — the repair tier and what it
costs, which actions may run, dry run or for real, how far back to read the logs, where the ZIP
goes. Or take the first answer on every screen and it runs with the defaults.

- **Nothing is a dead end.** Every prompt takes `Enter` for the default, `B` to go back one screen
  and `Q` to leave.
- **The first answer is always "just run it".** Each command opens on *Run it now* / *Options
  first*, so a run is three keystrokes away and the questions are opt-in.
- **It shows its working.** Before a run and again on the review screen, the menu prints the command
  line that would have produced it — `mecmdoctor repair -Level Safe -Verify` — so the menu is also
  how you learn to stop needing it.
- **It hands you the next thing.** When a diagnosis finds problems the finish screen offers the
  repair it recommends; after a repair it offers to re-check; when anything came back unhealthy it
  offers to bundle it up for whoever looks at it next.
- **It stops you wasting your time.** Choosing repair or reinstall without administrative rights
  says so immediately and offers to re-launch elevated, rather than asking four screens of questions
  and then refusing.
- **It changes nothing about the safety model.** The menu only decides what to run. `repair` still
  prints its plan and the finding behind each action, still asks before it touches anything, and
  still asks again for each destructive action.

Every command run from the menu writes its own pair of transcripts, named for it, exactly as though
it had been typed at a prompt. Menu navigation itself is not logged.

A session with no console — a scheduled task, an MECM script deployment, a remote shell, or output
piped to a file — has nobody to answer a menu, so `mecmdoctor` with no command runs a diagnosis
there instead of waiting at a prompt.

---

## What it detects

| Area | Checks |
|---|---|
| **Prerequisites** | Elevation, PowerShell version, 32-bit-shell-on-64-bit-OS redirection traps |
| **Client install** | Presence, version, install path, log directory, an install already in flight |
| **Services** | `CcmExec`, `Winmgmt`, `RpcSs`, `CryptSvc`, `Schedule`, `gpsvc`, `Dnscache` as core dependencies; `BITS`, `wuauserv`, `msiserver`, `W32Time`, `TrustedInstaller` as conditional services — see [Targeted service repairs](#targeted-service-repairs) |
| **Broken WMI** | Repository consistency, reachability of `root\cimv2` and all six client namespaces, class-definition and namespace-tree integrity, repository size, provider errors from the WMI-Activity log |
| **Client registration** | Site assignment, client GUID, `SMSCFG.INI`, confirmed registration in `ClientIDManagerStartup.log`, MP name resolution, live HTTP/HTTPS probe of the MP `mplist` endpoint |
| **Certificates** | The `LocalMachine\SMS` store, expiry, missing or inaccessible private keys, client-auth certificate for HTTPS-only clients |
| **Policy failures** | Applied vs requested policy body counts, and the last run time of nine client cycles |
| **Stuck updates** | Updates parked in an in-progress evaluation state, WSUS Group Policy conflict, update scan source (build-aware — see [Update source detection](#update-source-detection)), Windows Update datastore size |
| **Content download failures** | Cache configuration vs what is actually on disk, orphaned cache folders, failed and stalled BITS jobs |
| **Pending reboot** | CBS, Windows Update, `PendingFileRenameOperations`, pending computer rename, pending domain join, and the client's own `DetermineIfRebootPending` |
| **Group Policy corruption** | `Registry.pol` binary header validation (machine, user, and per-user local GPOs), zero-byte `gpt.ini`, `secedit.sdb` integrity, GP event log errors, last successful policy application |
| **Client health** | Microsoft's own `CcmEvalReport.xml`, including how stale it is |
| **System** | Free space on the system and cache volumes, time synchronisation source and skew risk |

### Group Policy corruption, specifically

A valid `Registry.pol` begins with the ASCII signature `PReg` followed by a little-endian version of
`1`. A zero-byte or truncated file — the usual result of a disk-full event or an unclean shutdown —
makes Group Policy processing fail entirely with **event 1096**, and nothing that depends on policy
works afterwards. That includes the WSUS settings the client relies on.

`mecmdoctor` validates that header directly rather than inferring corruption from symptoms, and
`repair -Level Standard` quarantines only the files that actually fail validation, backs them up,
and lets Windows rebuild them. A healthy `Registry.pol` holds real configuration and is never
touched.

The same binary read is also how the tool tells *"the MECM client set this WUServer value"* apart
from *"a GPO is forcing this WUServer value"* — they look identical in the live registry, and only
one of them is a problem.

### Update source detection

Dual scan — a client scanning Microsoft Update instead of your software update point — is a real
problem, but the policy that controls it changed. `DisableDualScan` was superseded at **Windows 10
1903 (build 18362)** by *"Specify source service for specific classes of Windows Updates"*, and it
only ever mattered once Windows Update for Business **deferral policies** were configured. Treating
a missing `DisableDualScan` as a fault produces a permanent false positive on Windows 11.

So `mecmdoctor` detects the build first, then judges the configuration that applies to it:

| Build | What decides the update source | When it is reported as a problem |
|---|---|---|
| **18362 and later** (Windows 10 1903+, Windows 11, Server 2022+) | The scan source policy | A class of updates is explicitly directed to Windows Update, **or** deferral policies are set with no scan source policy to constrain them |
| **Before 18362** (Windows 10 1607–1809, Server 2016/2019) | `DisableDualScan` | Deferral policies are configured **and** `DisableDualScan` is not `1` |

Either way, the detected configuration is always reported — WUServer, UseWUServer, every scan source
value, `DisableDualScan`, and which deferral policies are in play — so you can see what the client is
doing rather than only whether the tool approved of it. On a Windows 11 machine with no policy at
all, that reads:

```
[ OK ] Update scan source -- no deferral or scan source policy configured - the client sets
       its own update source
       - DisableDualScan does not apply on Windows 11; it was superseded by the scan source
         policy at Windows 10 1903 (build 18362).
       - Without Windows Update for Business deferral policies, dual scan cannot occur.
```

### WMI: size is not corruption

A WMI repository over a gigabyte is worth knowing about. It is **not** evidence of corruption, and
it never produces a repair recommendation:

```
[WARN] Repository size -- 1.42 GB - unusually large, but no corruption was detected.
       No repair recommended.
       - A repository this size is normally the result of years of MOF churn from inventory,
         third-party agents and servicing.
       - Size on its own is not corruption, and resetting the repository because of it would
         discard every custom WMI class on this machine for no benefit.
       > fix: Worth investigating rather than repairing: look for an agent re-registering its
         MOFs on a loop, and plan a rebuild during a maintenance window only if WMI actually
         starts failing.
```

A reset is proposed only when `winmgmt /verifyrepository` reports the repository inconsistent **and**
independent health checks agree — `root\cimv2` and `root\default` reachability, class-definition
reads, and namespace-tree enumeration. Salvage, which is non-destructive, is always planned first.

When a reset does reach the plan it re-verifies the repository itself immediately beforehand and
declines if it now verifies as consistent — so a salvage that worked means the reset does nothing.
If the repository really is still broken, it prints what a reset costs and asks its own question:

```
[WARN] WMI REPOSITORY RESET - read this before answering.
       ! Why this is being offered: winmgmt reports the repository inconsistent, and the
         diagnosis found independent evidence that WMI is not working correctly.
       ! What it costs: every custom WMI class and all data added since Windows was installed
         is discarded. Antivirus, monitoring, inventory and management agents can lose their
         WMI registration and may need repairing or reinstalling.

[ ?? ] WMI corruption was detected after health checks. Resetting WMI may affect applications
       and system management components. Continue? [y/N]
```

`wmi.reset` is excluded from `-All`. It enters a plan only because a finding named it, or because you
named it yourself with `-Only wmi.reset`.

### Targeted service repairs

Services are split into two classes, and they are treated differently on purpose.

**Core MECM dependencies** — `CcmExec`, `Winmgmt`, `RpcSs`, `CryptSvc`, `Schedule`, `gpsvc`,
`Dnscache`. Stopped or misconfigured, the client is broken. These are held to their full expected
configuration and repaired automatically.

**Conditional Windows services** — `BITS`, `wuauserv`, `msiserver`, `W32Time`, `TrustedInstaller`.
Whether these should be `Auto`, `Manual` or `Disabled` depends on how the environment is built, so
their startup configuration is **never** changed just because it differs from an expected value.
Only `Disabled` is even questioned, and only when something else in the diagnosis is failing in a way
consistent with it:

```
[INFO] msiserver: start mode is Disabled, but nothing in this diagnosis depends on it.
       No repair proposed.
```
```
[FAIL] msiserver: start mode is Disabled, and 2 failing check(s) are consistent with that.
       - Logs: Software logs -- 3 distinct error(s) in the last 7 day(s)
```

Every service finding carries the service name in its `Data`, and `services.fix` acts on exactly the
services the findings named — nothing else is even inspected:

```
[ 1/1 ] REPAIR: SERVICES.FIX ----------------------------------------------------
  [INFO] tier: Safe
         - acting on: BITS
```

With no diagnosis to work from (`-NoDiagnose`, or `-Only services.fix` alone) the fallback is the
core dependencies only. A conditional service is never touched without a finding that names it.

---

## Repair tiers

`repair` runs a diagnosis first, then applies **only the actions the findings implicated**. That is
what makes it safe to run on a machine that turns out to be healthy: it will do nothing.

| Tier | Actions | Risk |
|---|---|---|
| **Safe** | Start and re-enable an implicated service · restart `CcmExec` · clear failed and stalled BITS jobs · clear the content cache · `gpupdate /force` · trigger the client action cycles · force a software update scan · run `ccmeval` | Reversible. Fine on a production machine during business hours. |
| **Standard** | Everything above, plus: salvage the WMI repository · quarantine corrupt `Registry.pol` · purge and re-download client policy · reset Windows Update components · repair the client | Rebuilds state that Windows or the client regenerates by itself. |
| **Aggressive** | Everything above, plus: reset the WMI repository · clear Group Policy state · rebuild `secedit.sdb` · uninstall and reinstall the client | **Destructive.** Every action prompts individually unless `-Force`. |

Every tier includes the ones below it.

### The flow

1. `repair` runs the full diagnosis.
2. It prints the findings and the prioritised issue list.
3. It prints the repair plan, and under it **which finding asked for each action**.
4. It asks whether to continue at the tier the diagnosis recommends.
5. Nothing runs until you answer yes.
6. Destructive actions ask again, individually, with their own explanation of what they cost.

```
=======================================================================================
  REPAIR PLAN  (TIER: SAFE)
=======================================================================================
  #     ACTION ID                 TIER          FINDINGS
  ----  ------------------------  ------------  --------
  10    services.fix              Safe          1

  Why each action is in the plan:

  services.fix  [Safe]
      - Services: Background Intelligent Transfer -- start mode is Disabled - correlated
        with 2 failing check(s)
      > will touch only: BITS

=======================================================================================
  CONFIRMATION
=======================================================================================
  [ ?? ] Diagnosis recommends Safe repairs. Continue? [y/N]
```

The default is **no**, so a bare Enter cancels and nothing is changed. Pass `-Level` yourself to
override the recommendation, and `-Force` to answer yes for unattended runs.

Useful flags:

```powershell
mecmdoctor repair                                # asks before it changes anything
mecmdoctor repair -DryRun                        # show the whole plan, change nothing, no prompt
mecmdoctor repair -Level Safe                    # stay reversible
mecmdoctor repair -Level Standard -Verify        # repair, then re-diagnose to show the delta
mecmdoctor repair -Only wmi.salvage,policy.reset # run exactly these, ignore the tier
mecmdoctor repair -All -Level Safe               # every Safe action, not just implicated ones
mecmdoctor repair -Level Aggressive -Force       # unattended and destructive
```

Run `mecmdoctor help` for the full list of repair action ids.

### What it will not do

- **It never resets the client identity.** No repair deletes `SMSCFG.INI` or the SMS certificate
  store. Doing that assigns the device a **new client GUID** and orphans its inventory, deployment
  and status history in the console. Where a client genuinely needs to re-register, `mecmdoctor`
  restarts `CcmExec` and lets it register under the identity it already has.
- **It never reboots.** A pending reboot is reported and explained; scheduling it is your call.
- **It never resets the WMI repository because the repository is large.** See
  [WMI: size is not corruption](#wmi-size-is-not-corruption).
- **It never normalises unrelated Windows services.** See
  [Targeted service repairs](#targeted-service-repairs).
- **It never guesses at install parameters.** With no `ClientReinstall.ps1` and no discoverable site
  code, `reinstall` tells you so instead of inventing a command line.
- **It backs up before it deletes.** `Registry.pol`, `secedit.sdb` and the Group Policy state
  registry keys are all copied to `%ProgramData%\MECMDoctor\Backups\<timestamp>` first.
- **It renames rather than deletes** `SoftwareDistribution` and `catroot2`, so the old datastore is
  still there if anyone needs to look at it.

---

## Support bundle

```
mecmdoctor bundle
```

Runs a full diagnosis and packages everything a colleague, a vendor or your future self needs into
one timestamped ZIP:

```
C:\ProgramData\MECMDoctor\Bundles\MECMDoctor-Bundle-WKS0042-20260826-112500.zip
```

| File | Contents |
|---|---|
| `README.txt` | What the bundle holds and what was deliberately left out |
| `diagnosis.json` | The full diagnosis in the stable `mecmdoctor/1` schema |
| `findings.txt` | The same diagnosis as readable text, issues first |
| `client.txt` | Client version, **client GUID**, site assignment, management point information |
| `services.txt` | State and startup configuration of every service, by class |
| `wmi.txt` | Repository consistency, repository file sizes, namespace reachability |
| `windows.txt` | Windows version/build, host facts, Windows Update / WSUS / scan source configuration |
| `logs-manifest.txt` | Which CCM logs were copied, and why any were skipped |
| `logs\` | The CCM logs themselves, rolled-over `.lo_` files included |
| `transcript\` | The `mecmdoctor` transcript for the run that produced the bundle |

Deliberately **not** collected: user documents, profiles or browsing data; certificates, private keys
or other key material; credentials or tokens; registry hives — only the named Windows Update policy
values the diagnosis already reads are recorded.

CCM logs can name deployed applications, packages and the accounts that ran them, so
`logs-manifest.txt` lists exactly what went in. Individual logs over 15 MB are skipped by name rather
than silently bloating the ZIP, and the log copy stops at 250 MB in total.

```powershell
mecmdoctor bundle                       # default location
mecmdoctor bundle -BundlePath C:\Temp   # a folder
mecmdoctor bundle -BundlePath C:\Temp\ticket-4821.zip   # an exact filename
mecmdoctor bundle -SkipLogs             # everything except the CCM logs
```

The final path is printed when it completes.

---

## Custom reinstall script

Drop a file named **`ClientReinstall.ps1`** next to `MECMDoctor.ps1` and `mecmdoctor` runs yours
instead of its built-in fallback. Searched, in order:

1. the folder `MECMDoctor.ps1` lives in
2. that folder's parent
3. the current working directory

Copy [`ClientReinstall.example.ps1`](ClientReinstall.example.ps1) to `ClientReinstall.ps1` and edit
the configuration block at the top. The example is a complete, working script: it uninstalls, cleans
up the leftovers that most often break a fresh install, installs from your source share, waits for
the background `ccmsetup` to actually finish, and checks the result.

**The contract:**

- If your script declares any of `-SiteCode`, `-ManagementPoint`, `-InstallPath` or `-LogDirectory`,
  `mecmdoctor` fills them in from what it discovered. Declare none of them and it is invoked with no
  arguments — that works too.
- Exit code `0` means success. Anything else is reported as a failed reinstall.
- Everything your script writes to the output stream is captured into the `mecmdoctor` transcript.

`ClientReinstall.ps1` is in `.gitignore`, because yours will contain internal server names.

> A full reinstall does replace the client identity — that is inherent to uninstalling the client,
> not something `mecmdoctor` does on its own. It is why `reinstall` is a separate, explicit command
> rather than something a repair can escalate into.

---

## Output

Every run writes to the console **and** to two files under `%ProgramData%\MECMDoctor\Logs`:

- `MECMDoctor_<command>_<timestamp>.log` — the plain-text transcript
- `MECMDoctor_<command>_<timestamp>.cmtrace.log` — the same content in CMTrace format, so you can
  open it in the same viewer you already use for the CCM logs

Console output uses fixed-width ASCII status tags (`[ OK ]`, `[WARN]`, `[FAIL]`, `[INFO]`, `[SKIP]`,
`[ >> ]`, `[ ?? ]`) rather than Unicode glyphs, because legacy console code pages are still common on
exactly the kind of endpoint this tool gets pointed at. Add `-NoColor` when piping to a file.

`-Quiet` trims the screen down to the parts you would have scrolled to anyway. A line is dropped only
if it is *running commentary* — a check that passed and its evidence, a step heading, a progress
line, the per-file notes a bundle emits as it builds. Warnings, failures and everything they say,
the summary table, the issues list with its fixes, repair results, confirmation prompts and the
footer all stay exactly where they were. **The two transcripts are written in full either way**, so
`-Quiet` never costs you anything you might need afterwards.

For fleet collection, `-Json <path>` writes a flat, stable report:

```powershell
mecmdoctor diagnose -SkipLogs -Json C:\Temp\$env:COMPUTERNAME.json
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Healthy, or all repairs applied successfully |
| `1` | Warnings only |
| `2` | One or more failures found |
| `3` | A repair action failed |
| `4` | Could not run, or could not produce the requested output — not elevated, missing library files, bad arguments, bundle could not be written |

These make it straightforward to run as a Configuration Manager script, a Configuration Item, or a
scheduled task, and act on the result. For unattended use, remember that `repair` will not proceed
past its confirmation gate without `-Force`.

---

## Options

| Option | Meaning |
|---|---|
| `-Level <tier>` | `Safe` \| `Standard` \| `Aggressive`. Default: whatever the diagnosis recommends. |
| `-DryRun` | Show what would happen and change nothing. Aliased to `-WhatIf`. |
| `-Force` | Answer yes to every confirmation, including the repair gate. Required for unattended runs. |
| `-Only <ids>` | Run only these repair actions, ignoring tier and diagnosis. |
| `-All` | Run every repair at the tier except those that require evidence (`wmi.reset`). |
| `-NoDiagnose` | Skip the diagnosis pass before repairing. |
| `-Verify` | Re-run the diagnosis after repairing. |
| `-Days <n>` | How many days of CCM logs to scan. Default `7`. |
| `-IncludeWarnings` | Report log warnings as well as errors. |
| `-SkipLogs` | Skip log parsing; also leaves the CCM logs out of a bundle. Much faster. |
| `-Json <path>` | Also write a machine-readable JSON report. |
| `-BundlePath <path>` | Where `bundle` writes its ZIP: a folder, or a full path ending in `.zip`. |
| `-LogDirectory <path>` | Where transcripts go. |
| `-NoColor` | Plain output, for piping to a file. |
| `-Quiet` | Drop the running commentary from the screen — passing checks, step headings, progress lines. Warnings, failures, the summary and both transcripts are untouched. |
| `-Trace` | Show the low-level diagnostic lines on screen. |
| `-NoClear` | Menu only: never clear the screen, so the whole session stays in the scrollback. |

---

## Layout

```
MECMDoctor.ps1              entry point - argument handling and orchestration
mecmdoctor.bat              launcher: execution-policy bypass and self-elevation
lib/
  Console.ps1               output rendering and the dual-transcript logging engine
  Common.ps1                shared helpers, the Finding object, client discovery
  ErrorCatalog.ps1          error code and message-pattern translation tables
  LogParser.ps1             CCM log reading, de-duplication and interpretation
  Checks.ps1                all diagnostics - read-only, by contract
  Repairs.ps1               all repair actions - the only code that writes
  Report.ps1                summary rendering, repair rationale, JSON export
  Bundle.ps1                the support bundle
  Menu.ps1                  the interactive menu and its option wizards
tests/
  Invoke-MDTests.ps1        the test run - no Pester, no modules, read-only
ClientReinstall.example.ps1 template for your own reinstall script
```

Checks never modify the machine; repairs are confined to `Repairs.ps1`. That split is the main
design rule, and it is what makes `diagnose` safe to run anywhere without thinking about it.

`Menu.ps1` does no work of its own either. Every screen ends by producing the same options object
the command line parses into, which the entry script hands to one runner — so a menu-driven run and
a typed one are the same run, and there is no second place a command's behaviour can drift.

---

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-MDTests.ps1
```

No Pester and no modules to install — the point of this tool is that it works on an endpoint exactly
as shipped, and its tests should not need anything it does not. Everything the run does is read-only;
nothing starts, stops or reconfigures a service, and nothing is written outside `%TEMP%`. Exit code
`0` when every test passes.

The suite covers the invariants that are easy to break by accident: that no repair path can reset the
client identity, that a large WMI repository never plans a reset, that `-All` cannot select
`wmi.reset`, that one bad service resolves to exactly one repair target, that a conditional service
without a correlated failure produces no repair, that a modern build is not failed for a missing
`DisableDualScan` while a pre-1903 build still is, and that the bundle produces a readable ZIP with a
valid JSON report inside.

The menu is tested the same way an operator uses it: the tests shadow `Read-Host` with a scripted
list of keystrokes and drive the real screens, checking that each answer sets the option it claims
to, that a dry run never also asks for a verification pass, that an unknown repair id is rejected
rather than passed through, that going back from the first screen returns to the start instead of
abandoning the command, and that a menu nobody is answering closes instead of looping forever.

---

## Contributing

The error catalogue is the easiest and most valuable place to help. Adding a code is one line in
[`lib/ErrorCatalog.ps1`](lib/ErrorCatalog.ps1):

```powershell
'0x87D00215' = @{
    Name  = 'CCM_E_NO_CONTENT_LOCATIONS'
    Area  = 'Content'
    Means = 'No distribution point could be found for this content. The client is in no boundary group that has a DP with this package.'
    Fix   = 'Check the client boundary/boundary group membership and that the package is distributed to a DP in that group.'
}
```

Codes are keyed on the canonical `0xXXXXXXXX` form — signed decimals, unsigned decimals and hex from
the logs are all normalised to it first, so you only need the one entry.

For failures that carry no code at all, add a regex to `$MDPatternCatalog` in the same file.

New checks go in `lib/Checks.ps1` and must return `New-MDFinding` objects and never throw. New
repairs go in `lib/Repairs.ps1`, must honour `-DryRun`, must back up anything they delete, and must
be registered in `$MDRepairCatalog` with a tier.

Two rules that are not negotiable:

- **A repair must not reset the client identity.** Nothing may delete `SMSCFG.INI` or the SMS
  certificate store.
- **A destructive repair must verify its own evidence.** Do not rely on the plan having been built
  correctly; re-check the condition immediately before acting, and mark the catalogue entry
  `NeedsEvidence = $true` so `-All` cannot select it.

Where a repair acts on a specific object rather than a whole category, pass that object through the
finding's `Data` — `services.fix` does this with `Data.Service` — so the repair's scope comes from
the diagnosis rather than from a hard-coded list.

Please run `tests\Invoke-MDTests.ps1` before opening a pull request, and add a case for what you
changed.

---

## Licence

MIT. See [LICENSE](LICENSE).

This tool is not affiliated with or endorsed by Microsoft. Configuration Manager, SCCM and MECM are
Microsoft products; this is an independent utility for administering them.
