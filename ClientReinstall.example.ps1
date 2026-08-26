<#
    ===========================================================================
     ClientReinstall.example.ps1
    ---------------------------------------------------------------------------
     A template for the OPTIONAL custom reinstall script.

     HOW TO USE THIS
       1. Copy this file to  ClientReinstall.ps1  (drop the ".example")
       2. Put it next to MECMDoctor.ps1, or in that folder's parent, or in the
          directory you run mecmdoctor from
       3. Edit the CONFIGURATION block below for your environment
       4. Run:  mecmdoctor reinstall

     mecmdoctor searches, in this order:
       - the folder MECMDoctor.ps1 lives in
       - that folder's parent
       - the current working directory
     and runs the first ClientReinstall.ps1 it finds, instead of its own
     built-in ccmsetup fallback.

     PARAMETERS
       Declare any of the four parameters below and mecmdoctor fills them in
       from what it discovered during diagnosis. Declare none of them and the
       script is simply invoked with no arguments - that works too.

     CONTRACT
       - exit code 0        => success
       - any other exit code => mecmdoctor reports the reinstall as failed
       - everything written to the output stream is captured into the
         mecmdoctor transcript, so Write-Output/Write-Host freely

     NOTE
       ccmsetup.exe returns as soon as it has handed off to its background
       service. This script waits for the actual install to finish, which is
       almost always what you want.

     CLIENT IDENTITY
       Removing SMSCFG.INI below is part of a full uninstall, and a reinstalled
       client registers with a NEW client GUID - the device's inventory and
       deployment history in the console is orphaned. That is inherent to
       reinstalling, which is why it is its own explicit command: no mecmdoctor
       repair resets the client identity, and none can escalate into this.

       If you would rather keep the existing identity, drop SMSCFG.INI from the
       $leftovers list below and let the client re-register with the GUID it
       already has.
    ===========================================================================
#>

[CmdletBinding()]
param(
    # Filled in by mecmdoctor from the client's current assignment, when known.
    [string] $SiteCode,

    # Filled in by mecmdoctor from the client's current management point.
    [string] $ManagementPoint,

    # The existing client install path, when one was found.
    [string] $InstallPath,

    # The directory mecmdoctor is writing its own transcripts to.
    [string] $LogDirectory
)

$ErrorActionPreference = 'Stop'


# ===========================================================================
#  CONFIGURATION -- edit this block for your environment
# ===========================================================================

# UNC path or local folder containing ccmsetup.exe.
# A share is the usual choice; make sure Domain Computers can read it, because
# this runs as SYSTEM when deployed through Configuration Manager itself.
$SourcePath = '\\contoso.local\SMS_ABC\Client'

# Fall back to these when mecmdoctor could not discover them (a client that is
# too broken to report its own assignment, or one that was never installed).
$FallbackSiteCode        = 'ABC'
$FallbackManagementPoint = 'mecm-mp01.contoso.local'

# Extra ccmsetup properties. Everything here is standard ccmsetup syntax.
#   SMSSITECODE      site to assign to
#   SMSMP            initial management point
#   FSP              fallback status point, so failures are reported centrally
#   RESETKEYINFORMATION=TRUE  discards the old site signing key; needed when a
#                    client was previously assigned to a different hierarchy
#   /forceinstall    installs even when a client is already present
#   /mp:             where to download the client source from
$InstallProperties = @(
    "SMSSITECODE=$FallbackSiteCode"
    'RESETKEYINFORMATION=TRUE'
    # 'FSP=mecm-fsp01.contoso.local'
    # 'SMSCACHESIZE=20480'
    # 'CCMHOSTNAME=CMG.contoso.com/CCM_Proxy_MutualAuth/72057594037928001'   # CMG clients
)

# How long to wait for ccmsetup to finish before giving up, in minutes.
$InstallTimeoutMinutes = 30

# ===========================================================================
#  END OF CONFIGURATION
# ===========================================================================


function Write-Step {
    param([string] $Message)
    Write-Output ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)
}


# --- resolve what we were given against the fallbacks ------------------------
if (-not $SiteCode)        { $SiteCode        = $FallbackSiteCode }
if (-not $ManagementPoint) { $ManagementPoint = $FallbackManagementPoint }

Write-Step 'Starting Configuration Manager client reinstall'
Write-Step ("  site code        : {0}" -f $SiteCode)
Write-Step ("  management point : {0}" -f $ManagementPoint)
Write-Step ("  source path      : {0}" -f $SourcePath)

# Keep the properties consistent with whatever site code we settled on.
$InstallProperties = @($InstallProperties | Where-Object { $_ -notlike 'SMSSITECODE=*' })
$InstallProperties += ("SMSSITECODE=$SiteCode")
$InstallProperties += ("SMSMP=$ManagementPoint")


# --- 1. uninstall the existing client ----------------------------------------
$localCcmSetup = Join-Path $env:windir 'ccmsetup\ccmsetup.exe'

if (Test-Path -LiteralPath $localCcmSetup) {
    Write-Step 'Uninstalling the existing client (ccmsetup.exe /uninstall)'
    Start-Process -FilePath $localCcmSetup -ArgumentList '/uninstall' -Wait -NoNewWindow

    # ccmsetup returns immediately and continues in the background.
    $deadline = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $deadline -and (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 10
    }
    Write-Step 'Uninstall finished'
}
else {
    Write-Step 'No local ccmsetup.exe found - skipping the uninstall step'
}


# --- 2. clean up what the uninstaller leaves behind ---------------------------
# Optional but recommended when you are reinstalling because the client was
# broken: these are the leftovers that most often break the fresh install too.
Write-Step 'Removing leftover client state'

$leftovers = @(
    (Join-Path $env:windir 'CCM')
    (Join-Path $env:windir 'CCMSetup')
    (Join-Path $env:windir 'CCMCache')
    (Join-Path $env:windir 'SMSCFG.INI')
)

foreach ($path in $leftovers) {
    if (Test-Path -LiteralPath $path) {
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-Step ("  removed {0}" -f $path)
        }
        catch {
            Write-Step ("  could not remove {0} - {1}" -f $path, $_.Exception.Message)
        }
    }
}

# The client WMI namespace survives an uninstall often enough to be worth
# clearing explicitly; a fresh install recreates it from its MOF files.
try {
    Get-CimInstance -Namespace 'root' -ClassName '__Namespace' -ErrorAction Stop |
        Where-Object { $_.Name -eq 'ccm' } |
        Remove-CimInstance -ErrorAction Stop
    Write-Step '  removed the root\ccm WMI namespace'
}
catch {
    Write-Step ('  root\ccm WMI namespace not removed - {0}' -f $_.Exception.Message)
}


# --- 3. install ---------------------------------------------------------------
$sourceCcmSetup = Join-Path $SourcePath 'ccmsetup.exe'
if (-not (Test-Path -LiteralPath $sourceCcmSetup)) {
    Write-Step ("FAILED: ccmsetup.exe not found at {0}" -f $sourceCcmSetup)
    Write-Step 'Check the $SourcePath setting at the top of this script, and that this account can read the share.'
    exit 1
}

$arguments = @("/mp:$ManagementPoint", '/forceinstall') + $InstallProperties

Write-Step ("Installing: {0} {1}" -f $sourceCcmSetup, ($arguments -join ' '))
Start-Process -FilePath $sourceCcmSetup -ArgumentList $arguments -Wait -NoNewWindow

# --- 4. wait for the background install to finish -----------------------------
Write-Step ("Waiting up to {0} minute(s) for ccmsetup to complete" -f $InstallTimeoutMinutes)

$deadline = (Get-Date).AddMinutes($InstallTimeoutMinutes)
while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Seconds 15
}

if (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue) {
    Write-Step 'FAILED: ccmsetup is still running past the timeout.'
    Write-Step 'Check C:\Windows\ccmsetup\Logs\ccmsetup.log for what it is stuck on.'
    exit 1
}


# --- 5. confirm the result ----------------------------------------------------
# ccmsetup records its own outcome in the registry; exit code 0 means success.
$lastExit = $null
try {
    $lastExit = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\CCMSetup' -Name 'LastExitCode' -ErrorAction Stop).LastExitCode
}
catch { }

if ($null -ne $lastExit -and $lastExit -ne 0) {
    Write-Step ("FAILED: ccmsetup reported exit code {0}" -f $lastExit)
    Write-Step 'See C:\Windows\ccmsetup\Logs\ccmsetup.log for the failing step.'
    exit $lastExit
}

$service = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Step 'FAILED: the SMS Agent Host service does not exist after the install.'
    exit 1
}

Write-Step ("SMS Agent Host is {0}" -f $service.Status)
Write-Step 'Client reinstall completed successfully.'
Write-Step 'Registration and the first policy download normally take a further 10-15 minutes.'

exit 0
