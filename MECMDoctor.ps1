#Requires -Version 5.1
<#
    ===========================================================================
     MECM Client Wizard  --  MECMDoctor.ps1
    ---------------------------------------------------------------------------
     An open-source troubleshooting utility for Microsoft Endpoint Configuration
     Manager (MECM / SCCM / ConfigMgr) clients.

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
    [Parameter(Position = 0)]
    [ValidateSet('diagnose', 'repair', 'logs', 'bundle', 'reinstall', 'help', 'version')]
    [string] $Command = 'diagnose',

    # Repair tier. Safe = reversible; Standard = rebuilds regenerable state;
    # Aggressive = destructive, always confirmed unless -Force.
    # Left unset, `repair` uses the tier the diagnosis recommends.
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
    [switch] $Quiet,

    # Show the low-level [ .. ] diagnostic lines on screen.
    [Alias('DebugOutput')]
    [switch] $Trace
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is much faster without it

$script:MDVersion = '1.1.0'

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
    Write-MDLine '  mecmdoctor <command> [options]' -Color 'Cyan'
    Write-MDLine ''
    Write-MDLine '  Or directly:' -Color 'Gray'
    Write-MDLine '  powershell -ExecutionPolicy Bypass -File .\MECMDoctor.ps1 <command> [options]' -Color 'Gray'

    Write-MDSection 'Commands'
    Write-MDLine ''
    $commands = @(
        [pscustomobject]@{ Name = 'diagnose';  What = 'Read-only health check. Changes nothing. This is the default.' }
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
        [pscustomobject]@{ Flag = '-Level <tier>';   What = 'Safe | Standard | Aggressive. Default: whatever the diagnosis recommends.' }
        [pscustomobject]@{ Flag = '-DryRun';         What = 'Show what would happen, change nothing. Aliased to -WhatIf.' }
        [pscustomobject]@{ Flag = '-Force';          What = 'Answer yes to every confirmation, including the repair gate. For unattended runs.' }
        [pscustomobject]@{ Flag = '-Only <ids>';     What = 'Run only these repair actions, ignoring tier and diagnosis.' }
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
        [pscustomobject]@{ Flag = '-Quiet';          What = 'Less console chatter. The transcripts stay complete.' }
        [pscustomobject]@{ Flag = '-Trace';          What = 'Show the low-level diagnostic lines on screen.' }
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
# Main
# ---------------------------------------------------------------------------

# Version and help need no logging setup or elevation.
if ($Command -eq 'version') {
    Write-Host ("mecmdoctor {0}" -f $script:MDVersion)
    exit 0
}

Initialize-MDConsole -LogDirectory $LogDirectory -NoColor:$NoColor -Quiet:$Quiet -DebugOutput:$Trace -Tag $Command

if ($Command -eq 'help') {
    Show-MDHelp
    exit 0
}

$exitCode = 0

try {
    $facts = Get-MDHostFacts
    Write-MDBanner -Version $script:MDVersion -Command $Command -Facts $facts

    if (-not (Test-MDAdmin)) {
        Write-MDWarn 'Not running elevated. Many checks will return incomplete results and no repair can be applied.'
        Write-MDDetail -Text 'Re-run using mecmdoctor.bat, which requests elevation automatically.' -Bullet '> ' -Color 'DarkYellow'

        # Read-only commands can still produce something useful; repairs cannot.
        if ($Command -in @('repair', 'reinstall')) {
            Write-MDFail 'Refusing to attempt repairs without administrative rights.'
            Write-MDFooter -ExitNote 'aborted: not elevated'
            exit 4
        }
    }

    Write-MDSection 'Client discovery'
    $clientInfo = Get-MDClientInfo

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

    $findings      = @()
    $repairResults = @()
    $summary       = $null

    switch ($Command) {

        # -------------------------------------------------------------------
        'diagnose' {
            $findings = Invoke-MDDiagnose -ClientInfo $clientInfo -SkipLogParsing:$SkipLogs `
                                          -LogDays $Days -LogWarnings:$IncludeWarnings
            $summary  = Write-MDSummary -Findings $findings

            if     ($summary.Fail -gt 0) { $exitCode = 2 }
            elseif ($summary.Warn -gt 0) { $exitCode = 1 }
        }

        # -------------------------------------------------------------------
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

        # -------------------------------------------------------------------
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

            # The tier: the operator's if they named one, otherwise whatever the
            # diagnosis concluded. -Only names the actions outright, so nothing
            # about it is the diagnosis's recommendation and it is not framed
            # as one.
            $usingOnly          = ($Only -and @($Only).Count -gt 0)
            $effectiveLevel     = $Level
            $levelFromDiagnosis = $false

            if (-not $script:MDLevelExplicit -and -not $usingOnly -and $summary -and $summary.Recommended) {
                $effectiveLevel     = $summary.Recommended
                $levelFromDiagnosis = $true
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

                # ---- the gate --------------------------------------------------
                # Nothing below this point runs until the operator has said yes.
                # -DryRun skips it because nothing is changed either way.
                if (-not $DryRun) {
                    Write-MDSection 'Confirmation'
                    Write-MDLine ''

                    $question = if ($levelFromDiagnosis) {
                        'Diagnosis recommends {0} repairs. Continue?' -f $effectiveLevel
                    } else {
                        'Run {0} repair action(s) at the {1} tier on {2}. Continue?' -f @($plan).Count, $effectiveLevel, $env:COMPUTERNAME
                    }

                    # No -DefaultYes: a bare Enter, or a Read-Host that returns
                    # nothing because stdin is not a console, must not start
                    # repairs. Unattended runs say so explicitly with -Force.
                    $proceed = Read-MDConfirm -Question $question -Force:$Force

                    # Destructive actions are agreed to separately, and each one
                    # asks again for itself when it runs.
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

        # -------------------------------------------------------------------
        'bundle' {
            # A bundle is a diagnosis plus everything that makes the diagnosis
            # interpretable by someone who is not sitting at this machine.
            $findings = Invoke-MDDiagnose -ClientInfo $clientInfo -SkipLogParsing:$SkipLogs `
                                          -LogDays $Days -LogWarnings:$IncludeWarnings
            $summary  = Write-MDSummary -Findings $findings

            Write-MDSection 'Support bundle'
            Write-MDLine ''

            $zip = New-MDSupportBundle -ClientInfo $clientInfo -Findings $findings -HostFacts $facts `
                                       -OutputPath $BundlePath -Version $script:MDVersion -SkipLogs:$SkipLogs

            Write-MDLine ''
            if ($zip -and (Test-Path -LiteralPath $zip)) {
                $zipSize = (Get-Item -LiteralPath $zip).Length
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

        # -------------------------------------------------------------------
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

    # ---- optional JSON export ---------------------------------------------
    if ($Json) {
        Write-MDSection 'Report export'
        [void](Export-MDReport -Path $Json -ClientInfo $clientInfo -Findings $findings `
                               -RepairResults $repairResults -HostFacts $facts `
                               -Command $Command -Version $script:MDVersion)
    }

    $note = switch ($exitCode) {
        0 { 'healthy / completed' }
        1 { 'completed with warnings' }
        2 { 'problems found' }
        3 { 'one or more repair actions failed' }
        4 { 'could not produce the requested output' }
        default { 'completed' }
    }
    Write-MDFooter -ExitNote ('exit {0} - {1}' -f $exitCode, $note)
}
catch {
    # Anything that escapes every local handler lands here. Print it properly
    # rather than letting PowerShell dump a raw stack trace on the operator.
    Write-MDLine ''
    Write-MDFail ('Unhandled error: {0}' -f $_.Exception.Message)
    Write-MDDetail -Text $_.ScriptStackTrace -Bullet '| '
    Write-MDFooter -ExitNote 'aborted: unhandled error'
    $exitCode = 4
}

exit $exitCode
