#Requires -Version 5.1
<#
.SYNOPSIS
    Stop and remove the gitchecker logon Scheduled Task.

.DESCRIPTION
    Stops the running server, unregisters the Scheduled Task, and removes the
    installed binary under %ProgramData%. Leaves your config + database in place
    unless -Purge is given. Self-elevates via UAC.

.PARAMETER Purge
    Also delete your config + database (under %APPDATA%\gitchecker).
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'gitchecker',
    [switch] $Purge
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal] $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges (a UAC prompt will appear)..." -ForegroundColor Yellow
    function Quote([string] $s) { '"' + ($s -replace '"', '\"') + '"' }
    $fwd = @('-TaskName', (Quote $TaskName))
    if ($Purge) { $fwd += '-Purge' }
    $argLine = "-NoExit -ExecutionPolicy Bypass -File $(Quote $PSCommandPath) " + ($fwd -join ' ')
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null }
    catch { Write-Warning "Elevation was declined; nothing was removed."; exit 1 }
    exit 0
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "==> Stopping and unregistering task '$TaskName'" -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "OK  removed task '$TaskName'" -ForegroundColor Green
}
else {
    Write-Host "Task '$TaskName' is not registered." -ForegroundColor Yellow
}

# Stop any still-running server process.
Get-Process gitchecker -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$installDir = Join-Path $env:ProgramData 'gitchecker\bin'
if (Test-Path $installDir) {
    Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
    Write-Host "OK  removed $installDir" -ForegroundColor Green
}

if ($Purge) {
    $data = Join-Path $env:APPDATA 'gitchecker'
    if (Test-Path $data) {
        Remove-Item -Recurse -Force $data
        Write-Host "OK  purged config/database -> $data" -ForegroundColor Green
    }
}
