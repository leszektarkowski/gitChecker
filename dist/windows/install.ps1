#Requires -Version 5.1
<#
.SYNOPSIS
    Build the gitchecker server and run it at logon via a per-user Scheduled Task.

.DESCRIPTION
    The Windows analog of the macOS per-user LaunchAgent. The server runs as YOU
    (your interactive logon), not as LocalSystem - so it owns your repositories
    (no "dubious ownership" errors) and has your git credentials for fetching.

    It:
      1. builds the release server (warns if Rust/cargo is missing);
      2. removes any leftover LocalSystem 'gitchecker' service from the older
         service-based install;
      3. copies the binary to %ProgramData%\gitchecker\bin (shared, user-run);
      4. registers a Scheduled Task that starts the server at logon, hidden, as
         your user, restarting on crash;
      5. starts it now and waits for the HTTP API to come up.

    Needs Administrator rights (to remove the old service and register the task);
    it self-elevates via a UAC prompt. The task itself runs un-elevated as you.

.PARAMETER SkipBuild
    Register using the already-built target\release\gitchecker.exe.
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'gitchecker',
    # Internal: the real interactive user, forwarded across self-elevation so the
    # task runs as them even if a different admin approves the UAC prompt.
    [string] $RunAsUser,
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path

# Capture the real user BEFORE elevation (after RunAs, these may be the admin's).
if (-not $RunAsUser) { $RunAsUser = "$env:USERDOMAIN\$env:USERNAME" }

# --- self-elevate: removing the old service + registering the task need admin --
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal] $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges (a UAC prompt will appear)..." -ForegroundColor Yellow
    function Quote([string] $s) { '"' + ($s -replace '"', '\"') + '"' }
    $fwd = [System.Collections.Generic.List[string]]::new()
    $fwd.Add('-TaskName');  $fwd.Add((Quote $TaskName))
    $fwd.Add('-RunAsUser'); $fwd.Add((Quote $RunAsUser))
    if ($SkipBuild) { $fwd.Add('-SkipBuild') }
    $argLine = "-NoExit -ExecutionPolicy Bypass -File $(Quote $PSCommandPath) " + ($fwd -join ' ')
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null }
    catch { Write-Warning "Elevation was declined; nothing was installed."; exit 1 }
    exit 0
}

# --- 1. build (also warns if Rust is unavailable) ----------------------------
if (-not $SkipBuild) {
    & "$PSScriptRoot\build-server.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$builtExe = Join-Path $RepoRoot 'target\release\gitchecker.exe'
if (-not (Test-Path $builtExe)) {
    throw "server binary not found: $builtExe (build it, or drop -SkipBuild)"
}

# --- 2. tear down the old LocalSystem service install, if present ------------
if (Get-Service -Name 'gitchecker' -ErrorAction SilentlyContinue) {
    Write-Host "==> Removing old LocalSystem service 'gitchecker'" -ForegroundColor Cyan
    & sc.exe stop 'gitchecker' | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        $svc = Get-Service 'gitchecker' -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -eq 'Stopped') { break }
        Start-Sleep -Milliseconds 250
    }
    & sc.exe delete 'gitchecker' | Out-Null
    Start-Sleep -Milliseconds 500
    # The old service ran as SYSTEM and wrote a config under the system profile
    # with the wrong (systemprofile) scan roots - drop it so the per-user run
    # uses your real ~/code config instead.
    $oldCfg = Join-Path $env:SystemRoot 'System32\config\systemprofile\AppData\Roaming\gitchecker'
    if (Test-Path $oldCfg) { Remove-Item -Recurse -Force $oldCfg -ErrorAction SilentlyContinue }
}
# Stop any stray running copy before replacing the binary.
Get-Process gitchecker -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# --- 3. install the binary to a shared, user-readable location --------------
$installDir = Join-Path $env:ProgramData 'gitchecker\bin'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$exe = Join-Path $installDir 'gitchecker.exe'
Copy-Item -Force $builtExe $exe
Write-Host "OK  installed server -> $exe" -ForegroundColor Green

# --- 4. register the logon Scheduled Task (runs as YOU) ----------------------
# Launch the (console) server through a hidden PowerShell host so no console
# window is ever shown; that host stays as the parent, so the task reports
# Running and Stop-ScheduledTask cleanly stops the server. (Launching the exe
# directly flashes a console; launching it detached makes Task Scheduler lose
# track of it - the hidden-host wrapper is the combination that actually works.)
$inner = "& '$exe'"
$taskArgs = '-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -Command "' + $inner + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs

# Two independent triggers:
#   - AtLogOn           → start as soon as you log in.
#   - a 5-min heartbeat → a standalone repeating trigger. With
#                         MultipleInstances=IgnoreNew it's a no-op while the server
#                         is running, but RESTARTS it within ~5 min if it ever died
#                         (covers crashes and the gap restart-on-failure misses).
# The heartbeat MUST be its own trigger, not grafted onto the logon trigger -
# a logon trigger's repetition only runs after an actual logon event.
$logon = New-ScheduledTaskTrigger -AtLogOn -User $RunAsUser
$heartbeat = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)

# Limited (not Highest): a normal, un-elevated token - the same one your shell
# uses - so the server owns your repos and reads your git credentials.
$principal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

Write-Host "==> Registering Scheduled Task '$TaskName' (run as $RunAsUser at logon)" -ForegroundColor Cyan
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $heartbeat) `
    -Principal $principal -Settings $settings -Force `
    -Description "Runs the gitchecker server at logon and reports git repo status over http://127.0.0.1:7878." | Out-Null

# --- 5. start now and wait for the API --------------------------------------
Write-Host "==> Starting task" -ForegroundColor Cyan
Start-ScheduledTask -TaskName $TaskName

$up = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:7878/healthz' -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $up = $true; break }
    }
    catch { Start-Sleep -Milliseconds 500 }
}

if ($up) {
    Write-Host "`n[OK] Task '$TaskName' is running as $RunAsUser; API is up at http://127.0.0.1:7878" -ForegroundColor Green
}
else {
    Write-Warning "Task registered, but the API has not responded yet. Check:  Get-ScheduledTaskInfo $TaskName"
}

Write-Host @"

   * Task:    $TaskName  (runs at logon as $RunAsUser, restarts on crash)
   * Binary:  $exe
   * Config:  %APPDATA%\gitchecker\config\config.toml  (your profile; scans ~/code by default)
   * Manage:  Start-ScheduledTask $TaskName  /  Stop-ScheduledTask $TaskName  /  Get-ScheduledTaskInfo $TaskName
   * Remove:  dist\windows\uninstall.ps1
"@ -ForegroundColor Gray
