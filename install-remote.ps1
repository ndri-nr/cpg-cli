<#
.SYNOPSIS
  One-liner installer - no `git clone` needed first:
    irm https://raw.githubusercontent.com/ndri-nr/compose-playground/main/install-remote.ps1 | iex

  Clones the repo (or pulls latest if already cloned) into $env:COMPOSE_PLAYGROUND_DIR
  (default ~/compose-playground), then runs its install.ps1 to wire up `cpg`.
#>
$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/ndri-nr/compose-playground.git"
$TargetDir = if ($env:COMPOSE_PLAYGROUND_DIR) { $env:COMPOSE_PLAYGROUND_DIR } else { Join-Path $HOME "compose-playground" }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host "git is required but not found on PATH. Install git first."
  exit 1
}

if (Test-Path (Join-Path $TargetDir ".git")) {
  Write-Host "Already cloned at $TargetDir - pulling latest..."
  git -C $TargetDir pull --ff-only
} else {
  Write-Host "Cloning into $TargetDir..."
  git clone $RepoUrl $TargetDir
}

& (Join-Path $TargetDir "install.ps1")
