<#
    ===========================================================================
     MECM Client Wizard  --  lib\Report.ps1
    ---------------------------------------------------------------------------
     Turns a pile of findings into something a human can act on:

       * the summary table (every check, one line each)
       * the prioritised issue list with the actual fix for each
       * the "run this next" recommendation
       * an optional JSON export for fleet-wide collection

     Nothing here inspects or changes the machine - it only formats what the
     checks already produced.
    ===========================================================================
#>

function Get-MDStatusColor {
    <# Console colour for a finding status. Case-insensitive on purpose: the
       table renders statuses upper-cased, the findings carry mixed case. #>
    param([string] $Status)

    switch ("$Status".ToUpperInvariant()) {
        'PASS'  { 'Green' }
        'WARN'  { 'Yellow' }
        'FAIL'  { 'Red' }
        'SKIP'  { 'DarkGray' }
        default { 'Gray' }
    }
}


function Write-MDSummary {
<#
    .SYNOPSIS
        The end-of-diagnosis report.
    .OUTPUTS
        A summary object with the counts and the recommended next command,
        so the caller can set an exit code from it.
#>
    param(
        [Parameter(Mandatory)] $Findings,
        [string] $Level = 'Standard'
    )

    $all = @($Findings)

    $pass = @($all | Where-Object { $_.Status -eq 'Pass' })
    $warn = @($all | Where-Object { $_.Status -eq 'Warn' })
    $fail = @($all | Where-Object { $_.Status -eq 'Fail' })
    $skip = @($all | Where-Object { $_.Status -eq 'Skip' })
    $info = @($all | Where-Object { $_.Status -eq 'Info' })

    # ---- full result table -------------------------------------------------
    Write-MDSection 'Diagnosis summary'
    Write-MDLine ''

    $rows = foreach ($f in $all) {
        [pscustomobject]@{
            Category = $f.Category
            Title    = $f.Title
            Detail   = $f.Detail
            Result   = $f.Status.ToUpperInvariant()
        }
    }

    Write-MDTable -Rows $rows -Columns @(
        @{ Header = 'AREA';   Property = 'Category'; Width = 14 }
        @{ Header = 'CHECK';  Property = 'Title';    Width = 38 }
        @{ Header = 'DETAIL'; Property = 'Detail';   Width = 34 }
        @{ Header = 'RESULT'; Property = 'Result';   Width = 6 }
    ) -RowColor { param($r) Get-MDStatusColor $r.Result }

    # ---- counts ------------------------------------------------------------
    Write-MDLine ''
    Write-MDLine ('  Totals: {0} pass   {1} warn   {2} fail   {3} skipped   {4} info' -f
                  $pass.Count, $warn.Count, $fail.Count, $skip.Count, $info.Count) -Color 'White'

    # ---- prioritised issues ------------------------------------------------
    $issues = @($all | Where-Object { $_.Status -in @('Warn', 'Fail') } |
                Sort-Object -Property @{ Expression = { $_.Severity }; Descending = $true },
                                      @{ Expression = { $_.Category } })

    if ($issues.Count -eq 0) {
        Write-MDLine ''
        Write-MDOk 'No problems found. This client looks healthy.'
    }
    else {
        Write-MDSection ('Issues found ({0})' -f $issues.Count)

        $n = 0
        foreach ($f in $issues) {
            $n++
            Write-MDLine ''
            $label = '  {0}. [{1}] {2}' -f $n, $f.Category, $f.Title
            Write-MDLine $label -Color (Get-MDStatusColor $f.Status)

            if ($f.Detail)      { Write-MDDetail -Text $f.Detail -Indent 6 -Color 'Gray' }
            foreach ($e in $f.Evidence) {
                if (-not [string]::IsNullOrWhiteSpace($e)) { Write-MDDetail -Text $e -Indent 6 -Bullet '- ' }
            }
            if ($f.Remediation) { Write-MDDetail -Text ('FIX: ' + $f.Remediation) -Indent 6 -Bullet '> ' -Color 'DarkYellow' }
        }
    }

    # ---- what to run next --------------------------------------------------
    $repairIds = @()
    foreach ($f in $issues) { if ($f.RepairIds) { $repairIds += $f.RepairIds } }
    $repairIds = @($repairIds | Where-Object { $_ } | Select-Object -Unique)

    $recommended = $null
    if ($repairIds.Count -gt 0) {
        # Recommend the lowest tier that actually covers what was found, so we
        # never talk someone into a destructive repair they do not need.
        $levelsNeeded = @()
        foreach ($id in $repairIds) {
            $entry = $script:MDRepairCatalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($entry) { $levelsNeeded += $entry.Level }
        }

        $recommended = 'Safe'
        if ($levelsNeeded -contains 'Standard')   { $recommended = 'Standard' }
        if ($levelsNeeded -contains 'Aggressive') { $recommended = 'Aggressive' }
    }

    # A machine with no client at all is a reinstall job, not a repair job.
    # Recommending "repair -Level Aggressive" there would be technically true
    # and practically useless.
    $clientMissing = @($all | Where-Object {
        $_.Category -eq 'Client' -and $_.Title -eq 'Client installed' -and $_.Status -eq 'Fail'
    }).Count -gt 0

    Write-MDSection 'Recommended next step'
    Write-MDLine ''

    if ($clientMissing) {
        Write-MDLine '  mecmdoctor reinstall' -Color 'Cyan'
        Write-MDLine ''
        Write-MDDetail -Text 'No Configuration Manager client is installed on this machine, so there is nothing to repair.' -Indent 4
        Write-MDDetail -Text 'Put your own ClientReinstall.ps1 next to MECMDoctor.ps1 to control exactly how it is installed; otherwise mecmdoctor falls back to ccmsetup.exe with the site parameters it discovered.' -Indent 4
    }
    elseif (-not $recommended) {
        Write-MDLine '  Nothing to repair.' -Color 'Green'
    }
    else {
        Write-MDLine ('  mecmdoctor repair -Level {0}' -f $recommended) -Color 'Cyan'
        Write-MDLine ''
        Write-MDDetail -Text ('This will run {0} targeted repair action(s): {1}' -f $repairIds.Count, ($repairIds -join ', ')) -Indent 4
        Write-MDDetail -Text 'Add -DryRun first to see exactly what would happen without changing anything.' -Indent 4
        if ($recommended -eq 'Aggressive') {
            Write-MDDetail -Text 'Aggressive actions are destructive and will prompt before running. Add -Force only in an unattended run you have already validated.' -Indent 4 -Color 'DarkYellow'
        }
    }

    [pscustomobject]@{
        Pass        = $pass.Count
        Warn        = $warn.Count
        Fail        = $fail.Count
        Skip        = $skip.Count
        Info        = $info.Count
        Issues      = $issues.Count
        RepairIds   = $repairIds
        Recommended = $recommended
    }
}


function Write-MDRepairSummary {
    <# End-of-repair report. #>
    param([Parameter(Mandatory)] $Results)

    $all = @($Results)

    Write-MDSection 'Repair summary'
    Write-MDLine ''

    if ($all.Count -eq 0) {
        Write-MDLine '  No repair actions were run.' -Color 'Gray'
        return [pscustomobject]@{ Success = 0; Failed = 0; Skipped = 0; Manual = 0; DryRun = 0; RebootRecommended = $false }
    }

    $rows = foreach ($r in $all) {
        [pscustomobject]@{
            Action = $r.Id
            Name   = $r.Name
            Detail = $r.Detail
            Result = $r.Status.ToUpperInvariant()
        }
    }

    Write-MDTable -Rows $rows -Columns @(
        @{ Header = 'ACTION'; Property = 'Action'; Width = 20 }
        @{ Header = 'WHAT IT DID'; Property = 'Name'; Width = 40 }
        @{ Header = 'OUTCOME'; Property = 'Detail'; Width = 26 }
        @{ Header = 'RESULT'; Property = 'Result'; Width = 9 }
    ) -RowColor {
        param($r)
        switch ($r.Result) {
            'SUCCESS'   { 'Green' }
            'NOTNEEDED' { 'DarkGray' }
            'SKIPPED'   { 'DarkGray' }
            'DRYRUN'    { 'Cyan' }
            'MANUAL'    { 'Yellow' }
            default     { 'Red' }
        }
    }

    $ok      = @($all | Where-Object { $_.Status -eq 'Success' })
    $failed  = @($all | Where-Object { $_.Status -eq 'Failed' })
    $skipped = @($all | Where-Object { $_.Status -in @('Skipped', 'NotNeeded') })
    $manual  = @($all | Where-Object { $_.Status -eq 'Manual' })
    $dryRun  = @($all | Where-Object { $_.Status -eq 'DryRun' })
    $reboot  = @($all | Where-Object { $_.RebootRecommended })

    Write-MDLine ''
    Write-MDLine ('  Totals: {0} applied   {1} failed   {2} skipped   {3} need a human' -f
                  $ok.Count, $failed.Count, $skipped.Count, $manual.Count) -Color 'White'

    if ($dryRun.Count -gt 0) {
        Write-MDLine ''
        Write-MDInfo ('{0} action(s) were simulated. Nothing on this machine was changed.' -f $dryRun.Count)
        Write-MDDetail -Text 'Re-run the same command without -DryRun to apply them.' -Indent 4
    }

    if ($manual.Count -gt 0) {
        Write-MDLine ''
        Write-MDWarn 'Some issues cannot be fixed automatically:'
        foreach ($m in $manual) {
            Write-MDDetail -Text $m.Name -Indent 6 -Bullet '> ' -Color 'Yellow'
            foreach ($e in $m.Evidence) { Write-MDDetail -Text $e -Indent 9 }
        }
    }

    if ($reboot.Count -gt 0) {
        Write-MDLine ''
        Write-MDWarn 'A reboot is recommended before the client will be fully healthy again.'
        foreach ($r in $reboot) { Write-MDDetail -Text $r.Name -Indent 6 -Bullet '- ' }
    }

    Write-MDLine ''
    Write-MDLine '  Re-run "mecmdoctor diagnose" in 15-30 minutes to confirm the client has recovered.' -Color 'Cyan'
    Write-MDDetail -Text 'Policy download, registration and update scans are all asynchronous; checking immediately will show stale state.' -Indent 4

    [pscustomobject]@{
        Success           = $ok.Count
        Failed            = $failed.Count
        Skipped           = $skipped.Count
        Manual            = $manual.Count
        DryRun            = $dryRun.Count
        RebootRecommended = ($reboot.Count -gt 0)
    }
}


function Export-MDReport {
<#
    .SYNOPSIS
        Writes the whole run to JSON, for collection across a fleet.
    .DESCRIPTION
        The shape is deliberately flat and stable so it can be piped straight
        into a database, a log analytics workspace, or a MECM Configuration
        Item without any further parsing.
#>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $ClientInfo,
        $Findings,
        $RepairResults,
        $HostFacts,
        [string] $Command = 'diagnose',
        [string] $Version = '1.0.0'
    )

    try {
        $report = [ordered]@{
            schema        = 'mecmdoctor/1'
            toolVersion   = $Version
            command       = $Command
            generated     = (Get-Date).ToString('o')
            computerName  = $env:COMPUTERNAME
            host          = $HostFacts
            client        = [ordered]@{
                installed       = $ClientInfo.Installed
                version         = $ClientInfo.Version
                installPath     = $ClientInfo.InstallPath
                logPath         = $ClientInfo.LogPath
                siteCode        = $ClientInfo.SiteCode
                managementPoint = $ClientInfo.ManagementPoint
                clientId        = $ClientInfo.ClientId
                cacheLocation   = $ClientInfo.CacheLocation
                cacheSizeMB     = $ClientInfo.CacheSizeMB
                httpsOnly       = $ClientInfo.HttpsOnly
            }
            findings      = @(foreach ($f in @($Findings)) {
                [ordered]@{
                    category    = $f.Category
                    title       = $f.Title
                    status      = $f.Status
                    severity    = $f.Severity
                    detail      = $f.Detail
                    evidence    = @($f.Evidence)
                    remediation = $f.Remediation
                    repairIds   = @($f.RepairIds)
                }
            })
            repairs       = @(foreach ($r in @($RepairResults)) {
                [ordered]@{
                    id                = $r.Id
                    name              = $r.Name
                    status            = $r.Status
                    detail            = $r.Detail
                    evidence          = @($r.Evidence)
                    rebootRecommended = $r.RebootRecommended
                }
            })
        }

        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        Write-MDOk ("Report written to {0}" -f $Path)
        return $true
    }
    catch {
        Write-MDFail ("Could not write the report to {0}: {1}" -f $Path, $_.Exception.Message)
        return $false
    }
}
