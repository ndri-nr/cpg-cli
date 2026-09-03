<#
.SYNOPSIS
  One-liner installer - no `git clone` needed first:
    irm https://raw.githubusercontent.com/ndri-nr/cpg-cli/main/install-remote.ps1 | iex

  Clones the repo (or pulls latest if already cloned) into $env:CPG_CLI_DIR
  (default ~/cpg-cli), then runs its install.ps1 to wire up `cpg`.
#>
$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/ndri-nr/cpg-cli.git"
$TargetDir = if ($env:CPG_CLI_DIR) { $env:CPG_CLI_DIR } else { Join-Path $HOME "cpg-cli" }

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
