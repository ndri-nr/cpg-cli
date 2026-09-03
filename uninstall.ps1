<#
.SYNOPSIS
  Removes the `cpg` command installed by install.ps1 (the ~/.local/bin wrapper only -
  doesn't touch this repo, your containers, or your volumes/data). Also offers to
  remove that folder from your User PATH if install.ps1 added it.
#>
$ErrorActionPreference = "Stop"

$InstallDir = Join-Path $HOME ".local\bin"
$removed = $false

foreach ($f in @("cpg", "cpg.cmd")) {
  $path = Join-Path $InstallDir $f
  if (Test-Path $path) {
    Remove-Item $path -Force
    Write-Host "Removed $path"
    $removed = $true
  }
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -and ($userPath -split ';' -contains $InstallDir)) {
  $yn = Read-Host "Remove $InstallDir from your User PATH too? (y/n)"
  if ($yn -match '^[Yy]') {
    $newPath = ($userPath -split ';' | Where-Object { $_ -ne $InstallDir }) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "Removed from PATH. Restart your terminal for it to take effect."
  }
}

if (-not $removed) {
  Write-Host "Nothing to remove - cpg isn't installed at $InstallDir."
} else {
  Write-Host "cpg uninstalled."
}

Write-Host ""
Write-Host "This repo (and any running containers/volumes) are untouched. To fully remove"
Write-Host "the stack too: cpg stop <group> for each group, then delete this folder."
