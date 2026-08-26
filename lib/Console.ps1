<#
    ===========================================================================
     MECM Client Wizard  --  lib\Console.ps1
    ---------------------------------------------------------------------------
     The console rendering + logging engine.

     Everything the tool prints goes through here so that we get, for free:
       * consistent, aligned, colour-coded output on screen
       * a plain-text transcript on disk
       * a CMTrace-formatted copy of the same transcript, so admins can open
         our log in the same viewer they already use for the CCM logs

     This file is dot-sourced by MECMDoctor.ps1, so every function and every
     $script: variable below lands in the entry script's scope.

     Design notes
     ------------
     * Status tags are plain ASCII ("[ OK ]", "[FAIL]"). Unicode glyphs look
       nicer but get mangled by the legacy console code pages that are still
       common on the kind of broken endpoint this tool is aimed at.
     * Nothing in here is allowed to throw. A logging engine that can fail is
       worse than no logging engine, because it takes the diagnosis down too.
    ===========================================================================
#>

# ---------------------------------------------------------------------------
# Engine state.
# One shared hashtable rather than a pile of loose variables, so that
# Initialize-MDConsole can reconfigure the whole engine in a single place.
# ---------------------------------------------------------------------------
$script:MDLog = @{
    Started     = (Get-Date)
    PlainPath   = $null      # full path to the human-readable transcript
    CMTracePath = $null      # full path to the CMTrace-formatted transcript
    UseColor    = $true      # cleared by -NoColor, or when there is no real console
    Quiet       = $false     # suppress routine console chatter (files still written)
    Debug       = $false     # also show [ .. ] diagnostic lines on screen
    Width       = 100        # render width, clamped to the real window when readable
    StepIndex   = 0          # current step number, drives the "[ 3/14]" prefix
    StepTotal   = 0          # total steps in the current phase
    Failures    = 0          # running counters, consumed by the exit-code logic
    Warnings    = 0
}

# Fixed-width status tags. Keeping every tag the same length is what makes the
# output columns line up regardless of which tag a given line uses.
$script:MDTags = @{
    Ok     = '[ OK ]'
    Warn   = '[WARN]'
    Fail   = '[FAIL]'
    Info   = '[INFO]'
    Skip   = '[SKIP]'
    Action = '[ >> ]'
    Debug  = '[ .. ]'
    Ask    = '[ ?? ]'
}

$script:MDColors = @{
    Ok     = 'Green'
    Warn   = 'Yellow'
    Fail   = 'Red'
    Info   = 'Gray'
    Skip   = 'DarkGray'
    Action = 'Cyan'
    Debug  = 'DarkGray'
    Ask    = 'Magenta'
    Header = 'Cyan'
    Step   = 'White'
    Rule   = 'DarkCyan'
    Detail = 'DarkGray'
    Accent = 'Cyan'
}


function Initialize-MDConsole {
<#
    .SYNOPSIS
        Configures the logging engine and opens the on-disk transcripts.
    .PARAMETER LogDirectory
        Where the two transcript files are written. Created if missing.
    .PARAMETER NoColor
        Render without console colours (useful when piping output to a file).
    .PARAMETER Quiet
        Trim routine console output; the transcripts stay complete.
    .PARAMETER DebugOutput
        Also show the low-level [ .. ] diagnostic lines on screen.
#>
    [CmdletBinding()]
    param(
        [string] $LogDirectory,
        [switch] $NoColor,
        [switch] $Quiet,
        [switch] $DebugOutput,
        [string] $Tag = 'run'
    )

    $script:MDLog.Started = Get-Date
    $script:MDLog.Quiet   = [bool]$Quiet
    $script:MDLog.Debug   = [bool]$DebugOutput

    # Colour is opt-out, but we also drop it automatically when the host has no
    # real screen buffer (scheduled task, remote exec, redirected output).
    $script:MDLog.UseColor = -not $NoColor
    try {
        if ($null -eq $Host.UI.RawUI.WindowSize) { $script:MDLog.UseColor = $false }
    } catch {
        $script:MDLog.UseColor = $false
    }

    # Match the real window width where we can, so rules and tables fit.
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -ge 60) {
            $script:MDLog.Width = [Math]::Min([Math]::Max($w - 1, 70), 120)
        }
    } catch { }

    if ($LogDirectory) {
        try {
            if (-not (Test-Path -LiteralPath $LogDirectory)) {
                New-Item -Path $LogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            $stamp = $script:MDLog.Started.ToString('yyyyMMdd-HHmmss')
            $base  = 'MECMDoctor_{0}_{1}' -f $Tag, $stamp
            $script:MDLog.PlainPath   = Join-Path $LogDirectory ($base + '.log')
            $script:MDLog.CMTracePath = Join-Path $LogDirectory ($base + '.cmtrace.log')

            # Touch both files now, so a permissions problem shows up immediately
            # rather than silently swallowing the whole transcript.
            $header = 'MECM Client Wizard transcript - started ' + $script:MDLog.Started.ToString('yyyy-MM-dd HH:mm:ss')
            Set-Content -LiteralPath $script:MDLog.PlainPath   -Value $header -Encoding UTF8 -ErrorAction Stop
            Set-Content -LiteralPath $script:MDLog.CMTracePath -Value ''      -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # Losing the transcript is survivable; losing the run is not.
            $script:MDLog.PlainPath   = $null
            $script:MDLog.CMTracePath = $null
            Write-Warning ("Could not open log files in '{0}': {1}" -f $LogDirectory, $_.Exception.Message)
        }
    }
}


function Write-MDLine {
<#
    .SYNOPSIS
        The single low-level writer. Every other Write-MD* function funnels here.
    .DESCRIPTION
        Sends one line to the console (unless -NoConsole) and to both transcripts
        (unless -NoFile). Swallows all of its own errors by design.
#>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $Text = '',

        [string] $Color,

        # CMTrace severity: 1 = info, 2 = warning, 3 = error.
        [ValidateSet(1, 2, 3)]
        [int] $Severity = 1,

        [string] $Component = 'mecmdoctor',

        [switch] $NoConsole,   # transcript only
        [switch] $NoFile       # console only
    )

    # ---- console -----------------------------------------------------------
    if (-not $NoConsole) {
        try {
            if ($script:MDLog.UseColor -and $Color) {
                Write-Host $Text -ForegroundColor $Color
            }
            else {
                Write-Host $Text
            }
        }
        catch {
            # Absolute last resort, so output is never lost entirely.
            [Console]::WriteLine($Text)
        }
    }

    if ($NoFile) { return }

    # ---- plain transcript --------------------------------------------------
    if ($script:MDLog.PlainPath) {
        try {
            $ts = (Get-Date).ToString('HH:mm:ss')
            Add-Content -LiteralPath $script:MDLog.PlainPath -Value ('{0}  {1}' -f $ts, $Text) -Encoding UTF8 -ErrorAction Stop
        } catch { }
    }

    # ---- CMTrace transcript ------------------------------------------------
    if ($script:MDLog.CMTracePath) {
        try {
            $now = Get-Date
            # CMTrace wants the UTC offset in signed minutes, no colon.
            $bias     = [int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
            $sign     = '+'
            if ($bias -lt 0) { $sign = '-' }
            $biasText = '{0}{1:000}' -f $sign, [Math]::Abs($bias)

            $safe  = $Text -replace ']]>', ']] >'
            $entry = '<![LOG[{0}]LOG]!><time="{1}{2}" date="{3}" component="{4}" context="" type="{5}" thread="{6}" file="MECMDoctor.ps1">' -f
                        $safe,
                        $now.ToString('HH:mm:ss.fff'),
                        $biasText,
                        $now.ToString('MM-dd-yyyy'),
                        $Component,
                        $Severity,
                        [System.Threading.Thread]::CurrentThread.ManagedThreadId

            Add-Content -LiteralPath $script:MDLog.CMTracePath -Value $entry -Encoding UTF8 -ErrorAction Stop
        } catch { }
    }
}


function Write-MDRule {
    <# Horizontal rule at the current render width. #>
    param(
        [string] $Char = '-',
        [string] $Color = 'DarkCyan'
    )
    Write-MDLine ($Char * $script:MDLog.Width) -Color $Color
}


function Write-MDBanner {
<#
    .SYNOPSIS
        Start-of-run header: product name, version, and the key host facts.
    .PARAMETER Facts
        Ordered dictionary / hashtable of label -> value shown under the banner.
#>
    param(
        [string] $Version = '1.0.0',
        [string] $Command = 'diagnose',
        $Facts = $null
    )

    Write-MDLine ''
    Write-MDRule '=' $script:MDColors.Header
    Write-MDLine '   M E C M   C L I E N T   W I Z A R D' -Color $script:MDColors.Header
    Write-MDLine ('   mecmdoctor v{0}  --  command: {1}' -f $Version, $Command) -Color $script:MDColors.Accent
    Write-MDRule '=' $script:MDColors.Header
    Write-MDLine ''

    if ($Facts) {
        foreach ($key in $Facts.Keys) {
            Write-MDKeyValue -Key $key -Value $Facts[$key]
        }
        Write-MDLine ''
    }
}


function Write-MDSection {
    <# Major phase heading, e.g. "DIAGNOSTICS" or "REPAIR ACTIONS". #>
    param([Parameter(Mandatory)][string] $Title)

    Write-MDLine ''
    Write-MDRule '=' $script:MDColors.Header
    Write-MDLine ('  ' + $Title.ToUpperInvariant()) -Color $script:MDColors.Header
    Write-MDRule '=' $script:MDColors.Header
}


function Set-MDStepTotal {
    <# Tells the engine how many steps this phase has, for the "[ 3/14]" prefix. #>
    param([int] $Total)
    $script:MDLog.StepTotal = $Total
    $script:MDLog.StepIndex = 0
}


function Write-MDStep {
<#
    .SYNOPSIS
        A numbered step heading, padded with a rule so it reads as a divider.
    .EXAMPLE
        [ 3/14] WMI HEALTH ------------------------------------------------
#>
    param([Parameter(Mandatory)][string] $Title)

    $script:MDLog.StepIndex++

    if ($script:MDLog.StepTotal -gt 0) {
        $prefix = '[{0,2}/{1,-2}]' -f $script:MDLog.StepIndex, $script:MDLog.StepTotal
    }
    else {
        $prefix = '[ {0,-3}]' -f $script:MDLog.StepIndex
    }

    $head = $prefix + ' ' + $Title.ToUpperInvariant() + ' '
    $pad  = [Math]::Max($script:MDLog.Width - $head.Length, 3)

    Write-MDLine ''
    Write-MDLine ($head + ('-' * $pad)) -Color $script:MDColors.Step
}


# ---------------------------------------------------------------------------
# Status lines. Every one has the same shape:   "  [TAG] message"
# ---------------------------------------------------------------------------
function Write-MDStatus {
    param(
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message,
        [string] $Color,
        [int]    $Severity  = 1,
        [string] $Component = 'mecmdoctor',
        [int]    $Indent    = 2
    )
    Write-MDLine ((' ' * $Indent) + $Tag + ' ' + $Message) -Color $Color -Severity $Severity -Component $Component
}

function Write-MDOk {
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2)
    Write-MDStatus -Tag $script:MDTags.Ok -Message $Message -Color $script:MDColors.Ok -Severity 1 -Component $Component -Indent $Indent
}

function Write-MDWarn {
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2)
    $script:MDLog.Warnings++
    Write-MDStatus -Tag $script:MDTags.Warn -Message $Message -Color $script:MDColors.Warn -Severity 2 -Component $Component -Indent $Indent
}

function Write-MDFail {
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2)
    $script:MDLog.Failures++
    Write-MDStatus -Tag $script:MDTags.Fail -Message $Message -Color $script:MDColors.Fail -Severity 3 -Component $Component -Indent $Indent
}

function Write-MDInfo {
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2)
    Write-MDStatus -Tag $script:MDTags.Info -Message $Message -Color $script:MDColors.Info -Severity 1 -Component $Component -Indent $Indent
}

function Write-MDSkip {
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2)
    Write-MDStatus -Tag $script:MDTags.Skip -Message $Message -Color $script:MDColors.Skip -Severity 1 -Component $Component -Indent $Indent
}

function Write-MDAction {
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2)
    Write-MDStatus -Tag $script:MDTags.Action -Message $Message -Color $script:MDColors.Action -Severity 1 -Component $Component -Indent $Indent
}

function Write-MDDebug {
    <# Always transcribed; only shown on screen when -DebugOutput was requested. #>
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2)

    if ($script:MDLog.Debug) {
        Write-MDStatus -Tag $script:MDTags.Debug -Message $Message -Color $script:MDColors.Debug -Severity 1 -Component $Component -Indent $Indent
    }
    else {
        Write-MDLine ((' ' * $Indent) + $script:MDTags.Debug + ' ' + $Message) -NoConsole -Component $Component
    }
}


function Write-MDDetail {
<#
    .SYNOPSIS
        Continuation text under a status line: evidence, log excerpts, hints.
    .DESCRIPTION
        Word-wraps to the render width and keeps a hanging indent, so a long
        remediation sentence still reads as one visual block.
#>
    param(
        [Parameter(ValueFromPipeline)][AllowEmptyString()][string[]] $Text,
        [int]    $Indent = 9,
        [string] $Color  = 'DarkGray',
        [string] $Bullet = ''
    )
    process {
        foreach ($line in @($Text)) {
            if ($null -eq $line) { continue }

            $prefix = (' ' * $Indent) + $Bullet
            $avail  = [Math]::Max($script:MDLog.Width - $prefix.Length, 20)

            # Honour caller-supplied line breaks, wrap anything over-long.
            # Tabs are expanded first: native tools such as winmgmt emit them,
            # and a raw tab wrecks the indentation of everything after it.
            foreach ($raw in ($line -split "`r?`n")) {
                $work = ($raw -replace "`t", '  ').TrimEnd()
                if ($work.Length -eq 0) { Write-MDLine '' -Color $Color; continue }

                while ($work.Length -gt $avail) {
                    $cut = $work.LastIndexOf(' ', [Math]::Min($avail, $work.Length - 1))
                    if ($cut -lt 20) { $cut = $avail }
                    Write-MDLine ($prefix + $work.Substring(0, $cut)) -Color $Color
                    $work   = $work.Substring($cut).TrimStart()
                    $prefix = ' ' * ($Indent + $Bullet.Length)   # hanging indent
                }

                Write-MDLine ($prefix + $work) -Color $Color
                $prefix = (' ' * $Indent) + $Bullet
            }
        }
    }
}


function Write-MDKeyValue {
    <# Aligned "Key .......... : Value" line, used in banners and summaries. #>
    param(
        # An empty key is allowed on purpose: it produces a continuation line
        # that stays aligned under the previous key.
        [Parameter(Mandatory)][AllowEmptyString()][string] $Key,
        $Value,
        [int]    $KeyWidth = 26,
        [int]    $Indent   = 2,
        [string] $Color    = 'Gray'
    )

    $shown = '(not set)'
    if ($null -ne $Value -and "$Value" -ne '') { $shown = "$Value" }

    $separator = ' : '
    if ($Key -eq '') { $separator = '   ' }

    Write-MDLine ((' ' * $Indent) + $Key.PadRight($KeyWidth) + $separator + $shown) -Color $Color
}


function Write-MDTable {
<#
    .SYNOPSIS
        Fixed-width ASCII table that survives a copy/paste into a ticket.
    .PARAMETER Columns
        Array of hashtables: @{ Header = 'CHECK'; Property = 'Title'; Width = 44 }
    .PARAMETER RowColor
        Optional scriptblock taking the row and returning a console colour name.
#>
    param(
        [Parameter(Mandatory)] $Rows,
        [Parameter(Mandatory)] [hashtable[]] $Columns,
        [int] $Indent = 2,
        [scriptblock] $RowColor = $null
    )

    $pad = ' ' * $Indent

    $headerCells = foreach ($c in $Columns) {
        $h = [string]$c.Header
        if ($h.Length -gt $c.Width) { $h = $h.Substring(0, $c.Width) }
        $h.PadRight($c.Width)
    }
    $ruleCells = foreach ($c in $Columns) { '-' * $c.Width }

    Write-MDLine ($pad + ($headerCells -join '  ')) -Color $script:MDColors.Accent
    Write-MDLine ($pad + ($ruleCells   -join '  ')) -Color $script:MDColors.Rule

    foreach ($row in @($Rows)) {
        $cells = foreach ($c in $Columns) {
            $v = [string]$row.($c.Property)
            if ($null -eq $v) { $v = '' }
            if ($v.Length -gt $c.Width) {
                # Ellipsise rather than wrap: tables stay strictly one line per row.
                $v = $v.Substring(0, [Math]::Max($c.Width - 3, 1)) + '...'
            }
            $v.PadRight($c.Width)
        }

        $color = $null
        if ($RowColor) { $color = & $RowColor $row }
        Write-MDLine ($pad + ($cells -join '  ')) -Color $color
    }
}


function Read-MDConfirm {
<#
    .SYNOPSIS
        Yes/no prompt that honours -Force and degrades safely on a headless host.
    .PARAMETER Force
        Prints the question, answers it, and returns $true without blocking.
#>
    param(
        [Parameter(Mandatory)][string] $Question,
        [switch] $Force,
        [switch] $DefaultYes
    )

    if ($Force) {
        Write-MDStatus -Tag $script:MDTags.Ask -Message ($Question + '  ->  auto-confirmed (-Force)') -Color $script:MDColors.Ask
        return $true
    }

    # No interactive host (scheduled task, MECM script deployment, remoting):
    # decline rather than block forever waiting on a Read-Host nobody sees.
    $interactive = $true
    try {
        if ($null -eq $Host.UI.RawUI.WindowSize) { $interactive = $false }
    } catch {
        $interactive = $false
    }

    if (-not $interactive) {
        Write-MDStatus -Tag $script:MDTags.Ask -Severity 2 -Color $script:MDColors.Ask `
            -Message ($Question + '  ->  declined (non-interactive session; re-run with -Force)')
        return $false
    }

    $suffix = '[y/N]'
    if ($DefaultYes) { $suffix = '[Y/n]' }

    Write-MDStatus -Tag $script:MDTags.Ask -Message ($Question + ' ' + $suffix) -Color $script:MDColors.Ask
    $answer = Read-Host '       Answer'

    if ([string]::IsNullOrWhiteSpace($answer)) {
        $result = [bool]$DefaultYes
    }
    else {
        $result = $answer -match '^\s*(y|yes)\s*$'
    }

    if ($result) { Write-MDLine '       -> confirmed' -Color $script:MDColors.Detail }
    else         { Write-MDLine '       -> declined'  -Color $script:MDColors.Detail }

    return $result
}


function Write-MDFooter {
    <# End-of-run block: elapsed time and where the transcripts landed. #>
    param([string] $ExitNote)

    $elapsed = (Get-Date) - $script:MDLog.Started

    Write-MDLine ''
    Write-MDRule '=' $script:MDColors.Header
    Write-MDKeyValue -Key 'Elapsed' -Value ('{0:hh\:mm\:ss}' -f $elapsed) -Color $script:MDColors.Accent
    if ($script:MDLog.PlainPath)   { Write-MDKeyValue -Key 'Transcript'  -Value $script:MDLog.PlainPath }
    if ($script:MDLog.CMTracePath) { Write-MDKeyValue -Key 'CMTrace log' -Value $script:MDLog.CMTracePath }
    if ($ExitNote)                 { Write-MDKeyValue -Key 'Result'      -Value $ExitNote -Color $script:MDColors.Accent }
    Write-MDRule '=' $script:MDColors.Header
    Write-MDLine ''
}
