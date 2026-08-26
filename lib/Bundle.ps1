<#
    ===========================================================================
     MECM Client Wizard  --  lib\Bundle.ps1
    ---------------------------------------------------------------------------
     Builds the support bundle: one timestamped ZIP holding everything someone
     who is not sitting at this machine needs in order to work out what is
     wrong with its Configuration Manager client.

     What goes in is deliberately bounded. This is a troubleshooting bundle for
     a ConfigMgr client, not a forensic image:

       IN   the diagnosis this run just produced, as JSON and as text
            client identity - version, GUID, site code, management point
            service state and start mode for the services the client uses
            WMI repository health and namespace reachability
            Windows version/build and the update source configuration
            the CCM logs the tool already knows how to read
            this run's own transcripts

       OUT  user documents, profiles and browsing data
            certificates, private keys and key material
            credentials, tokens and anything from a password store
            registry hives - only the specific Windows Update policy values
            the diagnosis already reads are recorded, by name and value

     Nothing in here modifies the machine. It reads, it copies, it zips.
    ===========================================================================
#>

# Per-file and whole-bundle limits for the log copy. A client with runaway
# logging can hold hundreds of megabytes under CCM\Logs, and a support bundle
# nobody can email is not much of a support bundle.
$script:MDBundleMaxLogBytes   = 15MB
$script:MDBundleMaxTotalBytes = 250MB


function Get-MDBundlePath {
<#
    .SYNOPSIS
        Turns whatever the operator passed for -BundlePath into a full zip path.
    .DESCRIPTION
        A path ending in .zip is taken literally. Anything else is treated as a
        directory to drop a timestamped bundle into, which is what the default
        does.
    .OUTPUTS
        The full path of the zip file to create.
#>
    param(
        [string] $OutputPath,
        [datetime] $Timestamp = (Get-Date)
    )

    $name = 'MECMDoctor-Bundle-{0}-{1}.zip' -f $env:COMPUTERNAME, $Timestamp.ToString('yyyyMMdd-HHmmss')

    if (-not $OutputPath) {
        return (Join-Path (Join-Path $env:ProgramData 'MECMDoctor\Bundles') $name)
    }
    if ($OutputPath -match '(?i)\.zip$') {
        return $OutputPath
    }
    Join-Path $OutputPath $name
}


function Write-MDBundleFile {
    <# Writes one text file into the staging folder, reporting what it holds. #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Name,
        # Blank lines are how these files are laid out, so both an empty array
        # and an empty element have to be acceptable.
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines
    )

    $path = Join-Path $Root $Name
    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        Set-Content -LiteralPath $path -Value $Lines -Encoding UTF8 -ErrorAction Stop
        Write-MDDetail -Text ('{0} ({1} line(s))' -f $Name, $Lines.Count) -Bullet '- '
        return $true
    }
    catch {
        Write-MDDebug ("could not write bundle file {0}: {1}" -f $Name, $_.Exception.Message)
        return $false
    }
}


function Get-MDBundleClientText {
    <# Client identity and site assignment, as plain key/value text. #>
    param([Parameter(Mandatory)] $ClientInfo)

    $lines = @('CONFIGURATION MANAGER CLIENT', '')

    $pairs = [ordered]@{
        'Computer'          = $env:COMPUTERNAME
        'Client installed'  = $(if ($ClientInfo.Installed) { 'yes' } else { 'no' })
        'Client version'    = $ClientInfo.Version
        'Install path'      = $ClientInfo.InstallPath
        'Log directory'     = $ClientInfo.LogPath
        'Client GUID'       = $ClientInfo.ClientId
        'Assigned site'     = $ClientInfo.SiteCode
        'Management point'  = $ClientInfo.ManagementPoint
        'HTTPS-only client' = $(if ($ClientInfo.HttpsOnly) { 'yes' } else { 'no' })
        'Cache location'    = $ClientInfo.CacheLocation
        'Cache limit (MB)'  = $ClientInfo.CacheSizeMB
        'ccmsetup.exe'      = $ClientInfo.CcmSetupPath
    }
    foreach ($k in $pairs.Keys) {
        $lines += ('{0,-20}: {1}' -f $k, $(if ($null -ne $pairs[$k] -and "$($pairs[$k])" -ne '') { $pairs[$k] } else { '(not set)' }))
    }

    # Everything the site knows about, straight from the client's own view.
    $lines += @('', 'MANAGEMENT POINTS (SMS_Authority / root\ccm)', '')
    $auth = Invoke-MDCimQuery -Namespace 'root\ccm' -ClassName 'SMS_Authority'
    if ($auth) {
        foreach ($a in @($auth)) {
            $lines += ('{0}  current MP: {1}' -f $a.Name, $a.CurrentManagementPoint)
        }
    }
    else {
        $lines += '(root\ccm is not readable, so no authority information is available)'
    }

    $lookup = Invoke-MDCimQuery -Namespace 'root\ccm\LocationServices' -ClassName 'SMS_MPInformation'
    if ($lookup) {
        $lines += @('', 'MP LIST (root\ccm\LocationServices)', '')
        foreach ($m in @($lookup)) { $lines += ('{0}  site {1}  https={2}' -f $m.MP, $m.SiteCode, $m.HTTPSEnabled) }
    }

    $lines
}


function Get-MDBundleServiceText {
    <# Every service the diagnosis looks at, with its class and configuration. #>
    param()

    $lines = @('SERVICE STATE AND STARTUP CONFIGURATION', '',
               'Class Core        = a Configuration Manager dependency; repairable automatically.',
               'Class Conditional = a Windows service repaired only when a diagnosed failure is correlated with it.',
               '',
               ('{0,-18} {1,-34} {2,-12} {3,-10} {4}' -f 'SERVICE', 'DISPLAY', 'CLASS', 'STATE', 'START'),
               ('{0,-18} {1,-34} {2,-12} {3,-10} {4}' -f ('-'*18), ('-'*34), ('-'*12), ('-'*10), ('-'*8)))

    foreach ($spec in $script:MDRequiredServices) {
        $svc   = Get-MDService -Name $spec.Name
        $start = Get-MDServiceStartMode -Name $spec.Name
        $state = if ($svc) { "$($svc.Status)" } else { 'ABSENT' }
        $lines += ('{0,-18} {1,-34} {2,-12} {3,-10} {4}' -f $spec.Name, $spec.Display, $spec.Class, $state, $(if ($start) { $start } else { '-' }))
    }

    $lines
}


function Get-MDBundleWmiText {
    <# Repository consistency, size and namespace reachability. #>
    param()

    $lines   = @('WMI HEALTH', '')
    $winmgmt = Join-Path $env:windir 'System32\wbem\winmgmt.exe'

    $verify = Invoke-MDProcess -FilePath $winmgmt -ArgumentList @('/verifyrepository') -TimeoutSeconds 120
    $lines += ('winmgmt /verifyrepository  exit {0}{1}' -f $verify.ExitCode, $(if ($verify.TimedOut) { '  (TIMED OUT)' } else { '' }))
    $lines += ('  ' + (($verify.StdOut + ' ' + $verify.StdErr).Trim()))

    $lines += @('', 'REPOSITORY FILES', '')
    $repo = Join-Path $env:windir 'System32\wbem\Repository'
    if (Test-Path -LiteralPath $repo) {
        foreach ($f in (Get-ChildItem -LiteralPath $repo -File -Force -ErrorAction SilentlyContinue)) {
            $lines += ('{0,-20} {1,12}  modified {2:yyyy-MM-dd HH:mm:ss}' -f $f.Name, (Format-MDBytes $f.Length), $f.LastWriteTime)
        }
    }
    else {
        $lines += '(repository folder not found)'
    }

    $lines += @('', 'NAMESPACE REACHABILITY', '')
    foreach ($ns in @(
        @{ Namespace = 'root\cimv2';                           Class = 'Win32_OperatingSystem' }
        @{ Namespace = 'root\default';                         Class = '__Namespace' }
        @{ Namespace = 'root\ccm';                             Class = 'SMS_Client' }
        @{ Namespace = 'root\ccm\ClientSDK';                   Class = 'CCM_ClientUtilities' }
        @{ Namespace = 'root\ccm\Policy\Machine\ActualConfig'; Class = 'CCM_Policy_Policy5' }
        @{ Namespace = 'root\ccm\SoftwareUpdates\UpdatesStore';Class = 'CCM_UpdateStatus' }
        @{ Namespace = 'root\ccm\SoftMgmtAgent';               Class = 'CacheConfig' }
        @{ Namespace = 'root\ccm\Scheduler';                   Class = 'CCM_Scheduler_History' }
    )) {
        $r = Invoke-MDCimQuery -Namespace $ns.Namespace -ClassName $ns.Class
        if ($null -ne $r) { $lines += ('OK    {0,-42} {1} instance(s)' -f $ns.Namespace, @($r).Count) }
        else              { $lines += ('FAIL  {0,-42} {1}' -f $ns.Namespace, $(if ($script:MDLastCimError) { $script:MDLastCimError.Exception.Message } else { 'query failed' })) }
    }

    $lines
}


function Get-MDBundleWindowsText {
    <# Windows version/build and the whole update source configuration. #>
    param($HostFacts)

    $release = Get-MDWindowsRelease
    $lines   = @('WINDOWS', '')

    $lines += ('Release            : {0}' -f $release.Text)
    $lines += ('Build              : {0}' -f $release.BuildFull)
    $lines += ('Product name       : {0}' -f $release.Caption)
    $lines += ('Display version    : {0}' -f $(if ($release.DisplayVersion) { $release.DisplayVersion } else { '(not set)' }))
    $lines += ('Server SKU         : {0}' -f $(if ($release.IsServer) { 'yes' } else { 'no' }))
    $lines += ('Windows 11         : {0}' -f $(if ($release.IsWindows11) { 'yes' } else { 'no' }))
    $lines += ('Architecture       : {0}' -f $env:PROCESSOR_ARCHITECTURE)

    if ($HostFacts) {
        $lines += @('', 'HOST FACTS', '')
        foreach ($k in $HostFacts.Keys) { $lines += ('{0,-19}: {1}' -f $k, $HostFacts[$k]) }
    }

    # The update source configuration, using exactly the values the dual scan
    # logic reads, so the bundle and the diagnosis can never disagree.
    $cfg = Get-MDUpdateSourceConfig -Release $release
    $lines += @('', 'WINDOWS UPDATE / WSUS / SCAN SOURCE', '')
    $lines += ('Policy model       : {0}' -f $(if ($cfg.UsesScanSourcePolicy) { 'scan source policy (build 18362+)' } else { 'DisableDualScan (pre-1903)' }))
    $lines += ('WUServer           : {0}' -f $(if ($cfg.WUServer) { $cfg.WUServer } else { '(not set)' }))
    $lines += ('WUStatusServer     : {0}' -f $(if ($cfg.WUStatusServer) { $cfg.WUStatusServer } else { '(not set)' }))
    $lines += ('UseWUServer        : {0}' -f $(if ($null -ne $cfg.UseWUServer) { $cfg.UseWUServer } else { '(not set)' }))
    $lines += ('NoAutoUpdate       : {0}' -f $(if ($null -ne $cfg.NoAutoUpdate) { $cfg.NoAutoUpdate } else { '(not set)' }))
    $lines += ('DisableDualScan    : {0}' -f $(if ($null -ne $cfg.DisableDualScan) { $cfg.DisableDualScan } else { '(not set)' }))
    $lines += ('WU policy from GPO : {0}' -f $(if ($cfg.GpoManagesWu) { 'yes - Registry.pol contains WindowsUpdate settings' } else { 'no' }))

    $lines += @('', 'Scan source policy values', '')
    if ($cfg.ScanSource.Count -gt 0) {
        foreach ($s in $cfg.ScanSource) { $lines += ('{0,-52} = {1}  ({2})' -f $s.Name, $s.Value, $s.Source) }
    }
    else {
        $lines += '(none configured)'
    }

    $lines += @('', 'Windows Update for Business deferral policies', '')
    if ($cfg.WufbConfigured) { $lines += $cfg.WufbPolicies }
    else                     { $lines += '(none configured)' }

    $lines
}


function Get-MDBundleFindingText {
    <# The diagnosis in plain text, so the ZIP is readable without a JSON tool. #>
    param($Findings)

    $all   = @($Findings)
    $lines = @('DIAGNOSIS RESULTS', '')

    if ($all.Count -eq 0) {
        $lines += '(no findings were produced - the diagnosis was skipped)'
        return $lines
    }

    $lines += ('{0,-14} {1,-44} {2,-6} {3}' -f 'AREA', 'CHECK', 'RESULT', 'DETAIL')
    $lines += ('{0,-14} {1,-44} {2,-6} {3}' -f ('-'*14), ('-'*44), ('-'*6), ('-'*40))
    foreach ($f in $all) {
        $lines += ('{0,-14} {1,-44} {2,-6} {3}' -f $f.Category, $f.Title, $f.Status.ToUpperInvariant(), $f.Detail)
    }

    $issues = @($all | Where-Object { $_.Status -in @('Warn', 'Fail') } |
                Sort-Object -Property @{ Expression = { $_.Severity }; Descending = $true }, @{ Expression = { $_.Category } })

    $lines += @('', ('ISSUES ({0})' -f $issues.Count), '')
    $n = 0
    foreach ($f in $issues) {
        $n++
        $lines += ('{0}. [{1}] {2} -- {3}' -f $n, $f.Category, $f.Title, $f.Detail)
        foreach ($e in $f.Evidence) { if (-not [string]::IsNullOrWhiteSpace($e)) { $lines += ('     - ' + $e) } }
        if ($f.Remediation) { $lines += ('     > FIX: ' + $f.Remediation) }
        if ($f.RepairIds -and @($f.RepairIds).Count) { $lines += ('     > repairs: ' + (@($f.RepairIds) -join ', ')) }
        $lines += ''
    }

    $lines
}


function Copy-MDBundleLogs {
<#
    .SYNOPSIS
        Copies the CCM logs the tool already knows how to read into the bundle.
    .DESCRIPTION
        Only the logs in $MDLogMap and their .lo_ rollovers, so the bundle
        carries the files someone would actually open rather than the whole
        directory. Oversized individual logs are recorded by name and skipped
        instead of silently bloating the ZIP.
    .OUTPUTS
        [string[]] a manifest describing what was and was not copied.
#>
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $ClientInfo
    )

    $manifest = @('CCM LOG COPY', '')
    $dest     = Join-Path $Root 'logs'
    $total    = 0
    $copied   = 0

    # Without a log root there is nothing to resolve the log names against, and
    # even the absolute ccmsetup entry is not worth a bundle folder on its own.
    if (-not $ClientInfo.LogPath -or -not (Test-Path -LiteralPath $ClientInfo.LogPath)) {
        return ($manifest + ('No CCM log directory was found (looked for {0}). No logs were copied.' -f
                             $(if ($ClientInfo.LogPath) { $ClientInfo.LogPath } else { '<unknown>' })))
    }

    try {
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -Path $dest -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    }
    catch {
        return ($manifest + ('could not create the log folder in the bundle: ' + $_.Exception.Message))
    }

    foreach ($entry in $script:MDLogMap) {
        $files = @(Get-MDLogFileSet -LogRoot $ClientInfo.LogPath -Name $entry.Name)
        if ($files.Count -eq 0) { continue }

        foreach ($file in $files) {
            if ($file.Length -gt $script:MDBundleMaxLogBytes) {
                $manifest += ('SKIPPED  {0,-38} {1} exceeds the {2} per-file limit' -f $file.Name, (Format-MDBytes $file.Length), (Format-MDBytes $script:MDBundleMaxLogBytes))
                continue
            }
            if (($total + $file.Length) -gt $script:MDBundleMaxTotalBytes) {
                $manifest += ('SKIPPED  {0,-38} the {1} bundle log budget is full' -f $file.Name, (Format-MDBytes $script:MDBundleMaxTotalBytes))
                continue
            }

            try {
                # ReadWrite sharing: CcmExec holds these open while it runs.
                $target = Join-Path $dest $file.Name
                $in  = New-Object System.IO.FileStream($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $out = New-Object System.IO.FileStream($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try { $in.CopyTo($out) } finally { $out.Dispose() }
                }
                finally { $in.Dispose() }

                $total  += $file.Length
                $copied++
                $manifest += ('copied   {0,-38} {1,10}  modified {2:yyyy-MM-dd HH:mm:ss}  ({3})' -f $file.Name, (Format-MDBytes $file.Length), $file.LastWriteTime, $entry.Area)
            }
            catch {
                $manifest += ('FAILED   {0,-38} {1}' -f $file.Name, $_.Exception.Message)
            }
        }
    }

    @(('{0} log file(s) copied, {1} in total.' -f $copied, (Format-MDBytes $total)), '') + $manifest
}


function New-MDSupportBundle {
<#
    .SYNOPSIS
        Assembles and compresses the support bundle.
    .DESCRIPTION
        Everything is staged in a temporary folder first and zipped in one go,
        so a half-written bundle never appears at the destination path.
    .OUTPUTS
        The full path of the ZIP, or $null if it could not be produced.
#>
    param(
        [Parameter(Mandatory)] $ClientInfo,
        $Findings,
        $RepairResults,
        $HostFacts,
        [string] $OutputPath,
        [string] $Version = '1.0.0',
        [switch] $SkipLogs
    )

    $stamp   = Get-Date
    $zipPath = Get-MDBundlePath -OutputPath $OutputPath -Timestamp $stamp
    $staging = Join-Path $env:TEMP ('MECMDoctor-Bundle-' + $stamp.ToString('yyyyMMdd-HHmmss'))

    try {
        # Compress-Archive exists on 5.1 but chokes on locked files and on
        # anything large; ZipFile is both faster and better behaved here.
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }
    catch {
        Write-MDFail ('ZIP support is unavailable in this PowerShell host: {0}' -f $_.Exception.Message)
        return $null
    }

    try {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
        New-Item -Path $staging -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-MDFail ('Could not create the staging folder {0}: {1}' -f $staging, $_.Exception.Message)
        return $null
    }

    try {
        Write-MDAction 'Collecting client information'
        [void](Write-MDBundleFile -Root $staging -Name 'client.txt'   -Lines (Get-MDBundleClientText -ClientInfo $ClientInfo))

        Write-MDAction 'Collecting service configuration'
        [void](Write-MDBundleFile -Root $staging -Name 'services.txt' -Lines (Get-MDBundleServiceText))

        Write-MDAction 'Collecting WMI health'
        [void](Write-MDBundleFile -Root $staging -Name 'wmi.txt'      -Lines (Get-MDBundleWmiText))

        Write-MDAction 'Collecting Windows and update source configuration'
        [void](Write-MDBundleFile -Root $staging -Name 'windows.txt'  -Lines (Get-MDBundleWindowsText -HostFacts $HostFacts))

        Write-MDAction 'Writing the diagnosis'
        [void](Write-MDBundleFile -Root $staging -Name 'findings.txt' -Lines (Get-MDBundleFindingText -Findings $Findings))
        [void](Export-MDReport -Path (Join-Path $staging 'diagnosis.json') -ClientInfo $ClientInfo -Findings $Findings `
                               -RepairResults $RepairResults -HostFacts $HostFacts -Command 'bundle' -Version $Version)

        if ($SkipLogs) {
            [void](Write-MDBundleFile -Root $staging -Name 'logs-manifest.txt' -Lines @('CCM LOG COPY', '', 'Skipped: -SkipLogs was given.'))
        }
        else {
            Write-MDAction 'Copying CCM logs'
            [void](Write-MDBundleFile -Root $staging -Name 'logs-manifest.txt' -Lines (Copy-MDBundleLogs -Root $staging -ClientInfo $ClientInfo))
        }

        # This run's own transcripts, so the bundle explains how it was made.
        foreach ($transcript in @($script:MDLog.PlainPath, $script:MDLog.CMTracePath)) {
            if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { continue }
            try {
                $target = Join-Path $staging ('transcript\' + (Split-Path -Leaf $transcript))
                $dir    = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
                Copy-Item -LiteralPath $transcript -Destination $target -Force -ErrorAction Stop
            }
            catch { Write-MDDebug ("could not add transcript {0}: {1}" -f $transcript, $_.Exception.Message) }
        }

        [void](Write-MDBundleFile -Root $staging -Name 'README.txt' -Lines @(
            'MECM Client Wizard support bundle'
            ('mecmdoctor {0}' -f $Version)
            ('Computer : {0}' -f $env:COMPUTERNAME)
            ('Created  : {0}' -f $stamp.ToString('yyyy-MM-dd HH:mm:ss K'))
            ''
            'CONTENTS'
            '  README.txt          this file'
            '  diagnosis.json      the full diagnosis in the mecmdoctor/1 JSON schema'
            '  findings.txt        the same diagnosis as readable text, issues first'
            '  client.txt          client version, GUID, site code and management point information'
            '  services.txt        state and startup configuration of every service the client uses'
            '  wmi.txt             repository consistency, repository file sizes, namespace reachability'
            '  windows.txt         Windows version/build, host facts, Windows Update / WSUS / scan source policy'
            '  logs-manifest.txt   which CCM logs were copied, and why any were skipped'
            '  logs\               the CCM logs themselves'
            '  transcript\         the mecmdoctor transcript for the run that produced this bundle'
            ''
            'NOT INCLUDED'
            '  User documents, profiles or browsing data.'
            '  Certificates, private keys or other key material.'
            '  Credentials or tokens of any kind.'
            '  Registry hives. Only the named Windows Update policy values the diagnosis reads are recorded.'
            ''
            'CCM logs can name deployed applications, packages and the accounts that ran them.'
            'Review logs-manifest.txt before sending this bundle outside your organisation.'
        ))

        Write-MDAction 'Compressing the bundle'
        $zipDir = Split-Path -Parent $zipPath
        if ($zipDir -and -not (Test-Path -LiteralPath $zipDir)) {
            New-Item -Path $zipDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop }

        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $staging, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

        return $zipPath
    }
    catch {
        Write-MDFail ('Could not build the support bundle: {0}' -f $_.Exception.Message)
        Write-MDDetail -Text $_.ScriptStackTrace -Bullet '| '
        return $null
    }
    finally {
        try { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
