@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ===========================================================================
rem  MECM Client Wizard  --  mecmdoctor.bat
rem ---------------------------------------------------------------------------
rem  Launcher for MECMDoctor.ps1. It exists so that an operator on a broken
rem  machine can type one word and get a result, without fighting the execution
rem  policy or remembering to open an elevated prompt first.
rem
rem  It does four things:
rem    1. runs PowerShell with -ExecutionPolicy Bypass, so an unsigned script
rem       in a locked-down environment still runs
rem    2. re-launches itself elevated when it is not already running as admin
rem       (skipped for help and version, which need no privileges)
rem    3. passes every argument through to MECMDoctor.ps1 untouched
rem    4. keeps the window open when it was started by double-click
rem
rem  Usage:
rem    mecmdoctor                      the menu - pick a command, answer a few
rem                                    questions, watch it run, pick the next
rem    mecmdoctor diagnose
rem    mecmdoctor repair -Level Safe
rem    mecmdoctor logs -Days 14
rem    mecmdoctor bundle
rem    mecmdoctor help
rem ===========================================================================

rem  Capture our own path BEFORE the argument loop below. That loop uses shift,
rem  and shift moves %0 as well - so %~f0 stops pointing at this file as soon
rem  as the first argument has been consumed.
set "SELF=%~f0"
set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%MECMDoctor.ps1"
set "PAUSEATEND="
set "FIRSTARG="

rem --- locate the PowerShell script -------------------------------------------
if not exist "%PS1%" (
    echo.
    echo   [FAIL] MECMDoctor.ps1 was not found next to this launcher.
    echo          Expected: "%PS1%"
    echo          Copy the whole folder, not just this .bat file.
    echo.
    exit /b 4
)

rem --- rebuild the argument list ----------------------------------------------
rem  Looping with shift instead of using %* lets us strip the internal
rem  --elevated marker while preserving the original quoting of every argument.
rem  Note the use of %1 rather than %~1: that keeps any quotes the caller wrote.
set "ARGS="

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--elevated" (
    set "PAUSEATEND=1"
    shift
    goto parse_args
)
if not defined FIRSTARG set "FIRSTARG=%~1"
set "ARGS=!ARGS! %1"
shift
goto parse_args
:args_done

rem --- keep the window open when double-clicked --------------------------------
rem  A double-clicked .bat runs as:  cmd /c ""C:\path\mecmdoctor.bat" "
rem  A .bat started from an existing console has no /c in cmdcmdline.
echo %cmdcmdline% | find /i "/c" >nul 2>&1
if not errorlevel 1 set "PAUSEATEND=1"

rem --- commands that never need elevation --------------------------------------
if /i "!FIRSTARG!"=="help"    goto run_script
if /i "!FIRSTARG!"=="version" goto run_script
if /i "!FIRSTARG!"=="-?"      goto run_script
if /i "!FIRSTARG!"=="/?"      goto run_script
if /i "!FIRSTARG!"=="--help"  goto run_script

rem --- reject an unknown command before asking for elevation -------------------
rem  Otherwise a typo pops a UAC prompt and only then reports the mistake.
rem  A leading - or / means the caller went straight to options, which is fine:
rem  the PowerShell script defaults to "diagnose".
if not defined FIRSTARG goto elevation_check
set "FIRSTCHAR=!FIRSTARG:~0,1!"
if "!FIRSTCHAR!"=="-" goto elevation_check
if "!FIRSTCHAR!"=="/" goto elevation_check
if /i "!FIRSTARG!"=="menu"      goto elevation_check
if /i "!FIRSTARG!"=="diagnose"  goto elevation_check
if /i "!FIRSTARG!"=="repair"    goto elevation_check
if /i "!FIRSTARG!"=="logs"      goto elevation_check
if /i "!FIRSTARG!"=="bundle"    goto elevation_check
if /i "!FIRSTARG!"=="reinstall" goto elevation_check

echo.
echo   [FAIL] Unknown command: !FIRSTARG!
echo          Valid commands: menu, diagnose, repair, logs, bundle, reinstall, help, version
echo          Run "mecmdoctor help" for the full usage.
echo.
if defined PAUSEATEND pause
exit /b 4

:elevation_check

rem --- elevation check ---------------------------------------------------------
rem  "net session" fails against a non-elevated token. It is the most portable
rem  admin test that does not require PowerShell to already be running.
net session >nul 2>&1
if not errorlevel 1 goto run_script

echo.
echo   [ ^>^> ] Administrative rights are required. Requesting elevation...
echo.

rem  Escape any double quotes in the argument list so that they survive the trip
rem  through cmd and into the PowerShell -Command string.
set "ESCARGS=!ARGS!"
if defined ESCARGS set "ESCARGS=!ESCARGS:"=\"!"

rem  -WorkingDirectory keeps the elevated copy in this folder. Without it the
rem  elevated process starts in system32, which would change where a
rem  ClientReinstall.ps1 in the current directory is looked for.
powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -Command "Start-Process -FilePath '!SELF!' -ArgumentList '--elevated!ESCARGS!' -WorkingDirectory '%SCRIPT_DIR%' -Verb RunAs"
if errorlevel 1 (
    echo.
    echo   [FAIL] Elevation was declined or failed.
    echo          Open an administrative command prompt and run this again.
    echo.
    if defined PAUSEATEND pause
    exit /b 4
)

rem  The elevated copy owns the run from here; this instance is finished.
exit /b 0

rem --- run ----------------------------------------------------------------------
:run_script
powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%PS1%"!ARGS!
set "RC=%ERRORLEVEL%"

if defined PAUSEATEND (
    echo.
    pause
)

endlocal & exit /b %RC%
