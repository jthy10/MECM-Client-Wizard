<#
    ===========================================================================
     MECM Client Wizard  --  lib\Common.ps1
    ---------------------------------------------------------------------------
     Shared plumbing used by both the diagnostics and the repair engine:

       * the Finding object (the single currency the whole tool trades in)
       * safe wrappers around CIM/WMI, the registry, services and processes
       * MECM client discovery (install path, version, site code, MP, cache)

     Every helper in here is written to fail soft. A broken client is exactly
     the situation where Get-CimInstance throws, so nothing may assume success.
    ===========================================================================
#>

# ---------------------------------------------------------------------------
# Repair action identifiers.
# Findings reference these so that `repair` knows what to run, and so that the
# user can target a single fix with `-Only`. Kept as a lookup rather than bare
# strings so a typo in a check surfaces immediately instead of silently
# producing a repair that never fires.
# ---------------------------------------------------------------------------
$script:MDRepairIds = @{
    ServicesFix       = 'services.fix'          # start/enable the services the client needs
    CcmRestart        = 'ccmexec.restart'       # bounce the SMS Agent Host
    WmiVerify         = 'wmi.verify'            # winmgmt /verifyrepository
    WmiSalvage        = 'wmi.salvage'           # winmgmt /salvagerepository
    WmiReset          = 'wmi.reset'             # winmgmt /resetrepository  (destructive)
    PolicyReset       = 'policy.reset'          # SMS_Client.ResetPolicy(1) - purge + redownload
    PolicyTrigger     = 'policy.trigger'        # kick the machine policy schedules
    ClientRepair      = 'client.repair'         # ccmrepair.exe / SMS_Client.RepairClient
    ClientReinstall   = 'client.reinstall'      # full uninstall + reinstall  (destructive)
    CacheClear        = 'cache.clear'           # purge the CCM content cache
    BitsClear         = 'bits.clear'            # remove failed/stale BITS jobs
    UpdatesReset      = 'updates.reset'         # rebuild SoftwareDistribution + catroot2
    UpdatesRescan     = 'updates.rescan'        # force a software update scan/eval cycle
    GpRepairPol       = 'gp.repair-pol'         # quarantine corrupt Registry.pol, re-apply
    GpResetState      = 'gp.reset-state'        # clear GP history/state keys  (destructive)
    GpResetSecEdit    = 'gp.reset-secedit'      # rebuild secedit.sdb          (destructive)
    CcmEvalRun        = 'ccmeval.run'           # run Microsoft's own client health eval
    DiskSpace         = 'manual.diskspace'      # nothing safe to automate - operator task
    Reboot            = 'manual.reboot'         # never automated, always the operator's call
}


function New-MDFinding {
<#
    .SYNOPSIS
        Creates one diagnostic result. This is the only object the report,
        the summary table, the JSON export and the repair planner consume.

    .PARAMETER Status
        Pass  - healthy, nothing to do
        Warn  - degraded or suspicious, worth a look
        Fail  - broken, will cause user-visible symptoms
        Info  - neutral fact worth recording (client version, site code, ...)
        Skip  - could not be evaluated (not applicable, or a prerequisite failed)

    .PARAMETER Severity
        Used purely for ordering the "top issues" list: 0 none .. 4 critical.

    .PARAMETER RepairIds
        Zero or more $script:MDRepairIds values that would address this finding.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail', 'Info', 'Skip')][string] $Status,
        [string]   $Detail = '',
        [string[]] $Evidence = @(),
        [string]   $Remediation = '',
        [string[]] $RepairIds = @(),
        [ValidateRange(0, 4)][int] $Severity = -1,
        $Data = $null
    )

    # Sensible default severity derived from status, so callers only have to
    # override it when a warning is unusually important (or a failure is not).
    if ($Severity -lt 0) {
        switch ($Status) {
            'Fail'  { $Severity = 3 }
            'Warn'  { $Severity = 2 }
            default { $Severity = 0 }
        }
    }

    [pscustomobject]@{
        PSTypeName  = 'MECMDoctor.Finding'
        Category    = $Category
        Title       = $Title
        Status      = $Status
        Severity    = $Severity
        Detail      = $Detail
        Evidence    = @($Evidence)
        Remediation = $Remediation
        RepairIds   = @($RepairIds)
        Data        = $Data
        Timestamp   = (Get-Date)
    }
}


function Write-MDFinding {
<#
    .SYNOPSIS
        Prints a finding using the right status tag, then its supporting detail.
    .DESCRIPTION
        Keeping this in one place is what makes every check render identically
        no matter who wrote it.
#>
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Finding,
        [switch] $HideEvidence
    )
    process {
        $component = $Finding.Category -replace '\s', ''
        $headline  = $Finding.Title
        if ($Finding.Detail) { $headline = $Finding.Title + ' -- ' + $Finding.Detail }

        # A check that passed is the running commentary; a check that did not
        # is the reason the tool was run. -Quiet keeps the second and drops the
        # first from the screen. Both are always written to the transcripts.
        $chatter = ($Finding.Status -notin @('Warn', 'Fail'))

        switch ($Finding.Status) {
            'Pass' { Write-MDOk   $headline -Component $component -Chatter }
            'Warn' { Write-MDWarn $headline -Component $component }
            'Fail' { Write-MDFail $headline -Component $component }
            'Skip' { Write-MDSkip $headline -Component $component -Chatter }
            default { Write-MDInfo $headline -Component $component -Chatter }
        }

        if (-not $HideEvidence -and $Finding.Evidence -and $Finding.Evidence.Count) {
            foreach ($line in $Finding.Evidence) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                Write-MDDetail -Text $line -Bullet '- ' -Chatter:$chatter
            }
        }

        if ($Finding.Remediation -and $Finding.Status -in @('Warn', 'Fail')) {
            Write-MDDetail -Text ('fix: ' + $Finding.Remediation) -Bullet '> ' -Color 'DarkYellow'
        }
    }
}


# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

function Test-MDAdmin {
    <# True when the current process is elevated. #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $false }
}


function Get-MDHostFacts {
    <# The block of context printed under the banner and stored in the report. #>
    $facts = [ordered]@{}

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop

        $facts['Computer']       = $env:COMPUTERNAME
        $facts['Domain']         = $cs.Domain
        $facts['Manufacturer']   = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        $facts['OS']             = ('{0} ({1})' -f $os.Caption, $os.Version)
        $facts['Last boot']      = $os.LastBootUpTime
        $facts['Uptime']         = '{0:%d}d {0:%h}h {0:%m}m' -f ((Get-Date) - $os.LastBootUpTime)
    }
    catch {
        $facts['Computer'] = $env:COMPUTERNAME
        $facts['OS']       = 'unavailable (WMI query failed): ' + $_.Exception.Message
    }

    $facts['Windows release'] = (Get-MDWindowsRelease).Text
    $facts['User context']    = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $facts['Elevated']        = if (Test-MDAdmin) { 'yes' } else { 'NO - most checks and all repairs need admin' }
    $facts['PowerShell']      = $PSVersionTable.PSVersion.ToString()
    $facts['Architecture']    = $env:PROCESSOR_ARCHITECTURE
    $facts['Started']         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K')

    $facts
}


function Get-MDWindowsRelease {
<#
    .SYNOPSIS
        Identifies the Windows release precisely enough to pick the right
        policy semantics for it.
    .DESCRIPTION
        Several Windows Update policies were replaced outright at specific
        builds, so "is this Windows 11" is not a detail - it decides whether a
        missing registry value is a misconfiguration or simply not applicable.

        Read from the registry rather than Win32_OperatingSystem: this has to
        keep working on a machine whose WMI repository is the thing that is
        broken.
    .OUTPUTS
        [pscustomobject] Build / Caption / DisplayVersion / IsServer /
        IsWindows11 / Name
#>
    [CmdletBinding()]
    param()

    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $build = 0
    $raw   = Get-MDRegValue -Path $cv -Name 'CurrentBuildNumber'
    if ($raw) { [void][int]::TryParse("$raw", [ref]$build) }
    if ($build -le 0) {
        try { $build = [Environment]::OSVersion.Version.Build } catch { $build = 0 }
    }

    # UBR is the fourth part of the full build string (10.0.22631.4317).
    $ubr = Get-MDRegValue -Path $cv -Name 'UBR'

    $caption = Get-MDRegValue -Path $cv -Name 'ProductName'
    if (-not $caption) { $caption = 'Windows' }

    # DisplayVersion (22H2) replaced ReleaseId (2009) at Windows 10 20H2.
    $display = Get-MDRegValue -Path $cv -Name 'DisplayVersion'
    if (-not $display) { $display = Get-MDRegValue -Path $cv -Name 'ReleaseId' }

    $installType = Get-MDRegValue -Path $cv -Name 'InstallationType'
    $isServer    = ("$installType" -match '(?i)server')

    # Windows 11 kept ProductName as "Windows 10" for its whole first year, so
    # the build number is the only trustworthy discriminator.
    $isWin11 = (-not $isServer) -and ($build -ge 22000)

    $name = $caption
    if ($isWin11 -and $caption -notmatch '11') { $name = $caption -replace '10', '11' }

    $full = "$build"
    if ($ubr) { $full = '{0}.{1}' -f $build, $ubr }

    [pscustomobject]@{
        Build          = $build
        BuildFull      = $full
        Caption        = $caption
        Name           = $name
        DisplayVersion = $display
        IsServer       = $isServer
        IsWindows11    = $isWin11
        Text           = ('{0}{1} (build {2})' -f $name, $(if ($display) { " $display" } else { '' }), $full)
    }
}


# ---------------------------------------------------------------------------
# Safe CIM / registry / service / process wrappers
# ---------------------------------------------------------------------------

function Invoke-MDCimQuery {
<#
    .SYNOPSIS
        Get-CimInstance that returns $null instead of throwing, and records the
        failure reason in $script:MDLastCimError for the caller to report on.
#>
    param(
        [Parameter(Mandatory)][string] $Namespace,
        [Parameter(Mandatory)][string] $ClassName,
        [string] $Filter,
        [string[]] $Property,
        [int] $TimeoutSeconds = 60
    )

    $script:MDLastCimError = $null
    try {
        $params = @{
            Namespace   = $Namespace
            ClassName   = $ClassName
            ErrorAction = 'Stop'
        }
        if ($Filter)   { $params['Filter']   = $Filter }
        if ($Property) { $params['Property'] = $Property }

        # A local query needs no CIM session, but it does need a hard timeout:
        # a wedged WMI provider will otherwise hang the entire run.
        $result = Get-CimInstance @params -OperationTimeoutSec $TimeoutSeconds
        Write-MDDebug ('CIM ok: {0}:{1} -> {2} instance(s)' -f $Namespace, $ClassName, (@($result).Count))
        return $result
    }
    catch {
        $script:MDLastCimError = $_
        Write-MDDebug ('CIM FAILED: {0}:{1} -> {2}' -f $Namespace, $ClassName, $_.Exception.Message)
        return $null
    }
}


function Invoke-MDCimMethod {
    <# Invoke-CimMethod that returns $null instead of throwing. #>
    param(
        [Parameter(Mandatory)][string] $Namespace,
        [Parameter(Mandatory)][string] $ClassName,
        [Parameter(Mandatory)][string] $MethodName,
        [hashtable] $Arguments,
        $InputObject
    )

    $script:MDLastCimError = $null
    try {
        if ($InputObject) {
            $params = @{ InputObject = $InputObject; MethodName = $MethodName; ErrorAction = 'Stop' }
        }
        else {
            $params = @{ Namespace = $Namespace; ClassName = $ClassName; MethodName = $MethodName; ErrorAction = 'Stop' }
        }
        if ($Arguments) { $params['Arguments'] = $Arguments }

        $r = Invoke-CimMethod @params
        Write-MDDebug ('CIM method ok: {0}:{1}.{2}' -f $Namespace, $ClassName, $MethodName)
        return $r
    }
    catch {
        $script:MDLastCimError = $_
        Write-MDDebug ('CIM method FAILED: {0}:{1}.{2} -> {3}' -f $Namespace, $ClassName, $MethodName, $_.Exception.Message)
        return $null
    }
}


function Get-MDRegValue {
    <# Reads a single registry value, returning $null when absent or unreadable. #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Name
    )
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch { return $null }
}


function Test-MDRegKey {
    param([Parameter(Mandatory)][string] $Path)
    try { Test-Path -LiteralPath $Path -ErrorAction Stop } catch { $false }
}


function Get-MDService {
    <# Get-Service that returns $null for a missing service instead of erroring. #>
    param([Parameter(Mandatory)][string] $Name)
    try { Get-Service -Name $Name -ErrorAction Stop } catch { $null }
}


function Get-MDServiceStartMode {
    <# Start mode as reported by WMI: Auto / Manual / Disabled, or $null. #>
    param([Parameter(Mandatory)][string] $Name)
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction Stop
        if ($svc) { return $svc.StartMode }
    }
    catch { }

    # WMI is exactly the thing that tends to be broken here, so fall back to
    # reading the service configuration straight out of the registry.
    $start = Get-MDRegValue -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name) -Name 'Start'
    switch ($start) {
        2 { 'Auto' }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { $null }
    }
}


function Invoke-MDProcess {
<#
    .SYNOPSIS
        Runs a native command, captures stdout/stderr and the exit code, and
        never lets a hung child process take the run down with it.
    .OUTPUTS
        [pscustomobject] ExitCode / StdOut / StdErr / TimedOut
#>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [int] $TimeoutSeconds = 300
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = ($ArgumentList -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    Write-MDDebug ('exec: {0} {1}' -f $FilePath, $psi.Arguments)

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message; TimedOut = $false }
    }

    # Read both streams asynchronously; reading them in sequence deadlocks as
    # soon as either pipe buffer fills.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        try { $proc.Kill() } catch { }
    }

    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.Result } catch { }
    try { $stderr = $errTask.Result } catch { }

    $code = -1
    try { $code = $proc.ExitCode } catch { }

    [pscustomobject]@{
        ExitCode = $code
        StdOut   = $stdout
        StdErr   = $stderr
        TimedOut = $timedOut
    }
}


# ---------------------------------------------------------------------------
# MECM client discovery
# ---------------------------------------------------------------------------

function Get-MDClientInfo {
<#
    .SYNOPSIS
        Everything we can learn about the installed client without assuming any
        one source works. Registry first (survives broken WMI), CIM second.
    .OUTPUTS
        [pscustomobject] with Installed / Version / InstallPath / LogPath /
        SiteCode / ManagementPoint / ClientId / CacheLocation / CacheSizeMB
#>
    [CmdletBinding()]
    param()

    $info = [pscustomobject]@{
        Installed       = $false
        InstallPath     = $null
        LogPath         = $null
        Version         = $null
        SiteCode        = $null
        ManagementPoint = $null
        ClientId        = $null
        CacheLocation   = $null
        CacheSizeMB     = $null
        HttpsOnly       = $null
        CcmSetupPath    = $null
    }

    # --- install location ---------------------------------------------------
    # "Local SMS Path" is written by ccmsetup and is the most reliable anchor.
    $localPath = Get-MDRegValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Client\Configuration\Client Properties' -Name 'Local SMS Path'
    if (-not $localPath) {
        $localPath = Get-MDRegValue -Path 'HKLM:\SOFTWARE\Microsoft\CCM' -Name 'Local SMS Path'
    }
    if (-not $localPath -and (Test-Path -LiteralPath (Join-Path $env:windir 'CCM'))) {
        $localPath = Join-Path $env:windir 'CCM'
    }

    if ($localPath) {
        $info.InstallPath = $localPath.TrimEnd('\')
        $info.LogPath     = Join-Path $info.InstallPath 'Logs'
        $info.Installed   = Test-Path -LiteralPath $info.InstallPath
    }

    # Logs can be relocated by the "Configuration Manager Properties" MOF or by
    # the client install; honour the override when it is present.
    $logOverride = Get-MDRegValue -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global' -Name 'LogDirectory'
    if ($logOverride -and (Test-Path -LiteralPath $logOverride)) { $info.LogPath = $logOverride.TrimEnd('\') }

    $ccmSetup = Join-Path $env:windir 'ccmsetup\ccmsetup.exe'
    if (Test-Path -LiteralPath $ccmSetup) { $info.CcmSetupPath = $ccmSetup }

    # --- version ------------------------------------------------------------
    $info.Version = Get-MDRegValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client' -Name 'ProductVersion'
    if (-not $info.Version) {
        $sms = Invoke-MDCimQuery -Namespace 'root\ccm' -ClassName 'SMS_Client'
        if ($sms) { $info.Version = ($sms | Select-Object -First 1).ClientVersion }
    }

    # --- site assignment ----------------------------------------------------
    $info.SiteCode = Get-MDRegValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client' -Name 'AssignedSiteCode'
    if (-not $info.SiteCode) {
        $auth = Invoke-MDCimQuery -Namespace 'root\ccm' -ClassName 'SMS_Authority'
        if ($auth) {
            $name = ($auth | Select-Object -First 1).Name
            if ($name -match '^SMS:(\w{3})$') { $info.SiteCode = $Matches[1] }
            $info.ManagementPoint = ($auth | Select-Object -First 1).CurrentManagementPoint
        }
    }

    if (-not $info.ManagementPoint) {
        $auth = Invoke-MDCimQuery -Namespace 'root\ccm' -ClassName 'SMS_Authority'
        if ($auth) { $info.ManagementPoint = ($auth | Select-Object -First 1).CurrentManagementPoint }
    }
    if (-not $info.ManagementPoint) {
        $info.ManagementPoint = Get-MDRegValue -Path 'HKLM:\SOFTWARE\Microsoft\CCM' -Name 'CurrentManagementPoint'
    }

    # --- identity -----------------------------------------------------------
    $client = Invoke-MDCimQuery -Namespace 'root\ccm' -ClassName 'CCM_Client'
    if ($client) { $info.ClientId = ($client | Select-Object -First 1).ClientId }
    if (-not $info.ClientId) {
        $info.ClientId = Get-MDRegValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client' -Name 'GUID'
    }

    # --- content cache ------------------------------------------------------
    $cache = Invoke-MDCimQuery -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheConfig'
    if ($cache) {
        $c = $cache | Select-Object -First 1
        $info.CacheLocation = $c.Location
        $info.CacheSizeMB   = $c.Size
    }
    if (-not $info.CacheLocation -and $info.InstallPath) {
        $guess = Join-Path $info.InstallPath 'Cache'
        if (Test-Path -LiteralPath $guess) { $info.CacheLocation = $guess }
    }

    # --- HTTPS-only / e-HTTP ------------------------------------------------
    $https = Get-MDRegValue -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Security' -Name 'ClientAlwaysOnInternet'
    $info.HttpsOnly = [bool]$https

    $info
}


function Get-MDVolumeForPath {
<#
    .SYNOPSIS
        The volume a path actually lives on, mount points included.
    .DESCRIPTION
        [System.IO.Path]::GetPathRoot returns "C:\" for C:\Mounts\Cache even
        when a separate volume is mounted at that folder, so a free-space check
        built on it silently measures the wrong disk - and cheerfully reports
        plenty of room on a cache volume that is completely full.

        Win32_Volume enumerates mount-point paths alongside drive letters, so
        the longest volume Name that prefixes the path is the volume holding
        it.
    .OUTPUTS
        "C:" for a lettered volume, the mount path for a mounted one, or the
        path root as a last resort.
#>
    param([Parameter(Mandatory)][string] $Path)

    $fallback = ''
    try { $fallback = [System.IO.Path]::GetPathRoot($Path).TrimEnd('\') } catch { }

    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }
    if (-not $full.EndsWith('\')) { $full += '\' }

    try {
        $best = $null
        foreach ($v in @(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop)) {
            if (-not $v.Name) { continue }
            if ($full.StartsWith($v.Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not $best -or $v.Name.Length -gt $best.Name.Length) { $best = $v }
            }
        }

        if ($best) {
            if ($best.DriveLetter) { return $best.DriveLetter.TrimEnd('\') }
            return $best.Name.TrimEnd('\')
        }
    }
    catch { }

    $fallback
}


function Test-MDCachePathSane {
<#
    .SYNOPSIS
        Is this path safe to sweep every subdirectory out of?
    .DESCRIPTION
        The client's cache location comes out of CacheConfig in WMI - the very
        subsystem this tool exists to diagnose as broken - and clearing the
        cache recursively deletes every subdirectory under it. A corrupt or
        mistyped Location pointing at a drive root, a profile folder or a data
        volume would turn a Safe-tier, "reversible" repair into an
        unrecoverable recursive delete, with no backup taken.

        So the sweep has to earn its way past two tests: the path must sit
        somewhere structurally sane, and it must actually look like a
        Configuration Manager cache. Refusing wrongly costs a few stale folders
        left on disk and a line of output saying so. Allowing wrongly costs the
        machine. The asymmetry decides it.
    .OUTPUTS
        [pscustomobject] Sane (bool) / Reason
#>
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Sane = $false; Reason = 'no cache location is configured' }
    }

    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { }
    if ([string]::IsNullOrWhiteSpace($full)) {
        return [pscustomobject]@{ Sane = $false; Reason = ('"{0}" is not a usable path' -f $Path) }
    }

    $root = ''
    try { $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\') } catch { }
    if ([string]::IsNullOrWhiteSpace($root) -or $full -ieq $root) {
        return [pscustomobject]@{ Sane = $false; Reason = ('"{0}" is a drive or share root' -f $full) }
    }

    $protected = @(
        $env:windir
        $env:SystemDrive
        $env:ProgramData
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:USERPROFILE
        (Join-Path $env:SystemDrive 'Users')
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    foreach ($p in $protected) {
        if ($full -ieq $p) {
            return [pscustomobject]@{ Sane = $false; Reason = ('"{0}" is a protected system location' -f $full) }
        }
    }

    # The name test is what catches a plausible-but-wrong path like D:\Data,
    # which passes every structural check above and is nobody's cache. The
    # default is %windir%\ccmcache; a relocated one is conventionally still
    # named for it, and a client-install-relative cache ends in \CCM\Cache.
    if ($full -inotmatch 'ccmcache' -and $full -inotmatch '\\CCM\\Cache$') {
        return [pscustomobject]@{ Sane = $false
                                  Reason = ('"{0}" does not look like a Configuration Manager cache' -f $full) }
    }

    [pscustomobject]@{ Sane = $true; Reason = ('{0} looks like a client cache' -f $full) }
}


function Get-MDWinEvent {
<#
    .SYNOPSIS
        Get-WinEvent -FilterHashtable that can tell "nothing matched" apart
        from "the log could not be read".
    .DESCRIPTION
        Get-WinEvent raises a terminating NoMatchingEventsFound rather than
        returning an empty collection when a filter matches nothing. Any caller
        that wraps it in a plain try/catch therefore reports the best possible
        outcome - zero errors in the window - as an unreadable log, and the
        "clean" branch of its if/else is unreachable code.

        The error id is the discriminator, never the message: the message text
        is localized and would not match on a non-English install.
    .OUTPUTS
        [pscustomobject] Available (bool) / Events (array) / Reason
#>
    param(
        [Parameter(Mandatory)][hashtable] $FilterHashtable,
        [int] $MaxEvents = 100
    )

    try {
        $events = @(Get-WinEvent -FilterHashtable $FilterHashtable -MaxEvents $MaxEvents -ErrorAction Stop)
        return [pscustomobject]@{ Available = $true; Events = $events; Reason = '' }
    }
    catch {
        if ("$($_.FullyQualifiedErrorId)" -match 'NoMatchingEventsFound') {
            return [pscustomobject]@{ Available = $true; Events = @(); Reason = 'no events matched the filter' }
        }
        return [pscustomobject]@{ Available = $false; Events = @(); Reason = $_.Exception.Message }
    }
}


function Get-MDWmiActivityDetail {
<#
    .SYNOPSIS
        Pulls the result code and the operation text out of a WMI-Activity
        event without going through its rendered message.
    .DESCRIPTION
        The .Message property is localized - it is assembled from the
        provider's resource DLL - so a regex for "ResultCode = 0x..." matches
        nothing on a German or French install. Every event then falls into "no
        result code" and the evidence names no fault at all, which is a silent
        loss of the most useful field in the record.

        The event's own UserData is not localized: the same element names and
        the same values in every locale. Read that first, and keep the message
        regex only as a fallback for a build that shapes UserData differently.

        The code is returned as written; ConvertTo-MDHexError already
        normalises signed decimal, unsigned decimal and hex alike.
    .OUTPUTS
        [pscustomobject] ResultCode / Operation
#>
    param([Parameter(Mandatory)] $Event)

    $code      = $null
    $operation = ''

    try {
        $xml = [xml]$Event.ToXml()

        # local-name() so this does not depend on the UserData namespace, which
        # differs between the schema versions Windows has shipped.
        $codeNode = $xml.SelectSingleNode('//*[local-name()="ResultCode"]')
        if ($codeNode -and -not [string]::IsNullOrWhiteSpace($codeNode.InnerText)) {
            $code = $codeNode.InnerText.Trim()
        }

        foreach ($name in @('NamespaceName', 'Operation', 'PossibleCause')) {
            $node = $xml.SelectSingleNode(('//*[local-name()="{0}"]' -f $name))
            if ($node -and $node.InnerText) { $operation += (' ' + $node.InnerText) }
        }
    }
    catch { }

    if (-not $code -and $Event.Message -match 'ResultCode\s*=\s*(0x[0-9A-Fa-f]+)') {
        $code = $Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($operation)) { $operation = "$($Event.Message)" }

    [pscustomobject]@{
        ResultCode = $(if ($code) { $code } else { 'no result code' })
        Operation  = $operation.Trim()
    }
}


function Get-MDCcmSetupInFlight {
<#
    .SYNOPSIS
        Reports whether a ccmsetup install or upgrade is running right now.
    .DESCRIPTION
        Repairing on top of an in-flight install is a reliable way to produce a
        half-installed client: the repair stops CcmExec, salvages WMI and
        resets policy underneath a ccmsetup that is still writing to all three.

        This is deliberately a bare process check and nothing cleverer.
        ccmsetup.exe being resident is the entire signal, and it is not one
        that needs a second opinion before it is acted on.
    .OUTPUTS
        [pscustomobject] Running / Processes / StartedAt
#>
    param()

    $procs = @(Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)

    # StartTime throws for a process owned by another account when we are not
    # elevated. It is decoration on an error message, so losing it is fine.
    $started = $null
    if ($procs.Count -gt 0) {
        try { $started = @($procs | Sort-Object StartTime | Select-Object -First 1)[0].StartTime } catch { }
    }

    [pscustomobject]@{
        Running   = ($procs.Count -gt 0)
        Processes = $procs.Count
        StartedAt = $started
    }
}


function Format-MDBytes {
    <# Human-readable size for log lines and tables. #>
    param([double] $Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    '{0} B' -f [int]$Bytes
}


function Format-MDAge {
    <# "3d 4h ago" style relative time, or "(never)" for a null timestamp. #>
    param($Timestamp)

    if (-not $Timestamp) { return '(never)' }
    try {
        $span = (Get-Date) - [datetime]$Timestamp
        if ($span.TotalMinutes -lt 1)  { return 'just now' }
        if ($span.TotalHours   -lt 1)  { return '{0:N0}m ago' -f $span.TotalMinutes }
        if ($span.TotalDays    -lt 1)  { return '{0:N0}h ago' -f $span.TotalHours }
        return '{0:N0}d ago' -f $span.TotalDays
    }
    catch { return "$Timestamp" }
}


function ConvertTo-MDHexError {
<#
    .SYNOPSIS
        Normalises whatever an API handed us into a canonical 0xXXXXXXXX string.
    .DESCRIPTION
        MECM logs report the same error as a signed decimal, an unsigned
        decimal, or hex, depending on which component wrote the line. The error
        catalogue is keyed on the 8-digit uppercase hex form, so everything is
        funnelled through here first.
#>
    param($Value)

    if ($null -eq $Value) { return $null }
    $text = "$Value".Trim()
    if ($text -eq '') { return $null }

    try {
        if ($text -match '^0[xX][0-9A-Fa-f]{1,8}$') {
            $n = [Convert]::ToUInt32($text.Substring(2), 16)
        }
        elseif ($text -match '^-\d+$') {
            # Reinterpret the signed 32-bit value's bit pattern as unsigned.
            # Note: masking with 0xFFFFFFFF does NOT work here - PowerShell
            # parses that literal as Int32 -1, so the mask is a no-op and the
            # cast to UInt32 then throws on the still-negative value.
            $n = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$text), 0)
        }
        elseif ($text -match '^\d+$') {
            $n = [uint32]([uint64]$text -band 0xFFFFFFFFL)
        }
        else {
            return $null
        }
        return '0x{0:X8}' -f $n
    }
    catch { return $null }
}
