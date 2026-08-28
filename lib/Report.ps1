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
        [Parameter(Mandatory)] $Findings
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
    $withheldIds = @()
    $plannedIds  = @($repairIds)

    if ($repairIds.Count -gt 0) {
        # Recommend the lowest tier that actually covers what was found, so we
        # never talk someone into a destructive repair they do not need.
        # Destructive actions are set aside rather than counted, so that one of
        # them cannot drag the recommended tier up for actions that do not need
        # it. A missing log directory implicating client.reinstall should still
        # recommend "Safe" for the ccmexec restart sitting next to it.
        $levelsNeeded = @()
        foreach ($id in $repairIds) {
            $entry = $script:MDRepairCatalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if (-not $entry) { continue }

            if ($entry.Level -eq 'Aggressive') { $withheldIds  += $entry.Id }
            else                               { $levelsNeeded += $entry.Level }
        }

        # The cap at Standard is the safety property of this whole function.
        # `repair` with no -Level runs whatever is recommended here, and -Force
        # answers every prompt on the way down - so if this were allowed to
        # return Aggressive, "mecmdoctor repair -Force" on a machine with a
        # missing CCM\Logs folder would uninstall and reinstall the client,
        # unattended, off the back of one modest finding.
        #
        # A destructive tier is reached only when the operator types
        # -Level Aggressive, or names the action outright with -Only. Nothing
        # a report concludes on its own is sufficient reason.
        $recommended = 'Safe'
        if ($levelsNeeded -contains 'Standard') { $recommended = 'Standard' }

        $withheldIds = @($withheldIds | Select-Object -Unique)
        $plannedIds  = @($repairIds | Where-Object { $withheldIds -notcontains $_ })
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
    elseif ($plannedIds.Count -eq 0) {
        # Everything the diagnosis implicated is destructive. There is nothing
        # to recommend here, only something to offer - and offering it is the
        # operator's decision to make, not the report's.
        Write-MDLine '  mecmdoctor repair -Level Aggressive -DryRun' -Color 'Cyan'
        Write-MDLine ''
        Write-MDDetail -Text ('The only repair action(s) this diagnosis implicated are destructive: {0}' -f ($withheldIds -join ', ')) -Indent 4 -Color 'DarkYellow'
        Write-MDDetail -Text 'mecmdoctor never escalates to a destructive tier on its own, so a plain "mecmdoctor repair" will find nothing to do here.' -Indent 4
        Write-MDDetail -Text 'Start with -DryRun above to see exactly what each one would do. Drop -DryRun only once you have read it and agree.' -Indent 4
    }
    else {
        Write-MDLine '  mecmdoctor repair' -Color 'Cyan'
        Write-MDLine ''
        Write-MDDetail -Text ('The diagnosis recommends the {0} tier, which is what repair uses unless you pass -Level yourself.' -f $recommended) -Indent 4
        Write-MDDetail -Text ('It would run {0} targeted repair action(s): {1}' -f $plannedIds.Count, ($plannedIds -join ', ')) -Indent 4
        Write-MDDetail -Text 'repair explains why each action is in the plan and asks before it changes anything.' -Indent 4
        Write-MDDetail -Text 'Add -DryRun to see exactly what would happen without changing anything.' -Indent 4

        if ($withheldIds.Count -gt 0) {
            Write-MDLine ''
            Write-MDDetail -Text ('The diagnosis also implicated {0} destructive action(s): {1}' -f $withheldIds.Count, ($withheldIds -join ', ')) -Indent 4 -Color 'DarkYellow'
            Write-MDDetail -Text 'They are deliberately left out of the recommendation above. A destructive repair is not something to run because a report suggested it.' -Indent 4 -Color 'DarkYellow'
            Write-MDDetail -Text 'To consider them, ask for them by name: mecmdoctor repair -Level Aggressive -DryRun. Each one still explains what it costs and asks for its own confirmation.' -Indent 4 -Color 'DarkYellow'
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

        # The destructive ids the diagnosis implicated but deliberately did not
        # recommend. Exposed so a caller (and the test suite) can see that the
        # cap above happened, rather than having to infer it from a tier name.
        Withheld    = $withheldIds
    }
}


function Write-MDRepairRationale {
<#
    .SYNOPSIS
        Prints the repair plan together with the reason each action is in it.
    .DESCRIPTION
        A list of action ids tells an operator what is about to happen but not
        why, which is exactly the information needed to decide whether to say
        yes. Every planned action is matched back to the findings that named
        it, so "wmi.salvage" reads as "because the repository verifies as
        inconsistent" rather than as a bare identifier.

        Actions with no matching finding are labelled as such - that is what
        -All and -Only produce, and it is worth seeing plainly.
#>
    param(
        [Parameter(Mandatory)] $Plan,
        $Findings,
        $Context
    )

    $plan = @($Plan)
    $all  = @($Findings)

    $rows = foreach ($p in $plan) {
        [pscustomobject]@{
            Order = $p.Order
            Id    = $p.Id
            Tier  = $p.Level
            Why   = @($all | Where-Object { $_.Status -in @('Warn', 'Fail') -and $_.RepairIds -contains $p.Id }).Count
        }
    }

    Write-MDTable -Rows $rows -Indent 2 -Columns @(
        @{ Header = '#';          Property = 'Order'; Width = 4 }
        @{ Header = 'ACTION ID';  Property = 'Id';    Width = 24 }
        @{ Header = 'TIER';       Property = 'Tier';  Width = 12 }
        @{ Header = 'FINDINGS';   Property = 'Why';   Width = 8 }
    ) -RowColor {
        param($r)
        switch ($r.Tier) { 'Aggressive' { 'Red' } 'Standard' { 'Yellow' } default { 'Gray' } }
    }

    Write-MDLine ''
    Write-MDLine '  Why each action is in the plan:' -Color 'White'

    foreach ($p in $plan) {
        $reasons = @($all | Where-Object { $_.Status -in @('Warn', 'Fail') -and $_.RepairIds -contains $p.Id })

        Write-MDLine ''
        Write-MDLine ('  {0}  [{1}]' -f $p.Id, $p.Level) -Color 'Cyan'

        if ($reasons.Count -eq 0) {
            Write-MDDetail -Indent 6 -Bullet '- ' -Color 'DarkYellow' `
                -Text 'No finding asked for this. It is in the plan because -All or -Only put it there.'
            continue
        }

        foreach ($r in ($reasons | Sort-Object -Property @{ Expression = { $_.Severity }; Descending = $true } | Select-Object -First 5)) {
            Write-MDDetail -Indent 6 -Bullet '- ' -Text ('{0}: {1} -- {2}' -f $r.Category, $r.Title, $r.Detail)
        }
        if ($reasons.Count -gt 5) {
            Write-MDDetail -Indent 6 -Bullet '- ' -Text ('and {0} more finding(s)' -f ($reasons.Count - 5))
        }

        # services.fix is the one action whose scope is not obvious from its id.
        if ($Context -and $p.Id -eq $script:MDRepairIds.ServicesFix) {
            $targets = @(Get-MDServiceRepairTargets -Names $Context.TargetServices | ForEach-Object { $_.Name })
            Write-MDDetail -Indent 6 -Bullet '> ' -Color 'DarkCyan' `
                -Text ('will touch only: {0}' -f ($targets -join ', '))
        }
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

        # .NET resolves a relative path against the process working directory,
        # which is not PowerShell's current location. -Json out.json would
        # otherwise land somewhere the operator did not ask for.
        $fullPath = $Path
        if (-not [System.IO.Path]::IsPathRooted($fullPath)) {
            $fullPath = Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $Path
        }

        # UTF-8 with no BOM, written directly rather than through Set-Content:
        # -Encoding UTF8 on PS 5.1 emits a byte-order mark, and this file is
        # explicitly meant to be eaten by a database, a Log Analytics
        # workspace or a Configuration Item. Python's json.load, several Go
        # parsers and a number of ingestion pipelines all reject a leading BOM.
        $json = $report | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($fullPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-MDOk ("Report written to {0}" -f $Path)
        return $true
    }
    catch {
        Write-MDFail ("Could not write the report to {0}: {1}" -f $Path, $_.Exception.Message)
        return $false
    }
}
