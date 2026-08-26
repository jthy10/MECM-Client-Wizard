#Requires -Version 5.1
<#
    ===========================================================================
     MECM Client Wizard  --  MECMDoctor.ps1
    ---------------------------------------------------------------------------
     An open-source troubleshooting utility for Microsoft Endpoint Configuration
     Manager (MECM / SCCM / ConfigMgr) clients.

       mecmdoctor diagnose      read-only health check of the whole client
       mecmdoctor repair        apply targeted, tiered repairs
       mecmdoctor logs          parse C:\Windows\CCM\Logs and translate errors
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

     ClientReinstall.ps1     OPTIONAL. Drop your own reinstall script beside
                             this file and mecmdoctor uses it instead of its
                             built-in fallback. See ClientReinstall.example.ps1.

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
    [ValidateSet('diagnose', 'repair', 'logs', 'reinstall', 'help', 'version')]
    [string] $Command = 'diagnose',

    # Repair tier. Safe = reversible; Standard = rebuilds regenerable state;
    # Aggressive = destructive, always confirmed unless -Force.
    [ValidateSet('Safe', 'Standard', 'Aggressive')]
    [string] $Level = 'Standard',

    # Run only these repair action ids, regardless of tier or diagnosis.
    # Use "mecmdoctor help" to see the list.
    [string[]] $Only,

    # Run every repair at the chosen tier, not just the ones the diagnosis
    # actually implicated.
    [switch] $All,

    # Skip the diagnosis pass before repairing. Only meaningful with -Only/-All.
    [switch] $NoDiagnose,

    # Re-run the diagnosis after repairing, to show what actually changed.
    [switch] $Verify,

    # ---- safety ------------------------------------------------------------

    # Answer yes to every confirmation. Required for unattended destructive runs.
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
    [switch] $SkipLogs,

    # ---- output ------------------------------------------------------------

    # Where the transcripts go.
    [string] $LogDirectory = (Join-Path $env:ProgramData 'MECMDoctor\Logs'),

    # Also write a machine-readable JSON report to this path.
    [string] $Json,

    [switch] $NoColor,
    [switch] $Quiet,

    # Show the low-level [ .. ] diagnostic lines on screen.
    [Alias('DebugOutput')]
    [switch] $Trace
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is much faster without it

$script:MDVersion = '1.0.0'


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
        [pscustomobject]@{ Name = 'repair';    What = 'Diagnose, then apply the repairs the diagnosis implicated.' }
        [pscustomobject]@{ Name = 'logs';      What = 'Parse the CCM logs and translate every error found.' }
        [pscustomobject]@{ Name = 'reinstall'; What = 'Remove and reinstall the client (uses your ClientReinstall.ps1 if present).' }
        [pscustomobject]@{ Name = 'help';      What = 'This text.' }
        [pscustomobject]@{ Name = 'version';   What = 'Print the version and exit.' }
    )
    Write-MDTable -Rows $commands -Indent 2 -Columns @(
        @{ Header = 'COMMAND'; Property = 'Name'; Width = 12 }
        @{ Header = 'WHAT IT DOES'; Property = 'What'; Width = 84 }
    )

    Write-MDSection 'Repair tiers'
    Write-MDLine ''
    Write-MDKeyValue -Key 'Safe'       -Value 'Restart services, clear the cache and failed BITS jobs, trigger client cycles, gpupdate.' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'Reversible. Safe on a production machine during the day.' -KeyWidth 12
    Write-MDLine ''
    Write-MDKeyValue -Key 'Standard'   -Value 'Everything in Safe, plus: salvage the WMI repository, quarantine corrupt Registry.pol,' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'purge and re-download policy, re-register the client, reset Windows Update, repair the client.' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'Rebuilds state that Windows or the client regenerates by itself. This is the default.' -KeyWidth 12
    Write-MDLine ''
    Write-MDKeyValue -Key 'Aggressive' -Value 'Everything above, plus: reset the WMI repository, clear Group Policy state,' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'rebuild the security database, reinstall the client.' -KeyWidth 12
    Write-MDKeyValue -Key ''           -Value 'DESTRUCTIVE. Always prompts unless -Force is given.' -KeyWidth 12

    Write-MDSection 'Options'
    Write-MDLine ''
    $options = @(
        [pscustomobject]@{ Flag = '-Level <tier>';   What = 'Safe | Standard | Aggressive. Default: Standard.' }
        [pscustomobject]@{ Flag = '-DryRun';         What = 'Show what would happen, change nothing. Aliased to -WhatIf.' }
        [pscustomobject]@{ Flag = '-Force';          What = 'Answer yes to every confirmation. Needed for unattended destructive runs.' }
        [pscustomobject]@{ Flag = '-Only <ids>';     What = 'Run only these repair actions, ignoring tier and diagnosis.' }
        [pscustomobject]@{ Flag = '-All';            What = 'Run every repair at the tier, not just the implicated ones.' }
        [pscustomobject]@{ Flag = '-NoDiagnose';     What = 'Skip the diagnosis pass before repairing.' }
        [pscustomobject]@{ Flag = '-Verify';         What = 'Re-run the diagnosis after repairing.' }
        [pscustomobject]@{ Flag = '-Days <n>';       What = 'How many days of CCM logs to scan. Default: 7.' }
        [pscustomobject]@{ Flag = '-IncludeWarnings';What = 'Report log warnings as well as errors.' }
        [pscustomobject]@{ Flag = '-SkipLogs';       What = 'Skip log parsing entirely. Much faster.' }
        [pscustomobject]@{ Flag = '-Json <path>';    What = 'Also write a machine-readable JSON report.' }
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
        [pscustomobject]@{ Id = $entry.Id; Tier = $entry.Level }
    }
    Write-MDTable -Rows $actions -Indent 2 -Columns @(
        @{ Header = 'ACTION ID'; Property = 'Id'; Width = 24 }
        @{ Header = 'TIER'; Property = 'Tier'; Width = 12 }
    )

    Write-MDSection 'Examples'
    Write-MDLine ''
    $examples = @(
        'mecmdoctor diagnose'
        'mecmdoctor diagnose -SkipLogs -Json C:\Temp\client.json'
        'mecmdoctor logs -Days 14 -IncludeWarnings'
        'mecmdoctor repair -DryRun'
        'mecmdoctor repair -Level Safe'
        'mecmdoctor repair -Level Standard -Verify'
        'mecmdoctor repair -Only wmi.salvage,policy.reset'
        'mecmdoctor repair -Level Aggressive -Force        # unattended, destructive'
        'mecmdoctor reinstall'
    )
    foreach ($e in $examples) { Write-MDLine ('  ' + $e) -Color 'Cyan' }

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

            # Client discovery is re-read after a diagnosis in case a check
            # populated something we did not know at the start.
            $context = New-MDRepairContext -ClientInfo $clientInfo -Level $Level `
                                           -ScriptRoot $script:MDRoot -Force:$Force -DryRun:$DryRun

            $plan = Get-MDRepairPlan -Level $Level -Findings $findings -Only $Only -All:$All

            Write-MDSection ('Repair plan  (tier: {0})' -f $Level)
            Write-MDLine ''

            if (-not $plan -or @($plan).Count -eq 0) {
                Write-MDOk 'Nothing to repair at this tier. The diagnosis implicated no repair actions.'
                Write-MDDetail -Text 'Use -All to run every action at this tier anyway, or -Only <id> to force a specific one.' -Indent 4
            }
            else {
                $planRows = foreach ($p in @($plan)) {
                    [pscustomobject]@{ Order = $p.Order; Id = $p.Id; Tier = $p.Level }
                }
                Write-MDTable -Rows $planRows -Indent 2 -Columns @(
                    @{ Header = '#';         Property = 'Order'; Width = 4 }
                    @{ Header = 'ACTION ID'; Property = 'Id';    Width = 24 }
                    @{ Header = 'TIER';      Property = 'Tier';  Width = 12 }
                )

                Write-MDLine ''
                if ($DryRun) {
                    Write-MDInfo 'Dry run: every action below reports what it would do and changes nothing.'
                }

                $hasAggressive = @($plan | Where-Object { $_.Level -eq 'Aggressive' }).Count -gt 0
                $proceed = $true

                if ($hasAggressive -and -not $DryRun) {
                    Write-MDLine ''
                    Write-MDWarn 'This plan contains DESTRUCTIVE actions. Each one prompts individually as well.'
                    $proceed = Read-MDConfirm -Question ('Proceed with {0} repair action(s) on {1}?' -f @($plan).Count, $env:COMPUTERNAME) -Force:$Force
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
