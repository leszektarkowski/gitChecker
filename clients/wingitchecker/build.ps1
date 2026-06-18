#Requires -Version 5.1
<#
.SYNOPSIS
    Build the WinGitChecker system-tray client.

.DESCRIPTION
    Warns and exits if the .NET SDK (dotnet) is not on PATH. By default it
    publishes a ready-to-run build into clients\wingitchecker\publish; pass
    -Mode build for a plain debug-style Release build under bin\Release.

.PARAMETER Mode
    'publish' (default) - produce a runnable build in .\publish.
    'build'             - just compile (bin\Release\net10.0-windows).

.PARAMETER SelfContained
    Publish a standalone build that bundles the .NET runtime (no SDK needed to
    run). Larger output. Only meaningful with -Mode publish.

.EXAMPLE
    clients\wingitchecker\build.ps1                 # framework-dependent publish
    clients\wingitchecker\build.ps1 -SelfContained  # standalone exe
#>
[CmdletBinding()]
param(
    [ValidateSet('publish', 'build')] [string] $Mode = 'publish',
    [switch] $SelfContained
)

$ErrorActionPreference = 'Stop'
$ProjDir = $PSScriptRoot
$Proj = Join-Path $ProjDir 'WinGitChecker.csproj'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Warning ".NET SDK not found - 'dotnet' is not on PATH."
    Write-Host   "Install the .NET 10 SDK from https://dotnet.microsoft.com/download and re-run." -ForegroundColor Yellow
    exit 1
}

if ($Mode -eq 'build') {
    Write-Host "==> dotnet build -c Release" -ForegroundColor Cyan
    dotnet build $Proj -c Release --nologo
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host "OK  built -> $ProjDir\bin\Release\net10.0-windows\WinGitChecker.exe" -ForegroundColor Green
    return
}

$outDir = Join-Path $ProjDir 'publish'
$sc = [bool]$SelfContained
Write-Host "==> dotnet publish -c Release -r win-x64 (self-contained: $sc)" -ForegroundColor Cyan
dotnet publish $Proj -c Release -r win-x64 --self-contained $sc -o $outDir --nologo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$exe = Join-Path $outDir 'WinGitChecker.exe'
Write-Host "OK  published -> $exe" -ForegroundColor Green
Write-Host "    Start at login: drop a shortcut to it into 'shell:startup' (Win+R -> shell:startup)." -ForegroundColor DarkGray
