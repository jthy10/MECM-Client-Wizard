#Requires -Version 5.1
<#
    ===========================================================================
     MECM Client Wizard  --  MECMDoctor.ps1
    ---------------------------------------------------------------------------
     An open-source troubleshooting utility for Microsoft Endpoint Configuration
     Manager (MECM / SCCM / ConfigMgr) clients.

       mecmdoctor               the menu: pick a command, answer a few
                                questions, watch it run, pick the next thing
       mecmdoctor diagnose      read-only health check of the whole client
       mecmdoctor repair        diagnose, explain, confirm, then repair
       mecmdoctor logs          parse C:\Windows\CCM\Logs and translate errors
       mecmdoctor bundle        build a support ZIP for someone else to read
       mecmdoctor reinstall     remove and reinstall the client
       mecmdoctor help          full usage

     Everything the tool does is written to the console AND to two transcripts:
     a plain-text one and a CMTrace-formatted one, both under
     %ProgramData%\MECMDoctor\Logs.

    ---------------------------------------------------------------------------
     LAYOUT

       MECMDoctor.ps1        this file - argument handling and orchestration
       mecmdoctor.bat        launcher: bypasses execution policy, self-elevates
       lib\Console.ps1       output rendering and logging engine
       lib\Common.ps1        shared helpers, the Finding object, client discovery
       lib\ErrorCatalog.ps1  error code and message translation tables
       lib\LogParser.ps1     CCM log reading and interpretation
       lib\Checks.ps1        all diagnostics (read-only)
       lib\Repairs.ps1       all repair actions (the only code that writes)
       lib\Report.ps1        summary rendering and JSON export
       lib\Bundle.ps1        the support bundle
       lib\Menu.ps1          the interactive menu and its option wizards

     ClientReinstall.ps1     OPTIONAL. Drop your own reinstall script beside
                             this file and mecmdoctor uses it instead of its
                             built-in fallback. See ClientReinstall.example.ps1.

    ---------------------------------------------------------------------------
     WHAT THIS TOOL WILL NOT DO

       * It never resets the client identity. No repair deletes SMSCFG.INI or
         the SMS certificate store, because that gives the device a new client
         GUID and orphans its history in the console. Restarting CcmExec makes
         the client re-register under the identity it already has.
       * It never reboots.
       * It never resets the WMI repository on weak evidence. Repository size
         alone is a warning, never a repair, and wmi.reset re-verifies the
         repository itself before it will run.

    ---------------------------------------------------------------------------
     EXIT CODES

       0   healthy, or all repairs applied successfully
       1   warnings only
       2   one or more failures found
       3   a repair action failed
       4   could not run (not elevated, missing library files, bad arguments)

    ---------------------------------------------------------------------------
     LICENCE: MIT. See LICENSE.
    ===========================================================================
#>

[CmdletBinding()]
param(
    # ---- what to do --------------------------------------------------------

    # The command to run. Positional so "MECMDoctor.ps1 diagnose" just works.
    # Left off entirely you get the menu - unless there is no console to draw
    # it on, in which case a diagnosis is run instead.
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'diagnose', 'repair', 'logs', 'bundle', 'reinstall', 'help', 'version')]
    [string] $Command = 'menu',

    # Repair tier. Safe = reversible; Standard = rebuilds regenerable state;
    # Aggressive = destructive, always confirmed unless -Force.
    # Left unset, `repair` uses the tier the diagnosis recommends - which is
    # capped at Standard, so only naming Aggressive here reaches it.
    [ValidateSet('Safe', 'Standard', 'Aggressive')]
    [string] $Level = 'Standard',

    # Run only these repair action ids, regardless of tier or diagnosis.
    # Use "mecmdoctor help" to see the list.
    [string[]] $Only,

    # Run every repair at the chosen tier, not just the ones the diagnosis
    # actually implicated. Actions that require evidence (wmi.reset) are still
    # excluded - name them with -Only if you really mean it.
    [switch] $All,

    # Skip the diagnosis pass before repairing. Only meaningful with -Only/-All.
    [switch] $NoDiagnose,

    # Re-run the diagnosis after repairing, to show what actually changed.
    [switch] $Verify,

    # ---- safety ------------------------------------------------------------

    # Answer yes to every confirmation, including the "continue into repairs?"
    # gate. Required for unattended runs.
    [switch] $Force,

    # Show what would happen and change nothing.
    [Alias('WhatIf')]
    [switch] $DryRun,

    # ---- scope -------------------------------------------------------------

    # How many days of CCM logs to scan.
    [ValidateRange(1, 90)]
    [int] $Days = 7,

    # Include warnings from the logs, not just errors.
    [switch] $IncludeWarnings,

    # Skip the log parsing pass (much faster on a machine with huge logs).
    # For `bundle`, also leaves the CCM logs out of the ZIP.
    [switch] $SkipLogs,

    # ---- output ------------------------------------------------------------

    # Where the transcripts go.
    [string] $LogDirectory = (Join-Path $env:ProgramData 'MECMDoctor\Logs'),

    # Also write a machine-readable JSON report to this path.
    [string] $Json,

    # Where `bundle` writes its ZIP. A folder, or a full path ending in .zip.
    # Default: %ProgramData%\MECMDoctor\Bundles.
    [string] $BundlePath,

    [switch] $NoColor,

    # Trim the running commentary from the screen: checks that passed, step
    # headings, progress lines. Warnings, failures, the summary and both
    # transcripts are untouched.
    [switch] $Quiet,

    # Show the low-level [ .. ] diagnostic lines on screen.
    [Alias('DebugOutput')]
    [switch] $Trace,

    # Menu only: never clear the screen, so the whole session stays in the
    # scrollback where it can be read back or copied out.
    [switch] $NoClear
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is much faster without it

$script:MDVersion = '1.2.0'

# Whether the operator actually chose a tier. Left alone, `repair` follows the
# tier the diagnosis recommends rather than a hard-coded default.
$script:MDLevelExplicit = $PSBoundParameters.ContainsKey('Level')


# ---------------------------------------------------------------------------
# Load the library. Order matters: Console first (everything logs), then
# Common (everything uses the helpers), then the rest.
# ---------------------------------------------------------------------------
$script:MDRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$libRoot       = Join-Path $script:MDRoot 'lib'

$libFiles = @(
    'Console.ps1'
    'Common.ps1'
    'ErrorCatalog.ps1'
    'LogParser.ps1'
    'Checks.ps1'
    'Repairs.ps1'
    'Report.ps1'
    'Bundle.ps1'
    'Menu.ps1'
)

foreach ($file in $libFiles) {
    $path = Join-Path $libRoot $file
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("FATAL: required library file is missing: {0}" -f $path) -ForegroundColor Red
        Write-Host  'Copy the whole folder, not just MECMDoctor.ps1.' -ForegroundColor Red
        exit 4
    }
    try {
        . $path
    }
    catch {
        Write-Host ("FATAL: could not load {0}" -f $path) -ForegroundColor Red
        Write-Host  $_.Exception.Message -ForegroundColor Red
        exit 4
    }
}


# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
function Show-MDHelp {
    Write-MDBanner -Version $script:MDVersion -Command 'help'

    Write-MDSection 'Usage'
    Write-MDLine ''
    Write-MDLine '  mecmdoctor                      the menu' -Color 'Cyan'
    Write-MDLine '  mecmdoctor <command> [options]  straight to one command' -Color 'Cyan'
    Write-MDLine ''
    Write-MDLine '  Or directly:' -Color 'Gray'
    Write-MDLine '  powershell -ExecutionPolicy Bypass -File .\MECMDoctor.ps1 <command> [options]' -Color 'Gray'
    Write-MDLine ''
    Write-MDDetail -Indent 2 -Text @(
        'With no command at all you get a menu: pick what to do, answer a few questions about how, watch it run, then pick the next thing. Every menu run prints the command line that would have produced it, so the menu is also how you learn the flags below.'
        'A session with no console - a scheduled task, an MECM script deployment, a remote shell - has nobody to answer a menu, so it runs a diagnosis instead of waiting at a prompt.'
    )

    Write-MDSection 'Commands'
    Write-MDLine ''
    $commands = @(
        [pscustomobject]@{ Name = 'menu';      What = 'The interactive menu. This is what you get when you name no command.' }
        [pscustomobject]@{ Name = 'diagnose';  What = 'Read-only health check. Changes nothing.' }
        [pscustomobject]@{ Name = 'repair';    What = 'Diagnose, explain what is recommended and why, ask, then repair.' }
        [pscustomobject]@{ Name = 'logs';      What = 'Parse the CCM logs and translate every error found.' }
        [pscustomobject]@{ Name = 'bundle';    What = 'Diagnose, then build a timestamped support ZIP for someone else to read.' }
        [pscustomobject]@{ Name = 'reinstall'; What = 'Remove and reinstall the client (uses your ClientReinstall.ps1 if present).' }
        [pscustomobject]@{ Name = 'help';      What = 'This text.' }
        [pscustomobject]@{ Name = 'version';   What = 'Print the version and exit.' }
    )
    Write-MDTable -Rows $commands -Indent 2 -Columns @(
        @{ Header = 'COMMAND'; Property = 'Name'; Width = 12 }
        @{ Header = 'WHAT IT DOES'; Property = 'What'; Width = 84 }
    )

    Write-MDSection 'How repair works'
    Write-MDLine ''
    Write-MDDetail -Indent 2 -Text @(
        '1. It runs the full diagnosis first.'
        '2. It prints the findings, then the repairs those findings implicated and which finding asked for each.'
        '3. It asks whether to continue at the tier the diagnosis recommends - "Diagnosis recommends Standard repairs. Continue?"'
        '4. Nothing runs until you answer yes. The default is no, so a bare Enter cancels. -Force answers yes for unattended runs; -DryRun skips the question because nothing is changed.'
        '5. Destructive actions ask again, individually, with their own explanation of what the action costs.'
        ''
        'Passing -Level yourself overrides the recommendation. Leaving it off lets the diagnosis choose.'
    )

    Write-MDSection 'Repair tiers'
    Write-MDLine ''
    Write-MDKeyValue -Key 'Safe'       -Value 'Start and re-enable an implicated service, restart CcmExec, clear the cache and failed BITS' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'jobs, trigger client cycles, gpupdate, run ccmeval.' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'Reversible. Safe on a production machine during the day.' -KeyWidth 12
    Write-MDLine ''
    Write-MDKeyValue -Key 'Standard'   -Value 'Everything in Safe, plus: salvage the WMI repository, quarantine corrupt Registry.pol,' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'purge and re-download policy, reset Windows Update, repair the client.' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'Rebuilds state that Windows or the client regenerates by itself.' -KeyWidth 12
    Write-MDLine ''
    Write-MDKeyValue -Key 'Aggressive' -Value 'Everything above, plus: reset the WMI repository, clear Group Policy state,' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'rebuild the security database, reinstall the client.' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'DESTRUCTIVE. Every action prompts individually unless -Force is given.' -KeyWidth 12

    Write-MDSection 'Options'
    Write-MDLine ''
    $options = @(
        [pscustomobject]@{ Flag = '-Level <tier>';   What = 'Safe | Standard | Aggressive. Default: what the diagnosis recommends, never Aggressive.' }
        [pscustomobject]@{ Flag = '-DryRun';         What = 'Show what would happen, change nothing. Aliased to -WhatIf.' }
        [pscustomobject]@{ Flag = '-Force';          What = 'Answer yes to every confirmation, including the repair gate. For unattended runs.' }
        [pscustomobject]@{ Flag = '-Only <ids>';     What = 'Run only these repair actions, ignoring tier and diagnosis. Unknown id = error.' }
        [pscustomobject]@{ Flag = '-All';            What = 'Run every repair at the tier except those that require evidence.' }
        [pscustomobject]@{ Flag = '-NoDiagnose';     What = 'Skip the diagnosis pass before repairing.' }
        [pscustomobject]@{ Flag = '-Verify';         What = 'Re-run the diagnosis after repairing.' }
        [pscustomobject]@{ Flag = '-Days <n>';       What = 'How many days of CCM logs to scan. Default: 7.' }
        [pscustomobject]@{ Flag = '-IncludeWarnings';What = 'Report log warnings as well as errors.' }
        [pscustomobject]@{ Flag = '-SkipLogs';       What = 'Skip log parsing; also leaves CCM logs out of a bundle. Much faster.' }
        [pscustomobject]@{ Flag = '-Json <path>';    What = 'Also write a machine-readable JSON report.' }
        [pscustomobject]@{ Flag = '-BundlePath';     What = 'Where bundle writes its ZIP: a folder, or a full path ending in .zip.' }
        [pscustomobject]@{ Flag = '-LogDirectory';   What = 'Where transcripts go. Default: %ProgramData%\MECMDoctor\Logs.' }
        [pscustomobject]@{ Flag = '-NoColor';        What = 'Plain output, for piping to a file.' }
        [pscustomobject]@{ Flag = '-Quiet';          What = 'Drop passing checks, step headings and progress lines from the screen. Warnings, failures, the summary and both transcripts are untouched.' }
        [pscustomobject]@{ Flag = '-Trace';          What = 'Show the low-level diagnostic lines on screen.' }
        [pscustomobject]@{ Flag = '-NoClear';        What = 'Menu only: never clear the screen, so the whole session stays in the scrollback.' }
    )
    Write-MDTable -Rows $options -Indent 2 -Columns @(
        @{ Header = 'OPTION'; Property = 'Flag'; Width = 18 }
        @{ Header = 'MEANING'; Property = 'What'; Width = 78 }
    )

    Write-MDSection 'Repair action ids (for -Only)'
    Write-MDLine ''
    $actions = foreach ($entry in ($script:MDRepairCatalog | Sort-Object { $_.Order })) {
        [pscustomobject]@{
            Id   = $entry.Id
            Tier = $entry.Level
            Note = $(if ($entry.NeedsEvidence) { 'needs evidence - excluded from -All' } else { '' })
        }
    }
    Write-MDTable -Rows $actions -Indent 2 -Columns @(
        @{ Header = 'ACTION ID'; Property = 'Id'; Width = 24 }
        @{ Header = 'TIER'; Property = 'Tier'; Width = 12 }
        @{ Header = 'NOTE'; Property = 'Note'; Width = 40 }
    )

    Write-MDSection 'Examples'
    Write-MDLine ''
    $examples = @(
        'mecmdoctor                                        # the menu'
        'mecmdoctor diagnose'
        'mecmdoctor diagnose -SkipLogs -Json C:\Temp\client.json'
        'mecmdoctor logs -Days 14 -IncludeWarnings'
        'mecmdoctor bundle'
        'mecmdoctor bundle -BundlePath C:\Temp'
        'mecmdoctor repair                                 # asks before it repairs anything'
        'mecmdoctor repair -DryRun'
        'mecmdoctor repair -Level Safe'
        'mecmdoctor repair -Level Standard -Verify'
        'mecmdoctor repair -Only wmi.salvage,policy.reset'
        'mecmdoctor repair -Level Aggressive -Force        # unattended, destructive'
        'mecmdoctor reinstall'
    )
    foreach ($e in $examples) { Write-MDLine ('  ' + $e) -Color 'Cyan' }

    Write-MDSection 'What mecmdoctor will not do'
    Write-MDLine ''
    Write-MDDetail -Indent 2 -Bullet '- ' -Text @(
        'It never resets the client identity. No repair deletes SMSCFG.INI or the SMS certificate store: that assigns a new client GUID and orphans the device history in the console. Restarting CcmExec re-registers the client under the identity it already has.'
        'It never reboots. A pending reboot is reported and explained; scheduling it is your call.'
        'It never resets the WMI repository because the repository is large. A reset needs winmgmt to report the repository inconsistent AND independent health checks to agree, and it re-verifies and asks again before it runs.'
        'It never changes the startup configuration of W32Time, TrustedInstaller, msiserver, wuauserv or BITS just because it differs from an expected value. Those are repaired only when a diagnosed failure is correlated with them.'
    )

    Write-MDSection 'Custom reinstall script'
    Write-MDLine ''
    Write-MDDetail -Indent 2 -Text @(
        'Put a file named ClientReinstall.ps1 next to MECMDoctor.ps1 (or in its parent folder, or in the'
        'working directory) and mecmdoctor runs yours instead of its built-in fallback.'
        ''
        'If your script declares any of the parameters -SiteCode, -ManagementPoint, -InstallPath or'
        '-LogDirectory, mecmdoctor fills them in from what it discovered. A script with no parameters'
        'at all works fine too. A non-zero exit code is treated as a failure.'
        ''
        'See ClientReinstall.example.ps1 in the repository for a working starting point.'
    )
    Write-MDLine ''
}
# ---------------------------------------------------------------------------
# The diagnosis pass
# ---------------------------------------------------------------------------
function Invoke-MDDiagnose {
<#
    .SYNOPSIS
        Runs every check in order and returns the combined findings.
    .DESCRIPTION
        Ordered cheapest-and-most-fundamental first, so that when something
        basic is broken you see it before the tool spends two minutes probing
        things that were never going to work.
#>
    param(
        [Parameter(Mandatory)] $ClientInfo,
        [switch] $SkipLogParsing,
        [int]    $LogDays = 7,
        [switch] $LogWarnings
    )

    $findings = @()

    Write-MDSection 'Diagnostics'

    # Thirteen checks below; log parsing is its own section, not a step here.
    Set-MDStepTotal 13

    Write-MDStep 'Prerequisites'
    $findings += Test-MDPrerequisites

    Write-MDStep 'Client installation'
    $findings += Test-MDClientInstall -ClientInfo $ClientInfo

    Write-MDStep 'Services'
    $findings += Test-MDServices

    Write-MDStep 'WMI health'
    $findings += Test-MDWmiHealth -ClientInfo $ClientInfo

    Write-MDStep 'Client registration'
    $findings += Test-MDClientRegistration -ClientInfo $ClientInfo

    Write-MDStep 'Certificates'
    $findings += Test-MDCertificates -ClientInfo $ClientInfo

    Write-MDStep 'Policy'
    $findings += Test-MDPolicy -ClientInfo $ClientInfo

    Write-MDStep 'Software updates'
    $findings += Test-MDSoftwareUpdates -ClientInfo $ClientInfo

    Write-MDStep 'Content and cache'
    $findings += Test-MDContent -ClientInfo $ClientInfo

    Write-MDStep 'Pending reboot'
    $findings += Test-MDPendingReboot -ClientInfo $ClientInfo

    Write-MDStep 'Group Policy'
    $findings += Test-MDGroupPolicy

    Write-MDStep 'Client health evaluation'
    $findings += Test-MDClientHealth -ClientInfo $ClientInfo

    Write-MDStep 'Disk and time'
    $findings += Test-MDSystemHealth -ClientInfo $ClientInfo

    if (-not $SkipLogParsing -and $ClientInfo.LogPath) {
        Write-MDSection ('CCM log analysis (last {0} day(s))' -f $LogDays)
        $minType = 3
        if ($LogWarnings) { $minType = 2 }
        $findings += Invoke-MDLogReport -LogRoot $ClientInfo.LogPath -Days $LogDays -MinType $minType
    }
    elseif (-not $SkipLogParsing) {
        Write-MDSection 'CCM log analysis'
        Write-MDSkip 'No client log directory is known, so there is nothing to parse.'
    }

    # Last, because it needs everything above it: a conditional Windows service
    # is only a fault when something else is failing because of it.
    Write-MDSection 'Service correlation'
    $findings = Resolve-MDServiceCorrelation -Findings $findings

    $findings
}


# ---------------------------------------------------------------------------
# One run
# ---------------------------------------------------------------------------
function Invoke-MDCommand {
<#
    .SYNOPSIS
        Runs one command with one set of options.
    .DESCRIPTION
        The command line and the menu both end up here, so there is exactly
        one implementation of what each command means.

        The result is recorded in $script:MDLastRun rather than returned: a
        stray line of pipeline output from anywhere in the library would
        otherwise be indistinguishable from an exit code.
    .PARAMETER Options
        The options hashtable built by New-MDRunOptions - one key per
        command-line parameter.
    .PARAMETER ClientInfo
        Client discovery results, when the caller already has fresh ones.
        Discovered here when it does not.
#>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        $ClientInfo,
        $HostFacts
    )

    # Unpacked into locals so that the body below reads exactly like the
    # parameter block it used to read from.
    $Command         = $Options.Command
    $Level           = $Options.Level
    $levelExplicit   = [bool]$Options.LevelExplicit
    $Only            = @($Options.Only)
    $All             = [bool]$Options.All
    $NoDiagnose      = [bool]$Options.NoDiagnose
    $Verify          = [bool]$Options.Verify
    $Force           = [bool]$Options.Force
    $DryRun          = [bool]$Options.DryRun
    $Days            = [int]$Options.Days
    $IncludeWarnings = [bool]$Options.IncludeWarnings
    $SkipLogs        = [bool]$Options.SkipLogs
    $Json            = $Options.Json
    $BundlePath      = $Options.BundlePath

    $exitCode      = 0
    $blocked       = $false
    $blockedReason = 'not elevated'
    $findings      = @()
    $repairResults = @()
    $summary       = $null
    $repairSummary = $null
    $bundleZip     = $null

    try {
        $facts = $HostFacts
        if (-not $facts) { $facts = Get-MDHostFacts }

        Write-MDBanner -Version $script:MDVersion -Command $Command -Facts $facts

        if (-not (Test-MDAdmin)) {
            Write-MDWarn 'Not running elevated. Many checks will return incomplete results and no repair can be applied.'
            Write-MDDetail -Text 'Re-run using mecmdoctor.bat, which requests elevation automatically.' -Bullet '> ' -Color 'DarkYellow'

            # Read-only commands can still produce something useful; repairs cannot.
            if ($Command -in @('repair', 'reinstall')) {
                Write-MDFail 'Refusing to attempt repairs without administrative rights.'
                $exitCode = 4
                $blocked  = $true
            }
        }

        # A repair on top of an in-flight ccmsetup produces a half-installed
        # client: we would stop CcmExec, salvage WMI and reset policy
        # underneath an installer still writing to all three.
        #
        # This is the one gate -Force does not answer. There is no unattended
        # scenario in which racing the installer is the right call, and the
        # cost of the alternative is only that the operator waits.
        if (-not $blocked -and $Command -in @('repair', 'reinstall') -and -not $DryRun) {
            $inFlight = Get-MDCcmSetupInFlight
            if ($inFlight.Running) {
                Write-MDFail 'ccmsetup is running: a client install or upgrade is in flight right now.'
                Write-MDDetail -Bullet '> ' -Color 'DarkYellow' -Text @(
                    ('{0} ccmsetup process(es) running{1}.' -f $inFlight.Processes,
                        $(if ($inFlight.StartedAt) { ', oldest started ' + (Format-MDAge $inFlight.StartedAt) } else { '' }))
                    'Repairing on top of it stops CcmExec, salvages WMI and resets policy underneath the installer, which reliably leaves a half-installed client behind.'
                    ('Watch {0}\ccmsetup\Logs\ccmsetup.log until it reports an exit code, then run this again.' -f $env:windir)
                    'This refusal is deliberately not overridable with -Force. Add -DryRun if you want to see the plan without touching anything.'
                )
                $exitCode      = 4
                $blocked       = $true
                $blockedReason = 'a client install is already in flight'
            }
        }

        # A typo in -Only used to select nothing, plan nothing, and print
        # "Nothing to repair at this tier" - which reads as "this machine is
        # fine" and is the most misleading thing the tool could say. Fail on it
        # instead. Get-MDRepairPlan throws on the same input as a backstop for
        # every other caller; this exists so the operator sees a sentence
        # rather than a stack trace.
        if (-not $blocked -and $Only -and @($Only).Count -gt 0) {
            $knownIds   = @($script:MDRepairCatalog | ForEach-Object { $_.Id })
            $unknownIds = @($Only | Where-Object { $knownIds -notcontains $_ })

            if ($unknownIds.Count -gt 0) {
                Write-MDFail ('Unknown repair action id(s): {0}' -f ($unknownIds -join ', '))
                Write-MDDetail -Bullet '> ' -Color 'DarkYellow' -Text @(
                    'Nothing was run. -Only names actions exactly, and an unrecognised name would otherwise select nothing and look like a clean bill of health.'
                    ('Valid ids: {0}' -f (($knownIds | Sort-Object) -join ', '))
                )
                $exitCode      = 4
                $blocked       = $true
                $blockedReason = 'unknown -Only action id'
            }
        }

        if (-not $blocked) {

            Write-MDSection 'Client discovery'
            if (-not $ClientInfo) { $ClientInfo = Get-MDClientInfo }
            $clientInfo = $ClientInfo

            Write-MDKeyValue -Key 'Client installed'  -Value $(if ($clientInfo.Installed) { 'yes' } else { 'NO' })
            Write-MDKeyValue -Key 'Install path'      -Value $clientInfo.InstallPath
            Write-MDKeyValue -Key 'Client version'    -Value $clientInfo.Version
            Write-MDKeyValue -Key 'Log directory'     -Value $clientInfo.LogPath
            Write-MDKeyValue -Key 'Assigned site'     -Value $clientInfo.SiteCode
            Write-MDKeyValue -Key 'Management point'  -Value $clientInfo.ManagementPoint
            Write-MDKeyValue -Key 'Client ID'         -Value $clientInfo.ClientId
            Write-MDKeyValue -Key 'Cache location'    -Value $clientInfo.CacheLocation
            Write-MDKeyValue -Key 'Cache size (MB)'   -Value $clientInfo.CacheSizeMB
            Write-MDKeyValue -Key 'HTTPS-only client' -Value $(if ($clientInfo.HttpsOnly) { 'yes' } else { 'no' })

            switch ($Command) {

                # -----------------------------------------------------------
                'diagnose' {
                    $findings = Invoke-MDDiagnose -ClientInfo $clientInfo -SkipLogParsing:$SkipLogs `
                                                  -LogDays $Days -LogWarnings:$IncludeWarnings
                    $summary  = Write-MDSummary -Findings $findings

                    if     ($summary.Fail -gt 0) { $exitCode = 2 }
                    elseif ($summary.Warn -gt 0) { $exitCode = 1 }
                }

                # -----------------------------------------------------------
                'logs' {
                    if (-not $clientInfo.LogPath) {
                        Write-MDFail 'No client log directory could be located, so there is nothing to parse.'
                        $exitCode = 2
                    }
                    else {
                        Write-MDSection ('CCM log analysis (last {0} day(s))' -f $Days)
                        $minType = 3
                        if ($IncludeWarnings) { $minType = 2 }

                        $findings = Invoke-MDLogReport -LogRoot $clientInfo.LogPath -Days $Days -MinType $minType
                        $summary  = Write-MDSummary -Findings $findings

                        if     ($summary.Fail -gt 0) { $exitCode = 2 }
                        elseif ($summary.Warn -gt 0) { $exitCode = 1 }
                    }
                }

                # -----------------------------------------------------------
                'repair' {
                    if (-not $NoDiagnose) {
                        $findings = Invoke-MDDiagnose -ClientInfo $clientInfo -SkipLogParsing:$SkipLogs `
                                                      -LogDays $Days -LogWarnings:$IncludeWarnings
                        $summary  = Write-MDSummary -Findings $findings
                    }
                    else {
                        Write-MDSection 'Diagnostics'
                        Write-MDSkip 'Skipped (-NoDiagnose). Repairs will be selected from -Only / -All alone.'
                    }

                    # The tier: the operator's if they named one, otherwise whatever
                    # the diagnosis concluded. -Only names the actions outright, so
                    # nothing about it is the diagnosis's recommendation and it is
                    # not framed as one.
                    $usingOnly          = ($Only -and @($Only).Count -gt 0)
                    $effectiveLevel     = $Level
                    $levelFromDiagnosis = $false

                    if (-not $levelExplicit -and -not $usingOnly -and $summary -and $summary.Recommended) {
                        $effectiveLevel     = $summary.Recommended
                        $levelFromDiagnosis = $true

                        # Belt and braces on top of the cap in Write-MDSummary.
                        # A diagnosis never escalates to a destructive tier on
                        # its own, whatever a summary object happens to say -
                        # Aggressive is reached only by the operator typing
                        # -Level or naming an action with -Only.
                        if ($effectiveLevel -eq 'Aggressive') { $effectiveLevel = 'Standard' }
                    }

                    $context = New-MDRepairContext -ClientInfo $clientInfo -Level $effectiveLevel `
                                                   -ScriptRoot $script:MDRoot -Findings $findings `
                                                   -Force:$Force -DryRun:$DryRun

                    $plan = Get-MDRepairPlan -Level $effectiveLevel -Findings $findings -Only $Only -All:$All

                    Write-MDSection ('Repair plan  (tier: {0})' -f $effectiveLevel)
                    Write-MDLine ''

                    if (-not $plan -or @($plan).Count -eq 0) {
                        Write-MDOk 'Nothing to repair at this tier. The diagnosis implicated no repair actions.'
                        Write-MDDetail -Text 'Use -All to run every action at this tier anyway, or -Only <id> to force a specific one.' -Indent 4
                    }
                    else {
                        # Which repairs, and - just as importantly - why each one.
                        Write-MDRepairRationale -Plan $plan -Findings $findings -Context $context

                        if ($levelFromDiagnosis) {
                            Write-MDLine ''
                            Write-MDInfo 'Tier chosen by the diagnosis. Pass -Level to override it.'
                        }

                        Write-MDLine ''
                        if ($DryRun) {
                            Write-MDInfo 'Dry run: every action below reports what it would do and changes nothing.'
                        }

                        $aggressive = @($plan | Where-Object { $_.Level -eq 'Aggressive' })
                        $proceed    = $true

                        # ---- the gate ------------------------------------------
                        # Nothing below this point runs until the operator has said
                        # yes. -DryRun skips it because nothing is changed either
                        # way. Reaching here from the menu changes nothing: the menu
                        # chooses the options, this question decides the run.
                        if (-not $DryRun) {
                            Write-MDSection 'Confirmation'
                            Write-MDLine ''

                            $question = if ($levelFromDiagnosis) {
                                'Diagnosis recommends {0} repairs. Continue?' -f $effectiveLevel
                            } else {
                                'Run {0} repair action(s) at the {1} tier on {2}. Continue?' -f @($plan).Count, $effectiveLevel, $env:COMPUTERNAME
                            }

                            # No -DefaultYes: a bare Enter, or a Read-Host that
                            # returns nothing because stdin is not a console, must
                            # not start repairs. Unattended runs say so explicitly
                            # with -Force.
                            $proceed = Read-MDConfirm -Question $question -Force:$Force

                            # Destructive actions are agreed to separately, and each
                            # one asks again for itself when it runs.
                            if ($proceed -and $aggressive.Count -gt 0) {
                                Write-MDLine ''
                                Write-MDWarn ('This plan contains {0} DESTRUCTIVE action(s):' -f $aggressive.Count)
                                foreach ($a in $aggressive) { Write-MDDetail -Text $a.Id -Indent 6 -Bullet '! ' -Color 'DarkYellow' }
                                Write-MDDetail -Indent 6 -Color 'DarkYellow' -Text @(
                                    'These discard state that does not come back on its own, and can require a reboot or a client reinstall afterwards.'
                                    'Each one explains what it costs and asks again before it does anything.'
                                )
                                Write-MDLine ''
                                $proceed = Read-MDConfirm -Question ('Include the destructive action(s) in this run on {0}?' -f $env:COMPUTERNAME) -Force:$Force
                            }
                        }

                        if (-not $proceed) {
                            Write-MDSkip 'Repair cancelled by the operator. Nothing was changed.'
                        }
                        else {
                            Write-MDSection 'Repair actions'
                            $repairResults = Invoke-MDRepairPlan -Plan $plan -Context $context

                            $repairSummary = Write-MDRepairSummary -Results $repairResults
                            if ($repairSummary.Failed -gt 0) { $exitCode = 3 }
                        }
                    }

                    # -Verify re-reads the machine so the operator can see the delta
                    # rather than taking the repair results on trust.
                    if ($Verify -and -not $DryRun) {
                        Write-MDSection 'Verification pass'
                        Write-MDInfo 'Some repairs are asynchronous - registration, policy download and update scans can take 15+ minutes to settle.'

                        $clientInfo = Get-MDClientInfo
                        $findings   = Invoke-MDDiagnose -ClientInfo $clientInfo -SkipLogParsing `
                                                        -LogDays $Days -LogWarnings:$IncludeWarnings
                        $summary    = Write-MDSummary -Findings $findings

                        if ($exitCode -eq 0) {
                            if     ($summary.Fail -gt 0) { $exitCode = 2 }
                            elseif ($summary.Warn -gt 0) { $exitCode = 1 }
                        }
                    }
                }

                # -----------------------------------------------------------
                'bundle' {
                    # A bundle is a diagnosis plus everything that makes the
                    # diagnosis interpretable by someone who is not sitting at
                    # this machine.
                    $findings = Invoke-MDDiagnose -ClientInfo $clientInfo -SkipLogParsing:$SkipLogs `
                                                  -LogDays $Days -LogWarnings:$IncludeWarnings
                    $summary  = Write-MDSummary -Findings $findings

                    Write-MDSection 'Support bundle'
                    Write-MDLine ''

                    $zip = New-MDSupportBundle -ClientInfo $clientInfo -Findings $findings -HostFacts $facts `
                                               -OutputPath $BundlePath -Version $script:MDVersion -SkipLogs:$SkipLogs

                    Write-MDLine ''
                    if ($zip -and (Test-Path -LiteralPath $zip)) {
                        $bundleZip = $zip
                        $zipSize   = (Get-Item -LiteralPath $zip).Length
                        Write-MDOk ('Support bundle written: {0}' -f $zip)
                        Write-MDKeyValue -Key 'Bundle' -Value $zip -Indent 4
                        Write-MDKeyValue -Key 'Size'   -Value (Format-MDBytes $zipSize) -Indent 4
                        Write-MDDetail -Indent 4 -Text 'Read README.txt inside the ZIP for what it contains and what was deliberately left out.'

                        if     ($summary.Fail -gt 0) { $exitCode = 2 }
                        elseif ($summary.Warn -gt 0) { $exitCode = 1 }
                    }
                    else {
                        Write-MDFail 'The support bundle could not be produced.'
                        $exitCode = 4
                    }
                }

                # -----------------------------------------------------------
                'reinstall' {
                    Write-MDSection 'Client reinstall'

                    $context = New-MDRepairContext -ClientInfo $clientInfo -Level 'Aggressive' `
                                                   -ScriptRoot $script:MDRoot -Force:$Force -DryRun:$DryRun

                    $custom = Find-MDCustomReinstallScript -ScriptRoot $script:MDRoot
                    if ($custom) {
                        Write-MDOk ("Custom reinstall script found: {0}" -f $custom)
                    }
                    else {
                        Write-MDWarn 'No ClientReinstall.ps1 found. Falling back to ccmsetup.exe with the discovered site parameters.'
                        Write-MDDetail -Text 'Searched the script folder, its parent, and the current directory.' -Bullet '- '
                        Write-MDDetail -Text 'Copy ClientReinstall.example.ps1 to ClientReinstall.ps1 and edit it to control exactly how the client is installed.' -Bullet '> ' -Color 'DarkYellow'
                    }

                    Set-MDStepTotal 1
                    Write-MDStep 'reinstall the Configuration Manager client'

                    $result        = Repair-MDClientReinstall -Context $context
                    $result | Write-MDRepairResult
                    $repairResults = @($result)

                    $repairSummary = Write-MDRepairSummary -Results $repairResults
                    if ($repairSummary.Failed -gt 0) { $exitCode = 3 }
                }
            }

            # ---- optional JSON export -------------------------------------
            if ($Json) {
                Write-MDSection 'Report export'
                [void](Export-MDReport -Path $Json -ClientInfo $clientInfo -Findings $findings `
                                       -RepairResults $repairResults -HostFacts $facts `
                                       -Command $Command -Version $script:MDVersion)
            }
        }

        $note = if ($blocked) { 'aborted: ' + $blockedReason } else {
            switch ($exitCode) {
                0 { 'healthy / completed' }
                1 { 'completed with warnings' }
                2 { 'problems found' }
                3 { 'one or more repair actions failed' }
                4 { 'could not produce the requested output' }
                default { 'completed' }
            }
        }
        Write-MDFooter -ExitNote ('exit {0} - {1}' -f $exitCode, $note)
    }
    catch {
        # Anything that escapes every local handler lands here. Print it
        # properly rather than letting PowerShell dump a raw stack trace on the
        # operator - and, in the menu, do not take the whole session down with
        # one failed command.
        Write-MDLine ''
        Write-MDFail ('Unhandled error: {0}' -f $_.Exception.Message)
        Write-MDDetail -Text $_.ScriptStackTrace -Bullet '| '
        Write-MDFooter -ExitNote 'aborted: unhandled error'
        $exitCode = 4
    }

    $script:MDLastRun = [pscustomobject]@{
        Command       = $Command
        ExitCode      = $exitCode
        Summary       = $summary
        RepairSummary = $repairSummary
        Findings      = $findings
        RepairResults = $repairResults
        BundlePath    = $bundleZip
        ClientInfo    = $ClientInfo
        Transcript    = $script:MDLog.PlainPath
    }
}


# ---------------------------------------------------------------------------
# The menu loop
# ---------------------------------------------------------------------------
function Invoke-MDMenuLoop {
<#
    .SYNOPSIS
        Draws the menu, runs whatever it produces, and comes back for more.
    .DESCRIPTION
        Every command still goes through Invoke-MDCommand with an options
        hashtable, so a menu-driven run and a command-line run are the same
        run. The loop's only extra jobs are keeping the machine facts current
        and giving each command its own transcript.

        Leaves the exit code in $script:MDMenuExitCode.
    .PARAMETER Options
        The command line the menu was started with, used as its defaults.
#>
    param([Parameter(Mandatory)][hashtable] $Options)

    Initialize-MDMenu -Defaults $Options -LogDirectory $LogDirectory -ScriptRoot $script:MDRoot -NoClear:$NoClear

    $script:MDMenuExitCode = 0
    $pending = $null       # a command handed over by the previous screen

    while ($true) {

        # Host facts and client state are re-read after anything that could
        # have changed them, and not otherwise: on a broken client the WMI
        # queries behind them are the slow part of drawing this menu.
        if ($script:MDMenu.NeedsRefresh) {
            $script:MDMenu.Facts        = Get-MDHostFacts
            $script:MDMenu.ClientInfo   = Get-MDClientInfo
            $script:MDMenu.NeedsRefresh = $false
        }

        $choice  = $pending
        $pending = $null
        if (-not $choice) { $choice = Show-MDMainMenu }

        if ($choice -eq $script:MDMenuQuit) { break }

        if ($choice -eq 'help') {
            Clear-MDScreen
            Show-MDHelp
            Read-MDMenuPause
            continue
        }

        if ($choice -eq 'logfolder') {
            Open-MDFolder -Path $LogDirectory
            Read-MDMenuPause
            continue
        }

        if ($choice -eq 'elevate') {
            if (Invoke-MDElevate -ScriptRoot $script:MDRoot) { break }
            continue
        }

        # ---- the wizard for the chosen command ----------------------------
        $request = Get-MDMenuRunRequest -Command $choice

        if ($request -isnot [hashtable]) {
            if ($request -eq $script:MDMenuQuit) { break }
            if ($request -eq $script:MDMenuBack) { continue }

            # A wizard is allowed to hand the operator somewhere better than
            # where they were going: reinstall offers a diagnosis instead.
            $pending = $request
            continue
        }

        # What was chosen this time becomes the defaults for next time.
        $script:MDMenu.Defaults = $request

        # ---- run it --------------------------------------------------------
        # Each command gets its own pair of transcripts, named for it, exactly
        # as though it had been run from the command line.
        Clear-MDScreen
        Initialize-MDConsole -LogDirectory $LogDirectory -NoColor:$NoColor -Quiet:$Quiet `
                             -DebugOutput:$Trace -Tag $request.Command

        Write-MDLine ''
        Write-MDInfo ('Running:  ' + (Get-MDCommandLine -Options $request))

        # Host facts are re-read per run rather than reused from the menu: they
        # carry the start time and the uptime, and a banner that reports when
        # the menu opened rather than when the command ran is a lie in the
        # transcript.
        Invoke-MDCommand -Options $request -ClientInfo $script:MDMenu.ClientInfo | Out-Null

        $run = $script:MDLastRun
        if ($run) { $script:MDMenuExitCode = [int]$run.ExitCode }

        # Anything that wrote to the machine invalidates what the menu shows.
        if ($request.Command -in @('repair', 'reinstall') -and -not $request.DryRun) {
            $script:MDMenu.NeedsRefresh = $true
        }

        $next = Show-MDPostRun -Options $request -Run $run

        # Menu navigation does not belong in a finished run's transcript, so
        # the engine goes back to console-only until the next command starts.
        Initialize-MDConsole -NoColor:$NoColor -Quiet:$Quiet -DebugOutput:$Trace -Tag 'menu'

        if ($next -eq $script:MDMenuQuit) { break }
        if ($next -ne 'menu') { $pending = $next }
    }

    Clear-MDScreen
    Write-MDLine ''
    Write-MDLine '  mecmdoctor - finished. Everything it did is in the transcripts.' -Color $script:MDColors.Accent
    if ($LogDirectory) { Write-MDKeyValue -Key 'Log folder' -Value $LogDirectory }
    Write-MDLine ''
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Version needs no logging setup, no elevation and no menu.
if ($Command -eq 'version') {
    Write-Host ("mecmdoctor {0}" -f $script:MDVersion)
    exit 0
}

# The command line, as an options object. The menu edits a copy of this; the
# command line runs it as it stands.
$cliOptions = New-MDRunOptions -Command $Command -From @{
    Level           = $Level
    LevelExplicit   = $script:MDLevelExplicit
    Only            = @($Only)
    All             = [bool]$All
    NoDiagnose      = [bool]$NoDiagnose
    Verify          = [bool]$Verify
    Force           = [bool]$Force
    DryRun          = [bool]$DryRun
    Days            = $Days
    IncludeWarnings = [bool]$IncludeWarnings
    SkipLogs        = [bool]$SkipLogs
    Json            = $Json
    BundlePath      = $BundlePath
}

# A scheduled task, an MECM script deployment or a remote session has nobody
# to answer a menu. Do the useful thing instead of hanging on a prompt.
$menuFellBack = $false
if ($Command -eq 'menu' -and -not (Test-MDMenuCapable)) {
    $Command            = 'diagnose'
    $cliOptions.Command = 'diagnose'
    $menuFellBack       = $true
}

if ($Command -eq 'menu') {
    # No log directory: menu navigation is not a run, and should not leave a
    # transcript of its own behind. Each command opens its own when it starts.
    Initialize-MDConsole -NoColor:$NoColor -Quiet:$Quiet -DebugOutput:$Trace -Tag 'menu'
    Invoke-MDMenuLoop -Options $cliOptions | Out-Null
    exit $script:MDMenuExitCode
}

Initialize-MDConsole -LogDirectory $LogDirectory -NoColor:$NoColor -Quiet:$Quiet -DebugOutput:$Trace -Tag $Command

if ($Command -eq 'help') {
    Show-MDHelp
    exit 0
}

if ($menuFellBack) {
    Write-MDInfo 'No interactive console, so the menu was skipped and a diagnosis was run instead.'
}

Invoke-MDCommand -Options $cliOptions | Out-Null

$exitCode = 0
if ($script:MDLastRun) { $exitCode = [int]$script:MDLastRun.ExitCode }
exit $exitCode
