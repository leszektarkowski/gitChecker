#Requires -Version 5.1
<#
.SYNOPSIS
    Build the gitchecker Rust server (release) for Windows.

.DESCRIPTION
    Warns and exits with a non-zero code if the Rust toolchain (cargo) is not on
    PATH. On success, builds the optimized binary and prints its path. The
    resulting gitchecker.exe is service-aware: launched as `gitchecker.exe
    --service` it runs under the Windows Service Control Manager; launched plainly
    it runs in the foreground.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Warning "Rust toolchain not found - 'cargo' is not on PATH."
    Write-Host   "Install it from https://rustup.rs and re-run this script." -ForegroundColor Yellow
    exit 1
}

Write-Host "==> cargo build --release" -ForegroundColor Cyan
Push-Location $RepoRoot
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
}

$exe = Join-Path $RepoRoot 'target\release\gitchecker.exe'
if (-not (Test-Path $exe)) { throw "build reported success but $exe is missing" }

Write-Host "OK  built $exe" -ForegroundColor Green
