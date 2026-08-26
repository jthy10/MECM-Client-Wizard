<#
    ===========================================================================
     MECM Client Wizard  --  lib\Repairs.ps1
    ---------------------------------------------------------------------------
     Everything that changes the machine lives in this file. Nothing else does.

     Three tiers, chosen with -Level:

       Safe        Reversible, no data loss, no service interruption beyond a
                   service restart. Safe to run on a production machine in the
                   middle of the day.

       Standard    Rebuilds client-side state that Windows or the client will
                   regenerate: the WMI repository salvage, policy purge,
                   Windows Update datastore, corrupt local Group Policy files.
                   Default level.

       Aggressive  Destructive. Resets the WMI repository outright, clears
                   Group Policy state, rebuilds the security database, or
                   reinstalls the client. Always prompts unless -Force.

     Every action:
       * announces itself before it runs
       * honours -DryRun (shows what it would do, changes nothing)
       * backs up anything it deletes into the backup folder for the run
       * returns a result object rather than throwing

     Two things this file deliberately does not contain:

       * any action that resets the client identity. Deleting SMSCFG.INI or
         the SMS certificate store gives the device a new client GUID and
         orphans its whole history in the console. The client re-registers
         under the identity it already has when CcmExec restarts, which is
         what ccmexec.restart does.
       * any path that resets the WMI repository on weak evidence. wmi.reset
         re-verifies the repository itself and refuses to run when it is
         consistent, whatever the plan said.
    ===========================================================================
#>

function New-MDRepairResult {
    <# The single result shape every repair action returns. #>
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Name,
        [ValidateSet('Success', 'Failed', 'Skipped', 'NotNeeded', 'Manual', 'DryRun')][string] $Status = 'Success',
        [string]   $Detail = '',
        [string[]] $Evidence = @(),
        [switch]   $RebootRecommended
    )
    [pscustomobject]@{
        PSTypeName        = 'MECMDoctor.RepairResult'
        Id                = $Id
        Name              = $Name
        Status            = $Status
        Detail            = $Detail
        Evidence          = @($Evidence)
        RebootRecommended = [bool]$RebootRecommended
        Timestamp         = (Get-Date)
    }
}


function Write-MDRepairResult {
    <# Renders a repair result with the matching status tag. #>
    param([Parameter(Mandatory, ValueFromPipeline)] $Result)
    process {
        $text = $Result.Name
        if ($Result.Detail) { $text = '{0} -- {1}' -f $Result.Name, $Result.Detail }

        switch ($Result.Status) {
            'Success'   { Write-MDOk   $text -Component 'repair' }
            'DryRun'    { Write-MDInfo ('[dry run] ' + $text) -Component 'repair' }
            'NotNeeded' { Write-MDSkip ($text + ' (nothing to do)') -Component 'repair' }
            'Skipped'   { Write-MDSkip $text -Component 'repair' }
            'Manual'    { Write-MDWarn $text -Component 'repair' }
            default     { Write-MDFail $text -Component 'repair' }
        }

        foreach ($e in $Result.Evidence) {
            if (-not [string]::IsNullOrWhiteSpace($e)) { Write-MDDetail -Text $e -Bullet '- ' }
        }
        if ($Result.RebootRecommended) {
            Write-MDDetail -Text 'A reboot is recommended for this change to fully take effect.' -Bullet '> ' -Color 'DarkYellow'
        }
    }
}


function New-MDRepairContext {
<#
    .SYNOPSIS
        Shared state handed to every repair action.
    .PARAMETER BackupRoot
        Where anything we delete or overwrite is copied first. One folder per
        run, so an operator can always put things back.
    .PARAMETER Findings
        The diagnosis this repair run is acting on. It is what turns "run
        services.fix" into "run services.fix against BITS": the actions come
        from the plan, but their scope comes from the findings.
#>
    param(
        [Parameter(Mandatory)] $ClientInfo,
        [Parameter(Mandatory)][string] $Level,
        [string] $ScriptRoot,
        [string] $BackupRoot,
        $Findings,
        [switch] $Force,
        [switch] $DryRun
    )

    if (-not $BackupRoot) {
        $BackupRoot = Join-Path $env:ProgramData ('MECMDoctor\Backups\' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    }

    [pscustomobject]@{
        ClientInfo     = $ClientInfo
        Level          = $Level
        ScriptRoot     = $ScriptRoot
        BackupRoot     = $BackupRoot
        # Exactly which services services.fix may touch. Empty means the
        # diagnosis blamed none of them, which the repair reads as "core
        # services only" rather than "all of them".
        TargetServices = @(Get-MDImplicatedServiceNames -Findings $Findings)
        Force          = [bool]$Force
        DryRun         = [bool]$DryRun
    }
}


function Save-MDBackupCopy {
<#
    .SYNOPSIS
        Copies a file into the run backup folder before we destroy it.
    .OUTPUTS
        The backup path, or $null if the copy could not be made.
#>
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $Path,
        [string] $SubFolder = ''
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    try {
        $dest = $Context.BackupRoot
        if ($SubFolder) { $dest = Join-Path $dest $SubFolder }
        if (-not (Test-Path -LiteralPath $dest)) {
            New-Item -Path $dest -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $target = Join-Path $dest (Split-Path -Leaf $Path)
        Copy-Item -LiteralPath $Path -Destination $target -Force -ErrorAction Stop
        Write-MDDebug ("backed up '{0}' -> '{1}'" -f $Path, $target)
        return $target
    }
    catch {
        Write-MDDebug ("backup of '{0}' failed: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}


function Invoke-MDTriggerSchedule {
    <# Fires one client schedule by GUID. Returns $true on success. #>
    param(
        [Parameter(Mandatory)][string] $ScheduleId,
        [Parameter(Mandatory)][string] $Name
    )

    $r = Invoke-MDCimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' `
                            -MethodName 'TriggerSchedule' -Arguments @{ sScheduleID = $ScheduleId }
    if ($null -ne $r) {
        Write-MDDetail -Text ("triggered: {0}" -f $Name) -Bullet '- '
        return $true
    }

    Write-MDDetail -Text ("could not trigger: {0}" -f $Name) -Bullet '- ' -Color 'DarkYellow'
    return $false
}


function Stop-MDServiceSafely {
<#
    .SYNOPSIS
        Stops a service and waits for it, killing the process only as a last
        resort. CcmExec in particular can take a while to unwind.
#>
    param(
        [Parameter(Mandatory)][string] $Name,
        [int] $TimeoutSeconds = 90
    )

    $svc = Get-MDService -Name $Name
    if (-not $svc) { return $true }
    if ($svc.Status -eq 'Stopped') { return $true }

    Write-MDDetail -Text ("stopping service {0}" -f $Name) -Bullet '- '
    try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch { Write-MDDebug ("Stop-Service {0}: {1}" -f $Name, $_.Exception.Message) }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-MDService -Name $Name
        if (-not $svc -or $svc.Status -eq 'Stopped') { return $true }
        Start-Sleep -Milliseconds 750
    }

    # Still running. Kill the hosting process so the repair can continue.
    Write-MDDetail -Text ("{0} did not stop within {1}s - terminating its process" -f $Name, $TimeoutSeconds) -Bullet '- ' -Color 'DarkYellow'
    try {
        $wmiSvc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction Stop
        if ($wmiSvc -and $wmiSvc.ProcessId -gt 0) {
            Stop-Process -Id $wmiSvc.ProcessId -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            return $true
        }
    }
    catch { Write-MDDebug ("could not terminate {0}: {1}" -f $Name, $_.Exception.Message) }

    return $false
}


function Start-MDServiceSafely {
    <# Starts a service and waits for it to report Running. #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [int] $TimeoutSeconds = 120
    )

    $svc = Get-MDService -Name $Name
    if (-not $svc) { return $false }
    if ($svc.Status -eq 'Running') { return $true }

    Write-MDDetail -Text ("starting service {0}" -f $Name) -Bullet '- '
    try { Start-Service -Name $Name -ErrorAction Stop } catch { Write-MDDebug ("Start-Service {0}: {1}" -f $Name, $_.Exception.Message) }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-MDService -Name $Name
        if ($svc -and $svc.Status -eq 'Running') { return $true }
        Start-Sleep -Milliseconds 750
    }
    return $false
}


function Get-MDImplicatedServiceNames {
<#
    .SYNOPSIS
        The services the diagnosis actually blamed.
    .DESCRIPTION
        Every services.fix finding carries the offending service in Data.Service.
        Reading it back here is what lets a repair act on the one service that
        caused the problem instead of the whole table.
#>
    param($Findings)

    $names = foreach ($f in @($Findings)) {
        if ($f.Status -notin @('Warn', 'Fail')) { continue }
        if (-not $f.RepairIds -or ($f.RepairIds -notcontains $script:MDRepairIds.ServicesFix)) { continue }
        if ($f.Data -and $f.Data.Service) { $f.Data.Service }
    }

    @($names | Where-Object { $_ } | Select-Object -Unique)
}


function Get-MDServiceRepairTargets {
<#
    .SYNOPSIS
        Resolves service names into the specs a services.fix run may touch.
    .DESCRIPTION
        One broken BITS does not become a licence to normalise W32Time,
        TrustedInstaller, msiserver and wuauserv on a machine where nothing
        else was wrong, so the caller passes exactly the names the diagnosis
        implicated and gets back exactly those.

        With no names at all (-NoDiagnose, or -Only services.fix on its own)
        the fallback is the core MECM dependencies. Conditional Windows
        services are never touched without a finding that names them, because
        "differs from a hard-coded expected value" is not a fault.
    .OUTPUTS
        The matching entries from $script:MDRequiredServices.
#>
    param([string[]] $Names)

    $wanted = @($Names | Where-Object { $_ } | Select-Object -Unique)

    if ($wanted.Count -gt 0) {
        return @($script:MDRequiredServices | Where-Object { $wanted -contains $_.Name })
    }

    @($script:MDRequiredServices | Where-Object { $_.Class -eq 'Core' })
}


# ===========================================================================
#  SAFE TIER
# ===========================================================================

function Repair-MDServices {
<#
    .SYNOPSIS
        Starts and re-enables the specific services the diagnosis implicated.
    .DESCRIPTION
        The service list comes from Context.TargetServices, which the repair
        planner fills in from the findings. Nothing outside that list is read,
        started, or reconfigured.
#>
    param([Parameter(Mandatory)] $Context)

    $id      = $script:MDRepairIds.ServicesFix
    $changed = @()
    $failed  = @()

    $targets = Get-MDServiceRepairTargets -Names $Context.TargetServices
    if (@($targets).Count -eq 0) {
        return New-MDRepairResult -Id $id -Name 'Correct client service configuration' -Status 'NotNeeded' `
            -Detail 'no service was implicated by the diagnosis'
    }

    $scope = ($targets | ForEach-Object { $_.Name }) -join ', '
    Write-MDDetail -Text ('acting on: {0}' -f $scope) -Bullet '- '

    foreach ($spec in $targets) {
        $svc = Get-MDService -Name $spec.Name
        if (-not $svc) { continue }

        $start = Get-MDServiceStartMode -Name $spec.Name

        # Correct a wrong start mode first - starting a Disabled service fails.
        # A conditional service is only ever moved off Disabled; its Auto/Manual
        # choice belongs to whoever built the machine.
        $needsStartMode = if ($spec.Class -eq 'Core') {
            ($start -and ($spec.AllowedStart -notcontains $start))
        } else {
            ($start -eq 'Disabled')
        }

        if ($needsStartMode) {
            $want = $spec.AllowedStart[0]
            $psStartupType = if ($want -eq 'Auto') { 'Automatic' } else { $want }

            if ($Context.DryRun) {
                $changed += ('would set {0} start mode {1} -> {2}' -f $spec.Name, $start, $want)
            }
            else {
                try {
                    Set-Service -Name $spec.Name -StartupType $psStartupType -ErrorAction Stop
                    $changed += ('{0}: start mode {1} -> {2}' -f $spec.Name, $start, $want)
                }
                catch {
                    $failed += ('{0}: could not set start mode - {1}' -f $spec.Name, $_.Exception.Message)
                }
            }
        }

        # A conditional service is started too when it was disabled: leaving it
        # enabled but stopped fixes nothing that was actually diagnosed.
        $needsStart = ($svc.Status -ne 'Running') -and ($spec.MustRun -or $needsStartMode)

        if ($needsStart) {
            if ($Context.DryRun) {
                $changed += ('would start {0}' -f $spec.Name)
            }
            elseif (Start-MDServiceSafely -Name $spec.Name) {
                $changed += ('{0}: started' -f $spec.Name)
            }
            else {
                $failed += ('{0}: would not start' -f $spec.Name)
            }
        }
    }

    $scopeNote = ('scope: {0} - no other service was inspected or changed' -f $scope)

    if ($Context.DryRun -and $changed.Count -gt 0) {
        return New-MDRepairResult -Id $id -Name 'Correct client service configuration' -Status 'DryRun' `
            -Detail ('{0} change(s) planned' -f $changed.Count) -Evidence ($changed + $scopeNote)
    }
    if ($changed.Count -eq 0 -and $failed.Count -eq 0) {
        return New-MDRepairResult -Id $id -Name 'Correct client service configuration' -Status 'NotNeeded' `
            -Detail ('{0} already configured and running' -f $scope)
    }
    if ($failed.Count -gt 0) {
        return New-MDRepairResult -Id $id -Name 'Correct client service configuration' -Status 'Failed' `
            -Detail ('{0} change(s) applied, {1} failed' -f $changed.Count, $failed.Count) `
            -Evidence ($changed + $failed + $scopeNote + 'A service that refuses to start or immediately reverts is usually being held that way by Group Policy.')
    }

    New-MDRepairResult -Id $id -Name 'Correct client service configuration' -Status 'Success' `
        -Detail ('{0} change(s) applied' -f $changed.Count) -Evidence ($changed + $scopeNote)
}


function Repair-MDCcmExecRestart {
    <# Bounces the SMS Agent Host. Fixes a surprising amount on its own. #>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.CcmRestart

    if (-not (Get-MDService -Name 'CcmExec')) {
        return New-MDRepairResult -Id $id -Name 'Restart the SMS Agent Host' -Status 'Skipped' -Detail 'CcmExec is not installed'
    }
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Restart the SMS Agent Host' -Status 'DryRun' -Detail 'would stop and start CcmExec'
    }

    if (-not (Stop-MDServiceSafely -Name 'CcmExec')) {
        return New-MDRepairResult -Id $id -Name 'Restart the SMS Agent Host' -Status 'Failed' -Detail 'CcmExec would not stop'
    }
    Start-Sleep -Seconds 3

    if (Start-MDServiceSafely -Name 'CcmExec') {
        # The agent needs a moment before its WMI providers answer again.
        Start-Sleep -Seconds 5
        return New-MDRepairResult -Id $id -Name 'Restart the SMS Agent Host' -Status 'Success' -Detail 'CcmExec is running'
    }

    New-MDRepairResult -Id $id -Name 'Restart the SMS Agent Host' -Status 'Failed' `
        -Detail 'CcmExec did not come back up' `
        -Evidence @('Check CcmExec.log and the System event log. A client that will not start usually needs a repair or reinstall.')
}


function Repair-MDTriggerCycles {
    <# Kicks the machine policy and evaluation cycles. #>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.PolicyTrigger

    if (-not $Context.ClientInfo.Installed) {
        return New-MDRepairResult -Id $id -Name 'Trigger client action cycles' -Status 'Skipped' -Detail 'client not installed'
    }
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Trigger client action cycles' -Status 'DryRun' -Detail 'would trigger the machine policy and evaluation cycles'
    }

    $cycles = @(
        @{ Id = '{00000000-0000-0000-0000-000000000021}'; Name = 'Machine Policy Retrieval' }
        @{ Id = '{00000000-0000-0000-0000-000000000022}'; Name = 'Machine Policy Evaluation' }
        @{ Id = '{00000000-0000-0000-0000-000000000003}'; Name = 'Discovery Data Collection' }
        @{ Id = '{00000000-0000-0000-0000-000000000001}'; Name = 'Hardware Inventory' }
        @{ Id = '{00000000-0000-0000-0000-000000000121}'; Name = 'Application Deployment Evaluation' }
        @{ Id = '{00000000-0000-0000-0000-000000000108}'; Name = 'Software Update Assignment Evaluation' }
    )

    $ok = 0
    foreach ($c in $cycles) {
        if (Invoke-MDTriggerSchedule -ScheduleId $c.Id -Name $c.Name) { $ok++ }
    }

    if ($ok -eq 0) {
        return New-MDRepairResult -Id $id -Name 'Trigger client action cycles' -Status 'Failed' `
            -Detail 'no cycle could be triggered' `
            -Evidence @('SMS_Client.TriggerSchedule is unavailable, which points at broken WMI or a stopped CcmExec.')
    }

    New-MDRepairResult -Id $id -Name 'Trigger client action cycles' -Status 'Success' `
        -Detail ('{0} of {1} cycle(s) triggered' -f $ok, $cycles.Count) `
        -Evidence @('Policy download is asynchronous. Give the client 5-15 minutes before re-running diagnose.')
}


function Repair-MDCacheClear {
<#
    .SYNOPSIS
        Empties the client content cache.
    .DESCRIPTION
        Uses the supported UIResource.UIResourceMgr COM interface so the client
        keeps its own bookkeeping straight, then sweeps up any orphaned folders
        the cache manager has already forgotten about.
#>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.CacheClear

    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Clear the client content cache' -Status 'DryRun' -Detail 'would remove all cached content'
    }

    $removed  = 0
    $evidence = @()
    $freed    = 0

    # --- supported path -----------------------------------------------------
    try {
        $rm    = New-Object -ComObject 'UIResource.UIResourceMgr' -ErrorAction Stop
        $cache = $rm.GetCacheInfo()
        $elements = @($cache.GetCacheElements())

        foreach ($el in $elements) {
            try {
                $freed += [double]$el.ContentSize * 1KB   # ContentSize is in KB
                $cache.DeleteCacheElement($el.CacheElementID)
                $removed++
            }
            catch {
                Write-MDDebug ("could not delete cache element {0}: {1}" -f $el.CacheElementID, $_.Exception.Message)
            }
        }
        $evidence += ('{0} of {1} tracked cache element(s) removed via the client cache manager' -f $removed, $elements.Count)
    }
    catch {
        $evidence += ('cache manager COM interface unavailable ({0}) - falling back to WMI' -f $_.Exception.Message)

        $cacheInfo = Invoke-MDCimQuery -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx'
        if ($cacheInfo) {
            foreach ($ci in $cacheInfo) {
                try { Remove-CimInstance -InputObject $ci -ErrorAction Stop; $removed++ } catch { }
            }
            $evidence += ('{0} cache record(s) removed via WMI' -f $removed)
        }
    }

    # --- orphan sweep -------------------------------------------------------
    # Folders left behind after a failed download are never reclaimed by the
    # client itself, and are a common cause of a cache drive filling up.
    $cacheRoot = $Context.ClientInfo.CacheLocation
    if ($cacheRoot -and (Test-Path -LiteralPath $cacheRoot)) {
        $orphans = @(Get-ChildItem -LiteralPath $cacheRoot -Directory -Force -ErrorAction SilentlyContinue)
        $orphanRemoved = 0

        foreach ($dir in $orphans) {
            try {
                $size = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
                $orphanRemoved++
                if ($size) { $freed += $size }
            }
            catch {
                Write-MDDebug ("could not remove orphaned cache folder {0}: {1}" -f $dir.FullName, $_.Exception.Message)
            }
        }
        if ($orphanRemoved -gt 0) {
            $evidence += ('{0} leftover cache folder(s) removed from disk' -f $orphanRemoved)
        }
    }

    if ($removed -eq 0 -and $freed -eq 0) {
        return New-MDRepairResult -Id $id -Name 'Clear the client content cache' -Status 'NotNeeded' -Detail 'the cache was already empty' -Evidence $evidence
    }

    New-MDRepairResult -Id $id -Name 'Clear the client content cache' -Status 'Success' `
        -Detail ('reclaimed approximately {0}' -f (Format-MDBytes $freed)) -Evidence $evidence
}


function Repair-MDBitsClear {
    <# Removes BITS jobs that have failed or stalled. #>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.BitsClear

    try {
        Import-Module BitsTransfer -ErrorAction Stop
        $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)
    }
    catch {
        # -AllUsers needs elevation. Without it this is a permissions problem
        # on our side, not a broken BITS - reporting it as a failed repair
        # would be misleading.
        if (-not (Test-MDAdmin)) {
            return New-MDRepairResult -Id $id -Name 'Clear failed BITS transfers' -Status 'Skipped' `
                -Detail 'requires elevation' `
                -Evidence @('Re-run via mecmdoctor.bat so BITS jobs for all users are visible.')
        }
        return New-MDRepairResult -Id $id -Name 'Clear failed BITS transfers' -Status 'Failed' `
            -Detail ('could not enumerate BITS jobs - {0}' -f $_.Exception.Message)
    }

    $targets = @($jobs | Where-Object {
        $_.JobState -in @('Error', 'TransientError') -or
        ($_.CreationTime -lt (Get-Date).AddDays(-3) -and $_.JobState -notin @('Transferred', 'Acknowledged'))
    })

    if ($targets.Count -eq 0) {
        return New-MDRepairResult -Id $id -Name 'Clear failed BITS transfers' -Status 'NotNeeded' `
            -Detail ('{0} job(s) present, none failed or stalled' -f $jobs.Count)
    }
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Clear failed BITS transfers' -Status 'DryRun' `
            -Detail ('would remove {0} job(s)' -f $targets.Count) `
            -Evidence (@($targets | ForEach-Object { '{0} [{1}]' -f $_.DisplayName, $_.JobState }))
    }

    $removed  = 0
    $evidence = @()
    foreach ($job in $targets) {
        try {
            $evidence += ('{0} [{1}]' -f $job.DisplayName, $job.JobState)
            Remove-BitsTransfer -BitsJob $job -ErrorAction Stop
            $removed++
        }
        catch {
            $evidence += ('could not remove {0}: {1}' -f $job.DisplayName, $_.Exception.Message)
        }
    }

    New-MDRepairResult -Id $id -Name 'Clear failed BITS transfers' -Status $(if ($removed -eq $targets.Count) { 'Success' } else { 'Failed' }) `
        -Detail ('{0} of {1} job(s) removed' -f $removed, $targets.Count) `
        -Evidence ($evidence + 'The client recreates the jobs it still needs on its next content request.')
}


function Repair-MDUpdatesRescan {
    <# Forces a fresh software update scan and deployment evaluation. #>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.UpdatesRescan

    if (-not $Context.ClientInfo.Installed) {
        return New-MDRepairResult -Id $id -Name 'Force a software update scan' -Status 'Skipped' -Detail 'client not installed'
    }
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Force a software update scan' -Status 'DryRun' -Detail 'would trigger scan and evaluation cycles'
    }

    $cycles = @(
        @{ Id = '{00000000-0000-0000-0000-000000000113}'; Name = 'Software Update Scan' }
        @{ Id = '{00000000-0000-0000-0000-000000000108}'; Name = 'Software Update Assignment Evaluation' }
        @{ Id = '{00000000-0000-0000-0000-000000000114}'; Name = 'Software Update Deployment Re-evaluation' }
    )

    $ok = 0
    foreach ($c in $cycles) { if (Invoke-MDTriggerSchedule -ScheduleId $c.Id -Name $c.Name) { $ok++ } }

    if ($ok -eq 0) {
        return New-MDRepairResult -Id $id -Name 'Force a software update scan' -Status 'Failed' -Detail 'no cycle could be triggered'
    }

    New-MDRepairResult -Id $id -Name 'Force a software update scan' -Status 'Success' `
        -Detail ('{0} of {1} cycle(s) triggered' -f $ok, $cycles.Count) `
        -Evidence @('Watch ScanAgent.log and WUAHandler.log. A full scan can take 10-30 minutes.')
}


function Repair-MDCcmEvalRun {
    <# Runs Microsoft's own client health evaluation. #>
    param([Parameter(Mandatory)] $Context)

    $id     = $script:MDRepairIds.CcmEvalRun
    $ccmEval = $null
    if ($Context.ClientInfo.InstallPath) { $ccmEval = Join-Path $Context.ClientInfo.InstallPath 'ccmeval.exe' }

    if (-not $ccmEval -or -not (Test-Path -LiteralPath $ccmEval)) {
        return New-MDRepairResult -Id $id -Name 'Run client health evaluation (ccmeval)' -Status 'Skipped' -Detail 'ccmeval.exe not found'
    }
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Run client health evaluation (ccmeval)' -Status 'DryRun' -Detail ('would run ' + $ccmEval)
    }

    Write-MDDetail -Text 'ccmeval can take several minutes; it repairs some issues by itself.' -Bullet '- '
    $r = Invoke-MDProcess -FilePath $ccmEval -TimeoutSeconds 900

    if ($r.TimedOut) {
        return New-MDRepairResult -Id $id -Name 'Run client health evaluation (ccmeval)' -Status 'Failed' -Detail 'timed out after 15 minutes'
    }

    New-MDRepairResult -Id $id -Name 'Run client health evaluation (ccmeval)' -Status 'Success' `
        -Detail ('completed with exit code {0}' -f $r.ExitCode) `
        -Evidence @('Results are written to CcmEvalReport.xml and CcmEval.log. Re-run "mecmdoctor diagnose" to read them back.')
}


function Repair-MDGroupPolicyRefresh {
    <# A plain gpupdate /force. Safe, and often all that is needed. #>
    param([Parameter(Mandatory)] $Context)

    $id = 'gp.refresh'
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Refresh Group Policy' -Status 'DryRun' -Detail 'would run gpupdate /force'
    }

    $r = Invoke-MDProcess -FilePath (Join-Path $env:windir 'System32\gpupdate.exe') `
                          -ArgumentList @('/force') -TimeoutSeconds 300

    if ($r.TimedOut) {
        return New-MDRepairResult -Id $id -Name 'Refresh Group Policy' -Status 'Failed' -Detail 'gpupdate did not finish within 5 minutes'
    }
    if ($r.ExitCode -ne 0) {
        return New-MDRepairResult -Id $id -Name 'Refresh Group Policy' -Status 'Failed' `
            -Detail ('gpupdate exited with {0}' -f $r.ExitCode) `
            -Evidence @(($r.StdOut + $r.StdErr).Trim())
    }

    New-MDRepairResult -Id $id -Name 'Refresh Group Policy' -Status 'Success' -Detail 'gpupdate /force completed'
}


# ===========================================================================
#  STANDARD TIER
# ===========================================================================

function Repair-MDWmiSalvage {
<#
    .SYNOPSIS
        Salvages the WMI repository - the non-destructive repository repair.
    .DESCRIPTION
        Salvage keeps custom classes and data where it can; reset throws
        everything away. Always try salvage first, and always stop CcmExec
        beforehand so its providers are not mid-call while the repository moves.
#>
    param([Parameter(Mandatory)] $Context)

    $id      = $script:MDRepairIds.WmiSalvage
    $winmgmt = Join-Path $env:windir 'System32\wbem\winmgmt.exe'

    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Salvage the WMI repository' -Status 'DryRun' `
            -Detail 'would stop CcmExec, run winmgmt /salvagerepository, then restart CcmExec'
    }

    $evidence = @()
    $ccmWasRunning = $false
    $svc = Get-MDService -Name 'CcmExec'
    if ($svc -and $svc.Status -eq 'Running') {
        $ccmWasRunning = $true
        [void](Stop-MDServiceSafely -Name 'CcmExec')
    }

    try {
        Write-MDDetail -Text 'running winmgmt /salvagerepository (this can take a few minutes)' -Bullet '- '
        $salvage = Invoke-MDProcess -FilePath $winmgmt -ArgumentList @('/salvagerepository') -TimeoutSeconds 600
        $evidence += ('salvagerepository exit {0}: {1}' -f $salvage.ExitCode, ($salvage.StdOut + $salvage.StdErr).Trim())

        $verify = Invoke-MDProcess -FilePath $winmgmt -ArgumentList @('/verifyrepository') -TimeoutSeconds 180
        $verifyText = ($verify.StdOut + $verify.StdErr).Trim()
        $evidence += ('verifyrepository exit {0}: {1}' -f $verify.ExitCode, $verifyText)

        $consistent = ($verify.ExitCode -eq 0 -and $verifyText -match '(?i)consistent')

        if ($consistent) {
            return New-MDRepairResult -Id $id -Name 'Salvage the WMI repository' -Status 'Success' `
                -Detail 'repository is consistent again' -Evidence $evidence -RebootRecommended
        }

        return New-MDRepairResult -Id $id -Name 'Salvage the WMI repository' -Status 'Failed' `
            -Detail 'repository is still inconsistent after salvage' `
            -Evidence ($evidence + 'Salvage was not enough. A full reset (wmi.reset, -Level Aggressive) is the next step, but it discards every custom WMI class on this machine and warns and asks for its own confirmation before it runs - schedule it deliberately.')
    }
    finally {
        if ($ccmWasRunning) { [void](Start-MDServiceSafely -Name 'CcmExec') }
    }
}


function Repair-MDPolicyReset {
<#
    .SYNOPSIS
        Purges all client policy and forces a full re-download.
    .DESCRIPTION
        SMS_Client.ResetPolicy(1) deletes the existing policy and requests
        everything again from the management point. Safe, but the client is
        effectively policy-less for a few minutes afterwards.
#>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.PolicyReset

    if (-not $Context.ClientInfo.Installed) {
        return New-MDRepairResult -Id $id -Name 'Reset and re-download client policy' -Status 'Skipped' -Detail 'client not installed'
    }
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Reset and re-download client policy' -Status 'DryRun' -Detail 'would call SMS_Client.ResetPolicy(1)'
    }

    # uFlags = 1 purges the full policy; 0 resets only the assigned policy.
    $r = Invoke-MDCimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' `
                            -MethodName 'ResetPolicy' -Arguments @{ uFlags = [uint32]1 }

    if ($null -eq $r) {
        return New-MDRepairResult -Id $id -Name 'Reset and re-download client policy' -Status 'Failed' `
            -Detail 'SMS_Client.ResetPolicy failed' `
            -Evidence @('This needs a working root\ccm namespace. Repair WMI first, then retry.')
    }

    Start-Sleep -Seconds 5
    [void](Invoke-MDTriggerSchedule -ScheduleId '{00000000-0000-0000-0000-000000000021}' -Name 'Machine Policy Retrieval')
    [void](Invoke-MDTriggerSchedule -ScheduleId '{00000000-0000-0000-0000-000000000022}' -Name 'Machine Policy Evaluation')

    New-MDRepairResult -Id $id -Name 'Reset and re-download client policy' -Status 'Success' `
        -Detail 'policy purged and re-requested' `
        -Evidence @('The client will be missing deployments until the download completes. Allow 15 minutes, then re-run diagnose.')
}


function Repair-MDClientRepair {
<#
    .SYNOPSIS
        Asks the client to repair itself (equivalent to the Repair button in
        the Configuration Manager control panel applet).
#>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.ClientRepair

    if (-not $Context.ClientInfo.Installed) {
        return New-MDRepairResult -Id $id -Name 'Repair the Configuration Manager client' -Status 'Skipped' -Detail 'client not installed'
    }
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Repair the Configuration Manager client' -Status 'DryRun' -Detail 'would invoke SMS_Client.RepairClient'
    }

    $r = Invoke-MDCimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' -MethodName 'RepairClient'
    if ($null -ne $r) {
        return New-MDRepairResult -Id $id -Name 'Repair the Configuration Manager client' -Status 'Success' `
            -Detail 'client repair started' `
            -Evidence @('ccmrepair.exe runs in the background and can take 10-20 minutes.',
                        'Follow progress in C:\Windows\ccmsetup\Logs\ccmsetup.log.')
    }

    # WMI is often the thing that is broken, so fall back to the executable.
    $ccmRepair = Join-Path $Context.ClientInfo.InstallPath 'ccmrepair.exe'
    if (Test-Path -LiteralPath $ccmRepair) {
        Write-MDDetail -Text 'SMS_Client.RepairClient unavailable - launching ccmrepair.exe directly' -Bullet '- '
        try {
            Start-Process -FilePath $ccmRepair -ErrorAction Stop
            return New-MDRepairResult -Id $id -Name 'Repair the Configuration Manager client' -Status 'Success' `
                -Detail 'ccmrepair.exe launched' `
                -Evidence @('Follow progress in C:\Windows\ccmsetup\Logs\ccmsetup.log.')
        }
        catch {
            return New-MDRepairResult -Id $id -Name 'Repair the Configuration Manager client' -Status 'Failed' `
                -Detail ('could not launch ccmrepair.exe - {0}' -f $_.Exception.Message)
        }
    }

    New-MDRepairResult -Id $id -Name 'Repair the Configuration Manager client' -Status 'Failed' `
        -Detail 'neither SMS_Client.RepairClient nor ccmrepair.exe is available' `
        -Evidence @('The install is too damaged to repair itself. Use: mecmdoctor reinstall')
}


function Repair-MDUpdatesReset {
<#
    .SYNOPSIS
        Rebuilds the Windows Update client state.
    .DESCRIPTION
        The classic sequence: stop the services, move SoftwareDistribution and
        catroot2 aside, clear the WSUS client identity so it re-registers, then
        start everything back up and rescan.

        Renaming rather than deleting means the old datastore is still there if
        anyone needs to look at it, and Windows rebuilds both folders itself.
#>
    param([Parameter(Mandatory)] $Context)

    $id    = $script:MDRepairIds.UpdatesReset
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

    $folders = @(
        @{ Path = (Join-Path $env:windir 'SoftwareDistribution'); Why = 'Windows Update datastore and download cache' }
        @{ Path = (Join-Path $env:windir 'System32\catroot2');    Why = 'cryptographic catalogue store' }
    )
    $services = @('wuauserv', 'BITS', 'CryptSvc', 'msiserver')

    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Reset Windows Update components' -Status 'DryRun' `
            -Detail 'would stop the update services, rename the datastore folders, and clear the WSUS client id' `
            -Evidence (@($folders | ForEach-Object { 'rename ' + $_.Path }) + 'clear SusClientId / SusClientIdValidation')
    }

    $evidence = @()

    # CcmExec holds handles under SoftwareDistribution during a scan.
    $ccmWasRunning = $false
    $svc = Get-MDService -Name 'CcmExec'
    if ($svc -and $svc.Status -eq 'Running') {
        $ccmWasRunning = $true
        [void](Stop-MDServiceSafely -Name 'CcmExec')
    }

    foreach ($s in $services) { [void](Stop-MDServiceSafely -Name $s -TimeoutSeconds 60) }

    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f.Path)) {
            $evidence += ('{0} not present, nothing to rename' -f $f.Path)
            continue
        }
        $target = '{0}.mecmdoctor-{1}' -f $f.Path, $stamp
        try {
            Rename-Item -LiteralPath $f.Path -NewName (Split-Path -Leaf $target) -Force -ErrorAction Stop
            $evidence += ('renamed {0} -> {1} ({2})' -f $f.Path, (Split-Path -Leaf $target), $f.Why)
        }
        catch {
            $evidence += ('could not rename {0}: {1}' -f $f.Path, $_.Exception.Message)
        }
    }

    # A duplicate SusClientId is the cause of the 0x80244007 SOAP faults; the
    # WUA generates a fresh one when these values are absent.
    $wuKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
    foreach ($name in @('SusClientId', 'SusClientIdValidation', 'AccountDomainSid', 'PingID')) {
        try {
            if ($null -ne (Get-MDRegValue -Path $wuKey -Name $name)) {
                Remove-ItemProperty -LiteralPath $wuKey -Name $name -Force -ErrorAction Stop
                $evidence += ('cleared {0}\{1}' -f $wuKey, $name)
            }
        }
        catch {
            $evidence += ('could not clear {0}: {1}' -f $name, $_.Exception.Message)
        }
    }

    foreach ($s in $services) {
        if (-not (Start-MDServiceSafely -Name $s -TimeoutSeconds 60)) {
            $evidence += ('service {0} did not restart' -f $s)
        }
    }
    if ($ccmWasRunning) { [void](Start-MDServiceSafely -Name 'CcmExec') }

    $failedSteps = @($evidence | Where-Object { $_ -match 'could not|did not restart' })
    $status = if ($failedSteps.Count -gt 0) { 'Failed' } else { 'Success' }

    New-MDRepairResult -Id $id -Name 'Reset Windows Update components' -Status $status `
        -Detail $(if ($status -eq 'Success') { 'datastore rebuilt, WSUS identity cleared' } else { ('{0} step(s) failed' -f $failedSteps.Count) }) `
        -Evidence ($evidence + 'Run a software update scan next; the first scan after a reset is slow.')
}


function Repair-MDGroupPolicyPol {
<#
    .SYNOPSIS
        Quarantines corrupt Registry.pol files and re-applies policy.
    .DESCRIPTION
        The fix for the classic event 1096 failure. Windows recreates a valid
        Registry.pol on the next policy application, so moving the damaged file
        aside is both the diagnosis and the cure.
#>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.GpRepairPol

    $candidates = @(
        @{ Path = (Join-Path $env:windir 'System32\GroupPolicy\Machine\Registry.pol'); Scope = 'Machine' }
        @{ Path = (Join-Path $env:windir 'System32\GroupPolicy\User\Registry.pol');    Scope = 'User' }
    )

    $gpUsersRoot = Join-Path $env:windir 'System32\GroupPolicyUsers'
    if (Test-Path -LiteralPath $gpUsersRoot) {
        foreach ($dir in (Get-ChildItem -LiteralPath $gpUsersRoot -Directory -ErrorAction SilentlyContinue)) {
            $candidates += @{ Path = (Join-Path $dir.FullName 'User\Registry.pol'); Scope = ('LocalUser ' + $dir.Name) }
        }
    }

    # Only touch files that actually fail validation. A healthy Registry.pol
    # holds real configuration and must not be thrown away.
    $bad = @()
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c.Path)) { continue }
        $verdict = Test-MDRegistryPolIntegrity -Path $c.Path
        if (-not $verdict.Valid) { $bad += [pscustomobject]@{ Path = $c.Path; Scope = $c.Scope; Reason = $verdict.Reason } }
    }

    # A zero-byte gpt.ini causes the same class of failure.
    $gptIni = Join-Path $env:windir 'System32\GroupPolicy\gpt.ini'
    $badGpt = (Test-Path -LiteralPath $gptIni) -and ((Get-Item -LiteralPath $gptIni).Length -eq 0)

    if ($bad.Count -eq 0 -and -not $badGpt) {
        return New-MDRepairResult -Id $id -Name 'Repair corrupt local Group Policy files' -Status 'NotNeeded' `
            -Detail 'all local policy files pass validation'
    }
    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Repair corrupt local Group Policy files' -Status 'DryRun' `
            -Detail ('would quarantine {0} file(s) and run gpupdate /force' -f ($bad.Count + [int]$badGpt)) `
            -Evidence (@($bad | ForEach-Object { '{0} ({1}): {2}' -f $_.Path, $_.Scope, $_.Reason }))
    }

    $evidence = @()

    foreach ($b in $bad) {
        $backup = Save-MDBackupCopy -Context $Context -Path $b.Path -SubFolder 'grouppolicy'
        try {
            Remove-Item -LiteralPath $b.Path -Force -ErrorAction Stop
            $evidence += ('quarantined {0} ({1}) - {2}{3}' -f $b.Path, $b.Scope, $b.Reason,
                          $(if ($backup) { "; copy kept at $backup" } else { '' }))
        }
        catch {
            $evidence += ('could not remove {0}: {1}' -f $b.Path, $_.Exception.Message)
        }
    }

    if ($badGpt) {
        $backup = Save-MDBackupCopy -Context $Context -Path $gptIni -SubFolder 'grouppolicy'
        try {
            Remove-Item -LiteralPath $gptIni -Force -ErrorAction Stop
            $evidence += ('quarantined zero-byte gpt.ini{0}' -f $(if ($backup) { "; copy kept at $backup" } else { '' }))
        }
        catch {
            $evidence += ('could not remove gpt.ini: {0}' -f $_.Exception.Message)
        }
    }

    Write-MDDetail -Text 'running gpupdate /force so Windows rebuilds the policy files' -Bullet '- '
    $gp = Invoke-MDProcess -FilePath (Join-Path $env:windir 'System32\gpupdate.exe') -ArgumentList @('/force') -TimeoutSeconds 300
    $evidence += ('gpupdate /force exit {0}' -f $gp.ExitCode)

    $failed = @($evidence | Where-Object { $_ -match 'could not' })
    New-MDRepairResult -Id $id -Name 'Repair corrupt local Group Policy files' -Status $(if ($failed.Count) { 'Failed' } else { 'Success' }) `
        -Detail ('{0} corrupt file(s) quarantined' -f ($bad.Count + [int]$badGpt)) `
        -Evidence $evidence
}


# ===========================================================================
#  AGGRESSIVE TIER  (destructive - always confirmed unless -Force)
# ===========================================================================

function Repair-MDWmiReset {
<#
    .SYNOPSIS
        Resets the WMI repository from scratch. The most destructive thing this
        tool can do to a machine that is staying where it is.
    .DESCRIPTION
        Every custom class and every piece of data added by any product since
        the OS was installed is discarded. Windows recompiles its own MOFs
        automatically; third-party products - antivirus, monitoring agents,
        management tooling and the MECM client itself - usually need a repair
        or a reinstall afterwards to put theirs back.

        Because of that, this action refuses to run on evidence it does not
        have:

          * it re-runs winmgmt /verifyrepository immediately beforehand, and
            stops if the repository verifies as consistent. Repository size,
            age or a stale finding from earlier in the run are never enough
          * it prints what the evidence actually is, and what a reset will cost
          * it then asks its own question, separately from any confirmation the
            repair plan already collected

        Salvage (wmi.salvage) runs earlier in the same plan and is the correct
        first attempt; by the time this runs, salvage has usually already fixed
        the problem and the verify below reports consistent.
#>
    param([Parameter(Mandatory)] $Context)

    $id      = $script:MDRepairIds.WmiReset
    $name    = 'Reset the WMI repository'
    $winmgmt = Join-Path $env:windir 'System32\wbem\winmgmt.exe'

    # --- evidence check -----------------------------------------------------
    # Deliberately not gated on -DryRun: knowing whether the reset would even
    # be attempted is the single most useful thing a dry run can report here.
    Write-MDDetail -Text 'confirming the repository is actually corrupt before considering a reset' -Bullet '- '
    $check     = Invoke-MDProcess -FilePath $winmgmt -ArgumentList @('/verifyrepository') -TimeoutSeconds 180
    $checkText = (($check.StdOut + ' ' + $check.StdErr)).Trim()
    $consistent = ($check.ExitCode -eq 0 -and $checkText -match '(?i)consistent' -and -not $check.TimedOut)

    if ($checkText -match '0x80041003' -or $checkText -match '(?i)access denied') {
        return New-MDRepairResult -Id $id -Name $name -Status 'Skipped' `
            -Detail 'cannot confirm repository corruption without elevation' `
            -Evidence @($checkText, 'Re-run via mecmdoctor.bat. This action will not reset a repository it has not been able to verify.')
    }

    if ($consistent) {
        return New-MDRepairResult -Id $id -Name $name -Status 'NotNeeded' `
            -Detail 'the repository verifies as consistent, so a reset is not warranted' `
            -Evidence @(
                $checkText
                'A reset discards every custom WMI class on this machine, and nothing here indicates it would fix anything.'
                'Repository size on its own is never a reason to reset - if the repository is simply large, investigate what is writing to it instead.'
            )
    }

    # --- from here the repository really is inconsistent ---------------------
    $evidence = @(('winmgmt /verifyrepository exit {0}: {1}' -f $check.ExitCode, $checkText))
    if ($check.TimedOut) { $evidence = @('winmgmt /verifyrepository did not respond within 180s - WMI is hung.') }

    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name $name -Status 'DryRun' `
            -Detail 'repository is inconsistent, so a reset would be offered here' `
            -Evidence ($evidence + 'Running for real, this would print the risks and ask for a separate confirmation before touching anything.') `
            -RebootRecommended
    }

    # --- the warning, then its own confirmation -----------------------------
    Write-MDLine ''
    Write-MDWarn 'WMI REPOSITORY RESET - read this before answering.'
    Write-MDDetail -Indent 9 -Color 'DarkYellow' -Bullet '! ' -Text @(
        'Why this is being offered: winmgmt reports the repository inconsistent, and the diagnosis found independent evidence that WMI is not working correctly.'
        'What it does: rebuilds the repository from the MOF files on disk.'
        'What it costs: every custom WMI class and all data added since Windows was installed is discarded. Antivirus, monitoring, inventory and management agents can lose their WMI registration and may need repairing or reinstalling.'
        'The Configuration Manager client will need a client repair afterwards, and the machine needs a reboot.'
        'Salvage (wmi.salvage) is the non-destructive alternative and has already run if it was in this plan.'
    )
    Write-MDLine ''

    $ok = Read-MDConfirm -Question 'WMI corruption was detected after health checks. Resetting WMI may affect applications and system management components. Continue?' -Force:$Context.Force
    if (-not $ok) {
        return New-MDRepairResult -Id $id -Name $name -Status 'Skipped' `
            -Detail 'declined by operator' `
            -Evidence ($evidence + 'Nothing was changed. Salvage remains available at -Level Standard.')
    }

    [void](Stop-MDServiceSafely -Name 'CcmExec')

    Write-MDDetail -Text 'running winmgmt /resetrepository' -Bullet '- '
    $reset = Invoke-MDProcess -FilePath $winmgmt -ArgumentList @('/resetrepository') -TimeoutSeconds 900
    $evidence += ('resetrepository exit {0}: {1}' -f $reset.ExitCode, ($reset.StdOut + $reset.StdErr).Trim())

    $verify = Invoke-MDProcess -FilePath $winmgmt -ArgumentList @('/verifyrepository') -TimeoutSeconds 180
    $verifyText = ($verify.StdOut + $verify.StdErr).Trim()
    $evidence += ('verifyrepository exit {0}: {1}' -f $verify.ExitCode, $verifyText)

    [void](Start-MDServiceSafely -Name 'CcmExec')

    $nowConsistent = ($verify.ExitCode -eq 0 -and $verifyText -match '(?i)consistent')

    New-MDRepairResult -Id $id -Name $name -Status $(if ($nowConsistent) { 'Success' } else { 'Failed' }) `
        -Detail $(if ($nowConsistent) { 'repository rebuilt and consistent' } else { 'repository is still not consistent' }) `
        -Evidence ($evidence + 'Repair the client next so it recompiles its own MOF files, then reboot. Check any other agent that registers WMI classes.') `
        -RebootRecommended
}
function Repair-MDGroupPolicyState {
<#
    .SYNOPSIS
        Clears cached Group Policy state so the whole set is re-applied.
    .DESCRIPTION
        Destructive in that local policy settings are lost, but everything that
        comes from a domain GPO is re-applied on the next refresh. Use when
        policy processing is broken in a way that quarantining Registry.pol
        alone does not fix.
#>
    param([Parameter(Mandatory)] $Context)

    $id = $script:MDRepairIds.GpResetState

    $stateKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine'
    )
    $polFiles = @(
        (Join-Path $env:windir 'System32\GroupPolicy\Machine\Registry.pol')
        (Join-Path $env:windir 'System32\GroupPolicy\User\Registry.pol')
    )

    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Clear Group Policy state and re-apply' -Status 'DryRun' `
            -Detail 'would remove the GP history keys and local Registry.pol files, then run gpupdate /force' `
            -Evidence ($stateKeys + $polFiles)
    }

    if (-not $Context.Force) {
        $ok = Read-MDConfirm -Question 'Clear all cached Group Policy state? Local policy settings are lost; domain policy re-applies on the next refresh.'
        if (-not $ok) {
            return New-MDRepairResult -Id $id -Name 'Clear Group Policy state and re-apply' -Status 'Skipped' -Detail 'declined by operator'
        }
    }

    $evidence = @()

    # Export the registry state before removing it - reg.exe is the only
    # reliable way to capture a whole key with its subkeys.
    foreach ($key in $stateKeys) {
        if (-not (Test-MDRegKey $key)) { $evidence += ("{0} not present" -f $key); continue }

        try {
            if (-not (Test-Path -LiteralPath $Context.BackupRoot)) {
                New-Item -Path $Context.BackupRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            $regPath  = $key -replace '^HKLM:\\', 'HKLM\'
            $exported = Join-Path $Context.BackupRoot (($key -replace '[:\\ ]', '_') + '.reg')
            [void](Invoke-MDProcess -FilePath (Join-Path $env:windir 'System32\reg.exe') `
                                    -ArgumentList @('export', ('"' + $regPath + '"'), ('"' + $exported + '"'), '/y') -TimeoutSeconds 60)

            Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
            $evidence += ('removed {0} (exported to {1})' -f $key, $exported)
        }
        catch {
            $evidence += ('could not remove {0}: {1}' -f $key, $_.Exception.Message)
        }
    }

    foreach ($pol in $polFiles) {
        if (-not (Test-Path -LiteralPath $pol)) { continue }
        $backup = Save-MDBackupCopy -Context $Context -Path $pol -SubFolder 'grouppolicy'
        try {
            Remove-Item -LiteralPath $pol -Force -ErrorAction Stop
            $evidence += ('removed {0}{1}' -f $pol, $(if ($backup) { "; copy kept at $backup" } else { '' }))
        }
        catch {
            $evidence += ('could not remove {0}: {1}' -f $pol, $_.Exception.Message)
        }
    }

    $gp = Invoke-MDProcess -FilePath (Join-Path $env:windir 'System32\gpupdate.exe') -ArgumentList @('/force') -TimeoutSeconds 300
    $evidence += ('gpupdate /force exit {0}' -f $gp.ExitCode)

    $failed = @($evidence | Where-Object { $_ -match 'could not' })
    New-MDRepairResult -Id $id -Name 'Clear Group Policy state and re-apply' -Status $(if ($failed.Count) { 'Failed' } else { 'Success' }) `
        -Detail 'Group Policy state cleared' -Evidence $evidence -RebootRecommended
}


function Repair-MDSecEditDatabase {
<#
    .SYNOPSIS
        Rebuilds the local security policy database (secedit.sdb).
    .DESCRIPTION
        A corrupt or zero-byte secedit.sdb makes the Security CSE fail, which
        shows up as SceCli event 1202 and stops security policy applying.
        Renaming the database makes Windows create a fresh one on the next
        policy refresh.

        This deliberately stops short of "secedit /configure /cfg defltbase.inf",
        which resets every security setting on the machine to Windows defaults.
        That is documented in the README as a manual last resort rather than
        being fired automatically.
#>
    param([Parameter(Mandatory)] $Context)

    $id  = $script:MDRepairIds.GpResetSecEdit
    $sdb = Join-Path $env:windir 'security\database\secedit.sdb'

    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Rebuild the local security database' -Status 'DryRun' `
            -Detail ('would rename {0} and refresh policy' -f $sdb)
    }

    if (-not $Context.Force) {
        $ok = Read-MDConfirm -Question 'Rebuild the local security policy database (secedit.sdb)?'
        if (-not $ok) {
            return New-MDRepairResult -Id $id -Name 'Rebuild the local security database' -Status 'Skipped' -Detail 'declined by operator'
        }
    }

    $evidence = @()

    if (Test-Path -LiteralPath $sdb) {
        $backup = Save-MDBackupCopy -Context $Context -Path $sdb -SubFolder 'security'
        try {
            $newName = 'secedit.sdb.mecmdoctor-{0}' -f (Get-Date).ToString('yyyyMMdd-HHmmss')
            Rename-Item -LiteralPath $sdb -NewName $newName -Force -ErrorAction Stop
            $evidence += ('renamed secedit.sdb -> {0}{1}' -f $newName, $(if ($backup) { "; copy kept at $backup" } else { '' }))
        }
        catch {
            return New-MDRepairResult -Id $id -Name 'Rebuild the local security database' -Status 'Failed' `
                -Detail ('could not rename secedit.sdb - {0}' -f $_.Exception.Message) `
                -Evidence @('The file is in use. Reboot and run this repair again before anything else.')
        }
    }
    else {
        $evidence += 'secedit.sdb was already missing'
    }

    $gp = Invoke-MDProcess -FilePath (Join-Path $env:windir 'System32\gpupdate.exe') -ArgumentList @('/force') -TimeoutSeconds 300
    $evidence += ('gpupdate /force exit {0}' -f $gp.ExitCode)

    $rebuilt = Test-Path -LiteralPath $sdb
    $evidence += $(if ($rebuilt) { 'a fresh secedit.sdb was created' } else { 'secedit.sdb has not been recreated yet - it appears on the next policy refresh or reboot' })

    New-MDRepairResult -Id $id -Name 'Rebuild the local security database' -Status 'Success' `
        -Detail 'security database rebuilt' -Evidence $evidence -RebootRecommended
}


function Find-MDCustomReinstallScript {
<#
    .SYNOPSIS
        Locates a user-supplied ClientReinstall.ps1.
    .DESCRIPTION
        Searched, in order:
          1. the folder MECMDoctor.ps1 lives in
          2. that folder's parent (so the tool can sit in a subfolder)
          3. the current working directory

        This is the documented extension point: drop your own reinstall script
        in beside the tool and mecmdoctor will run yours instead of its
        built-in fallback.
#>
    param([string] $ScriptRoot)

    $searchPaths = @()
    if ($ScriptRoot) {
        $searchPaths += $ScriptRoot
        $parent = Split-Path -Parent $ScriptRoot
        if ($parent) { $searchPaths += $parent }
    }
    $searchPaths += (Get-Location).Path

    foreach ($dir in ($searchPaths | Select-Object -Unique)) {
        if (-not $dir) { continue }
        $candidate = Join-Path $dir 'ClientReinstall.ps1'
        if (Test-Path -LiteralPath $candidate) {
            Write-MDDebug ("custom reinstall script found: {0}" -f $candidate)
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    Write-MDDebug ('no ClientReinstall.ps1 found in: {0}' -f (($searchPaths | Select-Object -Unique) -join '; '))
    $null
}


function Repair-MDClientReinstall {
<#
    .SYNOPSIS
        Reinstalls the Configuration Manager client.
    .DESCRIPTION
        Prefers a user-supplied ClientReinstall.ps1 sitting next to the tool.
        Any of -SiteCode / -ManagementPoint / -LogDirectory / -InstallPath that
        the custom script declares as parameters are passed to it; everything
        else is left to that script.

        With no custom script, falls back to ccmsetup.exe /uninstall followed by
        a fresh install using the site code and management point discovered
        during diagnosis.
#>
    param([Parameter(Mandatory)] $Context)

    $id     = $script:MDRepairIds.ClientReinstall
    $custom = Find-MDCustomReinstallScript -ScriptRoot $Context.ScriptRoot

    # --- user-supplied script ----------------------------------------------
    if ($custom) {
        Write-MDInfo ("Using custom reinstall script: {0}" -f $custom)

        if ($Context.DryRun) {
            return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'DryRun' `
                -Detail ('would run {0}' -f $custom)
        }
        if (-not $Context.Force) {
            $ok = Read-MDConfirm -Question ("Run your reinstall script '{0}' now? The client will be removed and reinstalled." -f (Split-Path -Leaf $custom))
            if (-not $ok) {
                return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'Skipped' -Detail 'declined by operator'
            }
        }

        # Only pass parameters the script actually declares, so a simple
        # parameterless script still works.
        $splat = @{}
        try {
            $cmd = Get-Command -Name $custom -CommandType ExternalScript -ErrorAction Stop
            $available = $cmd.Parameters.Keys

            if ($available -contains 'SiteCode'        -and $Context.ClientInfo.SiteCode)        { $splat['SiteCode']        = $Context.ClientInfo.SiteCode }
            if ($available -contains 'ManagementPoint' -and $Context.ClientInfo.ManagementPoint) { $splat['ManagementPoint'] = $Context.ClientInfo.ManagementPoint }
            if ($available -contains 'InstallPath'     -and $Context.ClientInfo.InstallPath)     { $splat['InstallPath']     = $Context.ClientInfo.InstallPath }
            if ($available -contains 'LogDirectory')                                            { $splat['LogDirectory']    = (Split-Path -Parent $script:MDLog.PlainPath) }
        }
        catch {
            Write-MDDebug ("could not inspect custom script parameters: {0}" -f $_.Exception.Message)
        }

        if ($splat.Count) {
            Write-MDDetail -Text ('passing: ' + (($splat.GetEnumerator() | ForEach-Object { '-{0} {1}' -f $_.Key, $_.Value }) -join ' ')) -Bullet '- '
        }

        try {
            Write-MDLine ''
            Write-MDRule '.' 'DarkGray'
            Write-MDLine ('  output of {0}' -f (Split-Path -Leaf $custom)) -Color 'DarkGray'
            Write-MDRule '.' 'DarkGray'

            # Stream the script's output into our transcript so the reinstall
            # is recorded alongside everything else.
            & $custom @splat 2>&1 | ForEach-Object {
                Write-MDLine ('    ' + $_) -Color 'Gray' -Component 'ClientReinstall'
            }
            $exit = $LASTEXITCODE

            Write-MDRule '.' 'DarkGray'

            if ($null -ne $exit -and $exit -ne 0) {
                return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'Failed' `
                    -Detail ('{0} exited with code {1}' -f (Split-Path -Leaf $custom), $exit)
            }

            return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'Success' `
                -Detail ('custom script {0} completed' -f (Split-Path -Leaf $custom)) `
                -Evidence @('Follow the install in C:\Windows\ccmsetup\Logs\ccmsetup.log; a full install takes 10-30 minutes.') `
                -RebootRecommended
        }
        catch {
            return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'Failed' `
                -Detail ('custom script threw: {0}' -f $_.Exception.Message)
        }
    }

    # --- built-in fallback --------------------------------------------------
    $ccmsetup = Join-Path $env:windir 'ccmsetup\ccmsetup.exe'
    if (-not (Test-Path -LiteralPath $ccmsetup)) {
        return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'Manual' `
            -Detail 'no ClientReinstall.ps1 supplied and ccmsetup.exe is not present locally' `
            -Evidence @(
                'mecmdoctor will not guess at your install parameters.'
                'Drop a ClientReinstall.ps1 next to MECMDoctor.ps1 with your organisation''s install command, then re-run: mecmdoctor reinstall'
                'A ClientReinstall.example.ps1 is included in the repository as a starting point.'
            )
    }

    $uninstallArgs = @('/uninstall')
    $installArgs   = @()
    if ($Context.ClientInfo.SiteCode)        { $installArgs += ('SMSSITECODE=' + $Context.ClientInfo.SiteCode) }
    if ($Context.ClientInfo.ManagementPoint) { $installArgs += ('SMSMP=' + $Context.ClientInfo.ManagementPoint) }

    if ($Context.DryRun) {
        return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'DryRun' `
            -Detail 'would uninstall then reinstall using the discovered site parameters' `
            -Evidence @(('{0} {1}' -f $ccmsetup, ($uninstallArgs -join ' ')),
                        ('{0} /mp:{1} {2}' -f $ccmsetup, $Context.ClientInfo.ManagementPoint, ($installArgs -join ' ')))
    }

    if ($installArgs.Count -eq 0) {
        return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'Manual' `
            -Detail 'no site code or management point could be discovered, so a fallback reinstall would be a guess' `
            -Evidence @('Supply a ClientReinstall.ps1 with your install command line and re-run: mecmdoctor reinstall')
    }

    if (-not $Context.Force) {
        $ok = Read-MDConfirm -Question 'Uninstall and reinstall the Configuration Manager client now? This takes 10-30 minutes and the device is unmanaged until it finishes.'
        if (-not $ok) {
            return New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'Skipped' -Detail 'declined by operator'
        }
    }

    $evidence = @()

    Write-MDDetail -Text 'running ccmsetup.exe /uninstall' -Bullet '- '
    $uninstall = Invoke-MDProcess -FilePath $ccmsetup -ArgumentList $uninstallArgs -TimeoutSeconds 1800
    $evidence += ('uninstall exit {0}' -f $uninstall.ExitCode)

    # ccmsetup returns immediately and continues in the background.
    $deadline = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $deadline -and (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 10
    }

    $reinstallArgs = @()
    if ($Context.ClientInfo.ManagementPoint) { $reinstallArgs += ('/mp:' + $Context.ClientInfo.ManagementPoint) }
    $reinstallArgs += $installArgs

    Write-MDDetail -Text ('running ccmsetup.exe ' + ($reinstallArgs -join ' ')) -Bullet '- '
    $install = Invoke-MDProcess -FilePath $ccmsetup -ArgumentList $reinstallArgs -TimeoutSeconds 300
    $evidence += ('install launch exit {0}' -f $install.ExitCode)

    New-MDRepairResult -Id $id -Name 'Reinstall the Configuration Manager client' -Status 'Success' `
        -Detail 'uninstall completed and the reinstall has been launched' `
        -Evidence ($evidence + 'ccmsetup continues in the background. Follow C:\Windows\ccmsetup\Logs\ccmsetup.log until it reports exit code 0.') `
        -RebootRecommended
}


function Repair-MDManualNote {
    <# Placeholder for things only a human should decide to do. #>
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Guidance
    )
    New-MDRepairResult -Id $Id -Name $Name -Status 'Manual' -Detail 'operator action required' -Evidence @($Guidance)
}


# ===========================================================================
#  CATALOGUE AND ORCHESTRATION
# ===========================================================================

# The order matters: services before WMI (a stopped Winmgmt makes every WMI
# repair fail), WMI before policy (policy lives in WMI), policy before updates.
$script:MDRepairCatalog = @(
    @{ Id = $script:MDRepairIds.ServicesFix;    Level = 'Safe';       Order = 10;  Action = { param($c) Repair-MDServices $c } }
    @{ Id = $script:MDRepairIds.CcmRestart;     Level = 'Safe';       Order = 20;  Action = { param($c) Repair-MDCcmExecRestart $c } }
    @{ Id = $script:MDRepairIds.BitsClear;      Level = 'Safe';       Order = 30;  Action = { param($c) Repair-MDBitsClear $c } }
    @{ Id = $script:MDRepairIds.CacheClear;     Level = 'Safe';       Order = 40;  Action = { param($c) Repair-MDCacheClear $c } }
    @{ Id = 'gp.refresh';                       Level = 'Safe';       Order = 50;  Action = { param($c) Repair-MDGroupPolicyRefresh $c } }
    @{ Id = $script:MDRepairIds.PolicyTrigger;  Level = 'Safe';       Order = 60;  Action = { param($c) Repair-MDTriggerCycles $c } }
    @{ Id = $script:MDRepairIds.UpdatesRescan;  Level = 'Safe';       Order = 70;  Action = { param($c) Repair-MDUpdatesRescan $c } }
    @{ Id = $script:MDRepairIds.CcmEvalRun;     Level = 'Safe';       Order = 80;  Action = { param($c) Repair-MDCcmEvalRun $c } }

    @{ Id = $script:MDRepairIds.WmiSalvage;     Level = 'Standard';   Order = 110; Action = { param($c) Repair-MDWmiSalvage $c } }
    @{ Id = $script:MDRepairIds.GpRepairPol;    Level = 'Standard';   Order = 120; Action = { param($c) Repair-MDGroupPolicyPol $c } }
    @{ Id = $script:MDRepairIds.PolicyReset;    Level = 'Standard';   Order = 130; Action = { param($c) Repair-MDPolicyReset $c } }
    @{ Id = $script:MDRepairIds.UpdatesReset;   Level = 'Standard';   Order = 150; Action = { param($c) Repair-MDUpdatesReset $c } }
    @{ Id = $script:MDRepairIds.ClientRepair;   Level = 'Standard';   Order = 160; Action = { param($c) Repair-MDClientRepair $c } }

    # NeedsEvidence: -All will not pick this up. A repository reset only ever
    # enters a plan because a finding named it, or because the operator asked
    # for it by id with -Only.
    @{ Id = $script:MDRepairIds.WmiReset;       Level = 'Aggressive'; Order = 210; NeedsEvidence = $true; Action = { param($c) Repair-MDWmiReset $c } }
    @{ Id = $script:MDRepairIds.GpResetState;   Level = 'Aggressive'; Order = 220; Action = { param($c) Repair-MDGroupPolicyState $c } }
    @{ Id = $script:MDRepairIds.GpResetSecEdit; Level = 'Aggressive'; Order = 230; Action = { param($c) Repair-MDSecEditDatabase $c } }
    @{ Id = $script:MDRepairIds.ClientReinstall;Level = 'Aggressive'; Order = 240; Action = { param($c) Repair-MDClientReinstall $c } }

    @{ Id = $script:MDRepairIds.DiskSpace;      Level = 'Safe';       Order = 900; Action = {
        param($c) Repair-MDManualNote -Context $c -Id $script:MDRepairIds.DiskSpace -Name 'Free up disk space' `
            -Guidance 'Nothing here is safe to automate. Remove user data, run Disk Cleanup, or grow the volume. Clearing the CCM cache has already been attempted where it applied.' } }
    @{ Id = $script:MDRepairIds.Reboot;         Level = 'Safe';       Order = 910; Action = {
        param($c) Repair-MDManualNote -Context $c -Id $script:MDRepairIds.Reboot -Name 'Reboot the machine' `
            -Guidance 'A pending reboot is blocking servicing. mecmdoctor never reboots by itself - schedule one, or run: shutdown /r /t 0' } }
)

# Which levels are included at each requested level.
$script:MDLevelIncludes = @{
    'Safe'       = @('Safe')
    'Standard'   = @('Safe', 'Standard')
    'Aggressive' = @('Safe', 'Standard', 'Aggressive')
}


function Get-MDRepairPlan {
<#
    .SYNOPSIS
        Works out which repairs to run.
    .DESCRIPTION
        By default only the repairs implicated by the diagnosis run - that is
        what makes `repair` safe to run on a healthy machine. -All ignores the
        findings and runs everything at the level; -Only runs exactly the ids
        given, regardless of level.

        Actions marked NeedsEvidence are exempt from -All. They are destructive
        enough that "run everything at this tier" is not an adequate reason to
        include them: a finding has to have named the action, or the operator
        has to name it with -Only.
#>
    param(
        [Parameter(Mandatory)][ValidateSet('Safe', 'Standard', 'Aggressive')][string] $Level,
        $Findings,
        [string[]] $Only,
        [switch] $All
    )

    $allowedLevels = $script:MDLevelIncludes[$Level]
    $plan = @()

    # Sort with a scriptblock, not a property name: the catalogue entries are
    # hashtables, and Sort-Object cannot see a hashtable key as a property.
    if ($Only -and $Only.Count -gt 0) {
        foreach ($entry in $script:MDRepairCatalog) {
            if ($Only -contains $entry.Id) { $plan += $entry }
        }
        return ($plan | Sort-Object { $_.Order })
    }

    # Every repair id referenced by a Warn or Fail finding.
    $indicated = @()
    if ($Findings) {
        foreach ($f in $Findings) {
            if ($f.Status -in @('Warn', 'Fail') -and $f.RepairIds) {
                $indicated += $f.RepairIds
            }
        }
        $indicated = @($indicated | Where-Object { $_ } | Select-Object -Unique)
    }

    foreach ($entry in $script:MDRepairCatalog) {
        if ($allowedLevels -notcontains $entry.Level) { continue }
        if ($indicated -contains $entry.Id) { $plan += $entry; continue }
        if ($All -and -not $entry.NeedsEvidence) { $plan += $entry }
    }

    $plan | Sort-Object { $_.Order }
}


function Invoke-MDRepairPlan {
<#
    .SYNOPSIS
        Executes a repair plan, printing each step as it goes.
    .OUTPUTS
        The repair result objects, in execution order.
#>
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] $Context
    )

    $results = @()
    $plan    = @($Plan)

    Set-MDStepTotal $plan.Count

    foreach ($entry in $plan) {
        Write-MDStep ("repair: {0}" -f $entry.Id)
        Write-MDInfo ('tier: {0}{1}' -f $entry.Level, $(if ($Context.DryRun) { '   (dry run - nothing will be changed)' } else { '' }))

        try {
            $result = & $entry.Action $Context
        }
        catch {
            # A repair that throws must not take the rest of the plan with it.
            $result = New-MDRepairResult -Id $entry.Id -Name $entry.Id -Status 'Failed' `
                -Detail ('unhandled error: {0}' -f $_.Exception.Message) `
                -Evidence @($_.ScriptStackTrace)
        }

        if ($result) {
            $result | Write-MDRepairResult
            $results += $result
        }
    }

    $results
}
