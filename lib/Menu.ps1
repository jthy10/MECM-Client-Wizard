<#
    ===========================================================================
     MECM Client Wizard  --  lib\Menu.ps1
    ---------------------------------------------------------------------------
     The interactive main menu.

     Running "mecmdoctor" with no arguments lands here: a numbered menu, a
     short wizard per command that offers the options in plain English, and a
     follow-up screen that hands you straight into the obvious next action.

     Nothing in this file does any work of its own. Every screen ends by
     producing an options hashtable, which MECMDoctor.ps1 hands to
     Invoke-MDCommand - the same entry point the command line uses. The menu
     builds an argument list; it is not a second implementation of the tool.

     Design notes
     ------------
     * ASCII only, like the rest of the output. The whole point of this tool
       is that it works on a broken endpoint with a legacy console code page.
     * Every prompt takes Enter for the default, B to go back one screen and
       Q to leave. No screen is a dead end.
     * Every prompt has a default, and the defaults are what an operator who
       just wants an answer would have picked anyway.
     * Every run prints the command line that would have produced it, so the
       menu teaches its way out of a job.
     * A menu whose input has gone away must not spin forever, so a run of
       blank answers that nothing accepted as a default ends the session.
    ===========================================================================
#>

# Sentinels, returned in place of an answer so that every caller can tell
# "the operator went back" from "the operator chose something".
$script:MDMenuBack = '<back>'
$script:MDMenuQuit = '<quit>'

# Session state. Defaults holds the options the last wizard produced, so a
# second visit starts from what was chosen the first time rather than from
# the factory settings.
$script:MDMenu = @{
    ClientInfo   = $null
    Facts        = $null
    NeedsRefresh = $false
    Blanks       = 0
    Clear        = $true
    LogDirectory = $null
    ScriptRoot   = $null
    Defaults     = $null
    LastRun      = $null
}


# ---------------------------------------------------------------------------
# The options object
# ---------------------------------------------------------------------------
function New-MDRunOptions {
<#
    .SYNOPSIS
        One run's worth of settings: exactly the command-line parameters, in a
        hashtable the menu can edit and Invoke-MDCommand can execute.
    .PARAMETER From
        Another options hashtable to seed from. Unknown keys are ignored, so
        this doubles as a copy that cannot smuggle anything in.
#>
    param(
        [string]    $Command = 'diagnose',
        [hashtable] $From
    )

    $options = @{
        Command         = 'diagnose'
        Level           = 'Standard'
        LevelExplicit   = $false
        Only            = @()
        All             = $false
        NoDiagnose      = $false
        Verify          = $false
        Force           = $false
        DryRun          = $false
        Days            = 7
        IncludeWarnings = $false
        SkipLogs        = $false
        Json            = $null
        BundlePath      = $null
    }

    if ($From) {
        foreach ($key in @($From.Keys)) {
            if ($options.ContainsKey($key)) { $options[$key] = $From[$key] }
        }
    }

    $options['Command'] = $Command
    $options
}


function Get-MDCommandLine {
<#
    .SYNOPSIS
        The command line that would produce this run.
    .DESCRIPTION
        Printed before every menu-driven run. It is the part of the menu that
        teaches: after a few runs the operator knows the flags and can skip
        the menu entirely, which is the outcome we want.
#>
    param([Parameter(Mandatory)][hashtable] $Options)

    $parts = @('mecmdoctor', $Options.Command)

    if ($Options.Command -eq 'repair') {
        if ($Options.LevelExplicit)       { $parts += @('-Level', $Options.Level) }
        if (@($Options.Only).Count -gt 0) { $parts += @('-Only', (@($Options.Only) -join ',')) }
        if ($Options.All)                 { $parts += '-All' }
        if ($Options.NoDiagnose)          { $parts += '-NoDiagnose' }
        if ($Options.Verify)              { $parts += '-Verify' }
    }

    if ($Options.Command -in @('diagnose', 'repair', 'bundle', 'logs')) {
        if ($Options.Days -ne 7)   { $parts += @('-Days', $Options.Days) }
        if ($Options.IncludeWarnings) { $parts += '-IncludeWarnings' }
    }
    if ($Options.Command -in @('diagnose', 'repair', 'bundle')) {
        if ($Options.SkipLogs) { $parts += '-SkipLogs' }
    }
    if ($Options.Command -eq 'bundle' -and $Options.BundlePath) {
        $parts += @('-BundlePath', (Format-MDArgument $Options.BundlePath))
    }

    if ($Options.DryRun) { $parts += '-DryRun' }
    if ($Options.Force)  { $parts += '-Force' }
    if ($Options.Json)   { $parts += @('-Json', (Format-MDArgument $Options.Json)) }

    $parts -join ' '
}


function Format-MDArgument {
    <# Quote a value only when it needs it, so the printed line is copy-pastable. #>
    param($Value)
    if ("$Value" -match '\s') { return ('"' + $Value + '"') }
    "$Value"
}


function Get-MDOptionSummary {
<#
    .SYNOPSIS
        The chosen options, described in the words the menu used to ask for
        them, for the review screen.
    .OUTPUTS
        Ordered dictionary of label -> description.
#>
    param([Parameter(Mandatory)][hashtable] $Options)

    $summary = [ordered]@{}

    switch ($Options.Command) {
        'repair' {
            if ($Options.LevelExplicit) { $summary['Repair tier'] = $Options.Level + '  (chosen by you)' }
            else                        { $summary['Repair tier'] = 'whatever the diagnosis recommends' }

            if (@($Options.Only).Count -gt 0) {
                $summary['Actions'] = 'only these: ' + (@($Options.Only) -join ', ')
            }
            elseif ($Options.All) {
                $summary['Actions'] = 'every action at the tier, implicated or not'
            }
            else {
                $summary['Actions'] = 'only what the diagnosis implicates'
            }

            if ($Options.NoDiagnose) { $summary['Diagnose first'] = 'no - skipped' }
            else                     { $summary['Diagnose first'] = 'yes' }

            if ($Options.DryRun) { $summary['Mode'] = 'DRY RUN - nothing is changed' }
            else                 { $summary['Mode'] = 'apply the repairs' }

            if ($Options.Verify) { $summary['Re-check after'] = 'yes - diagnose again to show what changed' }
            else                 { $summary['Re-check after'] = 'no' }
        }
        'reinstall' {
            if ($Options.DryRun) { $summary['Mode'] = 'DRY RUN - nothing is changed' }
            else                 { $summary['Mode'] = 'remove and reinstall the client' }
        }
        'bundle' {
            if ($Options.BundlePath) { $summary['ZIP goes to'] = $Options.BundlePath }
            else                     { $summary['ZIP goes to'] = 'default folder (%ProgramData%\MECMDoctor\Bundles)' }
        }
    }

    if ($Options.Command -in @('diagnose', 'repair', 'bundle', 'logs')) {
        if ($Options.SkipLogs -and $Options.Command -ne 'logs') {
            $note = 'skipped'
            if ($Options.Command -eq 'bundle') { $note = 'skipped - and left out of the ZIP' }
            $summary['Log analysis'] = $note
        }
        else {
            $kind = 'errors only'
            if ($Options.IncludeWarnings) { $kind = 'errors and warnings' }
            $summary['Log analysis'] = 'last {0} day(s), {1}' -f $Options.Days, $kind
        }
    }

    if ($Options.Json) { $summary['JSON report'] = $Options.Json }

    $summary
}


# ---------------------------------------------------------------------------
# Screen furniture
# ---------------------------------------------------------------------------
function Clear-MDScreen {
    <# Wipe the screen between screens, unless -NoClear said not to. #>
    if (-not $script:MDMenu.Clear) { return }
    try { Clear-Host } catch { }
}


function Write-MDMenuTitle {
<#
    .SYNOPSIS
        The heading block at the top of a menu screen.
    .PARAMETER Subtitle
        Where this screen sits in the wizard, e.g. "step 2 of 4".
#>
    param(
        [Parameter(Mandatory)][string] $Title,
        [string] $Subtitle
    )

    $head = '  ' + $Title.ToUpperInvariant()
    if ($Subtitle) { $head += '  --  ' + $Subtitle }

    Write-MDLine ''
    Write-MDRule '=' $script:MDColors.Header
    Write-MDLine $head -Color $script:MDColors.Header
    Write-MDRule '=' $script:MDColors.Header
}


function Write-MDMenuOption {
<#
    .SYNOPSIS
        One selectable line.
    .PARAMETER Wrap
        Put the explanation on its own indented line instead of alongside the
        label. Used where a choice needs a sentence rather than a phrase.
#>
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][string] $Label,
        [string] $Help,
        [string] $Color = 'White',
        [switch] $Wrap,
        [switch] $IsDefault
    )

    $marker = ''
    if ($IsDefault) { $marker = '   (default)' }

    if ($Wrap) {
        Write-MDLine ('    ' + $Key.PadRight(4) + $Label + $marker) -Color $Color
        if ($Help) { Write-MDDetail -Text $Help -Indent 8 }
    }
    else {
        Write-MDLine (('    ' + $Key.PadRight(4) + $Label.PadRight(16) + $Help + $marker).TrimEnd()) -Color $Color
    }
}


function Write-MDMenuHint {
    <# The "[Enter] = 1   [B] back   [Q] quit" line under a set of choices. #>
    param(
        [string] $Default,
        [switch] $NoBack,
        [switch] $NoQuit
    )

    $bits = @()
    if ($Default)     { $bits += ('[Enter] = ' + $Default) }
    if (-not $NoBack) { $bits += '[B] back' }
    if (-not $NoQuit) { $bits += '[Q] quit' }
    if ($bits.Count -eq 0) { return }

    Write-MDLine ''
    Write-MDLine ('    ' + ($bits -join '     ')) -Color $script:MDColors.Detail
}


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
function Read-MDMenuInput {
<#
    .SYNOPSIS
        One line from the operator, echoed into the transcript.
    .DESCRIPTION
        Read-Host is the only way in, so this is also the only place that can
        hang. A console whose stdin has been closed returns an unbroken run of
        empty strings; left alone that is an infinite menu loop, so blanks that
        no prompt accepted as a default are counted and eventually end the run.
#>
    param([string] $Prompt = 'Select')

    $raw = ''
    try {
        $raw = Read-Host ('   ' + $Prompt)
    }
    catch {
        return $script:MDMenuQuit
    }

    if ($null -eq $raw) { $raw = '' }
    $raw = $raw.Trim()

    if ($raw -eq '') {
        $script:MDMenu.Blanks++
        if ($script:MDMenu.Blanks -ge 5) {
            Write-MDLine ''
            Write-MDWarn 'No input is reaching the menu, so it is closing.'
            Write-MDDetail -Indent 4 -Text 'Run mecmdoctor with a command and its options directly when there is no console to type into.'
            return $script:MDMenuQuit
        }
    }
    else {
        $script:MDMenu.Blanks = 0
    }

    # Read-Host echoes to the screen but not to the transcript.
    Write-MDLine ('   ' + $Prompt + ': ' + $raw) -NoConsole
    $raw
}


function Resolve-MDMenuNavigation {
    <# Back and quit, recognised the same way on every prompt. #>
    param([string] $Answer, [switch] $NoBack)

    if ($Answer -match '^(q|quit|exit)$')              { return $script:MDMenuQuit }
    if (-not $NoBack -and $Answer -match '^(b|back)$') { return $script:MDMenuBack }
    $null
}


function Read-MDMenuChoice {
<#
    .SYNOPSIS
        A numbered list of choices. Returns the chosen option's Key.
    .PARAMETER Options
        Array of hashtables: @{ Key = '1'; Label = 'Diagnose'; Help = '...' },
        each with an optional Color and Wrap.
    .OUTPUTS
        The Key that was chosen, or the back / quit sentinel.
#>
    param(
        [Parameter(Mandatory)] $Options,
        [string] $Default,
        [switch] $NoBack,
        [switch] $NoQuit,
        [switch] $Wrap,
        [string] $Prompt = 'Select'
    )

    $opts = @($Options)

    Write-MDLine ''
    for ($i = 0; $i -lt $opts.Count; $i++) {
        $opt = $opts[$i]

        $color = 'White'
        if ($opt.Color) { $color = $opt.Color }

        $isDefault = ($Default -and $opt.Key -eq $Default)
        if ($isDefault -and -not $opt.Color) { $color = $script:MDColors.Accent }

        $useWrap = [bool]$Wrap
        if ($opt.ContainsKey('Wrap')) { $useWrap = [bool]$opt.Wrap }

        Write-MDMenuOption -Key $opt.Key -Label $opt.Label -Help ([string]$opt.Help) `
                           -Color $color -Wrap:$useWrap -IsDefault:$isDefault

        # A blank line between wrapped entries, but not after the last one:
        # the hint below adds its own, and two in a row reads as a gap.
        if ($useWrap -and $i -lt ($opts.Count - 1)) { Write-MDLine '' }
    }

    Write-MDMenuHint -Default $Default -NoBack:$NoBack -NoQuit:$NoQuit

    while ($true) {
        $answer = Read-MDMenuInput -Prompt $Prompt
        if ($answer -eq $script:MDMenuQuit) { return $script:MDMenuQuit }

        if ($answer -eq '') {
            if ($Default) {
                # Accepting a default is a real answer, not a dead keypress.
                $script:MDMenu.Blanks = 0
                return $Default
            }
            Write-MDLine '    Pick one of the entries above.' -Color $script:MDColors.Warn
            continue
        }

        $nav = Resolve-MDMenuNavigation -Answer $answer -NoBack:$NoBack
        if ($nav) { return $nav }

        $match = $opts | Where-Object { $_.Key -eq $answer } | Select-Object -First 1
        if ($match) { return $match.Key }

        Write-MDLine ('    "' + $answer + '" is not one of the choices.') -Color $script:MDColors.Warn
    }
}


function Read-MDMenuYesNo {
    <# Yes / no with a default. Returns 'yes', 'no', or a sentinel. #>
    param(
        [Parameter(Mandatory)][string] $Question,
        [bool]   $Default = $false,
        [string] $Help,
        [switch] $NoBack
    )

    Write-MDLine ''
    Write-MDLine ('    ' + $Question) -Color 'White'
    if ($Help) { Write-MDDetail -Text $Help -Indent 6 }

    $suffix  = '[y/N]'
    $hint    = 'no'
    if ($Default) { $suffix = '[Y/n]'; $hint = 'yes' }
    Write-MDMenuHint -Default $hint -NoBack:$NoBack

    while ($true) {
        $answer = Read-MDMenuInput -Prompt ('Answer ' + $suffix)
        if ($answer -eq $script:MDMenuQuit) { return $script:MDMenuQuit }

        if ($answer -eq '') {
            $script:MDMenu.Blanks = 0
            if ($Default) { return 'yes' }
            return 'no'
        }

        $nav = Resolve-MDMenuNavigation -Answer $answer -NoBack:$NoBack
        if ($nav) { return $nav }

        if ($answer -match '^(y|yes)$') { return 'yes' }
        if ($answer -match '^(n|no)$')  { return 'no' }

        Write-MDLine '    Answer y or n.' -Color $script:MDColors.Warn
    }
}


function Read-MDMenuNumber {
    <# A bounded whole number. Returns the number as text, or a sentinel. #>
    param(
        [Parameter(Mandatory)][string] $Question,
        [int]    $Default = 7,
        [int]    $Minimum = 1,
        [int]    $Maximum = 90,
        [string] $Help,
        [switch] $NoBack
    )

    Write-MDLine ''
    Write-MDLine ('    ' + $Question) -Color 'White'
    if ($Help) { Write-MDDetail -Text $Help -Indent 6 }
    Write-MDMenuHint -Default "$Default" -NoBack:$NoBack

    while ($true) {
        $answer = Read-MDMenuInput -Prompt ('Number ({0}-{1})' -f $Minimum, $Maximum)
        if ($answer -eq $script:MDMenuQuit) { return $script:MDMenuQuit }

        if ($answer -eq '') {
            $script:MDMenu.Blanks = 0
            return "$Default"
        }

        $nav = Resolve-MDMenuNavigation -Answer $answer -NoBack:$NoBack
        if ($nav) { return $nav }

        $value = 0
        if ([int]::TryParse($answer, [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) {
            return "$value"
        }

        Write-MDLine ('    Enter a whole number between {0} and {1}.' -f $Minimum, $Maximum) -Color $script:MDColors.Warn
    }
}


function Read-MDMenuText {
<#
    .SYNOPSIS
        A free-text answer, in practice always a path.
    .DESCRIPTION
        A lone "b" or "q" navigates rather than being taken as the answer. No
        real path is one character long, and the alternative - a prompt you
        cannot back out of - is worse.
#>
    param(
        [Parameter(Mandatory)][string] $Question,
        [string] $Default,
        [string] $Help,
        [switch] $NoBack
    )

    Write-MDLine ''
    Write-MDLine ('    ' + $Question) -Color 'White'
    if ($Help)    { Write-MDDetail -Text $Help -Indent 6 }
    if ($Default) { Write-MDDetail -Text ('[Enter] keeps: ' + $Default) -Indent 6 }
    Write-MDMenuHint -NoBack:$NoBack

    while ($true) {
        $answer = Read-MDMenuInput -Prompt 'Value'
        if ($answer -eq $script:MDMenuQuit) { return $script:MDMenuQuit }

        if ($answer -eq '') {
            if ($Default) {
                $script:MDMenu.Blanks = 0
                return $Default
            }
            Write-MDLine '    Type a value.' -Color $script:MDColors.Warn
            continue
        }

        $nav = Resolve-MDMenuNavigation -Answer $answer -NoBack:$NoBack
        if ($nav) { return $nav }

        return $answer.Trim('"')
    }
}


function Read-MDMenuPause {
    <# "Press Enter to continue." Never blocks a session that has no console. #>
    param([string] $Message = 'Press [Enter] for the main menu')

    Write-MDLine ''
    [void](Read-MDMenuInput -Prompt $Message)
    $script:MDMenu.Blanks = 0
}


# ---------------------------------------------------------------------------
# Wizard steps
#
# Each one edits the options hashtable in place - hashtables are references,
# so the caller sees the change - and returns 'ok', or a navigation sentinel.
# ---------------------------------------------------------------------------
function Step-MDLogScope {
<#
    .SYNOPSIS
        How much of the client's own log history to read.
    .PARAMETER NoSkip
        For the logs command, where "skip the logs" is not a coherent answer.
#>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        [string] $Position,
        [switch] $NoSkip
    )

    Write-MDMenuTitle -Title ($Options.Command + ': log analysis') -Subtitle $Position
    Write-MDLine ''
    Write-MDDetail -Indent 4 -Color 'Gray' -Text @(
        'The client writes down why it failed. Reading those logs is where most real causes turn up - and it is also the slowest part of a run on a machine with months of history.'
    )

    $choices = @(
        @{ Key = '1'; Label = 'Errors, 7 days';  Help = 'The default. Enough to explain a client that broke this week.' }
        @{ Key = '2'; Label = 'Add warnings';    Help = 'Errors and warnings for the same 7 days. Noisier, more complete.' }
        @{ Key = '3'; Label = 'Pick the range';  Help = 'Choose the number of days, and whether to include warnings.' }
    )
    if (-not $NoSkip) {
        $help = 'Much faster. The checks still run; only the log reading is skipped.'
        if ($Options.Command -eq 'bundle') {
            $help = 'Much faster, and leaves the CCM logs out of the ZIP as well.'
        }
        $choices += @{ Key = '4'; Label = 'Skip the logs'; Help = $help }
    }

    $default = '1'
    if ($Options.SkipLogs -and -not $NoSkip)                     { $default = '4' }
    elseif ($Options.Days -ne 7)                                 { $default = '3' }
    elseif ($Options.IncludeWarnings)                            { $default = '2' }

    $answer = Read-MDMenuChoice -Options $choices -Default $default -Wrap
    if ($answer -eq $script:MDMenuBack -or $answer -eq $script:MDMenuQuit) { return $answer }

    switch ($answer) {
        '1' { $Options.SkipLogs = $false; $Options.Days = 7; $Options.IncludeWarnings = $false }
        '2' { $Options.SkipLogs = $false; $Options.Days = 7; $Options.IncludeWarnings = $true }
        '4' { $Options.SkipLogs = $true }
        '3' {
            $days = Read-MDMenuNumber -Question 'How many days of logs should be read?' -Default $Options.Days `
                                      -Minimum 1 -Maximum 90 `
                                      -Help 'The client keeps a few weeks at most, so a large number is not an error - it just reads everything there is.'
            if ($days -eq $script:MDMenuBack -or $days -eq $script:MDMenuQuit) { return $days }

            $warn = Read-MDMenuYesNo -Question 'Include warnings as well as errors?' -Default $Options.IncludeWarnings `
                                     -Help 'Warnings catch problems that have not become failures yet, at the cost of a longer report.'
            if ($warn -eq $script:MDMenuBack -or $warn -eq $script:MDMenuQuit) { return $warn }

            $Options.SkipLogs        = $false
            $Options.Days            = [int]$days
            $Options.IncludeWarnings = ($warn -eq 'yes')
        }
    }

    'ok'
}


function Step-MDReportFile {
    <# Whether to also write the machine-readable JSON report. #>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        [string] $Position
    )

    Write-MDMenuTitle -Title ($Options.Command + ': machine-readable report') -Subtitle $Position
    Write-MDLine ''
    Write-MDDetail -Indent 4 -Color 'Gray' -Text @(
        'Every run always writes a plain-text transcript and a CMTrace copy of it. This is the extra one: a JSON file holding every finding as data, for a ticket, a dashboard, or a fleet-wide comparison.'
    )

    $answer = Read-MDMenuChoice -Wrap -Default '1' -Options @(
        @{ Key = '1'; Label = 'No JSON';        Help = 'Transcripts only.' }
        @{ Key = '2'; Label = 'Alongside logs'; Help = 'Write it next to the transcripts in the log folder.' }
        @{ Key = '3'; Label = 'Choose a path';  Help = 'Type the full path to write it to.' }
    )
    if ($answer -eq $script:MDMenuBack -or $answer -eq $script:MDMenuQuit) { return $answer }

    switch ($answer) {
        '1' { $Options.Json = $null }
        '2' {
            $folder = $script:MDMenu.LogDirectory
            if (-not $folder) { $folder = Join-Path $env:ProgramData 'MECMDoctor\Logs' }
            $name = 'MECMDoctor_{0}_{1}_{2}.json' -f $env:COMPUTERNAME, $Options.Command, (Get-Date).ToString('yyyyMMdd-HHmmss')
            $Options.Json = Join-Path $folder $name
        }
        '3' {
            $path = Read-MDMenuText -Question 'Where should the JSON report go?' -Default $Options.Json `
                                    -Help 'A full path ending in .json. The folder is created if it does not exist.'
            if ($path -eq $script:MDMenuBack -or $path -eq $script:MDMenuQuit) { return $path }
            $Options.Json = $path
        }
    }

    'ok'
}


function Step-MDRepairTier {
    <# Safe / Standard / Aggressive, or let the diagnosis decide. #>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        [string] $Position
    )

    Write-MDMenuTitle -Title 'repair: how far to go' -Subtitle $Position
    Write-MDLine ''
    Write-MDDetail -Indent 4 -Color 'Gray' -Text @(
        'The tier is a ceiling, not a script. Whatever you pick here, only the actions the diagnosis actually implicated will run - and every destructive action asks for itself, individually, before it does anything.'
    )

    $default = '1'
    if ($Options.LevelExplicit) {
        switch ($Options.Level) {
            'Safe'       { $default = '2' }
            'Standard'   { $default = '3' }
            'Aggressive' { $default = '4' }
        }
    }

    $answer = Read-MDMenuChoice -Wrap -Default $default -Options @(
        @{ Key = '1'; Label = 'Recommended'; Help = 'Let the diagnosis pick the lowest tier that covers what it found. This is what "mecmdoctor repair" does on its own, and it never picks Aggressive - a destructive action is only ever reached by choosing it below.' }
        @{ Key = '2'; Label = 'Safe';        Help = 'Reversible only: start an implicated service, restart CcmExec, clear the cache and failed BITS jobs, trigger client cycles, run ccmeval. Fine on a production machine during the day.' }
        @{ Key = '3'; Label = 'Standard';    Help = 'Safe, plus rebuilding state that Windows regenerates by itself: salvage the WMI repository, quarantine a corrupt Registry.pol, purge and re-download policy, reset Windows Update, repair the client.' }
        @{ Key = '4'; Label = 'Aggressive';  Help = 'Everything above, plus destructive actions: reset the WMI repository, clear Group Policy state, rebuild the security database, reinstall the client.'; Color = 'Yellow' }
    )
    if ($answer -eq $script:MDMenuBack -or $answer -eq $script:MDMenuQuit) { return $answer }

    switch ($answer) {
        '1' { $Options.LevelExplicit = $false; $Options.Level = 'Standard' }
        '2' { $Options.LevelExplicit = $true;  $Options.Level = 'Safe' }
        '3' { $Options.LevelExplicit = $true;  $Options.Level = 'Standard' }
        '4' { $Options.LevelExplicit = $true;  $Options.Level = 'Aggressive' }
    }

    'ok'
}


function Step-MDRepairScope {
    <# Which actions: the implicated ones, all of them, or a hand-picked list. #>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        [string] $Position
    )

    Write-MDMenuTitle -Title 'repair: which actions' -Subtitle $Position
    Write-MDLine ''
    Write-MDDetail -Indent 4 -Color 'Gray' -Text @(
        'Normally a repair runs only what the diagnosis implicated: one broken service means one service gets fixed, not the whole service table. The other two answers here override that.'
    )

    $default = '1'
    if (@($Options.Only).Count -gt 0) { $default = '3' }
    elseif ($Options.All)             { $default = '2' }

    $answer = Read-MDMenuChoice -Wrap -Default $default -Options @(
        @{ Key = '1'; Label = 'Implicated';   Help = 'Only the actions a finding asked for. The normal answer.' }
        @{ Key = '2'; Label = 'Everything';   Help = 'Every action at the chosen tier, whether or not anything is wrong with it. Actions that need evidence, such as a WMI repository reset, are still excluded.' }
        @{ Key = '3'; Label = 'Pick by id';   Help = 'Choose specific repair actions yourself from the catalogue.' }
    )
    if ($answer -eq $script:MDMenuBack -or $answer -eq $script:MDMenuQuit) { return $answer }

    switch ($answer) {
        '1' { $Options.All = $false; $Options.Only = @(); $Options.NoDiagnose = $false }
        '2' { $Options.All = $true;  $Options.Only = @(); $Options.NoDiagnose = $false }
        '3' {
            $picked = Read-MDRepairActions -Options $Options
            if ($picked -eq $script:MDMenuBack -or $picked -eq $script:MDMenuQuit) { return $picked }

            $Options.Only = @($picked)
            $Options.All  = $false

            $diag = Read-MDMenuYesNo -Question 'Run the full diagnosis first anyway?' -Default $true `
                                     -Help 'It changes nothing about which actions run - you have already named those - but it records the state of the machine before the repair, which is what makes the transcript worth keeping.'
            if ($diag -eq $script:MDMenuBack -or $diag -eq $script:MDMenuQuit) { return $diag }
            $Options.NoDiagnose = ($diag -eq 'no')
        }
    }

    'ok'
}


function Read-MDRepairActions {
<#
    .SYNOPSIS
        The repair catalogue as a numbered list, and a comma-separated answer.
    .OUTPUTS
        An array of repair action ids, or a navigation sentinel.
#>
    param([Parameter(Mandatory)][hashtable] $Options)

    $catalog = @($script:MDRepairCatalog | Sort-Object { $_.Order })

    Write-MDLine ''
    Write-MDLine '    Repair actions' -Color $script:MDColors.Accent
    Write-MDLine ''

    $rows = @()
    for ($i = 0; $i -lt $catalog.Count; $i++) {
        $note = ''
        if ($catalog[$i].NeedsEvidence)   { $note = 'needs evidence - only ever runs when named' }
        if ($catalog[$i].Id -like 'manual.*') { $note = 'advice only - nothing is automated' }
        $rows += [pscustomobject]@{
            Num  = ($i + 1)
            Id   = $catalog[$i].Id
            Tier = $catalog[$i].Level
            Note = $note
        }
    }

    Write-MDTable -Rows $rows -Indent 4 -Columns @(
        @{ Header = '#';         Property = 'Num';  Width = 4  }
        @{ Header = 'ACTION ID'; Property = 'Id';   Width = 24 }
        @{ Header = 'TIER';      Property = 'Tier'; Width = 12 }
        @{ Header = 'NOTE';      Property = 'Note'; Width = 42 }
    ) -RowColor { param($r) if ($r.Tier -eq 'Aggressive') { 'Yellow' } else { $null } }

    Write-MDLine ''
    Write-MDDetail -Indent 4 -Text 'Enter the numbers or the ids, separated by commas: "2,11" or "ccmexec.restart,policy.reset".'
    Write-MDMenuHint

    while ($true) {
        $answer = Read-MDMenuInput -Prompt 'Actions'
        if ($answer -eq $script:MDMenuQuit) { return $script:MDMenuQuit }

        if ($answer -eq '') {
            Write-MDLine '    Name at least one action, or [B] to go back.' -Color $script:MDColors.Warn
            continue
        }

        $nav = Resolve-MDMenuNavigation -Answer $answer
        if ($nav) { return $nav }

        $chosen  = @()
        $unknown = @()
        foreach ($token in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
            $number = 0
            if ([int]::TryParse($token, [ref]$number)) {
                if ($number -ge 1 -and $number -le $catalog.Count) { $chosen += $catalog[$number - 1].Id }
                else { $unknown += $token }
                continue
            }

            $entry = $catalog | Where-Object { $_.Id -eq $token } | Select-Object -First 1
            if ($entry) { $chosen += $entry.Id } else { $unknown += $token }
        }

        if ($unknown.Count -gt 0) {
            Write-MDLine ('    Not in the catalogue: ' + ($unknown -join ', ')) -Color $script:MDColors.Warn
            continue
        }

        $chosen = @($chosen | Select-Object -Unique)
        if ($chosen.Count -eq 0) {
            Write-MDLine '    Nothing was selected.' -Color $script:MDColors.Warn
            continue
        }

        Write-MDLine ('    Selected: ' + ($chosen -join ', ')) -Color $script:MDColors.Ok
        return $chosen
    }
}


function Step-MDRepairSafety {
    <# Dry run or not, and whether to re-check the machine afterwards. #>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        [string] $Position
    )

    Write-MDMenuTitle -Title 'repair: dry run or for real' -Subtitle $Position
    Write-MDLine ''
    Write-MDDetail -Indent 4 -Color 'Gray' -Text @(
        'A dry run walks the whole plan and reports what each action would do, without touching the machine. It is the honest way to find out what a repair is about to cost you.'
    )

    $default = '1'
    if ($Options.DryRun) { $default = '2' }

    $mode = Read-MDMenuChoice -Wrap -Default $default -Options @(
        @{ Key = '1'; Label = 'Repair it';  Help = 'Apply the repairs. You are still asked to confirm the plan before anything runs, and again for each destructive action.' }
        @{ Key = '2'; Label = 'Dry run';    Help = 'Show what would happen and change nothing.' }
    )
    if ($mode -eq $script:MDMenuBack -or $mode -eq $script:MDMenuQuit) { return $mode }
    $Options.DryRun = ($mode -eq '2')

    if ($Options.DryRun) {
        # -Verify re-reads the machine to show a delta. After a dry run there
        # is no delta, and the entry script skips it anyway.
        $Options.Verify = $false
        return 'ok'
    }

    $verify = Read-MDMenuYesNo -Question 'Re-run the diagnosis afterwards to show what changed?' -Default $Options.Verify `
                               -Help 'Roughly doubles the runtime, and is the only way to see the result rather than take the repair log on trust. Registration, policy and update scans are asynchronous, so some findings need 15 minutes or more to settle.'
    if ($verify -eq $script:MDMenuBack -or $verify -eq $script:MDMenuQuit) { return $verify }
    $Options.Verify = ($verify -eq 'yes')

    'ok'
}


function Step-MDBundleOutput {
    <# Where the support ZIP is written. #>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        [string] $Position
    )

    Write-MDMenuTitle -Title 'bundle: where the ZIP goes' -Subtitle $Position
    Write-MDLine ''
    Write-MDDetail -Indent 4 -Color 'Gray' -Text @(
        'The bundle is a timestamped ZIP holding the diagnosis, the client state, the service and log evidence behind it, and this run''s transcript - everything someone who is not sitting at this machine needs to read it.'
    )

    $default = '1'
    if ($Options.BundlePath) { $default = '2' }

    $answer = Read-MDMenuChoice -Wrap -Default $default -Options @(
        @{ Key = '1'; Label = 'Default folder'; Help = '%ProgramData%\MECMDoctor\Bundles' }
        @{ Key = '2'; Label = 'Somewhere else'; Help = 'A folder to drop it in, or a full path ending in .zip. A network share works, if this account can write to it.' }
    )
    if ($answer -eq $script:MDMenuBack -or $answer -eq $script:MDMenuQuit) { return $answer }

    if ($answer -eq '1') {
        $Options.BundlePath = $null
        return 'ok'
    }

    $path = Read-MDMenuText -Question 'Where should the bundle be written?' -Default $Options.BundlePath `
                            -Help 'For example C:\Temp, or \\server\share\bundles, or C:\Temp\WKS01.zip.'
    if ($path -eq $script:MDMenuBack -or $path -eq $script:MDMenuQuit) { return $path }
    $Options.BundlePath = $path

    'ok'
}


# ---------------------------------------------------------------------------
# The wizard driver
# ---------------------------------------------------------------------------
function Show-MDRunReview {
<#
    .SYNOPSIS
        The last screen before a run: everything that was chosen, and the
        command line that would have produced it.
    .OUTPUTS
        'run', 'edit', or a navigation sentinel.
#>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        [string] $Title
    )

    Write-MDMenuTitle -Title ($Title + ': ready') -Subtitle 'review'
    Write-MDLine ''

    $summary = Get-MDOptionSummary -Options $Options
    foreach ($key in $summary.Keys) {
        Write-MDKeyValue -Key $key -Value $summary[$key] -KeyWidth 18 -Indent 4
    }

    Write-MDLine ''
    Write-MDLine '    Same thing from the command line:' -Color $script:MDColors.Detail
    Write-MDLine ('      ' + (Get-MDCommandLine -Options $Options)) -Color $script:MDColors.Accent

    $answer = Read-MDMenuChoice -Default '1' -Options @(
        @{ Key = '1'; Label = 'Run it';  Help = 'Start now.' }
        @{ Key = '2'; Label = 'Change';  Help = 'Go back through the options.' }
    )

    switch ($answer) {
        '1' { return 'run' }
        '2' { return 'edit' }
    }
    $answer
}


function Invoke-MDWizardSteps {
<#
    .SYNOPSIS
        Runs one command's option screens and returns the finished options.
    .DESCRIPTION
        Every wizard has the same shape: a gate offering to run straight away,
        then the option screens, then a review. Back navigation walks the
        screens in reverse and finally out to the main menu, so nothing here
        can trap the operator.
    .OUTPUTS
        The options hashtable to run, or a navigation sentinel.
#>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        [Parameter(Mandatory)][scriptblock[]] $Steps,
        [Parameter(Mandatory)][string] $Title,
        [string[]] $QuickHelp,
        [string] $CustomHelp = 'Step through the options one screen at a time.'
    )

    $startAtSteps = $false

    while ($true) {

        if (-not $startAtSteps) {
            Write-MDMenuTitle -Title $Title
            Write-MDLine ''
            Write-MDDetail -Indent 4 -Color 'Gray' -Text $QuickHelp

            $gate = Read-MDMenuChoice -Wrap -Default '1' -Options @(
                @{ Key = '1'; Label = 'Run it now';  Help = (Get-MDCommandLine -Options $Options) }
                @{ Key = '2'; Label = 'Options first'; Help = $CustomHelp }
            )
            if ($gate -eq $script:MDMenuBack -or $gate -eq $script:MDMenuQuit) { return $gate }
            if ($gate -eq '1') { return $Options }
        }
        $startAtSteps = $false

        # ---- the option screens -------------------------------------------
        $index   = 0
        $backOut = $false

        while ($index -lt $Steps.Count) {
            $position = 'step {0} of {1}' -f ($index + 1), $Steps.Count
            $result   = & $Steps[$index] $Options $position

            if ($result -eq $script:MDMenuQuit) { return $script:MDMenuQuit }
            if ($result -eq $script:MDMenuBack) {
                $index--
                if ($index -lt 0) { $backOut = $true; break }
                continue
            }
            $index++
        }

        if ($backOut) { continue }   # back out of step 1 lands on the gate

        # ---- review --------------------------------------------------------
        $review = Show-MDRunReview -Options $Options -Title $Title
        if ($review -eq $script:MDMenuQuit) { return $script:MDMenuQuit }
        if ($review -eq 'run')  { return $Options }
        if ($review -eq 'edit') { $startAtSteps = $true; continue }
        # anything else is Back, which lands on the gate
    }
}


# ---------------------------------------------------------------------------
# The wizards
# ---------------------------------------------------------------------------
function Show-MDElevationRequired {
<#
    .SYNOPSIS
        The screen that stands in front of repair and reinstall when the tool
        is not elevated.
    .DESCRIPTION
        Invoke-MDCommand refuses these two commands without administrative
        rights anyway. Refusing here instead means the operator finds out
        before answering four screens of questions, and is offered the two
        things that would actually help.
    .OUTPUTS
        'elevate', 'diagnose', or a navigation sentinel.
#>
    param([Parameter(Mandatory)][string] $Command)

    Write-MDMenuTitle -Title ($Command + ' needs administrative rights')
    Write-MDLine ''
    Write-MDDetail -Indent 4 -Color 'Gray' -Text @(
        ('mecmdoctor is not running elevated, so it will refuse to {0}. Several diagnostic checks come back incomplete without those rights too.' -f $Command)
    )

    $answer = Read-MDMenuChoice -Wrap -Default '1' -Options @(
        @{ Key = '1'; Label = 'Re-launch as admin'; Help = 'Start mecmdoctor again with administrative rights. Windows will ask you to approve it.' }
        @{ Key = '2'; Label = 'Diagnose instead';   Help = 'A read-only check runs without elevation, and tells you what a repair would need to do.' }
    )
    if ($answer -eq $script:MDMenuBack -or $answer -eq $script:MDMenuQuit) { return $answer }
    if ($answer -eq '2') { return 'diagnose' }

    'elevate'
}


function Invoke-MDDiagnoseWizard {
    $options = New-MDRunOptions -Command 'diagnose' -From $script:MDMenu.Defaults

    Invoke-MDWizardSteps -Options $options -Title 'Diagnose' -Steps @(
        { param($o, $p) Step-MDLogScope   -Options $o -Position $p }
        { param($o, $p) Step-MDReportFile -Options $o -Position $p }
    ) -QuickHelp @(
        'A read-only health check: thirteen areas of the client, then its logs. It changes nothing at all, so there is nothing to confirm and nothing to undo.'
        'Two to five minutes on a healthy machine; longer when the logs are large.'
    )
}


function Invoke-MDRepairWizard {
    # Verify defaults to on here - see Initialize-MDMenu. Somebody sitting at
    # the menu watching a repair is exactly the person who wants to be shown
    # that it worked rather than told.
    $options = New-MDRunOptions -Command 'repair' -From $script:MDMenu.Defaults

    Invoke-MDWizardSteps -Options $options -Title 'Repair' -Steps @(
        { param($o, $p) Step-MDRepairTier   -Options $o -Position $p }
        { param($o, $p) Step-MDRepairScope  -Options $o -Position $p }
        { param($o, $p) Step-MDRepairSafety -Options $o -Position $p }
        { param($o, $p) Step-MDLogScope     -Options $o -Position $p }
        { param($o, $p) Step-MDReportFile   -Options $o -Position $p }
    ) -QuickHelp @(
        'Diagnose the machine, print the repairs the findings implicated and the finding behind each one, then ask before changing anything. Destructive actions ask again, individually.'
        'Nothing runs until you have said yes, so "run it now" is safe to pick and read.'
    ) -CustomHelp 'Choose the tier, which actions may run, and whether this is a dry run.'
}


function Invoke-MDBundleWizard {
    $options = New-MDRunOptions -Command 'bundle' -From $script:MDMenu.Defaults

    Invoke-MDWizardSteps -Options $options -Title 'Bundle' -Steps @(
        { param($o, $p) Step-MDBundleOutput -Options $o -Position $p }
        { param($o, $p) Step-MDLogScope     -Options $o -Position $p }
        { param($o, $p) Step-MDReportFile   -Options $o -Position $p }
    ) -QuickHelp @(
        'Run the full diagnosis, then pack it and its evidence into a timestamped ZIP: client state, services, WMI, policy, certificates, the CCM logs and this run''s transcript.'
        'Read-only. Nothing on the machine is changed.'
    ) -CustomHelp 'Choose where the ZIP goes and how much log history goes into it.'
}


function Invoke-MDLogsWizard {
    $options = New-MDRunOptions -Command 'logs' -From $script:MDMenu.Defaults

    Invoke-MDWizardSteps -Options $options -Title 'Logs' -Steps @(
        { param($o, $p) Step-MDLogScope -Options $o -Position $p -NoSkip }
        { param($o, $p) Step-MDReportFile -Options $o -Position $p }
    ) -QuickHelp @(
        'Read the CCM logs - both on-disk formats, rolled-over .lo_ files included - and translate every error into what it actually means, with the fix.'
        'Read-only, and usually the fastest way to find out what a client is complaining about.'
    ) -CustomHelp 'Choose how far back to read and whether warnings count.'
}


function Invoke-MDReinstallWizard {
<#
    .SYNOPSIS
        The reinstall gate. Bespoke rather than a standard wizard, because the
        only interesting question is whether the operator has understood what
        they are about to do.
#>
    $options = New-MDRunOptions -Command 'reinstall' -From $script:MDMenu.Defaults

    while ($true) {
        Write-MDMenuTitle -Title 'Reinstall the Configuration Manager client'
        Write-MDLine ''
        Write-MDDetail -Indent 4 -Color 'Gray' -Text @(
            'This removes the client and installs it again. It is the last resort, not a first move: nearly everything a reinstall fixes is also fixed by a repair, without the hour of re-registration, policy download and update scanning that follows a fresh install.'
        )
        Write-MDLine ''

        $custom = $null
        try { $custom = Find-MDCustomReinstallScript -ScriptRoot $script:MDMenu.ScriptRoot } catch { }

        if ($custom) {
            Write-MDOk ('Your own reinstall script will be used: {0}' -f $custom)
        }
        else {
            Write-MDWarn 'No ClientReinstall.ps1 was found, so ccmsetup.exe will be called with the site parameters discovered on this machine.'
            Write-MDDetail -Indent 4 -Text 'Copy ClientReinstall.example.ps1 to ClientReinstall.ps1 next to MECMDoctor.ps1 to control exactly how the client is installed.'
        }

        $answer = Read-MDMenuChoice -Wrap -Default '1' -Options @(
            @{ Key = '1'; Label = 'Dry run first'; Help = 'Show what the reinstall would do and change nothing. Start here.' }
            @{ Key = '2'; Label = 'Reinstall it';  Help = 'Remove and reinstall the client for real. You are asked to confirm once more before anything is removed.'; Color = 'Yellow' }
            @{ Key = '3'; Label = 'Diagnose instead'; Help = 'Find out what is actually wrong first. Most of the time this is the better answer.' }
        )
        if ($answer -eq $script:MDMenuBack -or $answer -eq $script:MDMenuQuit) { return $answer }
        if ($answer -eq '3') { return 'diagnose' }

        $options.DryRun = ($answer -eq '1')
        return $options
    }
}


function Get-MDMenuRunRequest {
    <# Dispatch to the wizard for one command. #>
    param([Parameter(Mandatory)][string] $Command)

    # The two commands that write to the machine are refused without elevation.
    # Say so before asking for options that cannot be acted on.
    if ($Command -in @('repair', 'reinstall') -and -not (Test-MDAdmin)) {
        return (Show-MDElevationRequired -Command $Command)
    }

    switch ($Command) {
        'diagnose'  { return (Invoke-MDDiagnoseWizard) }
        'repair'    { return (Invoke-MDRepairWizard) }
        'bundle'    { return (Invoke-MDBundleWizard) }
        'logs'      { return (Invoke-MDLogsWizard) }
        'reinstall' { return (Invoke-MDReinstallWizard) }
    }
    $script:MDMenuBack
}


# ---------------------------------------------------------------------------
# The main menu
# ---------------------------------------------------------------------------
function Write-MDMenuStatus {
    <# The machine block at the top of the main menu. #>
    $facts  = $script:MDMenu.Facts
    $client = $script:MDMenu.ClientInfo

    $computer = $env:COMPUTERNAME
    if ($facts -and $facts['Domain']) { $computer = '{0}   ({1})' -f $computer, $facts['Domain'] }
    Write-MDKeyValue -Key 'Computer' -Value $computer -KeyWidth 16

    if ($facts -and $facts['OS']) {
        $os = [string]$facts['OS']
        if ($facts['Windows release']) { $os = '{0}   {1}' -f $os, $facts['Windows release'] }
        Write-MDKeyValue -Key 'Windows' -Value $os -KeyWidth 16
    }

    if ($client) {
        if ($client.Installed) {
            $version = $client.Version
            if (-not $version) { $version = 'version unknown' }
            Write-MDKeyValue -Key 'Client' -Value ('installed   ' + $version) -KeyWidth 16 -Color $script:MDColors.Ok

            $site = $client.SiteCode
            if (-not $site) { $site = 'unassigned' }
            $mp = $client.ManagementPoint
            if (-not $mp) { $mp = 'not known' }
            Write-MDKeyValue -Key 'Site / MP' -Value ('{0}   /   {1}' -f $site, $mp) -KeyWidth 16
        }
        else {
            Write-MDKeyValue -Key 'Client' -Value 'NOT INSTALLED' -KeyWidth 16 -Color $script:MDColors.Fail
        }
    }

    $context = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    if (Test-MDAdmin) {
        Write-MDKeyValue -Key 'Running as' -Value ($context + '   (elevated)') -KeyWidth 16
    }
    else {
        Write-MDKeyValue -Key 'Running as' -Value ($context + '   NOT ELEVATED') -KeyWidth 16 -Color $script:MDColors.Warn
    }
}


function Show-MDMainMenu {
<#
    .SYNOPSIS
        The main menu.
    .OUTPUTS
        A command name, 'help', 'logfolder', 'elevate', or the quit sentinel.
#>
    Clear-MDScreen

    Write-MDLine ''
    Write-MDRule '=' $script:MDColors.Header
    Write-MDLine '   M E C M   C L I E N T   W I Z A R D' -Color $script:MDColors.Header
    $version = $script:MDVersion
    if (-not $version) { $version = '1.0.0' }
    Write-MDLine ('   mecmdoctor v{0}  --  main menu' -f $version) -Color $script:MDColors.Accent
    Write-MDRule '=' $script:MDColors.Header
    Write-MDLine ''

    Write-MDMenuStatus

    $elevated = Test-MDAdmin

    $choices = @(
        @{ Key = '1'; Label = 'Diagnose';   Help = 'Read-only health check. Changes nothing.' }
        @{ Key = '2'; Label = 'Repair';     Help = 'Diagnose, explain, ask, then fix what is broken.' }
        @{ Key = '3'; Label = 'Bundle';     Help = 'Build a support ZIP for someone else to read.' }
        @{ Key = '4'; Label = 'Logs';       Help = 'Read the CCM logs and translate every error.' }
        @{ Key = '5'; Label = 'Reinstall';  Help = 'Remove and reinstall the client. Last resort.' }
        @{ Key = '6'; Label = 'Help';       Help = 'Full usage, every option and every repair id.' }
        @{ Key = '7'; Label = 'Log folder'; Help = 'Open the folder the transcripts are written to.' }
    )
    if (-not $elevated) {
        $choices += @{ Key = 'E'; Label = 'Elevate'; Help = 'Re-launch as administrator. Repairs need this.'; Color = 'Yellow' }
    }
    $choices += @{ Key = 'Q'; Label = 'Quit'; Help = '' }

    if (-not $elevated) {
        Write-MDLine ''
        Write-MDWarn 'Not elevated: several checks will come back incomplete and no repair can run.'
    }

    Write-MDLine ''
    Write-MDLine '  WHAT DO YOU WANT TO DO?' -Color $script:MDColors.Header

    # No hint line: Q is already on the list, and there is nowhere to go back to.
    $answer = Read-MDMenuChoice -Options $choices -NoBack -NoQuit -Prompt 'Select'
    if ($answer -eq $script:MDMenuQuit) { return $script:MDMenuQuit }

    switch ($answer) {
        '1' { return 'diagnose' }
        '2' { return 'repair' }
        '3' { return 'bundle' }
        '4' { return 'logs' }
        '5' { return 'reinstall' }
        '6' { return 'help' }
        '7' { return 'logfolder' }
        'Q' { return $script:MDMenuQuit }
        'E' { return 'elevate' }
    }
    $script:MDMenuBack
}


function Show-MDPostRun {
<#
    .SYNOPSIS
        What happened, and the obvious next thing to do about it.
    .OUTPUTS
        A command name to run next, 'menu', or the quit sentinel.
#>
    param(
        [Parameter(Mandatory)][hashtable] $Options,
        $Run
    )

    $exitCode = 0
    if ($Run) { $exitCode = [int]$Run.ExitCode }

    $note = switch ($exitCode) {
        0 { 'healthy / completed' }
        1 { 'completed with warnings' }
        2 { 'problems found' }
        3 { 'one or more repair actions failed' }
        4 { 'could not produce the requested output' }
        default { 'completed' }
    }

    $color = $script:MDColors.Ok
    if ($exitCode -eq 1) { $color = $script:MDColors.Warn }
    if ($exitCode -ge 2) { $color = $script:MDColors.Fail }

    Write-MDMenuTitle -Title ($Options.Command + ' finished') -Subtitle ('exit {0} - {1}' -f $exitCode, $note)
    Write-MDLine ''

    $summary = $null
    if ($Run) { $summary = $Run.Summary }

    if ($summary) {
        Write-MDLine ('    {0} passed, {1} warning(s), {2} failure(s).' -f $summary.Pass, $summary.Warn, $summary.Fail) -Color $color
    }
    if ($Run -and $Run.RepairSummary) {
        $r = $Run.RepairSummary
        Write-MDLine ('    Repairs: {0} succeeded, {1} failed, {2} skipped, {3} left for you.' -f $r.Success, $r.Failed, $r.Skipped, $r.Manual) -Color $color
        if ($r.RebootRecommended) {
            Write-MDLine '    A reboot is recommended before the result can be trusted.' -Color $script:MDColors.Warn
        }
    }
    if ($Run -and $Run.BundlePath) {
        Write-MDLine ('    Bundle: ' + $Run.BundlePath) -Color $script:MDColors.Accent
    }
    if ($Run -and $Run.Transcript) {
        Write-MDLine ('    Transcript: ' + $Run.Transcript) -Color $script:MDColors.Detail
    }

    # ---- what makes sense next --------------------------------------------
    # Built as a list and numbered afterwards, so a follow-up that does not
    # apply this time leaves no gap in the numbering.
    $followUps = @()

    $recommended = $null
    if ($summary -and $summary.Recommended) { $recommended = $summary.Recommended }

    switch ($Options.Command) {
        'diagnose' {
            if ($recommended) {
                Write-MDLine ''
                Write-MDLine ('    The diagnosis recommends the {0} repair tier.' -f $recommended) -Color $script:MDColors.Accent
                $followUps += @{ Action = 'repair'; Label = 'Repair it'; Help = 'Fix what was just found. It asks before it changes anything.' }
            }
        }
        'logs' {
            if ($recommended) {
                Write-MDLine ''
                Write-MDLine ('    The errors in these logs point at the {0} repair tier.' -f $recommended) -Color $script:MDColors.Accent
                $followUps += @{ Action = 'repair'; Label = 'Repair it'; Help = 'Fix what the logs implicated. It asks before it changes anything.' }
            }
            $followUps += @{ Action = 'diagnose'; Label = 'Diagnose'; Help = 'Run the full health check as well, not just the logs.' }
        }
        'repair' {
            if (-not $Options.Verify -and -not $Options.DryRun) {
                $followUps += @{ Action = 'diagnose'; Label = 'Re-check it'; Help = 'Diagnose again now the repairs have run. Registration, policy and update scans can take 15 minutes to settle.' }
            }
        }
        'reinstall' {
            $followUps += @{ Action = 'diagnose'; Label = 'Check it'; Help = 'Diagnose the freshly installed client. Give it a few minutes first.' }
        }
    }

    if ($Options.Command -eq 'bundle') {
        if ($Run -and $Run.BundlePath) {
            $followUps += @{ Action = 'openbundle'; Label = 'Open folder'; Help = 'Show the ZIP in Explorer, ready to attach to a ticket.' }
        }
    }
    elseif ($exitCode -ge 1) {
        $followUps += @{ Action = 'bundle'; Label = 'Bundle it'; Help = 'Pack this up for whoever is going to look at it next.' }
    }

    $choices = @()
    $actions = @{}
    $number  = 0
    foreach ($followUp in $followUps) {
        $number++
        $key = "$number"
        $actions[$key] = $followUp.Action
        $choices += @{ Key = $key; Label = $followUp.Label; Help = $followUp.Help }
    }

    $number++
    $menuKey = "$number"
    $choices += @{ Key = $menuKey; Label = 'Main menu'; Help = 'Back to the top.' }
    $choices += @{ Key = 'Q';      Label = 'Quit' }

    $answer = Read-MDMenuChoice -Options $choices -Default $menuKey -NoBack -NoQuit
    if ($answer -eq $script:MDMenuQuit) { return $script:MDMenuQuit }

    $action = $actions[$answer]
    if (-not $action) { return 'menu' }

    if ($action -eq 'openbundle') {
        Open-MDFolder -Path (Split-Path -Parent $Run.BundlePath)
        Read-MDMenuPause
        return 'menu'
    }

    $action
}


function Open-MDFolder {
    <# Show a folder in Explorer. Never fatal: it is a convenience, not a step. #>
    param([string] $Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Write-MDWarn ('There is nothing at {0} to open yet.' -f $Path)
        Write-MDDetail -Indent 4 -Text 'The folder is created by the first run that writes to it.'
        return
    }

    # Server Core ships no Explorer at all, so falling into the catch below
    # would report a deliberately absent OS feature as a failure. Printing the
    # path is the entire useful outcome either way - checking first just stops
    # it looking like something went wrong.
    $explorer = Join-Path $env:windir 'explorer.exe'
    if (-not (Test-Path -LiteralPath $explorer)) {
        Write-MDInfo 'This installation has no Explorer (Server Core), so here is the path instead.'
        Write-MDKeyValue -Key 'Folder' -Value $Path -Indent 4
        return
    }

    try {
        Start-Process -FilePath $explorer -ArgumentList ('"' + $Path + '"') -ErrorAction Stop
        Write-MDOk ('Opened {0}' -f $Path)
    }
    catch {
        Write-MDWarn ('Could not open Explorer: {0}' -f $_.Exception.Message)
        Write-MDKeyValue -Key 'Folder' -Value $Path -Indent 4
    }
}


function Invoke-MDElevate {
<#
    .SYNOPSIS
        Re-launch the menu with administrative rights.
    .DESCRIPTION
        Prefers mecmdoctor.bat, which is what an operator would have run in the
        first place and which keeps the elevated window open. Falls back to
        PowerShell against the entry script.
    .OUTPUTS
        $true when a new process was started and this one should stand down.
#>
    param([string] $ScriptRoot)

    Write-MDLine ''
    Write-MDInfo 'Windows will ask you to approve the elevated process.'

    $launcher = Join-Path $ScriptRoot 'mecmdoctor.bat'
    $entry    = Join-Path $ScriptRoot 'MECMDoctor.ps1'

    # Carry -NoClear across, so a session deliberately kept in the scrollback
    # does not start clearing the screen the moment it is elevated.
    $extra = ''
    if (-not $script:MDMenu.Clear) { $extra = ' -NoClear' }

    try {
        if (Test-Path -LiteralPath $launcher) {
            Start-Process -FilePath $launcher -ArgumentList ('--elevated menu' + $extra) `
                          -WorkingDirectory $ScriptRoot -Verb RunAs -ErrorAction Stop
        }
        else {
            $arguments = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $entry + '"'), 'menu')
            if ($extra) { $arguments += '-NoClear' }
            Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
                          -WorkingDirectory $ScriptRoot -Verb RunAs -ErrorAction Stop
        }
    }
    catch {
        Write-MDLine ''
        Write-MDFail ('Elevation was declined or failed: {0}' -f $_.Exception.Message)
        Write-MDDetail -Indent 4 -Text 'Open an administrative command prompt in this folder and run mecmdoctor again.'
        Read-MDMenuPause
        return $false
    }

    Write-MDLine ''
    Write-MDOk 'An elevated mecmdoctor has been started. This window is finished with.'
    return $true
}


function Initialize-MDMenu {
<#
    .SYNOPSIS
        Seeds the menu from the command line it was started with.
    .DESCRIPTION
        Options given on the way in - mecmdoctor -Days 14, for instance -
        become the menu's starting defaults rather than being thrown away.
#>
    param(
        [hashtable] $Defaults,
        [string]    $LogDirectory,
        [string]    $ScriptRoot,
        [switch]    $NoClear
    )

    $seed = New-MDRunOptions -Command 'diagnose' -From $Defaults

    # The one place the menu's defaults differ from the command line's. A
    # repair started from here re-runs the diagnosis afterwards unless the
    # operator turns it off, because the person who chose a menu is the person
    # who wants to be shown the result rather than told it.
    $seed.Verify = $true

    $script:MDMenu.Defaults     = $seed
    $script:MDMenu.LogDirectory = $LogDirectory
    $script:MDMenu.ScriptRoot   = $ScriptRoot
    $script:MDMenu.Clear        = (-not $NoClear)
    $script:MDMenu.Blanks       = 0
    $script:MDMenu.NeedsRefresh = $true
}
