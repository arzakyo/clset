<#
.SYNOPSIS
    Portable installer for clset on any Windows PC.
.EXAMPLE
    irm https://raw.githubusercontent.com/arzakyo/clset/main/install.ps1 | iex
#>
param(
    [string]$InstallDir = "$env:USERPROFILE\bin",
    [string]$Repo = "arzakyo/clset",
    [string]$Branch = "main",
    [switch]$SkipInit
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$files = @("clset.ps1", "clset.cmd", "clset")
$scriptRoot = if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "clset.ps1"))) { $PSScriptRoot } else { $null }

foreach ($f in $files) {
    $dest = Join-Path $InstallDir $f
    if ($scriptRoot) {
        Copy-Item -Force -Path (Join-Path $scriptRoot $f) -Destination $dest
    } elseif ($Repo) {
        $url = "https://raw.githubusercontent.com/$Repo/$Branch/$f"
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
    } else {
        throw "Run install.ps1 from the cloned repo folder, or pass -Repo '<owner>/clset'."
    }
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ";") -notcontains $InstallDir) {
    $newPath = if ($userPath) { "$userPath;$InstallDir" } else { $InstallDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:Path += ";$InstallDir"
    Write-Host "Added $InstallDir to User PATH."
}

Write-Host "Installed clset to $InstallDir"
if (-not $SkipInit) {
    & (Join-Path $InstallDir "clset.cmd") init
}
