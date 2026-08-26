# MECM Client Wizard

A dedicated, open-source troubleshooting utility for Microsoft Endpoint Configuration Manager
(MECM / SCCM / ConfigMgr) clients.

It finds out **why** a client is unhealthy, explains the failure in plain English, and then applies
targeted repairs — in tiers, so you decide how much risk you are taking.

```
mecmdoctor diagnose
mecmdoctor repair
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
- **It separates safe from destructive.** Repairs are tiered, everything destructive prompts, and
  `-DryRun` shows you the whole plan before you commit to any of it.
- **It never hides what it did.** Every run produces a plain-text transcript *and* a CMTrace-format
  copy, and anything it deletes is backed up first.

---

## Quick start

```
git clone https://github.com/jthy10/MECM-Client-Wizard.git
cd MECM-Client-Wizard
mecmdoctor diagnose
```

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
| `mecmdoctor diagnose` | Read-only health check across thirteen areas, plus log analysis. Changes nothing. This is the default. |
| `mecmdoctor repair` | Diagnose, then apply exactly the repairs the diagnosis implicated. |
| `mecmdoctor logs` | Parse `C:\Windows\CCM\Logs` and translate every error found. |
| `mecmdoctor reinstall` | Remove and reinstall the client, using your `ClientReinstall.ps1` when you supply one. |
| `mecmdoctor help` | Full usage, including every repair action id. |
| `mecmdoctor version` | Print the version. |

---

## What it detects

| Area | Checks |
|---|---|
| **Prerequisites** | Elevation, PowerShell version, 32-bit-shell-on-64-bit-OS redirection traps |
| **Client install** | Presence, version, install path, log directory, an install already in flight |
| **Services** | `CcmExec`, `Winmgmt`, `RpcSs`, `BITS`, `wuauserv`, `CryptSvc`, `msiserver`, `Schedule`, `gpsvc`, `Dnscache`, `W32Time`, `TrustedInstaller` — state *and* start mode, because a `Disabled` service is a different problem from a stopped one |
| **Broken WMI** | Repository consistency, reachability of `root\cimv2` and all six client namespaces, repository size, provider errors from the WMI-Activity log |
| **Client registration** | Site assignment, client GUID, `SMSCFG.INI`, confirmed registration in `ClientIDManagerStartup.log`, MP name resolution, live HTTP/HTTPS probe of the MP `mplist` endpoint |
| **Certificates** | The `LocalMachine\SMS` store, expiry, missing or inaccessible private keys, client-auth certificate for HTTPS-only clients |
| **Policy failures** | Applied vs requested policy body counts, and the last run time of nine client cycles |
| **Stuck updates** | Updates parked in an in-progress evaluation state, WSUS Group Policy conflict, dual-scan configuration, Windows Update datastore size |
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

---

## Repair tiers

`repair` runs a diagnosis first and then applies **only the actions the findings implicated**. That
is what makes it safe to run on a machine that turns out to be healthy: it will do nothing.

| Tier | Actions | Risk |
|---|---|---|
| **Safe** | Correct service start modes and start what should be running · restart `CcmExec` · clear failed and stalled BITS jobs · clear the content cache · `gpupdate /force` · trigger the client action cycles · force a software update scan · run `ccmeval` | Reversible. Fine on a production machine during business hours. |
| **Standard** *(default)* | Everything above, plus: salvage the WMI repository · quarantine corrupt `Registry.pol` · purge and re-download client policy · re-register the client · reset Windows Update components · repair the client | Rebuilds state that Windows or the client regenerates by itself. |
| **Aggressive** | Everything above, plus: reset the WMI repository · clear Group Policy state · rebuild `secedit.sdb` · uninstall and reinstall the client | **Destructive.** Prompts for each action unless `-Force`. |

Every tier includes the ones below it. Useful flags:

```powershell
mecmdoctor repair -DryRun                        # show the whole plan, change nothing
mecmdoctor repair -Level Safe                    # stay reversible
mecmdoctor repair -Level Standard -Verify        # repair, then re-diagnose to show the delta
mecmdoctor repair -Only wmi.salvage,policy.reset # run exactly these, ignore the tier
mecmdoctor repair -All -Level Safe               # every Safe action, not just implicated ones
mecmdoctor repair -Level Aggressive -Force       # unattended and destructive
```

Run `mecmdoctor help` for the full list of repair action ids.

### What it will not do

- **It never reboots.** A pending reboot is reported and explained; scheduling it is your call.
- **It never guesses at install parameters.** With no `ClientReinstall.ps1` and no discoverable site
  code, `reinstall` tells you so instead of inventing a command line.
- **It backs up before it deletes.** `SMSCFG.INI`, `Registry.pol`, `secedit.sdb` and the Group Policy
  state registry keys are all copied to `%ProgramData%\MECMDoctor\Backups\<timestamp>` first.
- **It renames rather than deletes** `SoftwareDistribution` and `catroot2`, so the old datastore is
  still there if anyone needs to look at it.

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

---

## Output

Every run writes to the console **and** to two files under `%ProgramData%\MECMDoctor\Logs`:

- `MECMDoctor_<command>_<timestamp>.log` — the plain-text transcript
- `MECMDoctor_<command>_<timestamp>.cmtrace.log` — the same content in CMTrace format, so you can
  open it in the same viewer you already use for the CCM logs

Console output uses fixed-width ASCII status tags (`[ OK ]`, `[WARN]`, `[FAIL]`, `[INFO]`, `[SKIP]`,
`[ >> ]`) rather than Unicode glyphs, because legacy console code pages are still common on exactly
the kind of endpoint this tool gets pointed at. Add `-NoColor` when piping to a file.

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
| `4` | Could not run — not elevated, missing library files, bad arguments |

These make it straightforward to run as a Configuration Manager script, a Configuration Item, or a
scheduled task, and act on the result.

---

## Options

| Option | Meaning |
|---|---|
| `-Level <tier>` | `Safe` \| `Standard` \| `Aggressive`. Default `Standard`. |
| `-DryRun` | Show what would happen and change nothing. Aliased to `-WhatIf`. |
| `-Force` | Answer yes to every confirmation. Required for unattended destructive runs. |
| `-Only <ids>` | Run only these repair actions, ignoring tier and diagnosis. |
| `-All` | Run every repair at the tier, not just the implicated ones. |
| `-NoDiagnose` | Skip the diagnosis pass before repairing. |
| `-Verify` | Re-run the diagnosis after repairing. |
| `-Days <n>` | How many days of CCM logs to scan. Default `7`. |
| `-IncludeWarnings` | Report log warnings as well as errors. |
| `-SkipLogs` | Skip log parsing entirely. Much faster. |
| `-Json <path>` | Also write a machine-readable JSON report. |
| `-LogDirectory <path>` | Where transcripts go. |
| `-NoColor` | Plain output, for piping to a file. |
| `-Quiet` | Less console chatter; the transcripts stay complete. |
| `-Trace` | Show the low-level diagnostic lines on screen. |

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
  Report.ps1                summary rendering and JSON export
ClientReinstall.example.ps1 template for your own reinstall script
```

Checks never modify the machine; repairs are confined to `Repairs.ps1`. That split is the main
design rule, and it is what makes `diagnose` safe to run anywhere without thinking about it.

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

Issues and pull requests welcome.

---

## Licence

MIT. See [LICENSE](LICENSE).

This tool is not affiliated with or endorsed by Microsoft. Configuration Manager, SCCM and MECM are
Microsoft products; this is an independent utility for administering them.
