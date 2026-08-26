<#
    ===========================================================================
     MECM Client Wizard  --  lib\LogParser.ps1
    ---------------------------------------------------------------------------
     Reads and interprets the logs under C:\Windows\CCM\Logs.

     What makes this worth having over "open CMTrace and squint":
       * both on-disk log formats are handled (the modern <![LOG[...]]> form
         and the old  message $$<component><time><thread=..>  form)
       * rolled-over logs (*.lo_) are read as well, so a failure that happened
         an hour ago is not lost
       * identical repeated lines are collapsed into one entry with a count,
         which is the difference between 900 lines of noise and 6 real problems
       * every error code found is run through the catalogue in ErrorCatalog.ps1
         and printed in English with a suggested fix
    ===========================================================================
#>

# ---------------------------------------------------------------------------
# Which logs matter, and why. The Area field ties a log back to the diagnostic
# category it belongs to, so `diagnose` can show log evidence next to the
# check it supports.
# ---------------------------------------------------------------------------
$script:MDLogMap = @(
    @{ Name = 'ClientIDManagerStartup.log'; Area = 'Registration'; Why = 'client identity, GUID assignment and registration' }
    @{ Name = 'ClientLocation.log';         Area = 'Registration'; Why = 'site assignment and management point lookup' }
    @{ Name = 'LocationServices.log';       Area = 'Registration'; Why = 'MP/DP location requests and boundary resolution' }
    @{ Name = 'CcmMessaging.log';           Area = 'Registration'; Why = 'all client-to-MP message traffic' }
    @{ Name = 'ClientAuth.log';             Area = 'Certificates'; Why = 'client authentication token / certificate selection' }
    @{ Name = 'CertificateMaintenance.log'; Area = 'Certificates'; Why = 'certificate store maintenance and self-signed cert renewal' }
    @{ Name = 'CcmExec.log';                Area = 'Service';      Why = 'SMS Agent Host startup, shutdown and provider state' }
    @{ Name = 'PolicyAgent.log';            Area = 'Policy';       Why = 'policy requests and downloads from the MP' }
    @{ Name = 'PolicyEvaluator.log';        Area = 'Policy';       Why = 'policy compilation and application into WMI' }
    @{ Name = 'StatusAgent.log';            Area = 'Policy';       Why = 'status message generation' }
    @{ Name = 'ScanAgent.log';              Area = 'Updates';      Why = 'software update scan requests' }
    @{ Name = 'WUAHandler.log';             Area = 'Updates';      Why = 'Windows Update Agent interaction - the real update errors live here' }
    @{ Name = 'UpdatesDeployment.log';      Area = 'Updates';      Why = 'update deployment evaluation, enforcement and reboots' }
    @{ Name = 'UpdatesHandler.log';         Area = 'Updates';      Why = 'update download and install orchestration' }
    @{ Name = 'UpdatesStore.log';           Area = 'Updates';      Why = 'compliance state of each update' }
    @{ Name = 'CAS.log';                    Area = 'Content';      Why = 'content access service - cache decisions and content location' }
    @{ Name = 'ContentTransferManager.log'; Area = 'Content';      Why = 'content transfer job creation and state' }
    @{ Name = 'DataTransferService.log';    Area = 'Content';      Why = 'BITS download detail including HTTP status codes' }
    @{ Name = 'execmgr.log';                Area = 'Software';     Why = 'package/program execution' }
    @{ Name = 'AppEnforce.log';             Area = 'Software';     Why = 'application install command lines and their exit codes' }
    @{ Name = 'AppIntentEval.log';          Area = 'Software';     Why = 'application deployment intent evaluation' }
    @{ Name = 'AppDiscovery.log';           Area = 'Software';     Why = 'application detection method results' }
    @{ Name = 'InventoryAgent.log';         Area = 'Inventory';    Why = 'hardware and software inventory cycles' }
    @{ Name = 'CcmEval.log';                Area = 'Health';       Why = 'Microsoft client health evaluation' }

    # ccmsetup logs live outside the CCM log root, so this entry carries an
    # absolute path. Get-MDLogFileSet honours a rooted Name verbatim.
    @{ Name = (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log'); Area = 'Install'; Why = 'client installation and upgrade' }
)

# Lines matching these are noise: expected, high-volume, and never actionable.
# Filtering them out is what keeps the report readable.
$script:MDLogNoise = @(
    'Raising event:\s*$'
    'Successfully sent'
    'Sleeping for \d+'
    'Message Body:'
    'Persisted state'
    'Attempting to send'
    'CTM job .* (started|suspended|resumed)'
    'Successfully created'
)


function Get-MDLogTail {
<#
    .SYNOPSIS
        Reads the tail of a log file without loading a huge file into memory,
        and without tripping over the share lock CcmExec holds on it.
    .PARAMETER MaxBytes
        How much of the end of the file to read. CCM logs roll at a few hundred
        KB, so 2 MB comfortably covers a whole log plus its rollover.
#>
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $MaxBytes = 2MB
    )

    try {
        # FileShare::ReadWrite is essential - CcmExec keeps these files open.
        $fs = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
    }
    catch {
        Write-MDDebug ("cannot open log '{0}': {1}" -f $Path, $_.Exception.Message)
        return $null
    }

    try {
        $skipPartialFirstLine = $false
        if ($fs.Length -gt $MaxBytes) {
            [void]$fs.Seek(-$MaxBytes, [System.IO.SeekOrigin]::End)
            $skipPartialFirstLine = $true
        }

        # CCM logs are UTF-8 (sometimes with a BOM); detectEncodingFromByteOrderMarks
        # handles the UTF-16 logs a few older components still emit.
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        $text   = $reader.ReadToEnd()
        $reader.Dispose()

        if ($skipPartialFirstLine) {
            $nl = $text.IndexOf("`n")
            if ($nl -ge 0) { $text = $text.Substring($nl + 1) }
        }
        return $text
    }
    catch {
        Write-MDDebug ("cannot read log '{0}': {1}" -f $Path, $_.Exception.Message)
        return $null
    }
    finally {
        try { $fs.Dispose() } catch { }
    }
}


function ConvertFrom-MDLogText {
<#
    .SYNOPSIS
        Parses raw log text into entry objects.
    .DESCRIPTION
        Handles both formats emitted by Configuration Manager components:

          <![LOG[message]LOG]!><time="14:23:45.123-300" date="08-25-2026"
              component="X" context="" type="3" thread="4532" file="y.cpp:12">

          message   $$<X><08-25-2026 14:23:45.123-300><thread=4532 (0x11B4)>

        Anything that matches neither is returned as a plain untyped line so
        that nothing is silently dropped.
#>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [string] $LogName = ''
    )

    $entries = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Text)) { return $entries }

    # --- modern format ------------------------------------------------------
    # Singleline so a message containing newlines is captured whole.
    $modern = [regex]::Matches(
        $Text,
        '<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<time>[^"]*)"\s+date="(?<date>[^"]*)"\s+component="(?<comp>[^"]*)"\s+context="(?<ctx>[^"]*)"\s+type="(?<type>\d+)"\s+thread="(?<thread>[^"]*)"',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

    foreach ($m in $modern) {
        $entries.Add((New-MDLogEntry `
            -Message  $m.Groups['msg'].Value `
            -TimeText $m.Groups['time'].Value `
            -DateText $m.Groups['date'].Value `
            -Component $m.Groups['comp'].Value `
            -Type     ([int]$m.Groups['type'].Value) `
            -Thread   $m.Groups['thread'].Value `
            -LogName  $LogName))
    }

    if ($entries.Count -gt 0) { return $entries }

    # --- legacy format ------------------------------------------------------
    $legacy = [regex]::Matches(
        $Text,
        '(?m)^(?<msg>.*?)\s+\$\$<(?<comp>[^>]*)><(?<stamp>[^>]+)><thread=(?<thread>[^>\s]+)')

    foreach ($m in $legacy) {
        $stamp = $m.Groups['stamp'].Value.Trim()
        $d = ''
        $t = ''
        if ($stamp -match '^(?<d>[\d\-/]+)\s+(?<t>[\d:\.\+\-]+)$') {
            $d = $Matches['d']
            $t = $Matches['t']
        }
        # The legacy header has no severity field; infer it from the wording.
        $type = 1
        if ($m.Groups['msg'].Value -match '(?i)\bwarn') { $type = 2 }
        if ($m.Groups['msg'].Value -match '(?i)(\berror\b|\bfail)') { $type = 3 }

        $entries.Add((New-MDLogEntry `
            -Message  $m.Groups['msg'].Value `
            -TimeText $t `
            -DateText $d `
            -Component $m.Groups['comp'].Value `
            -Type     $type `
            -Thread   $m.Groups['thread'].Value `
            -LogName  $LogName))
    }

    if ($entries.Count -gt 0) { return $entries }

    # --- unparsed fallback --------------------------------------------------
    # ccmsetup.log and a few others sometimes contain plain lines. Keep them
    # rather than reporting "no entries" on a log that clearly has content.
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $type = 1
        if ($line -match '(?i)\bwarn') { $type = 2 }
        if ($line -match '(?i)(\berror\b|\bfail)') { $type = 3 }
        $entries.Add((New-MDLogEntry -Message $line -Component '' -Type $type -LogName $LogName))
    }

    $entries
}


function New-MDLogEntry {
    <# Builds one parsed log entry, resolving the timestamp as best it can. #>
    param(
        [AllowEmptyString()][string] $Message,
        [AllowEmptyString()][string] $TimeText = '',
        [AllowEmptyString()][string] $DateText = '',
        [AllowEmptyString()][string] $Component = '',
        [int] $Type = 1,
        [AllowEmptyString()][string] $Thread = '',
        [string] $LogName = ''
    )

    $when = $null
    if ($TimeText -and $DateText) {
        # Strip the trailing UTC bias ("14:23:45.123-300") before parsing; the
        # bias is minutes-from-UTC and .NET will not accept it as an offset.
        $clean = $TimeText -replace '[\+\-]\d{1,4}$', ''
        $stamp = "$DateText $clean"
        $formats = @(
            'MM-dd-yyyy HH:mm:ss.fff'
            'M-d-yyyy HH:mm:ss.fff'
            'MM-dd-yyyy HH:mm:ss'
            'M-d-yyyy HH:mm:ss'
            'dd-MM-yyyy HH:mm:ss.fff'
        )
        $parsed = [datetime]::MinValue
        foreach ($f in $formats) {
            if ([datetime]::TryParseExact($stamp, $f, [Globalization.CultureInfo]::InvariantCulture,
                                          [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                $when = $parsed
                break
            }
        }
    }

    [pscustomobject]@{
        Time      = $when
        Component = $Component
        Type      = $Type          # 1 info, 2 warning, 3 error
        Thread    = $Thread
        Message   = ($Message -replace '\s+', ' ').Trim()
        LogName   = $LogName
    }
}


function Get-MDLogFileSet {
<#
    .SYNOPSIS
        Resolves a logical log name to the files that hold it: the live log
        plus its rollover (.lo_) sibling, newest last.
#>
    param(
        [Parameter(Mandatory)][string] $LogRoot,
        [Parameter(Mandatory)][string] $Name
    )

    # A rooted Name (e.g. the ccmsetup log) is used as-is; everything else is
    # resolved relative to the client log directory.
    if ([System.IO.Path]::IsPathRooted($Name)) { $primary = $Name }
    else                                       { $primary = Join-Path $LogRoot $Name }

    $files = @()

    if (Test-Path -LiteralPath $primary) { $files += (Get-Item -LiteralPath $primary) }

    # CCM renames the previous log to <name>.lo_ when it rolls.
    $rolled = [System.IO.Path]::ChangeExtension($primary, '.lo_')
    if (Test-Path -LiteralPath $rolled) { $files += (Get-Item -LiteralPath $rolled) }

    $files | Sort-Object LastWriteTime
}


function Get-MDLogIssues {
<#
    .SYNOPSIS
        The workhorse: scans the requested logs and returns de-duplicated,
        translated problem entries.

    .PARAMETER Since
        Only consider entries newer than this. Entries with an unparseable
        timestamp are always kept - dropping them would hide real failures.

    .PARAMETER MinType
        2 = warnings and errors, 3 = errors only.

    .OUTPUTS
        One object per distinct problem, with Count, First/Last seen, the
        matched catalogue entry, and a representative message.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LogRoot,
        [string[]] $Names,
        [string]   $Area,
        [datetime] $Since = ([datetime]::MinValue),
        [ValidateSet(2, 3)][int] $MinType = 3,
        [int] $MaxPerLog = 8
    )

    $results = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $LogRoot)) {
        Write-MDDebug "log root not found: $LogRoot"
        return $results
    }

    # Decide which logs to scan.
    $targets = $script:MDLogMap
    if ($Area)  { $targets = $targets | Where-Object { $_.Area -eq $Area } }
    if ($Names) { $targets = $targets | Where-Object { $Names -contains $_.Name } }

    foreach ($target in $targets) {
        # Display name is always the leaf, even when the map entry is absolute.
        $display = [System.IO.Path]::GetFileName($target.Name)

        $files = Get-MDLogFileSet -LogRoot $LogRoot -Name $target.Name
        if (-not $files) {
            Write-MDDebug ("log not present: {0}" -f $display)
            continue
        }

        # Bucket key -> aggregate. Collapsing repeats is what makes the output
        # readable; a single failing update can emit the same line 400 times.
        $buckets = @{}

        foreach ($file in $files) {
            $text = Get-MDLogTail -Path $file.FullName
            if (-not $text) { continue }

            foreach ($entry in (ConvertFrom-MDLogText -Text $text -LogName $display)) {

                if ($entry.Type -lt $MinType) { continue }
                if ($entry.Time -and $entry.Time -lt $Since) { continue }
                if ([string]::IsNullOrWhiteSpace($entry.Message)) { continue }

                $isNoise = $false
                foreach ($n in $script:MDLogNoise) {
                    if ($entry.Message -match $n) { $isNoise = $true; break }
                }
                if ($isNoise) { continue }

                # Pull every error code out of the line and keep the first that
                # the catalogue recognises, falling back to the first found.
                $codes = @()
                foreach ($m in [regex]::Matches($entry.Message, '0x[0-9A-Fa-f]{8}')) { $codes += $m.Value }
                foreach ($m in [regex]::Matches($entry.Message, '(?i)(?:error|hr|status|code|rc)[\s=:]+(-?\d{4,10})\b')) {
                    $codes += $m.Groups[1].Value
                }

                $resolved = $null
                foreach ($c in $codes) {
                    $r = Resolve-MDError $c
                    if ($r -and $r.Known) { $resolved = $r; break }
                    if ($r -and -not $resolved) { $resolved = $r }
                }

                $pattern = Resolve-MDPattern -Message $entry.Message -LogName $display

                # Nothing recognised and only a warning: not worth surfacing.
                if (-not $resolved -and -not $pattern -and $entry.Type -lt 3) { continue }

                # Key on the code when we have one, otherwise on a normalised
                # prefix of the message, so near-identical lines merge.
                if ($resolved) {
                    $key = '{0}|{1}|{2}' -f $display, $entry.Component, $resolved.Code
                }
                else {
                    $norm = ($entry.Message -replace '\{[0-9A-Fa-f\-]{36}\}', '{GUID}' `
                                            -replace '\b\d{4,}\b', '#')
                    if ($norm.Length -gt 90) { $norm = $norm.Substring(0, 90) }
                    $key = '{0}|{1}|{2}' -f $display, $entry.Component, $norm
                }

                if ($buckets.ContainsKey($key)) {
                    $b = $buckets[$key]
                    $b.Count++
                    if ($entry.Time -and (-not $b.LastSeen -or $entry.Time -gt $b.LastSeen))  { $b.LastSeen  = $entry.Time; $b.Message = $entry.Message }
                    if ($entry.Time -and (-not $b.FirstSeen -or $entry.Time -lt $b.FirstSeen)) { $b.FirstSeen = $entry.Time }
                }
                else {
                    $buckets[$key] = [pscustomobject]@{
                        LogName    = $display
                        LogArea    = $target.Area
                        Component  = $entry.Component
                        Type       = $entry.Type
                        Message    = $entry.Message
                        Count      = 1
                        FirstSeen  = $entry.Time
                        LastSeen   = $entry.Time
                        Error      = $resolved
                        Pattern    = $pattern
                    }
                }
            }
        }

        # Newest first, capped, so one chatty log cannot drown the report.
        $ordered = $buckets.Values |
                   Sort-Object -Property @{ Expression = { $_.LastSeen }; Descending = $true },
                                         @{ Expression = { $_.Count };    Descending = $true } |
                   Select-Object -First $MaxPerLog

        foreach ($o in $ordered) { $results.Add($o) | Out-Null }
    }

    $results
}


function Write-MDLogIssue {
<#
    .SYNOPSIS
        Renders one parsed log problem: the headline, the raw line, and the
        translation from the error catalogue.
#>
    param([Parameter(Mandatory, ValueFromPipeline)] $Issue)

    process {
        $when = '(no timestamp)'
        if ($Issue.LastSeen) { $when = $Issue.LastSeen.ToString('MM-dd HH:mm:ss') }

        $repeat = ''
        if ($Issue.Count -gt 1) { $repeat = ' (x{0})' -f $Issue.Count }

        $headline = '{0} [{1}] {2}{3}' -f $when, $Issue.Component, $Issue.LogName, $repeat

        if ($Issue.Type -ge 3) { Write-MDFail $headline -Component $Issue.LogArea }
        else                   { Write-MDWarn $headline -Component $Issue.LogArea }

        Write-MDDetail -Text $Issue.Message -Bullet '| '

        if ($Issue.Error) {
            Write-MDDetail -Text ('{0}  {1}' -f $Issue.Error.Code, $Issue.Error.Name) -Bullet '> ' -Color 'White'
            Write-MDDetail -Text $Issue.Error.Means -Bullet '  '
            if ($Issue.Error.Fix) { Write-MDDetail -Text ('fix: ' + $Issue.Error.Fix) -Bullet '  ' -Color 'DarkYellow' }
        }

        if ($Issue.Pattern) {
            Write-MDDetail -Text $Issue.Pattern.Means -Bullet '> ' -Color 'White'
            if ($Issue.Pattern.Fix) { Write-MDDetail -Text ('fix: ' + $Issue.Pattern.Fix) -Bullet '  ' -Color 'DarkYellow' }
        }
    }
}


function Invoke-MDLogReport {
<#
    .SYNOPSIS
        The `mecmdoctor logs` command: walk every known log area, print what
        was found, and return findings so the caller can fold them into the
        overall diagnosis.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LogRoot,
        [int] $Days = 7,
        [ValidateSet(2, 3)][int] $MinType = 3,
        [int] $MaxPerLog = 6
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $since    = (Get-Date).AddDays(-$Days)

    if (-not (Test-Path -LiteralPath $LogRoot)) {
        Write-MDFail ("Log directory not found: {0}" -f $LogRoot)
        $findings.Add((New-MDFinding -Category 'Logs' -Title 'CCM log directory' -Status 'Fail' `
            -Detail "not found at $LogRoot" `
            -Remediation 'The client is not installed, or its install path is unknown. Run: mecmdoctor diagnose' `
            -RepairIds @($script:MDRepairIds.ClientReinstall))) | Out-Null
        return $findings
    }

    # The map entries are hashtables, so pull the key out by hand -
    # Select-Object -ExpandProperty cannot see a hashtable key as a property.
    $areas = @($script:MDLogMap | ForEach-Object { $_.Area } | Select-Object -Unique)
    Set-MDStepTotal $areas.Count

    foreach ($area in $areas) {
        Write-MDStep ("$area logs")

        $logsInArea = ($script:MDLogMap | Where-Object { $_.Area -eq $area })
        foreach ($l in $logsInArea) {
            $files = Get-MDLogFileSet -LogRoot $LogRoot -Name $l.Name
            if ($files) {
                $newest = ($files | Select-Object -Last 1)
                Write-MDDebug ('{0}: {1}, last written {2}' -f [System.IO.Path]::GetFileName($l.Name), (Format-MDBytes $newest.Length), (Format-MDAge $newest.LastWriteTime))
            }
        }

        $issues = Get-MDLogIssues -LogRoot $LogRoot -Area $area -Since $since -MinType $MinType -MaxPerLog $MaxPerLog

        if (-not $issues -or $issues.Count -eq 0) {
            Write-MDOk ("No errors in the last {0} day(s) across: {1}" -f $Days, (($logsInArea | ForEach-Object { [System.IO.Path]::GetFileName($_.Name) }) -join ', '))
            $findings.Add((New-MDFinding -Category 'Logs' -Title ("$area logs") -Status 'Pass' `
                -Detail ("clean over the last $Days day(s)"))) | Out-Null
            continue
        }

        $issues | Write-MDLogIssue

        # Roll the log evidence up into one finding per area, carrying the
        # repair suggestions implied by the codes we recognised.
        $repairIds = @()
        foreach ($i in $issues) {
            switch ($i.LogArea) {
                'Registration' { $repairIds += $script:MDRepairIds.CcmRestart;   $repairIds += $script:MDRepairIds.PolicyTrigger }
                'Policy'       { $repairIds += $script:MDRepairIds.PolicyReset }
                'Updates'      { $repairIds += $script:MDRepairIds.UpdatesReset; $repairIds += $script:MDRepairIds.UpdatesRescan }
                'Content'      { $repairIds += $script:MDRepairIds.CacheClear;   $repairIds += $script:MDRepairIds.BitsClear }
                'WMI'          { $repairIds += $script:MDRepairIds.WmiSalvage }
                'Certificates' { $repairIds += $script:MDRepairIds.CcmRestart }
            }
        }

        $evidence = foreach ($i in ($issues | Select-Object -First 4)) {
            $code = ''
            if ($i.Error) { $code = $i.Error.Code + ' ' }
            '{0}: {1}{2}' -f $i.LogName, $code, ($i.Message.Substring(0, [Math]::Min(120, $i.Message.Length)))
        }

        $findings.Add((New-MDFinding -Category 'Logs' -Title ("$area logs") -Status 'Fail' `
            -Detail ("{0} distinct error(s) in the last {1} day(s)" -f $issues.Count, $Days) `
            -Evidence $evidence `
            -Remediation (($issues | Where-Object { $_.Error } | Select-Object -First 1).Error.Fix) `
            -RepairIds ($repairIds | Select-Object -Unique))) | Out-Null
    }

    $findings
}
