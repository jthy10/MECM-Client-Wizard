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
    Started       = (Get-Date)
    PlainPath     = $null    # full path to the human-readable transcript
    CMTracePath   = $null    # full path to the CMTrace-formatted transcript
    PlainWriter   = $null    # held-open StreamWriter for PlainPath
    CMTraceWriter = $null    # held-open StreamWriter for CMTracePath
    UseColor      = $true    # cleared by -NoColor, or when there is no real console
    Quiet         = $false   # suppress routine console chatter (files still written)
    Debug         = $false   # also show [ .. ] diagnostic lines on screen
    Width         = 100      # render width, clamped to the real window when readable
    StepIndex     = 0        # current step number, drives the "[ 3/14]" prefix
    StepTotal     = 0        # total steps in the current phase
    Failures      = 0        # running counters, consumed by the exit-code logic
    Warnings      = 0
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


function Test-MDInteractive {
<#
    .SYNOPSIS
        True when there is a real console for a prompt to appear on.
    .DESCRIPTION
        A scheduled task, an MECM script deployment, a remoting session or
        redirected output all have nowhere to draw a question, and a Read-Host
        there either returns nothing forever or blocks. Everything that wants
        to ask the operator something checks this first.
#>
    try {
        if ($null -eq $Host.UI.RawUI.WindowSize) { return $false }
    }
    catch {
        return $false
    }
    $true
}


function Test-MDMenuCapable {
<#
    .SYNOPSIS
        True when there is a person at a keyboard for a menu to talk to.
    .DESCRIPTION
        Stricter than Test-MDInteractive, and used only to decide whether to
        draw the menu at all.

        A scheduled task, an MECM script deployment and a piped-in answer file
        can all end up with a console window of some sort attached, so a window
        size on its own does not prove that anybody is there to type. Redirected
        input does prove that nobody is - and a menu nobody can answer is worse
        than no menu, because it does nothing at all.

        Read-MDConfirm deliberately does not use this: an operator who pipes an
        answer into a repair still gets their answer honoured.
#>
    if (-not (Test-MDInteractive)) { return $false }
    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch { }
    $true
}


function New-MDTranscriptWriter {
<#
    .SYNOPSIS
        A truncating UTF-8 StreamWriter over one transcript file.
    .DESCRIPTION
        FileShare::ReadWrite so anything else - CMTrace, a tail, the support
        bundle copying its own transcript in mid-run - can read the file while
        it is being written. AutoFlush so an aborted run still leaves every
        line that was reported on screen.
#>
    param([Parameter(Mandatory)][string] $Path)

    $stream = New-Object System.IO.FileStream($Path,
                    [System.IO.FileMode]::Create,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite)

    # UTF8Encoding($false): no BOM, matching what Set-Content produced here
    # before and keeping the transcripts plain for anything that greps them.
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    $writer
}


function Close-MDTranscripts {
    <#
        Closes both transcript writers if they are open. Safe to call at any
        time, including when nothing was ever opened.
    #>
    foreach ($key in @('PlainWriter', 'CMTraceWriter')) {
        $writer = $script:MDLog[$key]
        if ($writer) {
            try { $writer.Flush() }   catch { }
            try { $writer.Dispose() } catch { }
        }
        $script:MDLog[$key] = $null
    }
}


function Initialize-MDConsole {
<#
    .SYNOPSIS
        Configures the logging engine and opens the on-disk transcripts.
    .DESCRIPTION
        Safe to call more than once: the menu re-runs it for every command so
        that each one gets its own pair of transcripts, named for it.
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

    # Forget the previous run's transcripts before deciding on this one's.
    # Without this, re-initialising without a log directory would leave the
    # engine still appending to a file the last run has already closed off.
    # The writers are disposed here too - the menu re-initialises per command,
    # and leaking a file handle per command would keep the previous run's
    # transcript locked for the rest of the session.
    #
    # Deliberately here and not in Write-MDFooter: anything printed after the
    # footer still belongs in the transcript that is open, exactly as it did
    # when every line reopened the file for itself.
    Close-MDTranscripts
    $script:MDLog.PlainPath   = $null
    $script:MDLog.CMTracePath = $null
    $script:MDLog.StepIndex   = 0
    $script:MDLog.StepTotal   = 0
    $script:MDLog.Failures    = 0
    $script:MDLog.Warnings    = 0

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

            # Opened once and held. Add-Content per line opened, wrote and
            # closed both files for every line of output - several thousand
            # open/close pairs on a full diagnose, each one an on-access scan
            # for whatever endpoint protection is watching. On the slow,
            # unhealthy machines this tool is pointed at, that was a
            # meaningful share of the runtime for no benefit at all.
            #
            # AutoFlush so a crash still leaves a complete transcript, and
            # FileShare::ReadWrite so CMTrace, a tail, or the bundle's own
            # Copy-Item can read the file while the run is still writing it.
            $script:MDLog.PlainWriter   = New-MDTranscriptWriter -Path $script:MDLog.PlainPath
            $script:MDLog.CMTraceWriter = New-MDTranscriptWriter -Path $script:MDLog.CMTracePath

            # Written through the writer, so a permissions problem shows up
            # here rather than silently swallowing the whole transcript.
            $header = 'MECM Client Wizard transcript - started ' + $script:MDLog.Started.ToString('yyyy-MM-dd HH:mm:ss')
            $script:MDLog.PlainWriter.WriteLine($header)
        }
        catch {
            # Losing the transcript is survivable; losing the run is not.
            Close-MDTranscripts
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
    if ($script:MDLog.PlainWriter) {
        try {
            # The extra parentheses are load-bearing: inside a method call the
            # comma is an argument separator, so WriteLine('{0} {1}' -f $ts,
            # $Text) binds as WriteLine(('{0} {1}' -f $ts), $Text) and throws
            # a FormatException that the catch below would silently eat.
            $ts = (Get-Date).ToString('HH:mm:ss')
            $script:MDLog.PlainWriter.WriteLine(('{0}  {1}' -f $ts, $Text))
        } catch { }
    }

    # ---- CMTrace transcript ------------------------------------------------
    if ($script:MDLog.CMTraceWriter) {
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

            $script:MDLog.CMTraceWriter.WriteLine($entry)
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

    # A step heading is a divider for the commentary underneath it. With -Quiet
    # there is no commentary underneath it, so the heading goes too.
    $hide = [bool]$script:MDLog.Quiet

    Write-MDLine '' -NoConsole:$hide
    Write-MDLine ($head + ('-' * $pad)) -Color $script:MDColors.Step -NoConsole:$hide
}


# ---------------------------------------------------------------------------
# Status lines. Every one has the same shape:   "  [TAG] message"
# ---------------------------------------------------------------------------
function Write-MDStatus {
<#
    .PARAMETER Chatter
        Marks a line as running commentary rather than a result: progress,
        a check that passed, a file that was written. -Quiet drops those from
        the screen and keeps them in the transcripts, which is the whole of
        what -Quiet means. Warnings, failures, questions, the summary and the
        footer are never chatter.
#>
    param(
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message,
        [string] $Color,
        [int]    $Severity  = 1,
        [string] $Component = 'mecmdoctor',
        [int]    $Indent    = 2,
        [switch] $Chatter
    )
    $hide = ($Chatter -and $script:MDLog.Quiet)
    Write-MDLine ((' ' * $Indent) + $Tag + ' ' + $Message) -Color $Color -Severity $Severity -Component $Component -NoConsole:$hide
}

function Write-MDOk {
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2, [switch] $Chatter)
    Write-MDStatus -Tag $script:MDTags.Ok -Message $Message -Color $script:MDColors.Ok -Severity 1 -Component $Component -Indent $Indent -Chatter:$Chatter
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
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2, [switch] $Chatter)
    Write-MDStatus -Tag $script:MDTags.Info -Message $Message -Color $script:MDColors.Info -Severity 1 -Component $Component -Indent $Indent -Chatter:$Chatter
}

function Write-MDSkip {
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2, [switch] $Chatter)
    Write-MDStatus -Tag $script:MDTags.Skip -Message $Message -Color $script:MDColors.Skip -Severity 1 -Component $Component -Indent $Indent -Chatter:$Chatter
}

function Write-MDAction {
    <# "About to do a thing." Always chatter: it is progress, never a result. #>
    param([string] $Message, [string] $Component = 'mecmdoctor', [int] $Indent = 2)
    Write-MDStatus -Tag $script:MDTags.Action -Message $Message -Color $script:MDColors.Action -Severity 1 -Component $Component -Indent $Indent -Chatter
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
    .PARAMETER Chatter
        See Write-MDStatus. Set it when this detail belongs to a line that is
        itself chatter, so that -Quiet never leaves the evidence on screen
        with the statement it was supporting removed.
#>
    param(
        [Parameter(ValueFromPipeline)][AllowEmptyString()][string[]] $Text,
        [int]    $Indent = 9,
        [string] $Color  = 'DarkGray',
        [string] $Bullet = '',
        [switch] $Chatter
    )
    process {
        $hide = ($Chatter -and $script:MDLog.Quiet)

        foreach ($line in @($Text)) {
            if ($null -eq $line) { continue }

            $prefix = (' ' * $Indent) + $Bullet
            $avail  = [Math]::Max($script:MDLog.Width - $prefix.Length, 20)

            # Honour caller-supplied line breaks, wrap anything over-long.
            # Tabs are expanded first: native tools such as winmgmt emit them,
            # and a raw tab wrecks the indentation of everything after it.
            foreach ($raw in ($line -split "`r?`n")) {
                $work = ($raw -replace "`t", '  ').TrimEnd()
                if ($work.Length -eq 0) { Write-MDLine '' -Color $Color -NoConsole:$hide; continue }

                while ($work.Length -gt $avail) {
                    $cut = $work.LastIndexOf(' ', [Math]::Min($avail, $work.Length - 1))
                    if ($cut -lt 20) { $cut = $avail }
                    Write-MDLine ($prefix + $work.Substring(0, $cut)) -Color $Color -NoConsole:$hide
                    $work   = $work.Substring($cut).TrimStart()
                    $prefix = ' ' * ($Indent + $Bullet.Length)   # hanging indent
                }

                Write-MDLine ($prefix + $work) -Color $Color -NoConsole:$hide
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
    if (-not (Test-MDInteractive)) {
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
