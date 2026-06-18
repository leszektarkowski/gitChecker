#Requires -Version 5.1
<#
.SYNOPSIS
    Stop and remove the gitchecker Windows service.

.DESCRIPTION
    Stops the service, deletes its registration, and removes the installed
    binary under %ProgramData%. Leaves the config and database in place unless
    -Purge is given. Must be run from an elevated (Administrator) prompt.

.PARAMETER Purge
    Also delete the service account's config + database
    (under the system profile's AppData).
#>
[CmdletBinding()]
param(
    [string] $ServiceName = 'gitchecker',
    [switch] $Purge
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal] $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Removing a Windows service requires an elevated prompt."
    Write-Host "Re-run from an Administrator PowerShell:" -ForegroundColor Yellow
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Yellow
    exit 1
}

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "==> Stopping and deleting service '$ServiceName'" -ForegroundColor Cyan
    & sc.exe stop $ServiceName | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -eq 'Stopped') { break }
        Start-Sleep -Milliseconds 250
    }
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Milliseconds 500
    Write-Host "OK  removed service '$ServiceName'" -ForegroundColor Green
}
else {
    Write-Host "Service '$ServiceName' is not installed." -ForegroundColor Yellow
}

$installDir = Join-Path $env:ProgramData 'gitchecker\bin'
if (Test-Path $installDir) {
    Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
    Write-Host "OK  removed $installDir" -ForegroundColor Green
}

if ($Purge) {
    $svcData = Join-Path $env:SystemRoot 'System32\config\systemprofile\AppData\Roaming\gitchecker'
    if (Test-Path $svcData) {
        Remove-Item -Recurse -Force $svcData
        Write-Host "OK  purged service config/database -> $svcData" -ForegroundColor Green
    }
}
