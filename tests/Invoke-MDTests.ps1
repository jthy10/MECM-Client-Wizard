#Requires -Version 5.1
<#
    ===========================================================================
     MECM Client Wizard  --  tests\Invoke-MDTests.ps1
    ---------------------------------------------------------------------------
     Self-contained test run. No Pester, no modules to install - the whole
     point of this tool is that it works on an endpoint exactly as shipped,
     and its tests should not need anything the tool itself does not.

       powershell -ExecutionPolicy Bypass -File .\tests\Invoke-MDTests.ps1

     Everything here is read-only. Nothing starts, stops or reconfigures a
     service, touches WMI beyond querying it, or writes outside %TEMP%.

     Exit code 0 when every test passes, 1 otherwise.
    ===========================================================================
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($file in @('Console.ps1', 'Common.ps1', 'ErrorCatalog.ps1', 'LogParser.ps1',
                    'Checks.ps1', 'Repairs.ps1', 'Report.ps1', 'Bundle.ps1', 'Menu.ps1')) {
    . (Join-Path $root ('lib\' + $file))
}

# The library expects an initialised console. No log directory, so nothing is
# written to disk during a test run.
Initialize-MDConsole -NoColor -Tag 'tests'

$script:Passed = 0
$script:Failed = 0
$script:Names  = @()

function Test-Case {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][scriptblock] $Body
    )

    try {
        # Checks print as they run; the tests care about what they return.
        & $Body 6>$null
        $script:Passed++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    }
    catch {
        $script:Failed++
        $script:Names += $Name
        Write-Host ('  FAIL  ' + $Name) -ForegroundColor Red
        Write-Host ('        ' + $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Message = 'expected true')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message = '')
    if ("$Expected" -ne "$Actual") {
        throw ('{0}expected "{1}", got "{2}"' -f $(if ($Message) { $Message + ': ' } else { '' }), $Expected, $Actual)
    }
}

function New-TestFinding {
    <# A finding with just the fields the planner and repairs read. #>
    param(
        [string] $Category = 'Test',
        [string] $Title    = 'test',
        [string] $Status   = 'Fail',
        [string] $Detail   = '',
        [string[]] $RepairIds = @(),
        $Data = $null
    )
    New-MDFinding -Category $Category -Title $Title -Status $Status -Detail $Detail -RepairIds $RepairIds -Data $Data
}

function New-TestServiceFinding {
    <# What Test-MDServices produces for a disabled conditional service. #>
    param([string] $Service, [string] $Display, [string] $Class = 'Conditional')
    New-MDFinding -Category 'Services' -Title $Display -Status 'Warn' `
        -Detail 'start mode is Disabled - not repaired unless it is causing a failure' `
        -Data @{ Service = $Service; Class = $Class; Present = $true; State = 'Stopped'; StartMode = 'Disabled'; Problems = @('start mode is Disabled') }
}

Write-Host ''
Write-Host '  MECM Client Wizard - test run' -ForegroundColor Cyan
Write-Host ('  {0}' -f $root) -ForegroundColor DarkGray
Write-Host ''


# ===========================================================================
#  1. Client re-registration / GUID reset is gone and cannot be reached
# ===========================================================================
Write-Host '  Re-registration removal' -ForegroundColor White

Test-Case 'no re-registration repair id exists' {
    Assert-True (-not $script:MDRepairIds.ContainsKey('Reregister')) 'MDRepairIds still defines Reregister'
    Assert-True (($script:MDRepairIds.Values -notcontains 'client.reregister')) 'client.reregister is still a repair id'
}

Test-Case 'no catalogue entry can run a re-registration' {
    $ids = @($script:MDRepairCatalog | ForEach-Object { $_.Id })
    Assert-True ($ids -notcontains 'client.reregister') 'the repair catalogue still contains client.reregister'
    Assert-True (-not (Get-Command -Name 'Repair-MDReregister' -ErrorAction SilentlyContinue)) 'Repair-MDReregister is still defined'
}

Test-Case 'no repair path deletes SMSCFG.INI or the SMS certificate store' {
    # The identity reset is defined by these two operations, so the test is on
    # the operations rather than on any one function name.
    $repairs = Get-Content -LiteralPath (Join-Path $root 'lib\Repairs.ps1') -Raw
    Assert-True ($repairs -notmatch 'Remove-Item[^\r\n]*SMSCFG') 'Repairs.ps1 still removes SMSCFG.INI'
    Assert-True ($repairs -notmatch "Remove-Item[^\r\n]*Cert:\\LocalMachine\\SMS") 'Repairs.ps1 still removes SMS certificates'
}

Test-Case 'an unknown -Only id cannot resurrect it' {
    $plan = @(Get-MDRepairPlan -Level 'Aggressive' -Only @('client.reregister'))
    Assert-Equal 0 $plan.Count 'client.reregister still resolves to a plan entry'
}


# ===========================================================================
#  2. Diagnosis -> repair flow
# ===========================================================================
Write-Host ''
Write-Host '  Diagnosis to repair flow' -ForegroundColor White

Test-Case 'the summary recommends the lowest tier that covers the findings' {
    $safe = @(New-TestFinding -RepairIds @($script:MDRepairIds.CcmRestart))
    $r = Write-MDSummary -Findings $safe 6>$null
    Assert-Equal 'Safe' $r.Recommended 'a Safe-only finding set'

    $std = @(
        (New-TestFinding -RepairIds @($script:MDRepairIds.CcmRestart))
        (New-TestFinding -RepairIds @($script:MDRepairIds.WmiSalvage))
    )
    $r = Write-MDSummary -Findings $std 6>$null
    Assert-Equal 'Standard' $r.Recommended 'a Safe + Standard finding set'
}

Test-Case 'a healthy diagnosis recommends nothing' {
    $clean = @(New-MDFinding -Category 'Test' -Title 'fine' -Status 'Pass')
    $r = Write-MDSummary -Findings $clean 6>$null
    Assert-True ($null -eq $r.Recommended) 'a clean diagnosis produced a repair recommendation'
    Assert-Equal 0 $r.Issues 'issue count on a clean diagnosis'
}

Test-Case 'each tier still includes the tiers below it' {
    Assert-Equal 'Safe'                     ($script:MDLevelIncludes['Safe']       -join ',')
    Assert-Equal 'Safe,Standard'            ($script:MDLevelIncludes['Standard']   -join ',')
    Assert-Equal 'Safe,Standard,Aggressive' ($script:MDLevelIncludes['Aggressive'] -join ',')
}

Test-Case 'a Safe plan never contains a Standard or Aggressive action' {
    $findings = @(New-TestFinding -RepairIds @($script:MDRepairIds.WmiSalvage, $script:MDRepairIds.CcmRestart))
    $plan = @(Get-MDRepairPlan -Level 'Safe' -Findings $findings)
    Assert-Equal 1 $plan.Count 'only the Safe action should survive the tier filter'
    Assert-Equal $script:MDRepairIds.CcmRestart $plan[0].Id
}

Test-Case 'only implicated actions are planned' {
    $findings = @(New-TestFinding -RepairIds @($script:MDRepairIds.CacheClear))
    $plan = @(Get-MDRepairPlan -Level 'Standard' -Findings $findings)
    Assert-Equal 1 $plan.Count
    Assert-Equal $script:MDRepairIds.CacheClear $plan[0].Id
}

Test-Case 'Pass and Info findings never implicate a repair' {
    $findings = @(
        New-TestFinding -Status 'Pass' -RepairIds @($script:MDRepairIds.CacheClear)
        New-TestFinding -Status 'Info' -RepairIds @($script:MDRepairIds.WmiSalvage)
    )
    $plan = @(Get-MDRepairPlan -Level 'Aggressive' -Findings $findings)
    Assert-Equal 0 $plan.Count 'a healthy finding put an action in the plan'
}


# ===========================================================================
#  3. Dual scan / update source detection
# ===========================================================================
Write-Host ''
Write-Host '  Update source detection' -ForegroundColor White

function New-TestUpdateConfig {
    param(
        [int] $Build = 26100,
        $DisableDualScan = $null,
        [string[]] $Wufb = @(),
        $ScanSource = @(),
        $WUServer = $null,
        [bool] $GpoManagesWu = $false
    )
    [pscustomobject]@{
        Release              = [pscustomobject]@{
            Build = $Build; BuildFull = "$Build"; Caption = 'Windows'; Name = 'Windows'
            DisplayVersion = ''; IsServer = $false; IsWindows11 = ($Build -ge 22000)
            Text = ('Windows (build {0})' -f $Build)
        }
        UsesScanSourcePolicy = ($Build -ge $script:MDScanSourceMinBuild)
        WUServer             = $WUServer
        WUStatusServer       = $null
        UseWUServer          = $null
        NoAutoUpdate         = $null
        DisableDualScan      = $DisableDualScan
        ScanSource           = @($ScanSource)
        WufbPolicies         = @($Wufb)
        WufbConfigured       = (@($Wufb).Count -gt 0)
        GpoManagesWu         = $GpoManagesWu
    }
}

Test-Case 'Windows 11 with no DisableDualScan is not a failure' {
    $f = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 26100) 6>$null)
    $scan = $f | Where-Object { $_.Title -eq 'Update scan source' }
    Assert-True ($null -ne $scan) 'no scan source finding was produced'
    Assert-Equal 'Pass' $scan.Status 'Windows 11 with no policy at all'
    Assert-True (@($f | Where-Object { $_.Title -eq 'Dual scan' }).Count -eq 0) 'the legacy dual scan check ran on a modern build'
}

Test-Case 'Windows 11 reports the update source it detected' {
    $f = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 26100) 6>$null)
    $cfgFinding = $f | Where-Object { $_.Title -eq 'Update source configuration' }
    Assert-True ($null -ne $cfgFinding) 'no update source configuration finding'
    $evidence = (@($cfgFinding.Evidence) -join "`n")
    Assert-True ($evidence -match 'scan source policy') 'the policy model was not reported'
    Assert-True ($evidence -match 'DisableDualScan')    'DisableDualScan was not reported'
    Assert-True ($evidence -match 'deferral policies')  'the deferral policy state was not reported'
}

Test-Case 'a modern build sending updates to Windows Update is a failure' {
    $divert = @(
        [pscustomobject]@{ Name = 'SetPolicyDrivenUpdateSourceForQualityUpdates'; What = 'quality updates'; Value = 0; Source = 'Windows Update' }
        [pscustomobject]@{ Name = 'SetPolicyDrivenUpdateSourceForFeatureUpdates'; What = 'feature updates'; Value = 1; Source = 'WSUS / Configuration Manager' }
    )
    $f = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 26100 -ScanSource $divert) 6>$null)
    $scan = $f | Where-Object { $_.Title -eq 'Update scan source' }
    Assert-Equal 'Fail' $scan.Status 'a class pointed at Windows Update'
}

Test-Case 'a modern build with every class on WSUS passes' {
    $ok = @([pscustomobject]@{ Name = 'SetPolicyDrivenUpdateSourceForQualityUpdates'; What = 'quality updates'; Value = 1; Source = 'WSUS / Configuration Manager' })
    $f = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 26100 -ScanSource $ok) 6>$null)
    $scan = $f | Where-Object { $_.Title -eq 'Update scan source' }
    Assert-Equal 'Pass' $scan.Status
}

Test-Case 'deferral policies with no scan source policy warn on a modern build' {
    $f = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 26100 -Wufb @('DeferQualityUpdates = 1')) 6>$null)
    $scan = $f | Where-Object { $_.Title -eq 'Update scan source' }
    Assert-Equal 'Warn' $scan.Status
}

Test-Case 'DisableDualScan still applies on pre-1903 builds' {
    # Windows 10 1809 / Server 2019 with deferral policies and no DisableDualScan.
    $f = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 17763 -Wufb @('DeferQualityUpdates = 1')) 6>$null)
    $dual = $f | Where-Object { $_.Title -eq 'Dual scan' }
    Assert-True ($null -ne $dual) 'the legacy dual scan check did not run on a pre-1903 build'
    Assert-Equal 'Warn' $dual.Status

    $set = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 17763 -Wufb @('DeferQualityUpdates = 1') -DisableDualScan 1) 6>$null)
    Assert-Equal 'Pass' ($set | Where-Object { $_.Title -eq 'Dual scan' }).Status 'DisableDualScan = 1'
}

Test-Case 'a pre-1903 build with no deferral policies cannot dual scan' {
    $f = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 17763) 6>$null)
    $dual = $f | Where-Object { $_.Title -eq 'Dual scan' }
    Assert-Equal 'Pass' $dual.Status 'no deferral policies means nothing to disable'
}

Test-Case 'a WSUS GPO on a ConfigMgr client is still caught' {
    $f = @(Test-MDUpdateSource -Config (New-TestUpdateConfig -Build 26100 -WUServer 'http://wsus.contoso.com:8530' -GpoManagesWu $true) 6>$null)
    $conflict = $f | Where-Object { $_.Title -eq 'WSUS Group Policy conflict' }
    Assert-Equal 'Fail' $conflict.Status
}

Test-Case 'this machine is judged against its real build' {
    $cfg = Get-MDUpdateSourceConfig
    Assert-True ($cfg.Release.Build -gt 0) 'no Windows build could be determined'
    Assert-Equal ($cfg.Release.Build -ge 18362) $cfg.UsesScanSourcePolicy 'policy model does not match the build'
}


# ===========================================================================
#  4. WMI reset safety
# ===========================================================================
Write-Host ''
Write-Host '  WMI reset safety' -ForegroundColor White

Test-Case 'a large repository alone never plans a reset' {
    # Exactly what Test-MDWmiHealth emits for an oversized but healthy repository.
    $size = New-MDFinding -Category 'WMI' -Title 'Repository size' -Status 'Warn' `
        -Detail '1.40 GB - unusually large, but no corruption was detected. No repair recommended.'
    Assert-Equal 0 @($size.RepairIds).Count 'the repository size finding carries a repair id'

    $plan = @(Get-MDRepairPlan -Level 'Aggressive' -Findings @($size))
    Assert-Equal 0 $plan.Count 'an oversized repository produced a repair plan'
}

Test-Case '-All never selects the reset' {
    $plan = @(Get-MDRepairPlan -Level 'Aggressive' -All)
    $ids  = @($plan | ForEach-Object { $_.Id })
    Assert-True ($ids -notcontains $script:MDRepairIds.WmiReset) '-All -Level Aggressive included wmi.reset'
    Assert-True ($ids -contains $script:MDRepairIds.GpResetState) '-All should still include the other Aggressive actions'
}

Test-Case 'confirmed corruption is what puts the reset in a plan' {
    $confirmed = New-TestFinding -Category 'WMI' -Title 'WMI corruption assessment' `
        -RepairIds @($script:MDRepairIds.WmiSalvage, $script:MDRepairIds.WmiReset)
    $plan = @(Get-MDRepairPlan -Level 'Aggressive' -Findings @($confirmed) | ForEach-Object { $_.Id })
    Assert-True ($plan -contains $script:MDRepairIds.WmiReset) 'confirmed corruption did not plan the reset'
    Assert-True ($plan -contains $script:MDRepairIds.WmiSalvage) 'salvage should be planned alongside it'
    Assert-True ($plan[0] -eq $script:MDRepairIds.WmiSalvage) 'salvage must be ordered before the reset'
}

Test-Case 'a consistent repository refuses the reset even when asked directly' {
    # This machine is healthy, so the pre-flight verify is the thing under test.
    # A non-elevated run cannot verify at all, which must also refuse.
    $ctx = New-MDRepairContext -ClientInfo (Get-MDClientInfo) -Level 'Aggressive' -Force
    $r   = Repair-MDWmiReset -Context $ctx 6>$null
    Assert-True ($r.Status -in @('NotNeeded', 'Skipped')) ('expected the reset to decline, got ' + $r.Status)
    Assert-True ($r.Status -ne 'Success') 'the reset ran on a consistent repository'
}

Test-Case 'evidence lines survive a single-element result set' {
    # A machine whose WMI errors all share one result code used to collapse the
    # provider-error evidence into one concatenated line, because an unwrapped
    # foreach yields a scalar and + on a string concatenates.
    # The appended sentence is only ever a line of its own, so wherever it
    # appears it has to start the line. Anything else means it was glued to
    # the tail of the previous entry.
    $sentinel = 'Windows logs a WMI'
    $findings = @(Test-MDWmiHealth -ClientInfo (Get-MDClientInfo) 6>$null)
    foreach ($f in $findings) {
        foreach ($line in @($f.Evidence)) {
            if ($line -match [regex]::Escape($sentinel)) {
                Assert-True ($line.StartsWith($sentinel)) ('evidence lines were concatenated: ' + $line)
            }
        }
    }

    # The same shape, exercised directly: one line in, one line appended, two out.
    $one = @(foreach ($x in @('single')) { $x })
    $two = $one + 'appended'
    Assert-Equal 2 @($two).Count 'a one-element collection did not survive being appended to'
}

Test-Case 'the live WMI check attaches no reset to the size finding' {
    $findings = @(Test-MDWmiHealth -ClientInfo (Get-MDClientInfo) 6>$null)
    foreach ($f in ($findings | Where-Object { $_.Title -eq 'Repository size' })) {
        Assert-Equal 0 @($f.RepairIds).Count 'a live repository size finding carried a repair id'
    }
    Assert-True (@($findings | Where-Object { $_.Title -eq 'WMI corruption assessment' }).Count -eq 1) 'no corruption assessment was produced'
}


# ===========================================================================
#  5. Targeted service repairs
# ===========================================================================
Write-Host ''
Write-Host '  Targeted service repairs' -ForegroundColor White

Test-Case 'the service table separates core from conditional' {
    $core = @($script:MDRequiredServices | Where-Object { $_.Class -eq 'Core' } | ForEach-Object { $_.Name })
    $cond = @($script:MDRequiredServices | Where-Object { $_.Class -eq 'Conditional' } | ForEach-Object { $_.Name })

    Assert-True ($core -contains 'CcmExec')  'CcmExec must be a core dependency'
    Assert-True ($core -contains 'Winmgmt')  'Winmgmt must be a core dependency'
    foreach ($n in @('W32Time', 'TrustedInstaller', 'msiserver', 'wuauserv', 'BITS')) {
        Assert-True ($cond -contains $n) ("{0} must be conditional" -f $n)
    }
}

Test-Case 'only the implicated service is extracted from the findings' {
    $findings = @(
        New-MDFinding -Category 'Services' -Title 'Background Intelligent Transfer' -Status 'Fail' `
            -RepairIds @($script:MDRepairIds.ServicesFix) -Data @{ Service = 'BITS'; Class = 'Conditional' }
        New-MDFinding -Category 'Services' -Title 'Windows Time' -Status 'Info' `
            -RepairIds @() -Data @{ Service = 'W32Time'; Class = 'Conditional' }
        New-MDFinding -Category 'Content' -Title 'Cache' -Status 'Fail' -RepairIds @($script:MDRepairIds.CacheClear)
    )
    $names = @(Get-MDImplicatedServiceNames -Findings $findings)
    Assert-Equal 1 $names.Count 'more than one service was extracted'
    Assert-Equal 'BITS' $names[0]
}

Test-Case 'one bad service resolves to exactly one repair target' {
    $targets = @(Get-MDServiceRepairTargets -Names @('BITS') | ForEach-Object { $_.Name })
    Assert-Equal 'BITS' ($targets -join ',') 'the repair scope leaked to other services'
}

Test-Case 'with no diagnosis the fallback is core services only' {
    $targets = @(Get-MDServiceRepairTargets -Names @() | ForEach-Object { $_.Name })
    foreach ($n in @('W32Time', 'TrustedInstaller', 'msiserver', 'wuauserv', 'BITS')) {
        Assert-True ($targets -notcontains $n) ("{0} must not be touched without a finding naming it" -f $n)
    }
    Assert-True ($targets -contains 'CcmExec') 'core services should still be covered'
}

Test-Case 'the repair context carries the implicated service through' {
    $findings = @(New-MDFinding -Category 'Services' -Title 'Windows Installer' -Status 'Fail' `
                    -RepairIds @($script:MDRepairIds.ServicesFix) -Data @{ Service = 'msiserver'; Class = 'Conditional' })
    $ctx = New-MDRepairContext -ClientInfo (Get-MDClientInfo) -Level 'Safe' -Findings $findings -DryRun
    Assert-Equal 'msiserver' (@($ctx.TargetServices) -join ',') 'the context did not carry the implicated service'
}

Test-Case 'the repair touches only the implicated service' {
    $ctx = New-MDRepairContext -ClientInfo (Get-MDClientInfo) -Level 'Safe' -DryRun
    $ctx.TargetServices = @('BITS')
    $r = Repair-MDServices -Context $ctx 6>$null

    $text = ((@($r.Evidence) + $r.Detail) -join ' ')
    foreach ($n in @('W32Time', 'TrustedInstaller', 'msiserver', 'wuauserv', 'CcmExec', 'Winmgmt')) {
        Assert-True ($text -notmatch ('\b' + $n + '\b')) ("the BITS repair mentioned {0}" -f $n)
    }
}

Test-Case 'a conditional service with no correlated failure is information only' {
    $findings = @(
        (New-TestServiceFinding -Service 'msiserver' -Display 'Windows Installer')
        (New-MDFinding -Category 'Updates' -Title 'Stuck updates' -Status 'Fail' -Detail 'unrelated to MSI')
    )
    $out = @(Resolve-MDServiceCorrelation -Findings $findings 6>$null)
    $svc = $out | Where-Object { $_.Category -eq 'Services' }

    Assert-Equal 'Info' $svc.Status 'a disabled msiserver with no MSI failure should not be a fault'
    Assert-Equal 0 @($svc.RepairIds).Count 'no repair should be proposed'
    Assert-Equal 0 @(Get-MDRepairPlan -Level 'Safe' -Findings $out).Count 'it still produced a repair plan'
}

Test-Case 'a conditional service with a correlated failure becomes repairable' {
    $findings = @(
        (New-TestServiceFinding -Service 'msiserver' -Display 'Windows Installer')
        (New-MDFinding -Category 'Logs' -Title 'Software logs' -Status 'Fail' -Detail '3 distinct error(s)')
    )
    $out = @(Resolve-MDServiceCorrelation -Findings $findings 6>$null)
    $svc = $out | Where-Object { $_.Category -eq 'Services' }

    Assert-Equal 'Fail' $svc.Status 'a disabled msiserver with an MSI deployment failure should be repairable'
    Assert-True (@($svc.RepairIds) -contains $script:MDRepairIds.ServicesFix) 'services.fix was not attached'
    Assert-Equal 'msiserver' (@(Get-MDImplicatedServiceNames -Findings $out) -join ',') 'the repair scope is wrong'
}

Test-Case 'correlation blames only the service the symptom belongs to' {
    $findings = @(
        (New-TestServiceFinding -Service 'msiserver' -Display 'Windows Installer')
        (New-TestServiceFinding -Service 'W32Time'   -Display 'Windows Time')
        (New-TestServiceFinding -Service 'BITS'      -Display 'Background Intelligent Transfer')
        (New-MDFinding -Category 'Content' -Title 'BITS jobs in error' -Status 'Fail' -Detail '4 job(s) in error')
    )
    $out   = @(Resolve-MDServiceCorrelation -Findings $findings 6>$null)
    $names = @(Get-MDImplicatedServiceNames -Findings $out)

    Assert-Equal 'BITS' ($names -join ',') 'the wrong services were implicated'
}


# ===========================================================================
#  6. Support bundle
# ===========================================================================
Write-Host ''
Write-Host '  Support bundle' -ForegroundColor White

Test-Case 'the bundle name is timestamped and names the computer' {
    $when = Get-Date '2026-08-26 11:25:00'
    $path = Get-MDBundlePath -OutputPath 'C:\Temp' -Timestamp $when
    Assert-Equal ('C:\Temp\MECMDoctor-Bundle-{0}-20260826-112500.zip' -f $env:COMPUTERNAME) $path
}

Test-Case 'an explicit .zip path is honoured' {
    $path = Get-MDBundlePath -OutputPath 'C:\Temp\my-bundle.zip'
    Assert-Equal 'C:\Temp\my-bundle.zip' $path
}

Test-Case 'the bundle produces a valid, readable ZIP' {
    $dir = Join-Path $env:TEMP ('mdtests-' + [System.Diagnostics.Process]::GetCurrentProcess().Id)
    try {
        $client = Get-MDClientInfo
        $zip = New-MDSupportBundle -ClientInfo $client -Findings @(New-TestFinding) -HostFacts (Get-MDHostFacts) `
                                   -OutputPath $dir -Version 'test' -SkipLogs 6>$null

        Assert-True ($null -ne $zip)                     'no bundle path was returned'
        Assert-True (Test-Path -LiteralPath $zip)        'the bundle file does not exist'
        Assert-True ((Get-Item -LiteralPath $zip).Length -gt 0) 'the bundle is empty'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entries = @($archive.Entries | ForEach-Object { $_.FullName })
            foreach ($expected in @('README.txt', 'diagnosis.json', 'findings.txt', 'client.txt',
                                    'services.txt', 'wmi.txt', 'windows.txt', 'logs-manifest.txt')) {
                Assert-True ($entries -contains $expected) ("the bundle is missing {0}" -f $expected)
            }

            # The JSON has to be machine-readable, not just present.
            $entry  = $archive.Entries | Where-Object { $_.FullName -eq 'diagnosis.json' }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $json = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            Assert-Equal 'mecmdoctor/1' $json.schema 'the JSON report is not in the expected schema'
        }
        finally { $archive.Dispose() }
    }
    finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Test-Case 'the bundle records the update source configuration' {
    $lines = @(Get-MDBundleWindowsText -HostFacts $null 6>$null) -join "`n"
    foreach ($expected in @('DisableDualScan', 'Scan source policy values', 'WUServer', 'Build', 'deferral policies')) {
        Assert-True ($lines -match [regex]::Escape($expected)) ("windows.txt is missing {0}" -f $expected)
    }
}

Test-Case 'the bundle records service startup configuration by class' {
    $lines = @(Get-MDBundleServiceText 6>$null) -join "`n"
    Assert-True ($lines -match 'CcmExec')     'services.txt does not list CcmExec'
    Assert-True ($lines -match 'Conditional') 'services.txt does not distinguish conditional services'
}

Test-Case 'the bundle records the client GUID and site assignment' {
    $lines = @(Get-MDBundleClientText -ClientInfo (Get-MDClientInfo) 6>$null) -join "`n"
    foreach ($expected in @('Client GUID', 'Assigned site', 'Management point', 'Client version')) {
        Assert-True ($lines -match [regex]::Escape($expected)) ("client.txt is missing {0}" -f $expected)
    }
}


# ===========================================================================
#  7. Repair catalogue integrity
# ===========================================================================
Write-Host ''
Write-Host '  Repair catalogue' -ForegroundColor White

Test-Case 'every catalogue id is a known repair id' {
    $known = @($script:MDRepairIds.Values) + @('gp.refresh')
    foreach ($entry in $script:MDRepairCatalog) {
        Assert-True ($known -contains $entry.Id) ("{0} is not in MDRepairIds" -f $entry.Id)
    }
}

Test-Case 'every repair id used by a check exists in the catalogue' {
    # Catches a check pointing at an action that was renamed or removed.
    $catalogue = @($script:MDRepairCatalog | ForEach-Object { $_.Id })
    $manual    = @($script:MDRepairIds.DiskSpace, $script:MDRepairIds.Reboot)

    $source = Get-Content -LiteralPath (Join-Path $root 'lib\Checks.ps1') -Raw
    $used   = [regex]::Matches($source, '\$script:MDRepairIds\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique

    foreach ($key in $used) {
        Assert-True ($script:MDRepairIds.ContainsKey($key)) ("Checks.ps1 references MDRepairIds.{0}, which does not exist" -f $key)
        $id = $script:MDRepairIds[$key]
        Assert-True (($catalogue -contains $id) -or ($manual -contains $id)) ("{0} has no catalogue entry" -f $id)
    }
}

Test-Case 'every catalogue action resolves to a defined function' {
    foreach ($entry in $script:MDRepairCatalog) {
        $names = [regex]::Matches($entry.Action.ToString(), 'Repair-MD\w+') | ForEach-Object { $_.Value } | Select-Object -Unique
        foreach ($n in $names) {
            Assert-True ($null -ne (Get-Command -Name $n -ErrorAction SilentlyContinue)) ("{0} calls {1}, which is not defined" -f $entry.Id, $n)
        }
    }
}


# ===========================================================================
#  8. The menu
# ===========================================================================
Write-Host ''
Write-Host '  Menu' -ForegroundColor White

# The menu reaches the keyboard through exactly one call, Read-Host, so
# shadowing that turns the whole thing into something a test can drive - and
# every line of menu code above it stays the real one.
$script:MenuAnswers   = @()
$script:MenuExhausted = $false

function Read-Host {
    param([Parameter(Position = 0)][string] $Prompt)

    if ($script:MenuAnswers.Count -eq 0) {
        # Read-MDMenuInput treats a throwing Read-Host as a closed console, so
        # the flag is what tells the test this was its own fault.
        $script:MenuExhausted = $true
        throw ('no scripted answer left for: ' + $Prompt)
    }

    $next = $script:MenuAnswers[0]
    $script:MenuAnswers = @($script:MenuAnswers | Select-Object -Skip 1)
    $next
}

function Invoke-MenuWith {
    <# Answer a wizard with a scripted list of keystrokes and return what it produced. #>
    param([string[]] $Answers, [scriptblock] $Wizard)

    $script:MenuAnswers   = @($Answers)
    $script:MenuExhausted = $false
    $script:MDMenu.Blanks = 0

    $result = & $Wizard 6>$null
    if ($script:MenuExhausted) { throw 'the menu asked for more input than the test supplied' }
    $result
}

Initialize-MDMenu -Defaults (New-MDRunOptions -Command 'diagnose') `
                  -LogDirectory (Join-Path $env:TEMP 'MDTestLogs') -ScriptRoot $root -NoClear

Test-Case 'the options object carries exactly the command-line parameters' {
    $options = New-MDRunOptions -Command 'repair'
    foreach ($key in @('Command', 'Level', 'LevelExplicit', 'Only', 'All', 'NoDiagnose', 'Verify',
                       'Force', 'DryRun', 'Days', 'IncludeWarnings', 'SkipLogs', 'Json', 'BundlePath')) {
        Assert-True $options.ContainsKey($key) ("New-MDRunOptions is missing {0}" -f $key)
    }
    Assert-Equal 'repair' $options.Command
    Assert-Equal 7 $options.Days
}

Test-Case 'seeding the options ignores keys that are not parameters' {
    $options = New-MDRunOptions -Command 'diagnose' -From @{ Days = 21; Nonsense = 'x' }
    Assert-Equal 21 $options.Days
    Assert-True (-not $options.ContainsKey('Nonsense')) 'an unknown key was copied into the options'
}

Test-Case 'every option the menu can set is read back by Invoke-MDCommand' {
    # Catches an option the menu offers that the runner silently ignores.
    $entry   = Get-Content -LiteralPath (Join-Path $root 'MECMDoctor.ps1') -Raw
    $options = New-MDRunOptions -Command 'repair'
    foreach ($key in @($options.Keys)) {
        Assert-True ($entry -match ('\$Options\.' + [regex]::Escape($key) + '\b')) `
                    ("Invoke-MDCommand never reads Options.{0}" -f $key)
    }
}

Test-Case 'the equivalent command line matches the options' {
    $options = New-MDRunOptions -Command 'repair' -From @{
        Level = 'Safe'; LevelExplicit = $true; Verify = $true; DryRun = $true; Days = 14
    }
    Assert-Equal 'mecmdoctor repair -Level Safe -Verify -Days 14 -DryRun' (Get-MDCommandLine -Options $options)

    $bundle = New-MDRunOptions -Command 'bundle' -From @{ BundlePath = 'C:\Two Words'; SkipLogs = $true }
    Assert-Equal 'mecmdoctor bundle -SkipLogs -BundlePath "C:\Two Words"' (Get-MDCommandLine -Options $bundle)
}

Test-Case 'the command line leaves out flags the command does not have' {
    # -Level and -Verify are repair-only. A diagnose line carrying them would
    # be printed to the operator as advice that does not work.
    $options = New-MDRunOptions -Command 'diagnose' -From @{ Level = 'Aggressive'; LevelExplicit = $true; Verify = $true; All = $true }
    Assert-Equal 'mecmdoctor diagnose' (Get-MDCommandLine -Options $options)
}

Test-Case 'the quick path runs a command with the defaults' {
    $result = Invoke-MenuWith -Answers @('') -Wizard { Invoke-MDDiagnoseWizard }
    Assert-True ($result -is [hashtable]) 'the wizard did not produce an options object'
    Assert-Equal 'mecmdoctor diagnose' (Get-MDCommandLine -Options $result)
}

Test-Case 'the option screens set what they say they set' {
    # options first, pick the range, 14 days, include warnings, no JSON, run.
    $result = Invoke-MenuWith -Answers @('2', '3', '14', 'y', '1', '1') -Wizard { Invoke-MDDiagnoseWizard }
    Assert-Equal 14 $result.Days
    Assert-True $result.IncludeWarnings 'warnings were asked for and not set'
    Assert-True (-not $result.SkipLogs)  'log parsing was turned off by accident'
}

Test-Case 'a dry run never also asks for a verification pass' {
    # options first, recommended tier, implicated actions, dry run, skip logs, no JSON, run.
    $result = Invoke-MenuWith -Answers @('2', '1', '1', '2', '4', '1', '1') -Wizard { Invoke-MDRepairWizard }
    Assert-True $result.DryRun       'the dry run was not set'
    Assert-True (-not $result.Verify) 'a dry run has no delta to verify, but -Verify was set anyway'
}

Test-Case 'repair actions can be picked by number or by id' {
    $second = @($script:MDRepairCatalog | Sort-Object { $_.Order })[1].Id

    # options first, recommended, pick by id, "2,policy.reset", diagnose first,
    # apply, verify, logs, no JSON, run.
    $result = Invoke-MenuWith -Answers @('2', '1', '3', ('2,policy.reset'), 'y', '1', 'n', '1', '1', '1') `
                              -Wizard { Invoke-MDRepairWizard }
    Assert-Equal 2 @($result.Only).Count
    Assert-True (@($result.Only) -contains $second)       'the numbered action was not selected'
    Assert-True (@($result.Only) -contains 'policy.reset') 'the named action was not selected'
    Assert-True (-not $result.NoDiagnose) 'the diagnosis was skipped when it was asked for'
}

Test-Case 'an action id that is not in the catalogue is rejected, not accepted' {
    $result = Invoke-MenuWith -Answers @('2', '1', '3', 'not.a.repair', '1', 'y', '1', 'n', '1', '1', '1') `
                              -Wizard { Invoke-MDRepairWizard }
    Assert-True (@($result.Only) -notcontains 'not.a.repair') 'an unknown repair id was accepted'
    Assert-Equal 1 @($result.Only).Count
}

Test-Case 'back from the first screen returns to the start, not out of the menu' {
    # options first, back, then run: a wizard must not drop the operator out
    # of the command they chose just because they changed their mind once.
    $result = Invoke-MenuWith -Answers @('2', 'b', '1') -Wizard { Invoke-MDBundleWizard }
    Assert-True ($result -is [hashtable]) 'backing out of step one abandoned the command'
    Assert-Equal 'mecmdoctor bundle' (Get-MDCommandLine -Options $result)
}

Test-Case 'quit is honoured from inside a wizard' {
    $result = Invoke-MenuWith -Answers @('q') -Wizard { Invoke-MDLogsWizard }
    Assert-Equal $script:MDMenuQuit $result
}

Test-Case 'the logs command is never offered the option of skipping the logs' {
    $options = New-MDRunOptions -Command 'logs'
    $result  = Invoke-MenuWith -Answers @('4', '1', '1', '1') -Wizard {
        Step-MDLogScope -Options $options -Position 'test' -NoSkip
    }
    Assert-True (-not $options.SkipLogs) 'the logs command accepted -SkipLogs, which would leave it nothing to do'
}

Test-Case 'a menu with nobody answering it closes instead of looping forever' {
    # A closed stdin returns empty strings for ever. Five of them that no
    # prompt could use as a default is the end of the session.
    $result = Invoke-MenuWith -Answers @('', '', '', '', '', '', '', '') -Wizard {
        Read-MDMenuChoice -Options @( @{ Key = '1'; Label = 'One' } ) -NoBack
    }
    Assert-Equal $script:MDMenuQuit $result
}

Test-Case 'repair and reinstall are refused before the questions, not after' {
    if (Test-MDAdmin) {
        # Elevated, so the gate does not apply: check it would apply at all.
        Assert-True ($null -ne (Get-Command Show-MDElevationRequired -ErrorAction SilentlyContinue)) `
                    'there is no elevation gate in front of repair'
    }
    else {
        $result = Invoke-MenuWith -Answers @('2') -Wizard { Get-MDMenuRunRequest -Command 'repair' }
        Assert-Equal 'diagnose' $result
    }
}

Test-Case 'the launcher accepts every command the entry script does' {
    # mecmdoctor.bat keeps its own whitelist so a typo does not raise a UAC
    # prompt. The two lists drifting apart is how "menu" stops working.
    $entry = Get-Content -LiteralPath (Join-Path $root 'MECMDoctor.ps1') -Raw
    $bat   = Get-Content -LiteralPath (Join-Path $root 'mecmdoctor.bat') -Raw

    Assert-True ($entry -match "ValidateSet\(([^)]*)\)\]\s*\r?\n\s*\[string\]\s+\`$Command") 'could not find the Command ValidateSet'
    $commands = [regex]::Matches($Matches[1], "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value }
    Assert-True ($commands -contains 'menu') 'menu is not a valid command'

    foreach ($name in $commands) {
        if ($name -in @('help', 'version')) { continue }   # handled earlier, before elevation
        Assert-True ($bat -match ('"!FIRSTARG!"=="' + $name + '"')) ("mecmdoctor.bat rejects the {0} command" -f $name)
    }
}


# ===========================================================================
#  9. -Quiet
# ===========================================================================
Write-Host ''
Write-Host '  Quiet output' -ForegroundColor White

function Get-MDConsoleText {
    <# What a block of output actually put on the screen, as one string. #>
    param([scriptblock] $Body)
    $records = & $Body 6>&1
    (@($records | ForEach-Object { "$_" }) -join "`n")
}

function New-QuietFinding {
    param([string] $Status, [string] $Title)
    New-MDFinding -Category 'Test' -Title $Title -Status $Status -Detail 'the detail' `
                  -Evidence @('the supporting evidence') -Remediation 'the remediation'
}

Test-Case '-Quiet takes a passing check off the screen, evidence and all' {
    $finding = New-QuietFinding -Status 'Pass' -Title 'a passing check'

    Initialize-MDConsole -NoColor -Tag 'tests'
    $loud = Get-MDConsoleText { $finding | Write-MDFinding }

    Initialize-MDConsole -NoColor -Quiet -Tag 'tests'
    $quiet = Get-MDConsoleText { $finding | Write-MDFinding }

    Assert-True ($loud  -match 'a passing check')        'the check was not printed without -Quiet'
    Assert-True ($quiet -notmatch 'a passing check')     '-Quiet still printed a check that passed'

    # The important half: hiding a headline and keeping its evidence would
    # leave dangling fragments with nothing to belong to.
    Assert-True ($loud  -match 'supporting evidence')    'the evidence was not printed without -Quiet'
    Assert-True ($quiet -notmatch 'supporting evidence') '-Quiet orphaned the evidence of a check it had hidden'

    Initialize-MDConsole -NoColor -Tag 'tests'
}

Test-Case '-Quiet never hides a failure, its evidence or its fix' {
    Initialize-MDConsole -NoColor -Quiet -Tag 'tests'
    $text = Get-MDConsoleText { (New-QuietFinding -Status 'Fail' -Title 'a failing check') | Write-MDFinding }
    Initialize-MDConsole -NoColor -Tag 'tests'

    Assert-True ($text -match 'a failing check')       '-Quiet hid a failure'
    Assert-True ($text -match 'supporting evidence')   '-Quiet hid the evidence behind a failure'
    Assert-True ($text -match 'the remediation')       '-Quiet hid the fix for a failure'
}

Test-Case '-Quiet never hides a warning' {
    Initialize-MDConsole -NoColor -Quiet -Tag 'tests'
    $text = Get-MDConsoleText { (New-QuietFinding -Status 'Warn' -Title 'a warning check') | Write-MDFinding }
    Initialize-MDConsole -NoColor -Tag 'tests'

    Assert-True ($text -match 'a warning check') '-Quiet hid a warning'
}

Test-Case '-Quiet never hides a question' {
    # A repair gate nobody can see is the worst possible outcome of a flag
    # whose entire job is to print less.
    Initialize-MDConsole -NoColor -Quiet -Tag 'tests'
    $text = Get-MDConsoleText { [void](Read-MDConfirm -Question 'do the destructive thing?' -Force) }
    Initialize-MDConsole -NoColor -Tag 'tests'

    Assert-True ($text -match 'do the destructive thing') '-Quiet hid a confirmation prompt'
}

Test-Case '-Quiet changes nothing in the transcripts' {
    $dir = Join-Path $env:TEMP ('MDQuietTest_' + [Guid]::NewGuid().ToString('N'))
    try {
        $write = {
            $findings = @(
                New-QuietFinding -Status 'Pass' -Title 'a passing check'
                New-QuietFinding -Status 'Fail' -Title 'a failing check'
            )
            Set-MDStepTotal 1
            Write-MDStep 'a step heading'
            $findings | Write-MDFinding
            Write-MDAction 'a progress line'
        }

        Initialize-MDConsole -LogDirectory $dir -NoColor -Tag 'loud'
        $loudPath = $script:MDLog.PlainPath
        & $write 6>$null

        Initialize-MDConsole -LogDirectory $dir -NoColor -Quiet -Tag 'quiet'
        $quietPath = $script:MDLog.PlainPath
        & $write 6>$null

        # Drop the header line and the "HH:mm:ss  " stamp each line carries.
        $body = {
            param($path)
            (@(Get-Content -LiteralPath $path | Select-Object -Skip 1 |
                ForEach-Object { $_.Substring([Math]::Min(10, $_.Length)) }) -join "`n")
        }

        Assert-True ((& $body $loudPath).Length -gt 0) 'the loud transcript is empty'
        Assert-Equal (& $body $loudPath) (& $body $quietPath) 'the transcripts are not identical'
    }
    finally {
        Initialize-MDConsole -NoColor -Tag 'tests'
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'every -Quiet suppression happens through the one switch' {
    # Suppression is only ever "chatter plus quiet". Anything that tested
    # MDLog.Quiet on its own would be a second, undocumented rule.
    foreach ($file in @('Common.ps1', 'Checks.ps1', 'Repairs.ps1', 'Report.ps1', 'LogParser.ps1', 'Bundle.ps1', 'Menu.ps1')) {
        $source = Get-Content -LiteralPath (Join-Path $root ('lib\' + $file)) -Raw
        Assert-True ($source -notmatch '\$script:MDLog\.Quiet') ("{0} decides for itself what -Quiet means" -f $file)
    }
}


# ===========================================================================
#  Result
# ===========================================================================
Write-Host ''
Write-Host ('  {0} passed, {1} failed' -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
if ($script:Failed) {
    Write-Host ''
    foreach ($n in $script:Names) { Write-Host ('    failed: ' + $n) -ForegroundColor Red }
}
Write-Host ''

exit $(if ($script:Failed) { 1 } else { 0 })
