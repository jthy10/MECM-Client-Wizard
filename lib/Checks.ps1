<#
    ===========================================================================
     MECM Client Wizard  --  lib\Checks.ps1
    ---------------------------------------------------------------------------
     Every diagnostic check lives here.

     Contract for a check function:
       * name it Test-MD<Area>
       * accept $ClientInfo (from Get-MDClientInfo) where it needs it
       * emit findings with New-MDFinding, print them with Write-MDFinding
       * return the findings as an array
       * NEVER throw - a check that dies must degrade to a Skip finding, or it
         takes the rest of the diagnosis with it

     Checks are read-only. Everything that changes the machine is in Repairs.ps1.
    ===========================================================================
#>

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

# Services the client depends on, and what "healthy" means for each.
#
#   Class        Core        - a genuine MECM dependency. When one of these is
#                              stopped or disabled the client is broken, and
#                              correcting it automatically is both safe and
#                              obviously the right thing to do.
#                Conditional - a Windows service the client only needs in
#                              particular circumstances. Its configuration is
#                              always reported, but it is only ever repaired
#                              when a real, separately diagnosed symptom is
#                              correlated with it. A disabled msiserver on a
#                              machine with no MSI deployment failures is a
#                              deliberate configuration choice, not a fault.
#   MustRun      the service has to be running right now
#   AllowedStart acceptable start modes; the first is what a repair restores to
#   Critical     Core services only: a failure here is Fail rather than Warn
#   Correlate    Conditional services only. Given the full finding set, returns
#                the findings that turn "configured oddly" into "this is your
#                problem". No matches means no repair is proposed.
$script:MDRequiredServices = @(
    # ---- core MECM dependencies -------------------------------------------
    @{ Name = 'CcmExec';    Display = 'SMS Agent Host';                   Class = 'Core'; MustRun = $true;  AllowedStart = @('Auto');           Critical = $true;
       Note = 'The Configuration Manager client itself. Nothing works without it.' }
    @{ Name = 'Winmgmt';    Display = 'Windows Management Instrumentation'; Class = 'Core'; MustRun = $true; AllowedStart = @('Auto');          Critical = $true;
       Note = 'The client stores all of its state in WMI.' }
    @{ Name = 'RpcSs';      Display = 'Remote Procedure Call (RPC)';      Class = 'Core'; MustRun = $true;  AllowedStart = @('Auto');           Critical = $true;
       Note = 'WMI and the client agent both depend on RPC.' }
    @{ Name = 'CryptSvc';   Display = 'Cryptographic Services';           Class = 'Core'; MustRun = $true;  AllowedStart = @('Auto');           Critical = $true;
       Note = 'Validates content signatures and client certificates.' }
    @{ Name = 'Schedule';   Display = 'Task Scheduler';                   Class = 'Core'; MustRun = $true;  AllowedStart = @('Auto');           Critical = $false;
       Note = 'Runs the CcmEval client health task.' }
    @{ Name = 'gpsvc';      Display = 'Group Policy Client';              Class = 'Core'; MustRun = $true;  AllowedStart = @('Auto');           Critical = $false;
       Note = 'Applies Group Policy; also how WSUS policy reaches the client.' }
    @{ Name = 'Dnscache';   Display = 'DNS Client';                       Class = 'Core'; MustRun = $true;  AllowedStart = @('Auto');           Critical = $false;
       Note = 'Resolves the management point and distribution point names.' }

    # ---- conditional Windows services --------------------------------------
    # Each of these is legitimately Manual, Auto or Disabled depending on how
    # the environment is built, so only "Disabled" is even considered, and only
    # then when something else in the diagnosis actually points at it.
    @{ Name = 'BITS';       Display = 'Background Intelligent Transfer';  Class = 'Conditional'; MustRun = $false; AllowedStart = @('Auto', 'Manual');
       Note = 'Downloads all package, application and update content.'
       Needs = 'content or update downloads are failing'
       Correlate = {
           param($Findings)
           @($Findings | Where-Object {
               $_.Status -in @('Warn', 'Fail') -and (
                   $_.Category -eq 'Content' -or
                   ($_.Category -eq 'Logs' -and $_.Title -match '^(Content|Updates) logs$')
               )
           })
       } }
    @{ Name = 'wuauserv';   Display = 'Windows Update';                   Class = 'Conditional'; MustRun = $false; AllowedStart = @('Auto', 'Manual');
       Note = 'Performs the update scan on behalf of the client. Disabling it breaks patching entirely.'
       Needs = 'software update scans or installs are failing'
       Correlate = {
           param($Findings)
           @($Findings | Where-Object {
               $_.Status -in @('Warn', 'Fail') -and (
                   $_.Category -eq 'Updates' -or
                   ($_.Category -eq 'Logs' -and $_.Title -eq 'Updates logs')
               )
           })
       } }
    @{ Name = 'msiserver';  Display = 'Windows Installer';                Class = 'Conditional'; MustRun = $false; AllowedStart = @('Auto', 'Manual');
       Note = 'Required for MSI-based deployments.'
       Needs = 'an MSI-based deployment is failing'
       Correlate = {
           param($Findings)
           @($Findings | Where-Object {
               $_.Status -in @('Warn', 'Fail') -and
               $_.Category -eq 'Logs' -and $_.Title -match '^(Software|Install) logs$'
           })
       } }
    @{ Name = 'W32Time';    Display = 'Windows Time';                     Class = 'Conditional'; MustRun = $false; AllowedStart = @('Auto', 'Manual');
       Note = 'Clock skew breaks certificate validation and Kerberos.'
       Needs = 'certificate validation or clock skew is already causing failures'
       Correlate = {
           param($Findings)
           @($Findings | Where-Object {
               $_.Status -in @('Warn', 'Fail') -and (
                   $_.Category -eq 'Certificates' -or
                   $_.Title -eq 'Time synchronisation' -or
                   ($_.Category -eq 'Logs' -and $_.Title -eq 'Certificates logs')
               )
           })
       } }
    @{ Name = 'TrustedInstaller'; Display = 'Windows Modules Installer';  Class = 'Conditional'; MustRun = $false; AllowedStart = @('Auto', 'Manual');
       Note = 'Installs Windows updates. Disabled means no CU will ever apply.'
       Needs = 'Windows update installs are failing'
       Correlate = {
           param($Findings)
           @($Findings | Where-Object {
               $_.Status -in @('Warn', 'Fail') -and (
                   ($_.Category -eq 'Updates' -and $_.Title -match '(?i)stuck|install') -or
                   ($_.Category -eq 'Logs' -and $_.Title -eq 'Updates logs')
               )
           })
       } }
)

# CCM_SoftwareUpdate.EvaluationState -> human meaning.
# States 2..7 and 11 mean "in flight"; if an update sits there across scans it
# is stuck, which is exactly what we are looking for.
$script:MDUpdateStates = @{
    0  = @{ Text = 'None';                Stuck = $false }
    1  = @{ Text = 'Available';           Stuck = $false }
    2  = @{ Text = 'Submitted';           Stuck = $true  }
    3  = @{ Text = 'Detecting';           Stuck = $true  }
    4  = @{ Text = 'PreDownload';         Stuck = $true  }
    5  = @{ Text = 'Downloading';         Stuck = $true  }
    6  = @{ Text = 'WaitInstall';         Stuck = $true  }
    7  = @{ Text = 'Installing';          Stuck = $true  }
    8  = @{ Text = 'PendingSoftReboot';   Stuck = $false }
    9  = @{ Text = 'PendingHardReboot';   Stuck = $false }
    10 = @{ Text = 'WaitReboot';          Stuck = $false }
    11 = @{ Text = 'Verifying';           Stuck = $true  }
    12 = @{ Text = 'InstallComplete';     Stuck = $false }
    13 = @{ Text = 'Error';               Stuck = $true  }
    14 = @{ Text = 'WaitServiceWindow';   Stuck = $false }
    15 = @{ Text = 'WaitUserLogon';       Stuck = $false }
    16 = @{ Text = 'WaitUserLogoff';      Stuck = $false }
    17 = @{ Text = 'WaitJobUserLogon';    Stuck = $false }
    18 = @{ Text = 'WaitUserReconnect';   Stuck = $false }
    19 = @{ Text = 'PendingUserLogoff';   Stuck = $false }
    20 = @{ Text = 'PendingUpdate';       Stuck = $false }
    21 = @{ Text = 'WaitingRetry';        Stuck = $true  }
    22 = @{ Text = 'WaitPresModeOff';     Stuck = $false }
    23 = @{ Text = 'WaitForOrchestration';Stuck = $false }
}

# Scheduler trigger GUIDs worth reporting on, and how stale is too stale.
$script:MDScheduleIds = @(
    @{ Id = '{00000000-0000-0000-0000-000000000021}'; Name = 'Machine Policy Retrieval';        StaleDays = 2 }
    @{ Id = '{00000000-0000-0000-0000-000000000022}'; Name = 'Machine Policy Evaluation';       StaleDays = 2 }
    @{ Id = '{00000000-0000-0000-0000-000000000001}'; Name = 'Hardware Inventory';              StaleDays = 14 }
    @{ Id = '{00000000-0000-0000-0000-000000000002}'; Name = 'Software Inventory';              StaleDays = 30 }
    @{ Id = '{00000000-0000-0000-0000-000000000003}'; Name = 'Discovery Data Collection';       StaleDays = 14 }
    @{ Id = '{00000000-0000-0000-0000-000000000113}'; Name = 'Software Update Scan';            StaleDays = 10 }
    @{ Id = '{00000000-0000-0000-0000-000000000114}'; Name = 'Software Update Deployment Eval'; StaleDays = 10 }
    @{ Id = '{00000000-0000-0000-0000-000000000108}'; Name = 'Software Update Assignment Eval'; StaleDays = 10 }
    @{ Id = '{00000000-0000-0000-0000-000000000121}'; Name = 'Application Deployment Eval';     StaleDays = 10 }
)


# ===========================================================================
#  1. PREREQUISITES
# ===========================================================================
function Test-MDPrerequisites {
    <# Confirms we can actually do the job before reporting on anything else. #>
    [CmdletBinding()]
    param()

    $findings = @()

    $elevated = Test-MDAdmin
    if ($elevated) {
        $findings += New-MDFinding -Category 'Prerequisites' -Title 'Elevation' -Status 'Pass' -Detail 'running as administrator'
    }
    else {
        $findings += New-MDFinding -Category 'Prerequisites' -Title 'Elevation' -Status 'Fail' `
            -Detail 'NOT running as administrator' `
            -Remediation 'Re-launch using mecmdoctor.bat, which requests elevation, or start PowerShell as administrator. Most checks and all repairs need it.'
    }

    if ($PSVersionTable.PSVersion.Major -ge 5) {
        $findings += New-MDFinding -Category 'Prerequisites' -Title 'PowerShell version' -Status 'Pass' `
            -Detail $PSVersionTable.PSVersion.ToString()
    }
    else {
        $findings += New-MDFinding -Category 'Prerequisites' -Title 'PowerShell version' -Status 'Fail' `
            -Detail ('{0} - 5.1 or later required' -f $PSVersionTable.PSVersion) `
            -Remediation 'Install Windows Management Framework 5.1.'
    }

    # A 32-bit shell on a 64-bit OS sees a redirected registry and file system,
    # which silently breaks half of these checks. Worth catching loudly.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $findings += New-MDFinding -Category 'Prerequisites' -Title 'Process architecture' -Status 'Warn' `
            -Detail '32-bit PowerShell on a 64-bit OS' `
            -Remediation 'Re-run from C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe so registry and file system redirection do not hide the real state.'
    }
    else {
        $findings += New-MDFinding -Category 'Prerequisites' -Title 'Process architecture' -Status 'Pass' `
            -Detail $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit (32-bit OS)' })
    }

    $findings | Write-MDFinding
    $findings
}


# ===========================================================================
#  2. CLIENT INSTALLATION
# ===========================================================================
function Test-MDClientInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()

    if (-not $ClientInfo.Installed) {
        $findings += New-MDFinding -Category 'Client' -Title 'Client installed' -Status 'Fail' `
            -Detail 'no Configuration Manager client found' `
            -Evidence @("Looked for: $($env:windir)\CCM and HKLM:\SOFTWARE\Microsoft\SMS\Client") `
            -Remediation 'Install the client: mecmdoctor reinstall (uses your ClientReinstall.ps1 when present).' `
            -RepairIds @($script:MDRepairIds.ClientReinstall) -Severity 4
        $findings | Write-MDFinding
        return $findings
    }

    $findings += New-MDFinding -Category 'Client' -Title 'Client installed' -Status 'Pass' `
        -Detail $ClientInfo.InstallPath

    if ($ClientInfo.Version) {
        # 5.00.8853.x = 2002, 5.00.9012.x = 2103, 5.00.9058.x = 2207,
        # 5.00.9078.x = 2303, 5.00.9106.x = 2309, 5.00.9128.x = 2403+.
        # We deliberately do not hard-code a "minimum supported" build: that
        # changes every few months and would age badly. We report it instead.
        $findings += New-MDFinding -Category 'Client' -Title 'Client version' -Status 'Info' -Detail $ClientInfo.Version
    }
    else {
        $findings += New-MDFinding -Category 'Client' -Title 'Client version' -Status 'Warn' `
            -Detail 'could not be determined from registry or WMI' `
            -Remediation 'Usually means a half-finished install or upgrade. Check ccmsetup.log, then repair the client.' `
            -RepairIds @($script:MDRepairIds.ClientRepair)
    }

    # A running ccmsetup means an install/upgrade is in flight; repairing on
    # top of that is a reliable way to make things worse.
    $ccmsetupProc = @(Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)
    if ($ccmsetupProc.Count -gt 0) {
        $findings += New-MDFinding -Category 'Client' -Title 'ccmsetup running' -Status 'Warn' `
            -Detail 'a client install or upgrade is in progress right now' `
            -Remediation 'Wait for ccmsetup to finish before running any repair. Watch C:\Windows\ccmsetup\Logs\ccmsetup.log.'
    }

    if ($ClientInfo.LogPath -and (Test-Path -LiteralPath $ClientInfo.LogPath)) {
        $logCount = @(Get-ChildItem -LiteralPath $ClientInfo.LogPath -Filter '*.log' -ErrorAction SilentlyContinue).Count
        $findings += New-MDFinding -Category 'Client' -Title 'Log directory' -Status 'Pass' `
            -Detail ('{0} ({1} log files)' -f $ClientInfo.LogPath, $logCount)
    }
    else {
        $findings += New-MDFinding -Category 'Client' -Title 'Log directory' -Status 'Fail' `
            -Detail ('not found: {0}' -f $ClientInfo.LogPath) `
            -Remediation 'The client install is damaged. Repair, then reinstall if the directory still does not appear.' `
            -RepairIds @($script:MDRepairIds.ClientRepair, $script:MDRepairIds.ClientReinstall)
    }

    $findings | Write-MDFinding
    $findings
}


# ===========================================================================
#  3. SERVICES
# ===========================================================================
function Test-MDServices {
<#
    .SYNOPSIS
        Reports the state and start mode of every service the client can
        depend on, and decides which of them are actually repairable.
    .DESCRIPTION
        Core services get a repair attached immediately - a stopped CcmExec or
        a disabled Winmgmt is unambiguous.

        Conditional services do not. A disabled msiserver, W32Time or wuauserv
        is reported, but no repair is proposed here: whether it matters depends
        on whether anything else in the diagnosis is failing because of it.
        Resolve-MDServiceCorrelation makes that call once every other check has
        run.

        Each finding carries the service name in Data so the repair engine can
        act on exactly the service that was implicated and nothing else.
#>
    [CmdletBinding()]
    param()

    $findings = @()
    $rows     = @()

    foreach ($spec in $script:MDRequiredServices) {
        $svc   = Get-MDService -Name $spec.Name
        $start = Get-MDServiceStartMode -Name $spec.Name

        if (-not $svc) {
            # Some of these are genuinely absent on Server Core / stripped images.
            $status = 'Skip'
            $repair = @()
            if ($spec.Class -eq 'Core' -and $spec.Critical) { $status = 'Fail'; $repair = @($script:MDRepairIds.ClientReinstall) }

            $findings += New-MDFinding -Category 'Services' -Title $spec.Display -Status $status `
                -Detail ('service "{0}" is not installed' -f $spec.Name) `
                -Evidence @($spec.Note) `
                -Remediation $(if ($status -eq 'Fail') { 'A missing CcmExec means no client; a missing Windows service means an image problem that needs OS repair.' } else { '' }) `
                -RepairIds $repair `
                -Data @{ Service = $spec.Name; Class = $spec.Class; Present = $false }
            $rows += [pscustomobject]@{ Service = $spec.Name; Display = $spec.Display; State = 'ABSENT'; StartMode = '-'; Verdict = $status.ToUpperInvariant() }
            continue
        }

        $problems = @()
        if ($spec.MustRun -and $svc.Status -ne 'Running') {
            $problems += ('is {0} but must be Running' -f $svc.Status)
        }

        if ($spec.Class -eq 'Core') {
            # A core service is held to the full specification.
            if ($start -and ($spec.AllowedStart -notcontains $start)) {
                $problems += ('start mode is {0}, expected {1}' -f $start, ($spec.AllowedStart -join ' or '))
            }
        }
        else {
            # A conditional service is only ever questioned when it has been
            # switched off outright. Auto vs Manual is an environment choice,
            # not a fault, and normalising it would be pure churn.
            if ($start -eq 'Disabled') {
                $problems += 'start mode is Disabled'
            }
        }

        $data = @{ Service = $spec.Name; Class = $spec.Class; Present = $true; State = "$($svc.Status)"; StartMode = "$start"; Problems = $problems }

        if ($problems.Count -eq 0) {
            $findings += New-MDFinding -Category 'Services' -Title $spec.Display -Status 'Pass' `
                -Detail ('{0} / {1}' -f $svc.Status, $start) -Data $data
            $rows += [pscustomobject]@{ Service = $spec.Name; Display = $spec.Display; State = "$($svc.Status)"; StartMode = "$start"; Verdict = 'OK' }
            continue
        }

        if ($spec.Class -eq 'Core') {
            $status = if ($spec.Critical) { 'Fail' } else { 'Warn' }
            $findings += New-MDFinding -Category 'Services' -Title $spec.Display -Status $status `
                -Detail ($problems -join '; ') `
                -Evidence @($spec.Note) `
                -Remediation ('Run: mecmdoctor repair -Level Safe  (starts {0} and corrects its start mode, and touches no other service). If a GPO is disabling it, fix the policy first or it will revert.' -f $spec.Name) `
                -RepairIds @($script:MDRepairIds.ServicesFix) -Data $data
            $rows += [pscustomobject]@{ Service = $spec.Name; Display = $spec.Display; State = "$($svc.Status)"; StartMode = "$start"; Verdict = $status.ToUpperInvariant() }
        }
        else {
            # Recorded, not repaired. Resolve-MDServiceCorrelation promotes this
            # to a repairable finding only if something is failing because of it.
            $findings += New-MDFinding -Category 'Services' -Title $spec.Display -Status 'Warn' `
                -Detail (($problems -join '; ') + ' - not repaired unless it is causing a failure') `
                -Evidence @($spec.Note,
                            ('This only matters when {0}. Nothing else in the diagnosis has been correlated with it yet.' -f $spec.Needs)) `
                -Severity 1 -Data $data
            $rows += [pscustomobject]@{ Service = $spec.Name; Display = $spec.Display; State = "$($svc.Status)"; StartMode = "$start"; Verdict = 'NOTE' }
        }
    }

    $findings | Write-MDFinding -HideEvidence

    Write-MDLine ''
    Write-MDTable -Rows $rows -Indent 9 -Columns @(
        @{ Header = 'SERVICE';    Property = 'Service';   Width = 18 }
        @{ Header = 'DISPLAY';    Property = 'Display';   Width = 34 }
        @{ Header = 'STATE';      Property = 'State';     Width = 10 }
        @{ Header = 'START';      Property = 'StartMode'; Width = 9 }
        @{ Header = 'VERDICT';    Property = 'Verdict';   Width = 7 }
    ) -RowColor {
        param($r)
        switch ($r.Verdict) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'NOTE' { 'Yellow' } 'SKIP' { 'DarkGray' } default { 'Red' } }
    }

    $findings
}


function Resolve-MDServiceCorrelation {
<#
    .SYNOPSIS
        Decides whether a disabled conditional service is the cause of a real
        problem, or simply how this machine is built.
    .DESCRIPTION
        Runs after every other check, because that is the earliest point at
        which the question can honestly be answered. For each conditional
        service that is disabled, the spec's Correlate block is handed the
        whole finding set and returns whatever is failing in a way consistent
        with it.

          msiserver disabled + an MSI deployment failure  -> repair
          msiserver disabled + nothing MSI-related        -> information only

        Findings that correlate are promoted in place: status raised, the
        matching symptoms recorded as evidence, and services.fix attached with
        the service name in Data so the repair touches only that service.
    .OUTPUTS
        The same finding set, with any promotions applied.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Findings)

    $all         = @($Findings)
    $conditional = @($all | Where-Object {
        $_.Category -eq 'Services' -and $_.Data -and $_.Data.Class -eq 'Conditional' -and
        $_.Data.Problems -and @($_.Data.Problems).Count -gt 0
    })

    if ($conditional.Count -eq 0) {
        Write-MDOk 'No conditional Windows service is misconfigured, so there is nothing to correlate.'
        return $all
    }

    foreach ($finding in $conditional) {
        $spec = $script:MDRequiredServices | Where-Object { $_.Name -eq $finding.Data.Service } | Select-Object -First 1
        if (-not $spec -or -not $spec.Correlate) { continue }

        # A service finding must not count as its own justification, so the
        # whole Services category is withheld from the correlation.
        $others   = @($all | Where-Object { $_.Category -ne 'Services' })
        $symptoms = @(& $spec.Correlate $others)

        if ($symptoms.Count -eq 0) {
            Write-MDInfo ('{0}: {1}, but nothing in this diagnosis depends on it. No repair proposed.' -f
                          $spec.Name, ($finding.Data.Problems -join '; '))
            $finding.Status      = 'Info'
            $finding.Severity    = 0
            $finding.Detail      = ('{0} - no correlated failure, so this is a configuration choice rather than a fault' -f ($finding.Data.Problems -join '; '))
            $finding.Remediation = ''
            continue
        }

        $lines = @($symptoms | Select-Object -First 4 | ForEach-Object { '{0}: {1} -- {2}' -f $_.Category, $_.Title, $_.Detail })

        Write-MDFail ('{0}: {1}, and {2} failing check(s) are consistent with that.' -f
                      $spec.Name, ($finding.Data.Problems -join '; '), $symptoms.Count)
        Write-MDDetail -Text $lines -Bullet '- '

        $finding.Status      = 'Fail'
        $finding.Severity    = 3
        $finding.Detail      = ('{0} - correlated with {1} failing check(s)' -f ($finding.Data.Problems -join '; '), $symptoms.Count)
        $finding.Evidence    = @($spec.Note, ('{0} matters here because {1}:' -f $spec.Name, $spec.Needs)) + $lines
        $finding.Remediation = ('Run: mecmdoctor repair -Level Safe  (re-enables and starts {0} only - no other service is touched). If a GPO disabled it, fix the policy first or it will revert.' -f $spec.Name)
        $finding.RepairIds   = @($script:MDRepairIds.ServicesFix)
    }

    $all
}


# ===========================================================================
#  4. WMI HEALTH
# ===========================================================================
function Test-MDWmiDeepHealth {
<#
    .SYNOPSIS
        Second-opinion WMI checks, run only when the repository is already
        under suspicion.
    .DESCRIPTION
        winmgmt /verifyrepository is the headline signal, but on its own it is
        not enough to justify a repository reset: it reports "inconsistent" for
        conditions that a salvage clears in seconds, and it says nothing at all
        about whether WMI is usable right now.

        These checks answer the question a reset actually depends on - is the
        repository damaged in a way that stops WMI working - by exercising it
        from several independent angles. Each one that fails is a corroborating
        signal; none of them alone is proof.
    .OUTPUTS
        [pscustomobject[]] Check / Ok / Detail
#>
    [CmdletBinding()]
    param()

    $signals = @()

    # --- can the service even run -------------------------------------------
    $winmgmt = Get-MDService -Name 'Winmgmt'
    $signals += [pscustomobject]@{
        Check  = 'Winmgmt service'
        Ok     = ($winmgmt -and $winmgmt.Status -eq 'Running')
        Detail = $(if ($winmgmt) { 'service is ' + $winmgmt.Status } else { 'service is not installed' })
    }

    # --- the two namespaces every provider is built on ----------------------
    # A repository that cannot answer for root\cimv2 or root\default is broken
    # in the way that a reset exists to fix.
    foreach ($probe in @(
        @{ Namespace = 'root\cimv2';   Class = 'Win32_ComputerSystem'; What = 'core OS namespace' }
        @{ Namespace = 'root\default'; Class = '__Namespace';          What = 'default namespace' }
    )) {
        $r = Invoke-MDCimQuery -Namespace $probe.Namespace -ClassName $probe.Class
        $signals += [pscustomobject]@{
            Check  = ('{0} readable' -f $probe.Namespace)
            Ok     = ($null -ne $r)
            Detail = $(if ($null -ne $r) { '{0} answered' -f $probe.What }
                       else { '{0} did not answer: {1}' -f $probe.What, $(if ($script:MDLastCimError) { $script:MDLastCimError.Exception.Message } else { 'query failed' }) })
        }
    }

    # --- class definitions, not just instances ------------------------------
    # Instance queries can succeed against a repository whose class definitions
    # are damaged. Reading the schema is the check that catches that.
    $classOk     = $true
    $classDetail = 'Win32_Service and Win32_OperatingSystem definitions read cleanly'
    try {
        foreach ($cls in @('Win32_Service', 'Win32_OperatingSystem')) {
            $null = Get-CimClass -Namespace 'root\cimv2' -ClassName $cls -ErrorAction Stop
        }
    }
    catch {
        $classOk     = $false
        $classDetail = 'class definitions could not be read: ' + $_.Exception.Message
    }
    $signals += [pscustomobject]@{ Check = 'Class definitions'; Ok = $classOk; Detail = $classDetail }

    # --- namespace tree enumeration -----------------------------------------
    # Walking root\__NAMESPACE touches the repository index rather than any one
    # provider, so a failure here is structural.
    $nsOk     = $true
    $nsDetail = ''
    try {
        $children = @(Get-CimInstance -Namespace 'root' -ClassName '__Namespace' -ErrorAction Stop)
        $nsDetail = '{0} child namespace(s) enumerated under root' -f $children.Count
        if ($children.Count -eq 0) { $nsOk = $false; $nsDetail = 'root reports no child namespaces at all' }
    }
    catch {
        $nsOk     = $false
        $nsDetail = 'root\__Namespace could not be enumerated: ' + $_.Exception.Message
    }
    $signals += [pscustomobject]@{ Check = 'Namespace tree'; Ok = $nsOk; Detail = $nsDetail }

    $signals
}


function Test-MDWmiHealth {
<#
    .SYNOPSIS
        Reports on the WMI repository, and decides - carefully - whether it is
        genuinely corrupt.
    .DESCRIPTION
        Repository size is deliberately NOT treated as evidence of corruption.
        A large OBJECTS.DATA is worth knowing about and worth investigating,
        but on its own it is a perfectly healthy repository that has seen a lot
        of MOF churn, and resetting it would discard every custom WMI class on
        the machine for no reason at all.

        A repository reset is only ever proposed when winmgmt itself reports
        the repository inconsistent AND at least one independent health check
        agrees. Even then, salvage is proposed first and the reset carries its
        own explanation and its own confirmation.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()

    # Corroborating evidence, collected as we go and weighed up at the end.
    $inconsistent   = $false
    $corroborating  = @()

    # --- repository consistency --------------------------------------------
    Write-MDAction 'Running: winmgmt /verifyrepository'
    $verify = Invoke-MDProcess -FilePath (Join-Path $env:windir 'System32\wbem\winmgmt.exe') `
                               -ArgumentList @('/verifyrepository') -TimeoutSeconds 120
    $verifyText = (($verify.StdOut + ' ' + $verify.StdErr)).Trim()

    if ($verify.TimedOut) {
        $inconsistent  = $true
        $corroborating += 'winmgmt itself did not respond within 120 seconds'
        $findings += New-MDFinding -Category 'WMI' -Title 'Repository consistency' -Status 'Fail' `
            -Detail 'winmgmt /verifyrepository did not return within 120s' `
            -Remediation 'WMI is hung. Restart the Winmgmt service, then re-run. If it hangs again, reboot before repairing.' `
            -RepairIds @($script:MDRepairIds.WmiSalvage) -Severity 4
    }
    elseif ($verify.ExitCode -eq 0 -and $verifyText -match '(?i)consistent') {
        $findings += New-MDFinding -Category 'WMI' -Title 'Repository consistency' -Status 'Pass' -Detail 'repository is consistent'
    }
    elseif ($verifyText -match '0x80041003' -or $verifyText -match '(?i)access denied') {
        # Not a repository problem: verifyrepository simply refuses to answer
        # without elevation. Reporting this as corruption would be a lie.
        $findings += New-MDFinding -Category 'WMI' -Title 'Repository consistency' -Status 'Skip' `
            -Detail 'winmgmt refused the request (access denied)' `
            -Evidence @($verifyText, 'This check needs an elevated session. Re-run via mecmdoctor.bat.')
    }
    else {
        $inconsistent = $true
        $findings += New-MDFinding -Category 'WMI' -Title 'Repository consistency' -Status 'Fail' `
            -Detail ('inconsistent (exit {0})' -f $verify.ExitCode) `
            -Evidence @($verifyText) `
            -Remediation 'Run: mecmdoctor repair -Level Standard  (salvages the repository, which is non-destructive and fixes most inconsistencies).' `
            -RepairIds @($script:MDRepairIds.WmiSalvage) -Severity 4
    }

    # --- namespace reachability --------------------------------------------
    # Ordered from "the OS is fine" outwards to the client-specific namespaces,
    # so the first failure tells you how deep the damage goes.
    $namespaces = @(
        @{ Namespace = 'root\cimv2';                          Class = 'Win32_OperatingSystem'; Critical = $true;  Os = $true;  What = 'core OS namespace' }
        @{ Namespace = 'root\ccm';                            Class = 'SMS_Client';            Critical = $true;  Os = $false; What = 'client agent namespace' }
        @{ Namespace = 'root\ccm\ClientSDK';                  Class = 'CCM_ClientUtilities';   Critical = $true;  Os = $false; What = 'client SDK (used by every management script)' }
        @{ Namespace = 'root\ccm\Policy\Machine\ActualConfig';Class = 'CCM_Policy_Policy5';    Critical = $true;  Os = $false; What = 'applied machine policy' }
        @{ Namespace = 'root\ccm\SoftwareUpdates\UpdatesStore';Class = 'CCM_UpdateStatus';     Critical = $false; Os = $false; What = 'software update compliance store' }
        @{ Namespace = 'root\ccm\SoftMgmtAgent';              Class = 'CacheConfig';           Critical = $false; Os = $false; What = 'content cache configuration' }
        @{ Namespace = 'root\ccm\InvAgt';                     Class = 'InventoryActionStatus'; Critical = $false; Os = $false; What = 'inventory agent state' }
        @{ Namespace = 'root\ccm\Scheduler';                  Class = 'CCM_Scheduler_History'; Critical = $false; Os = $false; What = 'client schedule history' }
    )

    foreach ($ns in $namespaces) {
        # root\ccm* namespaces obviously cannot exist without a client.
        if (-not $ClientInfo.Installed -and $ns.Namespace -like 'root\ccm*') {
            $findings += New-MDFinding -Category 'WMI' -Title ('Namespace ' + $ns.Namespace) -Status 'Skip' `
                -Detail 'client not installed'
            continue
        }

        $result = Invoke-MDCimQuery -Namespace $ns.Namespace -ClassName $ns.Class
        if ($null -ne $result) {
            $findings += New-MDFinding -Category 'WMI' -Title ('Namespace ' + $ns.Namespace) -Status 'Pass' `
                -Detail ('{0} readable ({1} instance(s))' -f $ns.Class, (@($result).Count))
        }
        else {
            $msg  = 'query failed'
            $code = $null
            if ($script:MDLastCimError) {
                $msg = $script:MDLastCimError.Exception.Message
                # CIM exceptions expose the raw HRESULT, which the catalogue knows.
                try { $code = $script:MDLastCimError.Exception.HResult } catch { }
                if ($script:MDLastCimError.Exception.PSObject.Properties['StatusCode']) {
                    $code = $script:MDLastCimError.Exception.StatusCode
                }
            }

            $evidence = @("$($ns.Class) in $($ns.Namespace): $msg", $ns.What)
            $fix      = 'Run: mecmdoctor repair -Level Standard'

            $translated = if ($code) { Resolve-MDError $code } else { $null }
            if ($translated) {
                $evidence += ('{0} {1} - {2}' -f $translated.Code, $translated.Name, $translated.Means)
                if ($translated.Fix) { $fix = $translated.Fix }
            }

            # A failing OS namespace implicates the repository itself. A failing
            # root\ccm namespace usually implicates the client, which is why it
            # is not counted as evidence of repository corruption.
            if ($ns.Os) { $corroborating += ('{0} is not readable' -f $ns.Namespace) }

            $status = if ($ns.Critical) { 'Fail' } else { 'Warn' }
            $repair = @($script:MDRepairIds.WmiSalvage)
            if ($ns.Namespace -like 'root\ccm*') { $repair += $script:MDRepairIds.ClientRepair }

            $findings += New-MDFinding -Category 'WMI' -Title ('Namespace ' + $ns.Namespace) -Status $status `
                -Detail 'not readable' -Evidence $evidence -Remediation $fix -RepairIds $repair `
                -Severity $(if ($ns.Critical) { 4 } else { 2 })
        }
    }

    # --- recent WMI provider failures ---------------------------------------
    # Every Windows machine logs a steady trickle of WMI errors (a query for a
    # class that does not exist is an "error"), so a low count means nothing.
    # What matters is the result code and whether the failing queries are the
    # client's own. Both come out of the message body.
    $noiseThreshold = 25
    try {
        $wmiEvents = @(Get-WinEvent -FilterHashtable @{
                            LogName   = 'Microsoft-Windows-WMI-Activity/Operational'
                            Level     = 2
                            StartTime = (Get-Date).AddDays(-3)
                        } -MaxEvents 200 -ErrorAction Stop)

        if ($wmiEvents.Count -eq 0) {
            $findings += New-MDFinding -Category 'WMI' -Title 'Provider errors (last 3 days)' -Status 'Pass' -Detail 'none'
        }
        else {
            # Group by result code so the evidence names the actual fault.
            $codes = $wmiEvents |
                ForEach-Object {
                    if ($_.Message -match 'ResultCode\s*=\s*(0x[0-9A-Fa-f]+)') { $Matches[1] } else { 'no result code' }
                } | Group-Object | Sort-Object Count -Descending | Select-Object -First 4

            $evidence = foreach ($c in $codes) {
                $translated = Resolve-MDError $c.Name
                if ($translated -and $translated.Known) {
                    '{0} x{1} - {2}: {3}' -f $c.Name, $c.Count, $translated.Name, $translated.Means
                }
                else {
                    '{0} x{1}' -f $c.Name, $c.Count
                }
            }

            # Failures against a root\ccm namespace are the ones that actually
            # implicate the client rather than some unrelated agent.
            $ccmRelated = @($wmiEvents | Where-Object { $_.Message -match 'root\\ccm' })
            if ($ccmRelated.Count -gt 0) {
                $evidence += ('{0} of these involve a root\ccm namespace - the Configuration Manager client is directly affected.' -f $ccmRelated.Count)
            }

            # The query is capped at 200, so say so rather than implying that
            # 200 is the true total.
            $countText = '{0}' -f $wmiEvents.Count
            if ($wmiEvents.Count -ge 200) { $countText = '200+ (result capped)' }

            if ($ccmRelated.Count -gt 0) {
                $findings += New-MDFinding -Category 'WMI' -Title 'Provider errors (last 3 days)' -Status 'Warn' `
                    -Detail ('{0} error event(s), including client WMI queries' -f $countText) `
                    -Evidence $evidence `
                    -Remediation 'Client WMI queries are failing. Salvage the repository, then repair the client so its MOF files recompile.' `
                    -RepairIds @($script:MDRepairIds.WmiSalvage) -Severity 3
            }
            elseif ($wmiEvents.Count -ge $noiseThreshold) {
                # Plenty of errors, but none of them are the client's. Recording
                # it as Info keeps it out of the issue list, where it would be
                # a permanent false positive on any busy machine.
                $findings += New-MDFinding -Category 'WMI' -Title 'Provider errors (last 3 days)' -Status 'Info' `
                    -Detail ('{0} error event(s), none involving the client' -f $countText) `
                    -Evidence ($evidence + 'Windows logs a WMI "error" for every query against a class that does not exist, so a steady trickle here is normal.')
            }
            else {
                $findings += New-MDFinding -Category 'WMI' -Title 'Provider errors (last 3 days)' -Status 'Pass' `
                    -Detail ('{0} event(s) - within normal background noise' -f $countText) `
                    -Evidence $evidence
            }
        }
    }
    catch {
        # The operational log is disabled by default on some builds.
        $findings += New-MDFinding -Category 'WMI' -Title 'Provider errors (last 3 days)' -Status 'Skip' `
            -Detail 'WMI-Activity/Operational log unavailable or unreadable'
    }

    # --- repository size ----------------------------------------------------
    # Reported, never repaired. Size is a reason to look, not a reason to reset.
    $objectsData = Join-Path $env:windir 'System32\wbem\Repository\OBJECTS.DATA'
    $oversized   = $false
    $sizeText    = 'unknown'

    if (Test-Path -LiteralPath $objectsData) {
        $size     = (Get-Item -LiteralPath $objectsData).Length
        $sizeText = Format-MDBytes $size
        $oversized = ($size -gt 1GB)
    }

    # --- deeper health checks ------------------------------------------------
    # Only worth the seconds they cost when something already looks wrong.
    $deep = @()
    if ($inconsistent -or $oversized) {
        Write-MDAction 'Repository is suspect - running additional WMI health checks'
        $deep = @(Test-MDWmiDeepHealth)

        foreach ($signal in ($deep | Where-Object { -not $_.Ok })) {
            $corroborating += ('{0}: {1}' -f $signal.Check, $signal.Detail)
        }

        $deepPassed = @($deep | Where-Object { $_.Ok })
        $findings += New-MDFinding -Category 'WMI' -Title 'WMI health checks' `
            -Status $(if ($deepPassed.Count -eq @($deep).Count) { 'Pass' } else { 'Fail' }) `
            -Detail ('{0} of {1} check(s) passed' -f $deepPassed.Count, @($deep).Count) `
            -Evidence (@($deep | ForEach-Object { '{0}: {1} -- {2}' -f $(if ($_.Ok) { 'ok  ' } else { 'FAIL' }), $_.Check, $_.Detail })) `
            -Severity $(if ($deepPassed.Count -eq @($deep).Count) { 0 } else { 3 })
    }

    # Only failures that are about the repository itself count. Anything raised
    # by the /verifyrepository timeout is already reflected in $inconsistent.
    $corroborating = @($corroborating | Select-Object -Unique)
    $confirmed     = ($inconsistent -and $corroborating.Count -gt 0)

    if (Test-Path -LiteralPath $objectsData) {
        if ($oversized -and -not $confirmed) {
            # The headline case this tool used to get wrong. No repair id, so
            # nothing downstream can turn this into a reset.
            $findings += New-MDFinding -Category 'WMI' -Title 'Repository size' -Status 'Warn' `
                -Detail ('{0} - unusually large, but no corruption was detected. No repair recommended.' -f $sizeText) `
                -Evidence @(
                    'A repository this size is normally the result of years of MOF churn from inventory, third-party agents and servicing.'
                    'Size on its own is not corruption, and resetting the repository because of it would discard every custom WMI class on this machine for no benefit.'
                    $(if ($deep.Count) { '{0} additional WMI health check(s) all passed.' -f @($deep).Count } else { '' })
                ) `
                -Remediation 'Worth investigating rather than repairing: look for an agent re-registering its MOFs on a loop, and plan a rebuild during a maintenance window only if WMI actually starts failing.' `
                -Severity 1
        }
        elseif ($oversized) {
            $findings += New-MDFinding -Category 'WMI' -Title 'Repository size' -Status 'Warn' `
                -Detail ('{0} - large, and corruption has been detected separately' -f $sizeText) `
                -Evidence @('The size is context, not the diagnosis. See the WMI corruption assessment below for what is actually being proposed.') `
                -Severity 1
        }
        else {
            $findings += New-MDFinding -Category 'WMI' -Title 'Repository size' -Status 'Pass' -Detail $sizeText
        }
    }

    # --- corruption assessment ----------------------------------------------
    # The single place in the whole tool that can propose a repository reset.
    if ($confirmed) {
        $findings += New-MDFinding -Category 'WMI' -Title 'WMI corruption assessment' -Status 'Fail' `
            -Detail ('repository reports inconsistent and {0} independent check(s) agree' -f $corroborating.Count) `
            -Evidence (@('winmgmt /verifyrepository does not report the repository as consistent.') + $corroborating +
                       @('Salvage runs first and is non-destructive. A reset is only attempted if salvage leaves the repository inconsistent, and it prompts separately before it does anything.')) `
            -Remediation 'Run: mecmdoctor repair -Level Standard first - salvage alone fixes most of these. If salvage leaves it inconsistent, mecmdoctor repair -Level Aggressive offers the reset, which discards every custom WMI class and needs a client repair and a reboot afterwards.' `
            -RepairIds @($script:MDRepairIds.WmiSalvage, $script:MDRepairIds.WmiReset) -Severity 4
    }
    elseif ($inconsistent) {
        $findings += New-MDFinding -Category 'WMI' -Title 'WMI corruption assessment' -Status 'Warn' `
            -Detail 'repository reports inconsistent, but WMI is still answering normally' `
            -Evidence @('No independent health check failed, so this is very likely to be cleared by a salvage.',
                        'A repository reset is deliberately not proposed on this evidence.') `
            -Remediation 'Run: mecmdoctor repair -Level Standard  (salvage only).' `
            -RepairIds @($script:MDRepairIds.WmiSalvage) -Severity 2
    }
    elseif ($corroborating.Count -gt 0) {
        $findings += New-MDFinding -Category 'WMI' -Title 'WMI corruption assessment' -Status 'Warn' `
            -Detail ('{0} health check(s) failed, but the repository verifies as consistent' -f $corroborating.Count) `
            -Evidence ($corroborating + 'Without an inconsistent repository this points at a provider or a permissions problem rather than repository damage.') `
            -Remediation 'Restart the Winmgmt service and re-run the diagnosis. If the same checks fail, salvage the repository: mecmdoctor repair -Level Standard' `
            -RepairIds @($script:MDRepairIds.WmiSalvage) -Severity 2
    }
    else {
        $findings += New-MDFinding -Category 'WMI' -Title 'WMI corruption assessment' -Status 'Pass' `
            -Detail 'no evidence of repository corruption'
    }

    $findings | Write-MDFinding
    $findings
}
# ===========================================================================
#  5. CLIENT REGISTRATION
# ===========================================================================
function Test-MDClientRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()

    if (-not $ClientInfo.Installed) {
        $findings += New-MDFinding -Category 'Registration' -Title 'Client registration' -Status 'Skip' -Detail 'client not installed'
        $findings | Write-MDFinding
        return $findings
    }

    # --- site assignment ----------------------------------------------------
    if ($ClientInfo.SiteCode) {
        $findings += New-MDFinding -Category 'Registration' -Title 'Assigned site code' -Status 'Pass' -Detail $ClientInfo.SiteCode
    }
    else {
        $findings += New-MDFinding -Category 'Registration' -Title 'Assigned site code' -Status 'Fail' `
            -Detail 'the client is not assigned to a site' `
            -Evidence @('HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client\AssignedSiteCode is empty and SMS_Authority returned nothing.') `
            -Remediation 'This is a site-side problem before it is a client-side one: check AD site, boundary and boundary group configuration, then force a machine policy retrieval. If it stays unassigned, reinstall with SMSSITECODE set.' `
            -RepairIds @($script:MDRepairIds.PolicyTrigger) -Severity 4
    }

    # --- client identity ----------------------------------------------------
    # A missing GUID is reported, never "fixed". Deleting the client identity to
    # force a new one orphans every piece of inventory and deployment history
    # the site holds for this device, so mecmdoctor does not do it: restarting
    # CcmExec makes the client re-register under the identity it already has.
    if ($ClientInfo.ClientId -and $ClientInfo.ClientId -ne 'GUID:00000000-0000-0000-0000-000000000000') {
        $findings += New-MDFinding -Category 'Registration' -Title 'Client ID' -Status 'Pass' -Detail $ClientInfo.ClientId
    }
    else {
        $findings += New-MDFinding -Category 'Registration' -Title 'Client ID' -Status 'Fail' `
            -Detail 'no client GUID has been assigned' `
            -Evidence @('The client has never completed registration with the site, so it has no identity to work with.') `
            -Remediation 'Restart CcmExec so the client retries registration, then check ClientIDManagerStartup.log: mecmdoctor repair -Level Safe' `
            -RepairIds @($script:MDRepairIds.CcmRestart) -Severity 4
    }

    # SMSCFG.INI holds the persisted identity. Its absence on an otherwise
    # installed client means registration never completed. It is never deleted
    # by this tool - the client rebuilds it during registration, and removing it
    # by hand is what produces a brand new GUID.
    $smscfg = Join-Path $env:windir 'SMSCFG.INI'
    if (Test-Path -LiteralPath $smscfg) {
        $findings += New-MDFinding -Category 'Registration' -Title 'SMSCFG.INI' -Status 'Pass' `
            -Detail ('present, last written {0}' -f (Format-MDAge (Get-Item -LiteralPath $smscfg).LastWriteTime))
    }
    else {
        $findings += New-MDFinding -Category 'Registration' -Title 'SMSCFG.INI' -Status 'Warn' `
            -Detail 'missing - the client has no persisted identity' `
            -Remediation 'Restart CcmExec; the client registers and recreates the file by itself: mecmdoctor repair -Level Safe' `
            -RepairIds @($script:MDRepairIds.CcmRestart)
    }

    # --- registration confirmed in the log ----------------------------------
    if ($ClientInfo.LogPath) {
        $regLog = Get-MDLogFileSet -LogRoot $ClientInfo.LogPath -Name 'ClientIDManagerStartup.log'
        if ($regLog) {
            $text    = Get-MDLogTail -Path ($regLog | Select-Object -Last 1).FullName
            $entries = ConvertFrom-MDLogText -Text $text -LogName 'ClientIDManagerStartup.log'
            $success = $entries | Where-Object { $_.Message -match '(?i)(client is registered|Server assigned ClientID)' } | Select-Object -Last 1

            if ($success) {
                $findings += New-MDFinding -Category 'Registration' -Title 'Registration confirmed' -Status 'Pass' `
                    -Detail ('last confirmed {0}' -f (Format-MDAge $success.Time)) `
                    -Evidence @($success.Message)
            }
            else {
                $failLine = $entries | Where-Object { $_.Type -ge 3 } | Select-Object -Last 1
                $ev = @()
                if ($failLine) { $ev += $failLine.Message }
                $findings += New-MDFinding -Category 'Registration' -Title 'Registration confirmed' -Status 'Fail' `
                    -Detail 'ClientIDManagerStartup.log shows no successful registration' `
                    -Evidence $ev `
                    -Remediation 'Restart CcmExec so registration is retried, then follow ClientIDManagerStartup.log and CcmMessaging.log: mecmdoctor repair -Level Safe' `
                    -RepairIds @($script:MDRepairIds.CcmRestart, $script:MDRepairIds.PolicyTrigger) -Severity 4
            }
        }
    }

    # --- management point ---------------------------------------------------
    if (-not $ClientInfo.ManagementPoint) {
        $findings += New-MDFinding -Category 'Registration' -Title 'Management point' -Status 'Fail' `
            -Detail 'the client does not know of any management point' `
            -Remediation 'Check LocationServices.log and the boundary group configuration. Force a machine policy retrieval once boundaries are correct.' `
            -RepairIds @($script:MDRepairIds.PolicyTrigger) -Severity 4
    }
    else {
        $mp = $ClientInfo.ManagementPoint
        $findings += New-MDFinding -Category 'Registration' -Title 'Management point' -Status 'Pass' -Detail $mp

        # DNS first: a name that does not resolve makes the HTTP test pointless.
        $resolved = $null
        try { $resolved = [System.Net.Dns]::GetHostAddresses($mp) } catch { }

        if ($resolved -and $resolved.Count) {
            $findings += New-MDFinding -Category 'Registration' -Title 'MP name resolution' -Status 'Pass' `
                -Detail (($resolved | ForEach-Object { $_.IPAddressToString }) -join ', ')

            # The mplist endpoint is the canonical "is this MP alive" probe.
            $findings += Test-MDManagementPointHttp -ManagementPoint $mp -HttpsOnly $ClientInfo.HttpsOnly
        }
        else {
            $findings += New-MDFinding -Category 'Registration' -Title 'MP name resolution' -Status 'Fail' `
                -Detail ('DNS lookup for {0} failed' -f $mp) `
                -Remediation 'Fix DNS, or confirm the client is on a network with a route to internal DNS (VPN/DirectAccess). Then flush the resolver cache.' `
                -Severity 4
        }
    }

    $findings | Write-MDFinding
    $findings
}


function Test-MDManagementPointHttp {
    <# Probes the MP mplist endpoint over HTTP and/or HTTPS. #>
    param(
        [Parameter(Mandatory)][string] $ManagementPoint,
        $HttpsOnly
    )

    $findings = @()

    # Modern sites are TLS 1.2+; PS 5.1 still defaults to SSL3/TLS1.0.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    } catch { }

    $schemes = @('http')
    if ($HttpsOnly) { $schemes = @('https') } else { $schemes = @('http', 'https') }

    foreach ($scheme in $schemes) {
        $url = '{0}://{1}/sms_mp/.sms_aut?mplist' -f $scheme, $ManagementPoint
        Write-MDAction ("Probing management point: {0}" -f $url)

        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                # A healthy MP returns an XML MPList document.
                $looksRight = "$($resp.Content)" -match '(?i)<MPList|<MP '
                if ($looksRight) {
                    $findings += New-MDFinding -Category 'Registration' -Title ("MP reachable over $scheme") -Status 'Pass' `
                        -Detail ('HTTP 200, valid MPList ({0} bytes)' -f $resp.RawContentLength)
                }
                else {
                    $findings += New-MDFinding -Category 'Registration' -Title ("MP reachable over $scheme") -Status 'Warn' `
                        -Detail 'HTTP 200 but the response is not an MPList document' `
                        -Evidence @('Something is answering on this URL that is not a management point - check for a proxy or captive portal intercepting the request.')
                }
            }
            else {
                $findings += New-MDFinding -Category 'Registration' -Title ("MP reachable over $scheme") -Status 'Warn' `
                    -Detail ('HTTP {0}' -f $resp.StatusCode)
            }
        }
        catch {
            $msg    = $_.Exception.Message
            $status = 'Fail'
            $fix    = 'Confirm the MP is up and that nothing between this client and it is blocking the request.'

            # An HTTPS failure on a mixed-mode site is expected, not a problem.
            if ($scheme -eq 'https' -and -not $HttpsOnly) {
                $status = 'Info'
                $fix    = ''
            }

            $httpStatus = $null
            try { $httpStatus = [int]$_.Exception.Response.StatusCode } catch { }
            if ($httpStatus) {
                $translated = Resolve-MDError ('0x{0:X8}' -f (0x80190000 -bor $httpStatus))
                if ($translated -and $translated.Known) { $fix = $translated.Fix; $msg = '{0} ({1})' -f $msg, $translated.Name }
            }

            $findings += New-MDFinding -Category 'Registration' -Title ("MP reachable over $scheme") -Status $status `
                -Detail $msg -Remediation $fix -Severity $(if ($status -eq 'Fail') { 4 } else { 0 })
        }
    }

    $findings
}


# ===========================================================================
#  6. CERTIFICATES
# ===========================================================================
function Test-MDCertificates {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()

    if (-not $ClientInfo.Installed) {
        $findings += New-MDFinding -Category 'Certificates' -Title 'SMS certificate store' -Status 'Skip' -Detail 'client not installed'
        $findings | Write-MDFinding
        return $findings
    }

    # The client keeps its own certificates (self-signed, or a copy of the PKI
    # cert it selected) in a dedicated LocalMachine\SMS store.
    try {
        $smsCerts = @(Get-ChildItem -Path 'Cert:\LocalMachine\SMS' -ErrorAction Stop)

        # Certificates are reported, never deleted. The client reissues its own
        # self-signed certificate when it needs one; clearing the store by hand
        # is part of an identity reset, which this tool deliberately does not do.
        if ($smsCerts.Count -eq 0) {
            $findings += New-MDFinding -Category 'Certificates' -Title 'SMS certificate store' -Status 'Fail' `
                -Detail 'store is empty - the client has no identity certificate' `
                -Evidence @('The client generates a self-signed certificate during registration, so an empty store means registration has never succeeded.') `
                -Remediation 'Restart CcmExec so the client reissues its certificate during registration, then read CertificateMaintenance.log: mecmdoctor repair -Level Safe' `
                -RepairIds @($script:MDRepairIds.CcmRestart) -Severity 4
        }
        else {
            $expired  = @($smsCerts | Where-Object { $_.NotAfter -lt (Get-Date) })
            $expiring = @($smsCerts | Where-Object { $_.NotAfter -ge (Get-Date) -and $_.NotAfter -lt (Get-Date).AddDays(30) })

            if ($expired.Count -gt 0) {
                $findings += New-MDFinding -Category 'Certificates' -Title 'SMS certificate store' -Status 'Fail' `
                    -Detail ('{0} of {1} certificate(s) expired' -f $expired.Count, $smsCerts.Count) `
                    -Evidence (@($expired | ForEach-Object { '{0} expired {1:yyyy-MM-dd}' -f $_.Subject, $_.NotAfter })) `
                    -Remediation 'Restart CcmExec; the client renews an expired self-signed certificate itself. If it does not, check the system clock and CertificateMaintenance.log.' `
                    -RepairIds @($script:MDRepairIds.CcmRestart) -Severity 4
            }
            elseif ($expiring.Count -gt 0) {
                $findings += New-MDFinding -Category 'Certificates' -Title 'SMS certificate store' -Status 'Warn' `
                    -Detail ('{0} certificate(s) expire within 30 days' -f $expiring.Count) `
                    -Evidence (@($expiring | ForEach-Object { '{0} expires {1:yyyy-MM-dd}' -f $_.Subject, $_.NotAfter })) `
                    -Remediation 'The client normally renews these itself. Watch CertificateMaintenance.log as the date approaches.'
            }
            else {
                $findings += New-MDFinding -Category 'Certificates' -Title 'SMS certificate store' -Status 'Pass' `
                    -Detail ('{0} certificate(s), all valid' -f $smsCerts.Count) `
                    -Evidence (@($smsCerts | ForEach-Object { '{0} valid to {1:yyyy-MM-dd}' -f $_.Subject, $_.NotAfter }))
            }

            # A certificate with no usable private key looks fine in the store
            # and fails every single time it is used. Worth calling out.
            $noKey = @($smsCerts | Where-Object { -not $_.HasPrivateKey })
            if ($noKey.Count -gt 0) {
                $findings += New-MDFinding -Category 'Certificates' -Title 'Private keys' -Status 'Fail' `
                    -Detail ('{0} certificate(s) have no accessible private key' -f $noKey.Count) `
                    -Evidence @('Damaged ACLs on the MachineKeys folder are the usual cause, and no amount of client-side repair works around them.') `
                    -Remediation 'Fix permissions on C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys (SYSTEM and Administrators need full control), then restart CcmExec.' `
                    -RepairIds @($script:MDRepairIds.CcmRestart) -Severity 4
            }
        }
    }
    catch {
        $findings += New-MDFinding -Category 'Certificates' -Title 'SMS certificate store' -Status 'Warn' `
            -Detail ('could not read Cert:\LocalMachine\SMS - {0}' -f $_.Exception.Message)
    }

    # For an HTTPS-only client, a client authentication certificate in the
    # personal store is mandatory.
    if ($ClientInfo.HttpsOnly) {
        try {
            $clientAuth = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction Stop | Where-Object {
                $_.NotAfter -gt (Get-Date) -and
                ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.2' })
            })

            if ($clientAuth.Count -gt 0) {
                $findings += New-MDFinding -Category 'Certificates' -Title 'Client authentication certificate' -Status 'Pass' `
                    -Detail ('{0} valid certificate(s) available' -f $clientAuth.Count)
            }
            else {
                $findings += New-MDFinding -Category 'Certificates' -Title 'Client authentication certificate' -Status 'Fail' `
                    -Detail 'this client is HTTPS-only but has no valid client authentication certificate' `
                    -Remediation 'Fix certificate autoenrolment (gpupdate /force, then check the CA template permissions). The client cannot talk to the MP without one.' `
                    -Severity 4
            }
        }
        catch {
            $findings += New-MDFinding -Category 'Certificates' -Title 'Client authentication certificate' -Status 'Skip' `
                -Detail 'personal certificate store unreadable'
        }
    }

    $findings | Write-MDFinding
    $findings
}


# ===========================================================================
#  7. POLICY
# ===========================================================================
function Test-MDPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()

    if (-not $ClientInfo.Installed) {
        $findings += New-MDFinding -Category 'Policy' -Title 'Machine policy' -Status 'Skip' -Detail 'client not installed'
        $findings | Write-MDFinding
        return $findings
    }

    # --- how much policy has actually landed --------------------------------
    $applied = Invoke-MDCimQuery -Namespace 'root\ccm\Policy\Machine\ActualConfig' -ClassName 'CCM_Policy_Policy5'
    $requested = Invoke-MDCimQuery -Namespace 'root\ccm\Policy\Machine\RequestedConfig' -ClassName 'CCM_Policy_Policy5'

    $appliedCount   = @($applied).Count
    $requestedCount = @($requested).Count

    if ($null -eq $applied) {
        $findings += New-MDFinding -Category 'Policy' -Title 'Applied machine policy' -Status 'Fail' `
            -Detail 'the ActualConfig policy namespace could not be read' `
            -Remediation 'This is a WMI problem before it is a policy problem. Repair WMI first: mecmdoctor repair -Level Standard' `
            -RepairIds @($script:MDRepairIds.WmiSalvage, $script:MDRepairIds.PolicyReset) -Severity 4
    }
    elseif ($appliedCount -eq 0) {
        $findings += New-MDFinding -Category 'Policy' -Title 'Applied machine policy' -Status 'Fail' `
            -Detail 'no policy has been applied at all' `
            -Remediation 'Reset client policy so everything is re-requested: mecmdoctor repair -Level Standard' `
            -RepairIds @($script:MDRepairIds.PolicyReset) -Severity 4
    }
    elseif ($appliedCount -lt 20) {
        # A healthy client carries dozens of policy bodies - the default client
        # settings alone account for most of them. A handful means the download
        # started and stopped.
        $findings += New-MDFinding -Category 'Policy' -Title 'Applied machine policy' -Status 'Warn' `
            -Detail ('only {0} policy bodies applied ({1} requested)' -f $appliedCount, $requestedCount) `
            -Evidence @('A healthy client normally carries several dozen. This looks like a partial policy download.') `
            -Remediation 'Force a machine policy retrieval, then re-check. If it stays low, reset policy.' `
            -RepairIds @($script:MDRepairIds.PolicyTrigger, $script:MDRepairIds.PolicyReset)
    }
    else {
        $findings += New-MDFinding -Category 'Policy' -Title 'Applied machine policy' -Status 'Pass' `
            -Detail ('{0} policy bodies applied ({1} requested)' -f $appliedCount, $requestedCount)
    }

    # --- schedule history ---------------------------------------------------
    # This is the single most useful signal for "is the client actually doing
    # anything", and it is where stuck agents show up first.
    $history = Invoke-MDCimQuery -Namespace 'root\ccm\Scheduler' -ClassName 'CCM_Scheduler_History'

    $rows           = @()
    $cycleFindings  = @()

    if ($null -eq $history) {
        $findings += New-MDFinding -Category 'Policy' -Title 'Schedule history' -Status 'Warn' `
            -Detail 'root\ccm\Scheduler is not readable' `
            -RepairIds @($script:MDRepairIds.WmiSalvage)
    }
    else {
        foreach ($sched in $script:MDScheduleIds) {
            # Machine schedules have no user SID; user-targeted copies do.
            $entry = $history | Where-Object { $_.ScheduleID -eq $sched.Id -and (-not $_.UserSID -or $_.UserSID -eq 'Machine') } |
                     Sort-Object LastTriggerTime -Descending | Select-Object -First 1
            if (-not $entry) {
                $entry = $history | Where-Object { $_.ScheduleID -eq $sched.Id } |
                         Sort-Object LastTriggerTime -Descending | Select-Object -First 1
            }

            $last = $null
            if ($entry) { $last = $entry.LastTriggerTime }

            $verdict = 'OK'
            if (-not $last) {
                $verdict = 'NEVER'
            }
            elseif ($last -lt (Get-Date).AddDays(-$sched.StaleDays)) {
                $verdict = 'STALE'
            }

            $rows += [pscustomobject]@{
                Cycle   = $sched.Name
                Last    = $(if ($last) { $last.ToString('yyyy-MM-dd HH:mm') } else { '(never)' })
                Age     = (Format-MDAge $last)
                Verdict = $verdict
            }

            # One finding per cycle so the summary and the JSON export carry the
            # full picture; the table below is the at-a-glance version.
            switch ($verdict) {
                'STALE' {
                    $cycleFindings += New-MDFinding -Category 'Policy' -Title $sched.Name -Status 'Warn' `
                        -Detail ('last ran {0} (threshold {1} day(s))' -f (Format-MDAge $last), $sched.StaleDays) `
                        -Remediation 'Trigger the client cycles: mecmdoctor repair -Level Safe' `
                        -RepairIds @($script:MDRepairIds.PolicyTrigger)
                }
                'NEVER' {
                    # Only the policy cycles are alarming when they have never
                    # run; a device that has never done a software inventory is
                    # merely new.
                    if ($sched.StaleDays -le 2) {
                        $cycleFindings += New-MDFinding -Category 'Policy' -Title $sched.Name -Status 'Fail' `
                            -Detail 'has never run' `
                            -Remediation 'The scheduler is not running these cycles. Restart CcmExec and force a policy retrieval.' `
                            -RepairIds @($script:MDRepairIds.CcmRestart, $script:MDRepairIds.PolicyTrigger) -Severity 3
                    }
                    else {
                        $cycleFindings += New-MDFinding -Category 'Policy' -Title $sched.Name -Status 'Info' -Detail 'has never run'
                    }
                }
                default {
                    $cycleFindings += New-MDFinding -Category 'Policy' -Title $sched.Name -Status 'Pass' `
                        -Detail ('last ran {0}' -f (Format-MDAge $last))
                }
            }
        }
    }

    $findings | Write-MDFinding

    # Healthy cycles are covered by the table below, so only the problems get
    # their own status line - otherwise this one check prints twenty lines.
    $cycleFindings | Where-Object { $_.Status -ne 'Pass' } | Write-MDFinding

    if ($rows.Count -gt 0) {
        Write-MDLine ''
        Write-MDTable -Rows $rows -Indent 9 -Columns @(
            @{ Header = 'CLIENT CYCLE'; Property = 'Cycle';   Width = 36 }
            @{ Header = 'LAST RUN';     Property = 'Last';    Width = 18 }
            @{ Header = 'AGE';          Property = 'Age';     Width = 12 }
            @{ Header = 'VERDICT';      Property = 'Verdict'; Width = 7 }
        ) -RowColor {
            param($r)
            switch ($r.Verdict) { 'OK' { 'Green' } 'STALE' { 'Yellow' } default { 'Red' } }
        }
    }

    $findings + $cycleFindings
}


# ===========================================================================
#  8. SOFTWARE UPDATES
# ===========================================================================

# Where the client-side Windows Update policy lives.
$script:MDWuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

# "Specify source service for specific classes of Windows Updates", the policy
# that replaced DisableDualScan at Windows 10 1903 (build 18362). Each value is
# 0 = Windows Update, 1 = WSUS / Configuration Manager.
$script:MDScanSourcePolicies = @(
    @{ Name = 'SetPolicyDrivenUpdateSourceForFeatureUpdates'; What = 'feature updates' }
    @{ Name = 'SetPolicyDrivenUpdateSourceForQualityUpdates'; What = 'quality updates' }
    @{ Name = 'SetPolicyDrivenUpdateSourceForDriverUpdates';  What = 'driver updates' }
    @{ Name = 'SetPolicyDrivenUpdateSourceForOtherUpdates';   What = 'other updates' }
)

# Windows Update for Business deferral policies. These are what put a client
# into dual scan in the first place: with none of them configured, the scan
# source question does not arise at all.
$script:MDWufbPolicies = @(
    'DeferFeatureUpdates'
    'DeferFeatureUpdatesPeriodInDays'
    'DeferQualityUpdates'
    'DeferQualityUpdatesPeriodInDays'
    'BranchReadinessLevel'
    'DeferUpgrade'
    'TargetReleaseVersion'
    'TargetReleaseVersionInfo'
    'ProductVersion'
)

# Windows 10 1903. Before this build DisableDualScan is the control that
# matters; from it onwards the scan source policy takes precedence.
$script:MDScanSourceMinBuild = 18362


function Get-MDUpdateSourceConfig {
<#
    .SYNOPSIS
        Reads everything that decides where this machine scans for updates.
    .DESCRIPTION
        Kept separate from the check that judges it so that both the diagnosis
        and the support bundle report the same values, and so the decision
        logic can be reasoned about (and tested) without touching the registry.
    .OUTPUTS
        [pscustomobject] describing the policy state and which policy model
        applies to this Windows build.
#>
    [CmdletBinding()]
    param($Release)

    if (-not $Release) { $Release = Get-MDWindowsRelease }

    $au = $script:MDWuPolicyKey + '\AU'

    $scanSource = @()
    foreach ($p in $script:MDScanSourcePolicies) {
        $v = Get-MDRegValue -Path $script:MDWuPolicyKey -Name $p.Name
        if ($null -ne $v) {
            $scanSource += [pscustomobject]@{
                Name   = $p.Name
                What   = $p.What
                Value  = [int]$v
                Source = $(if ([int]$v -eq 1) { 'WSUS / Configuration Manager' } else { 'Windows Update' })
            }
        }
    }

    $wufb = @()
    foreach ($name in $script:MDWufbPolicies) {
        $v = Get-MDRegValue -Path $script:MDWuPolicyKey -Name $name
        if ($null -ne $v) { $wufb += ('{0} = {1}' -f $name, $v) }
    }

    [pscustomobject]@{
        Release            = $Release
        UsesScanSourcePolicy = ($Release.Build -ge $script:MDScanSourceMinBuild)
        WUServer           = Get-MDRegValue -Path $script:MDWuPolicyKey -Name 'WUServer'
        WUStatusServer     = Get-MDRegValue -Path $script:MDWuPolicyKey -Name 'WUStatusServer'
        UseWUServer        = Get-MDRegValue -Path $au -Name 'UseWUServer'
        NoAutoUpdate       = Get-MDRegValue -Path $au -Name 'NoAutoUpdate'
        DisableDualScan    = Get-MDRegValue -Path $script:MDWuPolicyKey -Name 'DisableDualScan'
        ScanSource         = $scanSource
        WufbPolicies       = $wufb
        WufbConfigured     = ($wufb.Count -gt 0)
        GpoManagesWu       = (Test-MDRegistryPolContains -Pattern 'WindowsUpdate')
    }
}


function Test-MDUpdateSource {
<#
    .SYNOPSIS
        Judges the update source configuration against the Windows build it is
        actually running on.
    .DESCRIPTION
        The old rule - "DisableDualScan is not 1, therefore this is broken" -
        produces a permanent false positive on Windows 11 and on Windows 10
        1903 and later, where that policy was superseded by the scan source
        policy and where a machine with no deferral policies cannot dual scan
        at all.

        What is reported now:

          * every build      the update source actually in effect, always
          * build >= 18362   the scan source policy decides. A conflict is only
                             reported when a policy explicitly sends a class of
                             updates to Windows Update while ConfigMgr owns
                             patching, or when deferral policies are set with
                             no scan source policy to constrain them.
          * build <  18362   DisableDualScan is still the control that matters,
                             but it is only relevant when Windows Update for
                             Business deferral policies are configured. Without
                             them there is nothing to disable.
    .OUTPUTS
        The findings, and the config object as Data on the summary finding.
#>
    [CmdletBinding()]
    param($Config)

    if (-not $Config) { $Config = Get-MDUpdateSourceConfig }

    $findings = @()
    $release  = $Config.Release

    # --- what is actually configured, stated plainly ------------------------
    $summary = @()
    $summary += ('Windows release: {0}' -f $release.Text)
    $summary += ('Update source policy model: {0}' -f $(if ($Config.UsesScanSourcePolicy) {
                    'scan source policy (Windows 10 1903 / build 18362 and later)'
                 } else {
                    'DisableDualScan (pre-1903 builds)'
                 }))
    $summary += ('WUServer: {0}' -f $(if ($Config.WUServer) { $Config.WUServer } else { '(not set)' }))
    $summary += ('UseWUServer: {0}' -f $(if ($null -ne $Config.UseWUServer) { $Config.UseWUServer } else { '(not set)' }))

    if ($Config.ScanSource.Count -gt 0) {
        foreach ($s in $Config.ScanSource) { $summary += ('{0}: {1} -> {2}' -f $s.Name, $s.What, $s.Source) }
    }
    else {
        $summary += 'Scan source policy: not configured'
    }

    $summary += ('DisableDualScan: {0}' -f $(if ($null -ne $Config.DisableDualScan) { $Config.DisableDualScan } else { '(not set)' }))
    $summary += ('Windows Update for Business deferral policies: {0}' -f $(if ($Config.WufbConfigured) { $Config.WufbPolicies -join ', ' } else { 'none configured' }))

    $sourceText = 'Configuration Manager software update point'
    if (-not $Config.WUServer) { $sourceText = 'not yet determined (no WUServer written)' }

    $findings += New-MDFinding -Category 'Updates' -Title 'Update source configuration' -Status 'Info' `
        -Detail ('scanning against: {0}' -f $sourceText) `
        -Evidence $summary -Data $Config

    if ($Config.WUServer) {
        Write-MDInfo ("WUServer currently set to: {0}" -f $Config.WUServer)
    }

    # --- WSUS settings arriving from a GPO ----------------------------------
    # Registry.pol is the authority on whether a *GPO* set these values, as
    # opposed to the MECM client setting them itself (which is normal). This
    # remains the number one cause of "the client never patches".
    if ($Config.GpoManagesWu -and $Config.WUServer) {
        $findings += New-MDFinding -Category 'Updates' -Title 'WSUS Group Policy conflict' -Status 'Fail' `
            -Detail 'a Group Policy is managing Windows Update settings on a Configuration Manager client' `
            -Evidence @(
                "WUServer = $($Config.WUServer)"
                "UseWUServer = $($Config.UseWUServer)"
                'Windows Update settings were found inside the machine Registry.pol, meaning they come from a GPO rather than from the MECM client.'
                'The client overwrites these at every scan, the GPO overwrites them back, and scans fail with 0x87D00692.'
            ) `
            -Remediation 'Remove the WUServer / UseWUServer settings from the GPO. Configuration Manager manages the update source itself. Then reset Windows Update components and rescan.' `
            -RepairIds @($script:MDRepairIds.UpdatesReset, $script:MDRepairIds.UpdatesRescan) -Severity 4
    }
    elseif ($Config.WUServer) {
        $findings += New-MDFinding -Category 'Updates' -Title 'WSUS Group Policy conflict' -Status 'Pass' `
            -Detail 'update source is set locally (expected for a MECM client)'
    }
    else {
        $findings += New-MDFinding -Category 'Updates' -Title 'WSUS Group Policy conflict' -Status 'Info' `
            -Detail 'no WUServer configured yet - normal before the first successful scan'
    }

    if ($Config.NoAutoUpdate -eq 1) {
        $findings += New-MDFinding -Category 'Updates' -Title 'NoAutoUpdate policy' -Status 'Info' `
            -Detail 'automatic updates disabled by policy (normal when MECM owns patching)'
    }

    # --- scan source / dual scan -------------------------------------------
    if ($Config.UsesScanSourcePolicy) {
        # Modern builds. DisableDualScan is superseded here, so its absence is
        # not a finding at all - only an actual conflict is.
        $divert = @($Config.ScanSource | Where-Object { $_.Value -ne 1 })

        if ($divert.Count -gt 0) {
            $findings += New-MDFinding -Category 'Updates' -Title 'Update scan source' -Status 'Fail' `
                -Detail ('{0} update class(es) are policy-directed to Windows Update instead of Configuration Manager' -f $divert.Count) `
                -Evidence (@($divert | ForEach-Object { '{0} -> {1}' -f $_.What, $_.Source }) +
                           'Configuration Manager cannot report on or deploy updates the client obtained from Windows Update, so these will scan and install outside its control.') `
                -Remediation 'Set "Specify source service for specific classes of Windows Updates" to WSUS for every class Configuration Manager is supposed to own, or remove the policy entirely and let the client set the source itself.' `
                -Severity 3
        }
        elseif ($Config.ScanSource.Count -gt 0) {
            $findings += New-MDFinding -Category 'Updates' -Title 'Update scan source' -Status 'Pass' `
                -Detail ('all {0} configured update class(es) point at WSUS / Configuration Manager' -f $Config.ScanSource.Count) `
                -Evidence (@($Config.ScanSource | ForEach-Object { '{0} -> {1}' -f $_.What, $_.Source }))
        }
        elseif ($Config.WufbConfigured) {
            # Deferral policies with nothing constraining the source is the one
            # genuine dual scan risk left on a modern build.
            $findings += New-MDFinding -Category 'Updates' -Title 'Update scan source' -Status 'Warn' `
                -Detail 'Windows Update for Business deferral policies are configured with no scan source policy to constrain them' `
                -Evidence (@('Configured: ' + ($Config.WufbPolicies -join ', ')) +
                           'Deferral policies are what put a client into dual scan. With no scan source policy, this client can scan Microsoft Update directly and pick up updates Configuration Manager knows nothing about.') `
                -Remediation 'Either remove the deferral policies (Configuration Manager handles deferral itself) or set "Specify source service for specific classes of Windows Updates" to WSUS for each class.' `
                -Severity 2
        }
        else {
            $findings += New-MDFinding -Category 'Updates' -Title 'Update scan source' -Status 'Pass' `
                -Detail 'no deferral or scan source policy configured - the client sets its own update source' `
                -Evidence @(('DisableDualScan does not apply on {0}; it was superseded by the scan source policy at Windows 10 1903 (build 18362).' -f $release.Name),
                            'Without Windows Update for Business deferral policies, dual scan cannot occur.')
        }
    }
    else {
        # Pre-1903, where DisableDualScan is still the control that matters -
        # but only once deferral policies have been configured.
        if ($Config.WufbConfigured -and $Config.DisableDualScan -ne 1) {
            $findings += New-MDFinding -Category 'Updates' -Title 'Dual scan' -Status 'Warn' `
                -Detail ('deferral policies are configured on {0} and DisableDualScan is not set' -f $release.Text) `
                -Evidence (@('Configured: ' + ($Config.WufbPolicies -join ', ')) +
                           'On this build, deferral policies without DisableDualScan send the client to Windows Update instead of the software update point, producing updates MECM knows nothing about.') `
                -Remediation 'Set "Do not allow update deferral policies to cause scans against Windows Update" (DisableDualScan = 1), or remove the deferral policies and let Configuration Manager handle deferral.' `
                -Severity 2
        }
        elseif ($Config.DisableDualScan -eq 1) {
            $findings += New-MDFinding -Category 'Updates' -Title 'Dual scan' -Status 'Pass' `
                -Detail 'DisableDualScan = 1, so deferral policies cannot divert the scan'
        }
        else {
            $findings += New-MDFinding -Category 'Updates' -Title 'Dual scan' -Status 'Pass' `
                -Detail 'no deferral policies configured, so dual scan cannot occur' `
                -Evidence @('DisableDualScan only matters once Windows Update for Business deferral policies are in play. None are set here.')
        }
    }

    $findings
}


function Test-MDSoftwareUpdates {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings  = @()
    $stuckRows = @()

    # --- update source, dual scan and WSUS policy conflicts -----------------
    $findings += Test-MDUpdateSource

    # --- scan freshness -----------------------------------------------------
    if ($ClientInfo.Installed) {
        $updates = Invoke-MDCimQuery -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_SoftwareUpdate'

        if ($null -eq $updates) {
            $findings += New-MDFinding -Category 'Updates' -Title 'Update inventory' -Status 'Warn' `
                -Detail 'CCM_SoftwareUpdate is not readable' `
                -Remediation 'Repair WMI, then force a software update scan.' `
                -RepairIds @($script:MDRepairIds.WmiSalvage, $script:MDRepairIds.UpdatesRescan)
        }
        else {
            $all   = @($updates)
            $stuck = @()
            $rows  = @()

            foreach ($u in $all) {
                $state = $script:MDUpdateStates[[int]$u.EvaluationState]
                $text  = if ($state) { $state.Text } else { "state $($u.EvaluationState)" }
                $isStuck = $state -and $state.Stuck

                if ($isStuck) {
                    $stuck += $u
                    $name = "$($u.Name)"
                    if ($name.Length -gt 58) { $name = $name.Substring(0, 55) + '...' }
                    $rows += [pscustomobject]@{
                        Article = "$($u.ArticleID)"
                        Name    = $name
                        State   = $text
                        Percent = "$($u.PercentComplete)"
                    }
                }
            }

            $findings += New-MDFinding -Category 'Updates' -Title 'Targeted updates' -Status 'Info' `
                -Detail ('{0} update(s) targeted at this client' -f $all.Count)

            if ($stuck.Count -gt 0) {
                $findings += New-MDFinding -Category 'Updates' -Title 'Stuck updates' -Status 'Fail' `
                    -Detail ('{0} update(s) sitting in an in-progress state' -f $stuck.Count) `
                    -Evidence (@($rows | Select-Object -First 5 | ForEach-Object { 'KB{0} - {1} ({2}%)' -f $_.Article, $_.State, $_.Percent })) `
                    -Remediation 'Reset Windows Update components and force a fresh scan: mecmdoctor repair -Level Standard' `
                    -RepairIds @($script:MDRepairIds.UpdatesReset, $script:MDRepairIds.UpdatesRescan) -Severity 3

                # Held for rendering after the status lines, below.
                $stuckRows = $rows
            }
            else {
                $findings += New-MDFinding -Category 'Updates' -Title 'Stuck updates' -Status 'Pass' -Detail 'none'
            }
        }
    }

    # --- Windows Update datastore ------------------------------------------
    $sd = Join-Path $env:windir 'SoftwareDistribution'
    if (Test-Path -LiteralPath $sd) {
        $edb = Join-Path $sd 'DataStore\DataStore.edb'
        if (Test-Path -LiteralPath $edb) {
            $edbSize = (Get-Item -LiteralPath $edb).Length
            if ($edbSize -gt 1GB) {
                $findings += New-MDFinding -Category 'Updates' -Title 'Windows Update datastore' -Status 'Warn' `
                    -Detail ('DataStore.edb is {0}' -f (Format-MDBytes $edbSize)) `
                    -Evidence @('An oversized datastore makes every scan slow and is a common source of 0x8007000D / 0x80248007.') `
                    -Remediation 'Reset Windows Update components: mecmdoctor repair -Level Standard' `
                    -RepairIds @($script:MDRepairIds.UpdatesReset)
            }
            else {
                $findings += New-MDFinding -Category 'Updates' -Title 'Windows Update datastore' -Status 'Pass' `
                    -Detail ('DataStore.edb is {0}' -f (Format-MDBytes $edbSize))
            }
        }
        else {
            $findings += New-MDFinding -Category 'Updates' -Title 'Windows Update datastore' -Status 'Warn' `
                -Detail 'DataStore.edb missing' `
                -Evidence @('Windows rebuilds this on the next scan; if scans still fail, the reset is the fix.') `
                -RepairIds @($script:MDRepairIds.UpdatesReset)
        }
    }

    $findings | Write-MDFinding

    if ($stuckRows.Count -gt 0) {
        Write-MDLine ''
        Write-MDTable -Rows $stuckRows -Indent 9 -Columns @(
            @{ Header = 'KB';     Property = 'Article'; Width = 10 }
            @{ Header = 'UPDATE'; Property = 'Name';    Width = 48 }
            @{ Header = 'STATE';  Property = 'State';   Width = 18 }
            @{ Header = 'PCT';    Property = 'Percent'; Width = 4 }
        ) -RowColor { 'Yellow' }
    }

    $findings
}


function Test-MDRegistryPolContains {
<#
    .SYNOPSIS
        True when the machine Registry.pol contains the given key fragment.
    .DESCRIPTION
        Registry.pol stores key paths as UTF-16LE text, so a plain byte-level
        search for the UTF-16 encoding of the fragment is both fast and
        reliable - and much simpler than a full .pol parser.

        Used to tell "the MECM client set this value" apart from "a GPO is
        forcing this value", which look identical in the live registry.
#>
    param([Parameter(Mandatory)][string] $Pattern)

    $pol = Join-Path $env:windir 'System32\GroupPolicy\Machine\Registry.pol'
    if (-not (Test-Path -LiteralPath $pol)) { return $false }

    try {
        $bytes  = [System.IO.File]::ReadAllBytes($pol)
        $text   = [System.Text.Encoding]::Unicode.GetString($bytes)
        return ($text -match [regex]::Escape($Pattern))
    }
    catch {
        Write-MDDebug ("could not scan Registry.pol: {0}" -f $_.Exception.Message)
        return $false
    }
}


# ===========================================================================
#  9. CONTENT / CACHE / BITS
# ===========================================================================
function Test-MDContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()

    # --- cache configuration and real size ----------------------------------
    if ($ClientInfo.CacheLocation) {
        $findings += New-MDFinding -Category 'Content' -Title 'Cache location' -Status 'Pass' `
            -Detail ('{0} (configured limit {1} MB)' -f $ClientInfo.CacheLocation, $ClientInfo.CacheSizeMB)

        if (Test-Path -LiteralPath $ClientInfo.CacheLocation) {
            try {
                $onDisk = (Get-ChildItem -LiteralPath $ClientInfo.CacheLocation -Recurse -File -Force -ErrorAction SilentlyContinue |
                           Measure-Object -Property Length -Sum).Sum
                if (-not $onDisk) { $onDisk = 0 }

                $limitBytes = 0
                if ($ClientInfo.CacheSizeMB) { $limitBytes = [double]$ClientInfo.CacheSizeMB * 1MB }

                if ($limitBytes -gt 0 -and $onDisk -gt ($limitBytes * 1.25)) {
                    # More on disk than the client thinks it is allowed means
                    # orphaned content the cache manager has lost track of.
                    $findings += New-MDFinding -Category 'Content' -Title 'Cache size on disk' -Status 'Warn' `
                        -Detail ('{0} on disk against a {1} MB limit' -f (Format-MDBytes $onDisk), $ClientInfo.CacheSizeMB) `
                        -Evidence @('Excess almost always means orphaned cache folders the client no longer tracks.') `
                        -Remediation 'Clear the cache: mecmdoctor repair -Level Safe' `
                        -RepairIds @($script:MDRepairIds.CacheClear)
                }
                else {
                    $findings += New-MDFinding -Category 'Content' -Title 'Cache size on disk' -Status 'Pass' -Detail (Format-MDBytes $onDisk)
                }
            }
            catch {
                $findings += New-MDFinding -Category 'Content' -Title 'Cache size on disk' -Status 'Skip' `
                    -Detail ('could not measure - {0}' -f $_.Exception.Message)
            }
        }
        else {
            $findings += New-MDFinding -Category 'Content' -Title 'Cache directory' -Status 'Fail' `
                -Detail ('configured cache path does not exist: {0}' -f $ClientInfo.CacheLocation) `
                -Remediation 'Clear/recreate the cache: mecmdoctor repair -Level Safe' `
                -RepairIds @($script:MDRepairIds.CacheClear)
        }

        # Orphan detection: folders on disk with no matching CacheInfoEx record.
        $cacheInfo = Invoke-MDCimQuery -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx'
        if ($null -ne $cacheInfo -and (Test-Path -LiteralPath $ClientInfo.CacheLocation)) {
            $tracked = @($cacheInfo | ForEach-Object { ($_.Location -replace '\\+$', '').ToLowerInvariant() })
            $onDiskDirs = @(Get-ChildItem -LiteralPath $ClientInfo.CacheLocation -Directory -Force -ErrorAction SilentlyContinue)
            $orphans = @($onDiskDirs | Where-Object { $tracked -notcontains $_.FullName.ToLowerInvariant() })

            if ($orphans.Count -gt 5) {
                $orphanBytes = ($orphans | ForEach-Object {
                    (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
                } | Measure-Object -Sum).Sum

                $findings += New-MDFinding -Category 'Content' -Title 'Orphaned cache content' -Status 'Warn' `
                    -Detail ('{0} untracked folder(s) holding {1}' -f $orphans.Count, (Format-MDBytes $orphanBytes)) `
                    -Remediation 'Clear the cache to reclaim the space: mecmdoctor repair -Level Safe' `
                    -RepairIds @($script:MDRepairIds.CacheClear)
            }
            else {
                $findings += New-MDFinding -Category 'Content' -Title 'Orphaned cache content' -Status 'Pass' `
                    -Detail ('{0} tracked item(s), {1} untracked folder(s)' -f @($cacheInfo).Count, $orphans.Count)
            }
        }
    }
    else {
        $findings += New-MDFinding -Category 'Content' -Title 'Cache location' -Status 'Warn' `
            -Detail 'cache configuration could not be read' `
            -Remediation 'Usually a WMI problem. Repair WMI, then re-check.' `
            -RepairIds @($script:MDRepairIds.WmiSalvage)
    }

    # --- BITS jobs ----------------------------------------------------------
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)

        $bad   = @($jobs | Where-Object { $_.JobState -in @('Error', 'TransientError') })
        $stale = @($jobs | Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-3) -and $_.JobState -notin @('Transferred', 'Acknowledged') })

        if ($bad.Count -gt 0) {
            $findings += New-MDFinding -Category 'Content' -Title 'BITS jobs in error' -Status 'Fail' `
                -Detail ('{0} of {1} job(s) are in an error state' -f $bad.Count, $jobs.Count) `
                -Evidence (@($bad | Select-Object -First 5 | ForEach-Object {
                    '{0} [{1}] {2}' -f $_.DisplayName, $_.JobState, $_.ErrorDescription
                })) `
                -Remediation 'Clear the failed jobs and let the client recreate them: mecmdoctor repair -Level Safe' `
                -RepairIds @($script:MDRepairIds.BitsClear) -Severity 3
        }
        elseif ($stale.Count -gt 0) {
            $findings += New-MDFinding -Category 'Content' -Title 'BITS jobs stalled' -Status 'Warn' `
                -Detail ('{0} job(s) older than 3 days and still not transferred' -f $stale.Count) `
                -Evidence (@($stale | Select-Object -First 5 | ForEach-Object {
                    '{0} [{1}] created {2}' -f $_.DisplayName, $_.JobState, $_.CreationTime
                })) `
                -Remediation 'Clear the stalled jobs: mecmdoctor repair -Level Safe' `
                -RepairIds @($script:MDRepairIds.BitsClear)
        }
        else {
            $findings += New-MDFinding -Category 'Content' -Title 'BITS jobs' -Status 'Pass' `
                -Detail ('{0} job(s), none failed' -f $jobs.Count)
        }
    }
    catch {
        # -AllUsers needs elevation; without it this says "access denied" and
        # means nothing about the health of BITS.
        if (-not (Test-MDAdmin)) {
            $findings += New-MDFinding -Category 'Content' -Title 'BITS jobs' -Status 'Skip' `
                -Detail 'enumerating all users'' BITS jobs requires elevation' `
                -Evidence @('Re-run via mecmdoctor.bat to include this check.')
        }
        else {
            $findings += New-MDFinding -Category 'Content' -Title 'BITS jobs' -Status 'Warn' `
                -Detail ('could not enumerate BITS jobs - {0}' -f $_.Exception.Message) `
                -Remediation 'If BITS itself will not respond, restart the BITS service and re-check.' `
                -RepairIds @($script:MDRepairIds.ServicesFix) -Data @{ Service = 'BITS' }
        }
    }

    $findings | Write-MDFinding
    $findings
}


# ===========================================================================
# 10. PENDING REBOOT
# ===========================================================================
function Test-MDPendingReboot {
<#
    .SYNOPSIS
        Checks every place Windows and the client record a pending reboot.
    .DESCRIPTION
        Worth being exhaustive here: a single pending reboot silently blocks
        servicing, application enforcement and update installs, and it is the
        answer to a surprising share of "the client does nothing" tickets.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()
    $reasons  = @()

    # --- Component Based Servicing -----------------------------------------
    if (Test-MDRegKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'Component Based Servicing has a reboot pending (a Windows update is half-applied).'
    }
    if (Test-MDRegKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress') {
        $reasons += 'Component Based Servicing reports a reboot already in progress.'
    }
    if (Test-MDRegKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') {
        $reasons += 'Component Based Servicing has packages waiting to be applied at reboot.'
    }

    # --- Windows Update -----------------------------------------------------
    if (Test-MDRegKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'Windows Update requires a reboot.'
    }
    if (Test-MDRegKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting') {
        $reasons += 'Windows Update is waiting to report the result of a previous reboot.'
    }

    # --- pending file renames ----------------------------------------------
    $pfro = Get-MDRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
    if ($pfro -and @($pfro).Count -gt 0) {
        $reasons += ('{0} file rename operation(s) are queued for the next boot.' -f @($pfro).Count)
    }

    # --- pending computer rename -------------------------------------------
    $active  = Get-MDRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name 'ComputerName'
    $pending = Get-MDRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name 'ComputerName'
    if ($active -and $pending -and ($active -ne $pending)) {
        $reasons += ('A computer rename is pending: {0} -> {1}.' -f $active, $pending)
    }

    # --- pending domain join ------------------------------------------------
    if ((Get-MDRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'JoinDomain') -or
        (Get-MDRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'AvoidSpnSet')) {
        $reasons += 'A domain join or SPN update is pending.'
    }

    # --- the client own view ------------------------------------------------
    if ($ClientInfo.Installed) {
        $ccmReboot = Invoke-MDCimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' `
                                        -MethodName 'DetermineIfRebootPending'
        if ($ccmReboot) {
            if ($ccmReboot.RebootPending)     { $reasons += 'The Configuration Manager client reports a pending reboot.' }
            if ($ccmReboot.IsHardRebootPending) { $reasons += 'The client reports a HARD reboot pending (cannot be deferred).' }
            if ($ccmReboot.InGracePeriod)     { $reasons += 'The client is inside a reboot grace period.' }
        }
    }

    if ($reasons.Count -eq 0) {
        $findings += New-MDFinding -Category 'Reboot' -Title 'Pending reboot' -Status 'Pass' -Detail 'none detected'
    }
    else {
        # This is a Warn rather than a Fail: a pending reboot is a normal state,
        # it just needs acting on. It becomes the blocker only in context.
        $findings += New-MDFinding -Category 'Reboot' -Title 'Pending reboot' -Status 'Warn' `
            -Detail ('{0} indicator(s) found' -f $reasons.Count) `
            -Evidence $reasons `
            -Remediation 'Reboot the machine. Update installs and application enforcement will keep failing until you do. mecmdoctor never reboots by itself.' `
            -RepairIds @($script:MDRepairIds.Reboot) -Severity 2
    }

    $findings | Write-MDFinding
    $findings
}


# ===========================================================================
# 11. GROUP POLICY
# ===========================================================================
function Test-MDGroupPolicy {
<#
    .SYNOPSIS
        Detects Group Policy corruption, which quietly breaks everything that
        depends on policy - including the WSUS settings the client relies on.
    .DESCRIPTION
        The primary signal is Registry.pol integrity. A valid .pol file starts
        with the ASCII signature "PReg" followed by a little-endian version of
        1. A zero-byte or truncated file is the classic corruption seen after
        a disk-full event or an unclean shutdown, and it produces event 1096.
#>
    [CmdletBinding()]
    param()

    $findings = @()

    $polFiles = @(
        @{ Path = (Join-Path $env:windir 'System32\GroupPolicy\Machine\Registry.pol'); Scope = 'Machine' }
        @{ Path = (Join-Path $env:windir 'System32\GroupPolicy\User\Registry.pol');    Scope = 'User' }
    )

    # Per-user local GPOs (GroupPolicyUsers) are rarer but corrupt just as well.
    $gpUsersRoot = Join-Path $env:windir 'System32\GroupPolicyUsers'
    if (Test-Path -LiteralPath $gpUsersRoot) {
        foreach ($dir in (Get-ChildItem -LiteralPath $gpUsersRoot -Directory -ErrorAction SilentlyContinue)) {
            $polFiles += @{ Path = (Join-Path $dir.FullName 'User\Registry.pol'); Scope = ('LocalUser ' + $dir.Name) }
        }
    }

    $corrupt = @()

    foreach ($p in $polFiles) {
        if (-not (Test-Path -LiteralPath $p.Path)) {
            # Absent is normal - it just means no local policy of that scope.
            $findings += New-MDFinding -Category 'GroupPolicy' -Title ('Registry.pol (' + $p.Scope + ')') -Status 'Pass' `
                -Detail 'not present (no local policy of this scope)'
            continue
        }

        $file = Get-Item -LiteralPath $p.Path -Force
        $verdict = Test-MDRegistryPolIntegrity -Path $p.Path

        if ($verdict.Valid) {
            $findings += New-MDFinding -Category 'GroupPolicy' -Title ('Registry.pol (' + $p.Scope + ')') -Status 'Pass' `
                -Detail ('valid, {0}, modified {1}' -f (Format-MDBytes $file.Length), (Format-MDAge $file.LastWriteTime))
        }
        else {
            $corrupt += $p.Path
            $findings += New-MDFinding -Category 'GroupPolicy' -Title ('Registry.pol (' + $p.Scope + ')') -Status 'Fail' `
                -Detail $verdict.Reason `
                -Evidence @(
                    $p.Path
                    ('size {0}, modified {1}' -f (Format-MDBytes $file.Length), $file.LastWriteTime)
                    'A corrupt Registry.pol makes Group Policy processing fail with event 1096, so no policy applies at all.'
                ) `
                -Remediation 'Quarantine the file and force a policy refresh: mecmdoctor repair -Level Standard' `
                -RepairIds @($script:MDRepairIds.GpRepairPol) -Severity 4
        }
    }

    # --- gpt.ini ------------------------------------------------------------
    $gptIni = Join-Path $env:windir 'System32\GroupPolicy\gpt.ini'
    if (Test-Path -LiteralPath $gptIni) {
        $gptSize = (Get-Item -LiteralPath $gptIni).Length
        if ($gptSize -eq 0) {
            $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Local gpt.ini' -Status 'Warn' `
                -Detail 'zero bytes' `
                -Remediation 'Quarantine it along with Registry.pol and let Windows rebuild: mecmdoctor repair -Level Standard' `
                -RepairIds @($script:MDRepairIds.GpRepairPol)
        }
        else {
            $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Local gpt.ini' -Status 'Pass' -Detail (Format-MDBytes $gptSize)
        }
    }

    # --- security database --------------------------------------------------
    $sdb = Join-Path $env:windir 'security\database\secedit.sdb'
    if (Test-Path -LiteralPath $sdb) {
        $sdbFile = Get-Item -LiteralPath $sdb -Force
        if ($sdbFile.Length -eq 0) {
            $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Security database' -Status 'Fail' `
                -Detail 'secedit.sdb is zero bytes' `
                -Remediation 'Rebuild the security database: mecmdoctor repair -Level Aggressive' `
                -RepairIds @($script:MDRepairIds.GpResetSecEdit) -Severity 3
        }
        else {
            $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Security database' -Status 'Pass' `
                -Detail ('secedit.sdb {0}, modified {1}' -f (Format-MDBytes $sdbFile.Length), (Format-MDAge $sdbFile.LastWriteTime))
        }
    }
    else {
        $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Security database' -Status 'Warn' `
            -Detail 'secedit.sdb is missing' `
            -Remediation 'Rebuild the security database: mecmdoctor repair -Level Aggressive' `
            -RepairIds @($script:MDRepairIds.GpResetSecEdit)
    }

    # --- event log evidence -------------------------------------------------
    # These IDs are the ones that actually mean something:
    #   1096 - Registry.pol could not be read (the corruption signature)
    #   1058 - could not read gpt.ini from SYSVOL (network/DFS/permissions)
    #   1053 - could not resolve the user/computer name (DC connectivity)
    #   7016/7017 - a CSE reported a fatal processing error
    $gpEventIds = @(1096, 1058, 1053, 7016, 7017, 1085)
    try {
        $gpEvents = @(Get-WinEvent -FilterHashtable @{
                          LogName   = 'Microsoft-Windows-GroupPolicy/Operational'
                          Id        = $gpEventIds
                          StartTime = (Get-Date).AddDays(-14)
                      } -MaxEvents 50 -ErrorAction Stop)

        if ($gpEvents.Count -gt 0) {
            $byId = $gpEvents | Group-Object Id | Sort-Object Count -Descending
            $has1096 = $gpEvents | Where-Object { $_.Id -eq 1096 } | Select-Object -First 1

            $status = if ($has1096) { 'Fail' } else { 'Warn' }
            $repair = if ($has1096) { @($script:MDRepairIds.GpRepairPol) } else { @() }

            $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Group Policy errors (14 days)' -Status $status `
                -Detail ('{0} event(s)' -f $gpEvents.Count) `
                -Evidence (@($byId | ForEach-Object { 'event {0} x{1}' -f $_.Name, $_.Count }) +
                           @(if ($has1096) { 'Event 1096 confirms Registry.pol could not be read - this is textbook local policy corruption.' })) `
                -Remediation $(if ($has1096) {
                    'Quarantine the corrupt Registry.pol and refresh policy: mecmdoctor repair -Level Standard'
                } else {
                    'Events 1058/1053 point at SYSVOL or DC connectivity rather than local corruption. Check DNS and access to \\<domain>\SYSVOL.'
                }) `
                -RepairIds $repair -Severity $(if ($has1096) { 4 } else { 2 })
        }
        else {
            $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Group Policy errors (14 days)' -Status 'Pass' -Detail 'none'
        }
    }
    catch {
        $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Group Policy errors (14 days)' -Status 'Skip' `
            -Detail 'GroupPolicy/Operational log unavailable'
    }

    # --- last successful processing ----------------------------------------
    try {
        $ok = Get-WinEvent -FilterHashtable @{
                  LogName = 'Microsoft-Windows-GroupPolicy/Operational'
                  Id      = 8004    # machine policy processing succeeded
              } -MaxEvents 1 -ErrorAction Stop

        if ($ok) {
            $age    = (Get-Date) - $ok.TimeCreated
            $status = if ($age.TotalDays -gt 7) { 'Warn' } else { 'Pass' }
            $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Last successful machine policy' -Status $status `
                -Detail (Format-MDAge $ok.TimeCreated) `
                -Remediation $(if ($status -eq 'Warn') { 'Run gpupdate /force, or let mecmdoctor repair -Level Safe do it, then confirm the machine can reach a domain controller.' } else { '' })
        }
    }
    catch {
        $findings += New-MDFinding -Category 'GroupPolicy' -Title 'Last successful machine policy' -Status 'Skip' `
            -Detail 'no processing events available'
    }

    $findings | Write-MDFinding
    $findings
}


function Test-MDRegistryPolIntegrity {
<#
    .SYNOPSIS
        Validates the binary header of a Registry.pol file.
    .OUTPUTS
        [pscustomobject] Valid / Reason
#>
    param([Parameter(Mandatory)][string] $Path)

    try {
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop

        if ($file.Length -eq 0) {
            return [pscustomobject]@{ Valid = $false; Reason = 'file is zero bytes (corrupt)' }
        }
        if ($file.Length -lt 8) {
            return [pscustomobject]@{ Valid = $false; Reason = ('file is only {0} bytes - too short to contain a valid header' -f $file.Length) }
        }

        $header = New-Object byte[] 8
        $fs = [System.IO.File]::OpenRead($Path)
        try { [void]$fs.Read($header, 0, 8) } finally { $fs.Dispose() }

        # "PReg" = 0x50 0x52 0x65 0x67, then a UInt32 version of 1.
        $signature = [System.Text.Encoding]::ASCII.GetString($header, 0, 4)
        $version   = [BitConverter]::ToUInt32($header, 4)

        if ($signature -ne 'PReg') {
            return [pscustomobject]@{ Valid = $false; Reason = ("signature is '{0}', expected 'PReg' (corrupt)" -f $signature) }
        }
        if ($version -ne 1) {
            return [pscustomobject]@{ Valid = $false; Reason = ('version is {0}, expected 1 (corrupt)' -f $version) }
        }

        return [pscustomobject]@{ Valid = $true; Reason = 'header is valid' }
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Reason = ('could not be read: {0}' -f $_.Exception.Message) }
    }
}


# ===========================================================================
# 12. CLIENT HEALTH (CcmEval)
# ===========================================================================
function Test-MDClientHealth {
<#
    .SYNOPSIS
        Reads Microsoft's own client health evaluation report.
    .DESCRIPTION
        CcmEval runs daily as a scheduled task and writes CcmEvalReport.xml.
        Surfacing its failed checks is free signal - it already knows things
        we would otherwise have to re-derive.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()

    if (-not $ClientInfo.Installed) {
        $findings += New-MDFinding -Category 'Health' -Title 'CcmEval report' -Status 'Skip' -Detail 'client not installed'
        $findings | Write-MDFinding
        return $findings
    }

    $reportPath = Join-Path $ClientInfo.InstallPath 'CcmEvalReport.xml'
    if (-not (Test-Path -LiteralPath $reportPath)) {
        $findings += New-MDFinding -Category 'Health' -Title 'CcmEval report' -Status 'Warn' `
            -Detail 'CcmEvalReport.xml not found - client health evaluation has never completed' `
            -Remediation 'Run the evaluation: mecmdoctor repair -Level Safe (runs ccmeval.exe), or check the Configuration Manager Health Evaluation scheduled task.' `
            -RepairIds @($script:MDRepairIds.CcmEvalRun)
        $findings | Write-MDFinding
        return $findings
    }

    $file = Get-Item -LiteralPath $reportPath
    try {
        [xml]$xml = Get-Content -LiteralPath $reportPath -Raw -ErrorAction Stop
    }
    catch {
        $findings += New-MDFinding -Category 'Health' -Title 'CcmEval report' -Status 'Warn' `
            -Detail ('CcmEvalReport.xml could not be parsed: {0}' -f $_.Exception.Message)
        $findings | Write-MDFinding
        return $findings
    }

    # The schema has moved around between client versions, so select on the
    # attributes we need rather than on a fixed element path.
    $checks = @($xml.SelectNodes('//*[@Description]'))
    if ($checks.Count -eq 0) { $checks = @($xml.SelectNodes('//HealthCheck')) }

    $failed = @()
    foreach ($c in $checks) {
        $result = "$($c.Result)"
        if (-not $result) { $result = "$($c.ResultCode)" }
        if (-not $result) { $result = "$($c.ResultType)" }

        # "Pass"/"0"/"NotApplicable" are all fine; anything else is a failure.
        if ($result -and $result -notmatch '(?i)^(pass|0|notapplicable|not applicable|skipped)$') {
            $failed += [pscustomobject]@{
                Check  = "$($c.Description)"
                Result = $result
                Detail = "$($c.ResultDetail)"
            }
        }
    }

    $age = Format-MDAge $file.LastWriteTime

    if ($failed.Count -eq 0) {
        $findings += New-MDFinding -Category 'Health' -Title 'CcmEval report' -Status 'Pass' `
            -Detail ('{0} check(s) evaluated, none failed (report written {1})' -f $checks.Count, $age)
    }
    else {
        $findings += New-MDFinding -Category 'Health' -Title 'CcmEval report' -Status 'Fail' `
            -Detail ('{0} of {1} health check(s) failed (report written {2})' -f $failed.Count, $checks.Count, $age) `
            -Evidence (@($failed | Select-Object -First 8 | ForEach-Object { '{0} -> {1}' -f $_.Check, $_.Result })) `
            -Remediation 'Microsoft''s own evaluation is already telling you what is broken. Run: mecmdoctor repair -Level Standard, then re-run ccmeval.' `
            -RepairIds @($script:MDRepairIds.ClientRepair, $script:MDRepairIds.CcmEvalRun) -Severity 3
    }

    if ($file.LastWriteTime -lt (Get-Date).AddDays(-7)) {
        $findings += New-MDFinding -Category 'Health' -Title 'CcmEval freshness' -Status 'Warn' `
            -Detail ('the health report is {0}' -f $age) `
            -Evidence @('CcmEval is supposed to run daily. A stale report means its scheduled task is not running.') `
            -Remediation 'Check the "Configuration Manager Health Evaluation" scheduled task, and that the Task Scheduler service is running.' `
            -RepairIds @($script:MDRepairIds.CcmEvalRun)
    }

    $findings | Write-MDFinding
    $findings
}


# ===========================================================================
# 13. DISK AND TIME
# ===========================================================================
function Test-MDSystemHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ClientInfo)

    $findings = @()

    # --- free disk space ----------------------------------------------------
    # The client needs headroom for the cache, the WU datastore and servicing.
    $drives = @($env:SystemDrive)
    if ($ClientInfo.CacheLocation) {
        $cacheDrive = [System.IO.Path]::GetPathRoot($ClientInfo.CacheLocation).TrimEnd('\')
        if ($cacheDrive -and $drives -notcontains $cacheDrive) { $drives += $cacheDrive }
    }

    foreach ($d in $drives) {
        try {
            $vol = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $d) -ErrorAction Stop
            if (-not $vol) { continue }

            $freePct = 0
            if ($vol.Size -gt 0) { $freePct = ($vol.FreeSpace / $vol.Size) * 100 }

            $detail = '{0} free of {1} ({2:N1}%)' -f (Format-MDBytes $vol.FreeSpace), (Format-MDBytes $vol.Size), $freePct

            if ($vol.FreeSpace -lt 2GB -or $freePct -lt 5) {
                $findings += New-MDFinding -Category 'System' -Title ("Free space on $d") -Status 'Fail' `
                    -Detail $detail `
                    -Evidence @('Below this, content downloads, update installs and servicing all fail in confusing ways.') `
                    -Remediation 'Free space before doing anything else. Clearing the CCM cache (mecmdoctor repair -Level Safe) is usually the quickest win.' `
                    -RepairIds @($script:MDRepairIds.CacheClear, $script:MDRepairIds.DiskSpace) -Severity 4
            }
            elseif ($vol.FreeSpace -lt 10GB -or $freePct -lt 10) {
                $findings += New-MDFinding -Category 'System' -Title ("Free space on $d") -Status 'Warn' `
                    -Detail $detail `
                    -Remediation 'Consider clearing the CCM cache to buy headroom.' `
                    -RepairIds @($script:MDRepairIds.CacheClear)
            }
            else {
                $findings += New-MDFinding -Category 'System' -Title ("Free space on $d") -Status 'Pass' -Detail $detail
            }
        }
        catch {
            $findings += New-MDFinding -Category 'System' -Title ("Free space on $d") -Status 'Skip' `
                -Detail ('could not query - {0}' -f $_.Exception.Message)
        }
    }

    # --- time synchronisation -----------------------------------------------
    # Clock skew breaks Kerberos and certificate validation, which then shows
    # up as a certificate error three layers away from the real cause.
    try {
        $w32 = Invoke-MDProcess -FilePath (Join-Path $env:windir 'System32\w32tm.exe') `
                                -ArgumentList @('/query', '/status') -TimeoutSeconds 30
        if ($w32.ExitCode -eq 0) {
            $source   = ''
            $lastSync = ''
            if ($w32.StdOut -match '(?im)^\s*Source:\s*(.+)$')            { $source   = $Matches[1].Trim() }
            if ($w32.StdOut -match '(?im)^\s*Last Successful Sync Time:\s*(.+)$') { $lastSync = $Matches[1].Trim() }

            $isDomainMember = $false
            try { $isDomainMember = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { }

            if ($isDomainMember -and $source -match '(?i)Local CMOS Clock|Free-running') {
                $findings += New-MDFinding -Category 'System' -Title 'Time synchronisation' -Status 'Warn' `
                    -Detail ('domain member syncing from "{0}"' -f $source) `
                    -Evidence @("Last successful sync: $lastSync",
                                'Clock skew beyond five minutes breaks Kerberos and makes valid certificates look expired.') `
                    -Remediation 'Run: w32tm /config /syncfromflags:domhier /update  then  w32tm /resync'
            }
            else {
                $findings += New-MDFinding -Category 'System' -Title 'Time synchronisation' -Status 'Pass' `
                    -Detail ('source {0}, last sync {1}' -f $source, $lastSync)
            }
        }
        else {
            # w32tm exits non-zero when the Windows Time service is stopped,
            # which is normal on a workgroup machine - keep the reason visible.
            $findings += New-MDFinding -Category 'System' -Title 'Time synchronisation' -Status 'Skip' `
                -Detail ('w32tm /query /status exited with {0}' -f $w32.ExitCode) `
                -Evidence @((($w32.StdOut + ' ' + $w32.StdErr)).Trim())
        }
    }
    catch {
        $findings += New-MDFinding -Category 'System' -Title 'Time synchronisation' -Status 'Skip' -Detail $_.Exception.Message
    }

    $findings | Write-MDFinding
    $findings
}
