<#
.SYNOPSIS
  Installs the `cpg` command globally (works from any directory, any shell) by dropping
  wrapper scripts into %USERPROFILE%\.local\bin and adding that folder to your User PATH.

  Two wrappers are written so the same `cpg` name works everywhere on Windows:
    - cpg.cmd  -> picked up by PowerShell / cmd.exe (PATHEXT resolution)
    - cpg      -> picked up by Git Bash (plain PATH lookup, ignores cpg.cmd)

.NOTES
  Open a NEW terminal after installing for the PATH change to take effect.
#>
$ErrorActionPreference = "Stop"

# Everything cpg drives is docker compose - no point wiring up the command if either
# piece is missing. Offers a best-effort install via winget, but always leaves the
# final call (and the UAC prompt) to the user.
function Test-DockerAvailable {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
  docker compose version *> $null
  return $LASTEXITCODE -eq 0
}

if (-not (Test-DockerAvailable)) {
  Write-Host "Docker (or the 'docker compose' plugin) isn't available on this machine."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    $yn = Read-Host "Install Docker Desktop now via winget? (y/n)"
    if ($yn -match '^[Yy]') {
      winget install -e --id Docker.DockerDesktop
      Write-Host ""
      Write-Host "Installed (or install started). Open Docker Desktop once from the Start"
      Write-Host "Menu and wait for it to say `"running`", then re-run this installer"
      Write-Host "(./install.ps1)."
      exit 0
    }
  }
  Write-Host "Install Docker yourself: https://docs.docker.com/get-docker/"
  Write-Host "(the compose plugin comes bundled with any current Docker install)"
  exit 1
}

$RepoRoot = $PSScriptRoot
$InstallDir = Join-Path $HOME ".local\bin"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# --- cmd.exe / PowerShell wrapper ---
$cmdWrapper = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$RepoRoot\cpg-cli.ps1`" %*`r`n"
Set-Content -Path (Join-Path $InstallDir "cpg.cmd") -Value $cmdWrapper -Encoding ascii -NoNewline

# --- Git Bash wrapper (forward slashes, LF line ending) ---
$repoRootUnix = $RepoRoot -replace '\\', '/'
$bashWrapper = "#!/usr/bin/env bash`nexec `"$repoRootUnix/cpg-cli.sh`" `"`$@`"`n"
$bashPath = Join-Path $InstallDir "cpg"
[System.IO.File]::WriteAllText($bashPath, ($bashWrapper -replace "`r`n", "`n"))

Write-Host "Installed:"
Write-Host "  $InstallDir\cpg.cmd -> $RepoRoot\cpg-cli.ps1  (PowerShell/cmd)"
Write-Host "  $InstallDir\cpg     -> $RepoRoot\cpg-cli.sh   (Git Bash)"

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
  Write-Host ""
  Write-Host "Added $InstallDir to your User PATH."
  Write-Host "Open a NEW terminal, then: cpg status"
} else {
  Write-Host ""
  Write-Host "Already on PATH. Try: cpg status"
}
