#Requires -Version 5.1
<#
.SYNOPSIS
    Build the gitchecker Rust server and register it as a Windows service.

.DESCRIPTION
    The Windows counterpart of the macOS launchd LaunchAgent (dist/install.sh).
    It:
      1. builds the release server (warns if Rust/cargo is missing);
      2. copies the binary to a stable location under %ProgramData%;
      3. seeds a config for the service account (if none exists) so it scans the
         right folders out of the box;
      4. registers it as an auto-start Windows service that restarts on crash;
      5. starts it and waits for the HTTP API to come up.

    Re-run any time to upgrade to a fresh build - it stops, replaces and restarts
    the service in place. Must be run from an elevated (Administrator) prompt.

.PARAMETER ScanRoots
    One or more absolute folders the service should scan for git repos. Only used
    when seeding a brand-new service config. Default: %USERPROFILE%\code.

.PARAMETER SkipBuild
    Register using the already-built target\release\gitchecker.exe (don't rebuild).

.EXAMPLE
    # From an Administrator PowerShell:
    dist\windows\install-service.ps1 -ScanRoots 'C:\Users\me\code','D:\work'
#>
[CmdletBinding()]
param(
    [string[]] $ScanRoots = @("$env:USERPROFILE\code"),
    [string]   $ServiceName = 'gitchecker',
    [switch]   $SkipBuild
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path

# --- must be elevated: sc.exe create requires Administrator ------------------
# If we're not already elevated, relaunch this script via UAC ("Run as
# administrator") instead of asking the user to open an admin terminal.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal] $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges (a UAC prompt will appear)..." -ForegroundColor Yellow

    # Forward the original arguments to the elevated instance. Double-quote each
    # value so paths containing spaces survive the relaunch.
    function Quote([string] $s) { '"' + ($s -replace '"', '\"') + '"' }
    $fwd = [System.Collections.Generic.List[string]]::new()
    $fwd.Add('-ScanRoots'); foreach ($r in $ScanRoots) { $fwd.Add((Quote $r)) }
    $fwd.Add('-ServiceName'); $fwd.Add((Quote $ServiceName))
    if ($SkipBuild) { $fwd.Add('-SkipBuild') }

    # -NoExit keeps the elevated window open so the result stays visible.
    $argLine = "-NoExit -ExecutionPolicy Bypass -File $(Quote $PSCommandPath) " + ($fwd -join ' ')
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    }
    catch {
        Write-Warning "Elevation was declined or failed; nothing was installed."
        exit 1
    }
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

# --- 2. install the binary to a stable, space-free location ------------------
$installDir = Join-Path $env:ProgramData 'gitchecker\bin'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$exe = Join-Path $installDir 'gitchecker.exe'

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing -and $existing.Status -ne 'Stopped') {
    Write-Host "==> Stopping running service '$ServiceName'" -ForegroundColor Cyan
    & sc.exe stop $ServiceName | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        if ((Get-Service $ServiceName).Status -eq 'Stopped') { break }
        Start-Sleep -Milliseconds 250
    }
}
Copy-Item -Force $builtExe $exe
Write-Host "OK  installed server -> $exe" -ForegroundColor Green

# --- 3. seed config for the LocalSystem service account, if absent -----------
# The service runs as LocalSystem, whose roaming AppData lives under the system
# profile. gitchecker writes/reads <RoamingAppData>\gitchecker\config\config.toml.
$svcConfigDir = Join-Path $env:SystemRoot 'System32\config\systemprofile\AppData\Roaming\gitchecker\config'
$svcConfig    = Join-Path $svcConfigDir 'config.toml'
if (-not (Test-Path $svcConfig)) {
    New-Item -ItemType Directory -Force -Path $svcConfigDir | Out-Null
    # TOML literal strings (single-quoted) keep Windows backslashes verbatim.
    $roots = ($ScanRoots | ForEach-Object { "'$_'" }) -join ', '
    $toml = @"
# gitchecker service configuration.
# The service runs as LocalSystem, so every path here must be absolute.
scan_roots = [$roots]
scan_excludes = ['node_modules', 'target', 'vendor', '.cache']
scan_interval_secs = 86400
check_interval_secs = 300
fetch_interval_secs = 1800
# LocalSystem has no user git credentials, so SSH fetches will fail (handled
# gracefully). Set false to skip the network entirely; 'behind origin' will then
# reflect cached remote refs only.
fetch_enabled = true
listen_addr = "127.0.0.1:7878"
"@
    # UTF-8 without BOM - the Rust TOML parser does not strip a BOM.
    [System.IO.File]::WriteAllText($svcConfig, $toml, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "OK  wrote service config -> $svcConfig" -ForegroundColor Green
    Write-Host "    scan_roots = [$roots]" -ForegroundColor DarkGray
}
else {
    Write-Host "==> Keeping existing service config -> $svcConfig" -ForegroundColor Cyan
}

# --- 4. (re)register the service ---------------------------------------------
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "==> Replacing existing service definition" -ForegroundColor Cyan
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Milliseconds 500
}

# $exe lives under %ProgramData% (no spaces), so the unquoted "exe --service"
# form is unambiguous to the SCM and avoids PowerShell 5.1 quote mangling.
$binPath = "$exe --service"
Write-Host "==> Creating service '$ServiceName'" -ForegroundColor Cyan
& sc.exe create $ServiceName binPath= $binPath start= auto DisplayName= "gitchecker (git status service)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "sc.exe create failed (exit $LASTEXITCODE)" }

& sc.exe description $ServiceName "Periodically reports the status of your git repositories over a local HTTP API (http://127.0.0.1:7878)." | Out-Null
# Restart on crash, mirroring the macOS LaunchAgent's KeepAlive: retry three
# times (5s apart), reset the failure counter after a day running clean.
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

# --- 5. start and wait for the API -------------------------------------------
Write-Host "==> Starting service" -ForegroundColor Cyan
& sc.exe start $ServiceName | Out-Null

$up = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:7878/healthz' -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $up = $true; break }
    }
    catch { Start-Sleep -Milliseconds 500 }
}

if ($up) {
    Write-Host "`n[OK] Service '$ServiceName' is running; API is up at http://127.0.0.1:7878" -ForegroundColor Green
}
else {
    Write-Warning "Service registered, but the API has not responded yet. Check:  sc.exe query $ServiceName"
}

Write-Host @"

   * Service:  $ServiceName  (auto-start, restarts on crash)
   * Binary:   $exe
   * Config:   $svcConfig
   * Manage:   sc.exe query $ServiceName  /  sc.exe stop $ServiceName  /  sc.exe start $ServiceName
   * Remove:   dist\windows\uninstall-service.ps1
"@ -ForegroundColor Gray
