# uninstall-windows.ps1 - removes everything install-windows.ps1 set up
#
# Stops the tray app, removes the login-autostart entry (HKCU\...\Run), deletes
# the repo's .venv, and deletes %LOCALAPPDATA%\Clawdmeter (config, daemon.log,
# latest.json). No admin required. Safe to re-run: anything already gone is
# skipped.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File uninstall-windows.ps1
#
# Not touched: the repository itself, your Claude Code login
# (%USERPROFILE%\.claude), and the Bluetooth pairing (remove that in
# Settings -> Bluetooth & devices).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log {
    param([string]$Msg)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $Msg"
}

$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) {
    $RepoRoot = (Get-Location).Path
}

Log "=== Clawdmeter Windows Uninstall ==="
Log "Repository root: $RepoRoot"

# ------------------------------------------------------------------
# Step 1: Stop the tray app (and a foreground daemon, if one is running)
# ------------------------------------------------------------------
# Matched by script name on the command line so unrelated Python processes are
# left alone. This must happen before Step 3: the tray loads the venv's
# site-packages, which keeps files in .venv locked while it runs.
$procs = @(Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'tray_windows\.py|claude_usage_daemon_windows\.py' })
if ($procs.Count -gt 0) {
    foreach ($p in $procs) {
        Log "Stopping Clawdmeter process $($p.ProcessId) ..."
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Wait-Process -Id ($procs | ForEach-Object { $_.ProcessId }) -Timeout 10 -ErrorAction SilentlyContinue
    Log "Tray app stopped (a leftover icon disappears when you hover over it)"
} else {
    Log "Tray app not running - skipping"
}

# ------------------------------------------------------------------
# Step 2: Remove the login-autostart entry
# ------------------------------------------------------------------
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Get-ItemProperty -Path $RunKey -Name Clawdmeter -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $RunKey -Name Clawdmeter
    Log "Autostart entry removed"
} else {
    Log "No autostart entry - skipping"
}

# ------------------------------------------------------------------
# Step 3: Delete the virtual environment
# ------------------------------------------------------------------
$VenvDir = Join-Path $RepoRoot ".venv"
if (Test-Path $VenvDir) {
    Log "Deleting virtual environment at .venv ..."
    Remove-Item -Recurse -Force $VenvDir
    Log "Virtual environment deleted"
} else {
    Log "No .venv - skipping"
}

# ------------------------------------------------------------------
# Step 4: Delete config, logs, and the latest-payload mirror
# ------------------------------------------------------------------
$DataDir = Join-Path $env:LOCALAPPDATA "Clawdmeter"
if (Test-Path $DataDir) {
    Remove-Item -Recurse -Force $DataDir
    Log "Deleted $DataDir"
} else {
    Log "No $DataDir - skipping"
}

Log "=== Uninstall complete ==="
Log "To unpair the device: Settings -> Bluetooth & devices -> Clawdmeter -> Remove device"
