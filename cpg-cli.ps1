<#
.SYNOPSIS
  Interactive start/stop/restart by group. Each group is its OWN docker-compose project
  (compose/<group>.yml), so this wraps `docker compose -f compose/<group>.yml ...` per
  group instead of filtering services within one file.

  Forgiving input: case-insensitive, understands common aliases (db, redis, rabbit,
  sonar, chroma, up/down, ...), unique prefixes (e.g. "obs" -> observability), and for
  an unrecognized-but-close typo it asks "did you mean X?" instead of just failing.

.EXAMPLE
  ./cpg-cli.ps1                  interactive menu (asks start or stop, then group)
  ./cpg-cli.ps1 status           show every group + running/total count
  ./cpg-cli.ps1 status cache     show just that group's status
  ./cpg-cli.ps1 start            pick from groups that aren't fully up
  ./cpg-cli.ps1 start db         start a specific group (alias for database)
  ./cpg-cli.ps1 start db ai messaging   start several groups at once
  ./cpg-cli.ps1 stop             pick from groups that have something running
  ./cpg-cli.ps1 stop rabbit
  ./cpg-cli.ps1 restart [group...]
  ./cpg-cli.ps1 help
#>
param(
  [Parameter(Position = 0)]
  [string]$Command = "",

  # start/stop/restart accept several group names at once (e.g. `cpg start db ai
  # messaging`) - status/detail only ever look at $Group[0].
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$Group = @()
)

Set-Location $PSScriptRoot

$GroupFile = @{
  database      = "compose/database.yml"
  cache         = "compose/cache.yml"
  messaging     = "compose/messaging.yml"
  observability = "compose/observability.yml"
  quality       = "compose/quality.yml"
  ai            = "compose/ai.yml"
}

# Deliberately excludes one-shot bootstrap jobs (mongo-cluster-init, redis-cluster-init)
# - they're supposed to exit 0 and stay exited, so counting them would make a
# fully-healthy group show as "partial" forever. `up -d` (the first-run fallback in
# Invoke-Start) still creates them fine, this list just isn't used for that.
$SvcGroups = [ordered]@{
  database      = @("postgres", "postgres-replica-1", "postgres-replica-2", "pgpool", "timescaledb", "mongo-primary", "mongo-replica-1", "mongo-replica-2", "mongo-express")
  cache         = @("redis", "redis-insight", "redis-cluster-1", "redis-cluster-2", "redis-cluster-3", "redis-cluster-4", "redis-cluster-5", "redis-cluster-6")
  messaging     = @("rabbitmq")
  observability = @("otel-collector", "tempo", "prometheus", "grafana")
  quality       = @("sonarqube")
  ai            = @("chromadb")
}

# ai's chromadb attaches to database's and cache's networks (external, cross-project) -
# those two must be up (or at least have created their network) before ai can start.
$GroupDepends = @{
  ai = @("database", "cache")
}

$GroupAlias = @{
  db = "database"; postgres = "database"; pg = "database"; sql = "database"; mongo = "database"
  redis = "cache"; caching = "cache"
  rabbit = "messaging"; rabbitmq = "messaging"; mq = "messaging"; broker = "messaging"; queue = "messaging"
  monitoring = "observability"; monitor = "observability"; obs = "observability"
  grafana = "observability"; metrics = "observability"; tracing = "observability"
  sonar = "quality"; sonarqube = "quality"; codequality = "quality"
  vector = "ai"; chroma = "ai"; chromadb = "ai"; vectordb = "ai"; llm = "ai"
}

$CmdAlias = @{
  up = "start"; on = "start"; run = "start"; nyalain = "start"; hidupkan = "start"
  down = "stop"; off = "stop"; kill = "stop"; matiin = "stop"; matikan = "stop"
  reboot = "restart"; rs = "restart"; re = "restart"
  st = "status"; ls = "status"; list = "status"; stat = "status"; stats = "status"; cek = "status"; check = "status"
  info = "detail"; conn = "detail"; connection = "detail"; creds = "detail"; credentials = "detail"; cred = "detail"
  upgrade = "update"; "self-update" = "update"; pull = "update"; upd = "update"
  remove = "uninstall"; unlink = "uninstall"
}
$Cmds = @("status", "start", "stop", "restart", "detail", "update", "uninstall")

function Invoke-Compose {
  param([string]$GroupName, [string[]]$Rest)
  docker compose -f $GroupFile[$GroupName] @Rest
}

# --- fuzzy matching --------------------------------------------------------

function Get-Levenshtein([string]$a, [string]$b) {
  $la = $a.Length; $lb = $b.Length
  $d = New-Object 'int[,]' ($la + 1), ($lb + 1)
  for ($i = 0; $i -le $la; $i++) { $d[$i, 0] = $i }
  for ($j = 0; $j -le $lb; $j++) { $d[0, $j] = $j }
  for ($i = 1; $i -le $la; $i++) {
    for ($j = 1; $j -le $lb; $j++) {
      $cost = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
      # Parens around the arithmetic are required here - PowerShell parses a bare
      # `$i - 1` inside a multi-dim array indexer as an argument list, not a
      # subtraction, and throws "op_Subtraction not found" at runtime.
      $del = $d[($i - 1), $j] + 1
      $ins = $d[$i, ($j - 1)] + 1
      $sub = $d[($i - 1), ($j - 1)] + $cost
      $d[$i, $j] = [Math]::Min([Math]::Min($del, $ins), $sub)
    }
  }
  return $d[$la, $lb]
}

# Returns the resolved canonical option on success (exact match, alias, unique
# prefix, or a confirmed close-typo guess). Returns $null if it can't figure it out -
# but not silently: prints the closest options ranked by similarity, so a totally-off
# guess still gets a useful recommendation instead of just "not found".
function Resolve-Choice([string]$val, [hashtable]$aliasMap, [string[]]$options) {
  $val = $val.ToLowerInvariant()
  if ($options -contains $val) { return $val }
  if ($aliasMap.ContainsKey($val)) { return $aliasMap[$val] }

  $prefixMatches = $options | Where-Object { $_.StartsWith($val) }
  if (@($prefixMatches).Count -eq 1) { return $prefixMatches }

  $scored = $options | ForEach-Object { [PSCustomObject]@{ Opt = $_; Dist = Get-Levenshtein $val $_ } } | Sort-Object Dist
  $best = $scored[0]

  if ($best.Dist -le 2) {
    $yn = Read-Host "? Gak nemu persis '$val'. Maksud lu '$($best.Opt)'? (y/n)"
    if ($yn -match '^[Yy]') { return $best.Opt }
  } else {
    $suggestions = ($scored | Select-Object -First 3 -ExpandProperty Opt) -join ', '
    Write-Host "✗ Gak ngerti '$val'. Mirip² gini: $suggestions" -ForegroundColor Red
  }
  return $null
}

# Returns the resolved group name, or $null if it can't figure it out - never exits
# the process, so the REPL loop can recover from a bad name instead of the whole
# shell dying. Resolve-Choice already told the user what it's close to; this just
# adds the full list as a last-resort fallback.
function Resolve-GroupOrDie([string]$val) {
  if ($SvcGroups.Contains($val)) { return $val }
  $resolved = Resolve-Choice $val $GroupAlias @($SvcGroups.Keys)
  if ($resolved) { return $resolved }
  Write-Host "  (grup yang ada: $($SvcGroups.Keys -join ', '))" -ForegroundColor DarkGray
  return $null
}

# --- status helpers ---------------------------------------------------------

function Get-RunningServicesOf([string]$groupName) {
  (Invoke-Compose $groupName @("ps", "--services", "--status", "running") 2>$null) -split "`n" | Where-Object { $_ -ne "" }
}

function Test-NetworkExists([string]$groupName) {
  docker network inspect "cpg-$groupName" *> $null
  return $LASTEXITCODE -eq 0
}

function Get-GroupState($groupName) {
  $svcs = $SvcGroups[$groupName]
  $runningList = Get-RunningServicesOf $groupName
  $running = ($svcs | Where-Object { $runningList -contains $_ }).Count
  $total = $svcs.Count
  $state = if ($running -eq 0) { "down" } elseif ($running -eq $total) { "up" } else { "partial" }
  [PSCustomObject]@{ Group = $groupName; Running = $running; Total = $total; State = $state; Services = $svcs }
}

function Write-GroupLine($info) {
  $color = switch ($info.State) { "up" { "Green" }; "partial" { "Yellow" }; "down" { "Red" } }
  $plainPrefix = "  ● {0,-15}{1,2}/{2,-2}  " -f $info.Group, $info.Running, $info.Total
  Write-Host -NoNewline "  ● " -ForegroundColor $color
  Write-Host -NoNewline ("{0,-15}" -f $info.Group)
  Write-Host -NoNewline -ForegroundColor $color ("{0,2}/{1,-2}  " -f $info.Running, $info.Total)

  # Full member list lives in `/detail <group>` - showing all of them here made the
  # line unreadably wide on anything but a maximized terminal. Fit as many names as
  # actually fit the current terminal width, "+N lainnya" for the rest - re-measured
  # every render, so it re-flows on the next redraw after a resize (this isn't a live
  # mid-resize repaint either - see Get-Hr).
  $width = $Host.UI.RawUI.WindowSize.Width
  if (-not $width -or $width -lt 1) { $width = 80 }
  $avail = [Math]::Max(0, $width - $plainPrefix.Length)

  $shown = [System.Collections.Generic.List[string]]::new()
  $curStr = ""
  for ($i = 0; $i -lt $info.Services.Count; $i++) {
    $candidate = $info.Services[$i]
    $tentative = if ($curStr) { "$curStr, $candidate" } else { $candidate }
    $remaining = $info.Services.Count - ($i + 1)
    $tentativeFull = if ($remaining -gt 0) { "$tentative, +$remaining lainnya" } else { $tentative }
    if ($tentativeFull.Length -gt $avail) { break }
    $curStr = $tentative
    $shown.Add($candidate)
  }

  if ($shown.Count -eq 0) {
    # Not even one name fits - just say how many there are.
    $svcText = "$($info.Services.Count) container"
  } else {
    $svcText = $curStr
    $remaining = $info.Services.Count - $shown.Count
    if ($remaining -gt 0) { $svcText += ", +$remaining lainnya" }
  }
  Write-Host $svcText -ForegroundColor DarkGray
}

function Show-Status([string]$filter) {
  if ($filter) {
    $filter = Resolve-GroupOrDie $filter
    if (-not $filter) { return }
  }
  foreach ($g in $SvcGroups.Keys) {
    if ($filter -and $g -ne $filter) { continue }
    Write-GroupLine (Get-GroupState $g)
  }
}

function Select-FromMenu([string]$prompt, [string[]]$choices) {
  Write-Host "? $prompt" -ForegroundColor DarkYellow
  for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host "  $($i + 1)) $($choices[$i])" -ForegroundColor DarkGray }
  Write-Host "  0) cancel" -ForegroundColor DarkGray
  $pick = Read-Host "  ❯"
  if ($pick -eq "0" -or [string]::IsNullOrWhiteSpace($pick)) { return $null }
  if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $choices.Count) {
    Write-Host "✗ Pilihan gak valid." -ForegroundColor Red
    return $null
  }
  return $choices[[int]$pick - 1]
}

function Show-Help {
  Write-Host @"
Kelola service docker-compose per grup (start/stop/restart/status). Tiap grup itu
project compose terpisah (compose/<grup>.yml) - keliatan sbg baris sendiri2 di
'docker compose ls' / Docker Desktop.

Usage:
  ./cpg-cli.ps1                    masuk interactive shell (prompt cpg>, ketik /status /start dst berulang)
  ./cpg-cli.ps1 status [grup]      liat status (semua grup, atau 1 grup doang)
  ./cpg-cli.ps1 start  [grup]      nyalain grup (tanpa nama -> pilih dari yg belum full up)
  ./cpg-cli.ps1 stop   [grup]      matiin grup  (tanpa nama -> pilih dari yg lagi jalan)
  ./cpg-cli.ps1 restart [grup]
  ./cpg-cli.ps1 detail [grup]      connection info (host/port/user/pass/URI) per service
  ./cpg-cli.ps1 update             git pull cpg-cli itself + refresh the cpg wrapper
  ./cpg-cli.ps1 uninstall          remove the cpg command (repo/containers/data untouched)
  ./cpg-cli.ps1 clear              clear the terminal (in the shell: also redraws the banner+status)

Grup: $($SvcGroups.Keys -join ', ')
Boleh ketik alias/singkatan juga, misal: db, redis, rabbit, obs, sonar, chroma, up, down.
Typo dikit juga ketauan - bakal ditanya "maksud lu ini?" kalo mirip.

Catatan: grup 'ai' (chromadb) butuh network dari 'database' & 'cache' - kalo itu
belum nyala, cpg nyalain otomatis dulu sebelum start 'ai'.
"@
}

# --- actions -----------------------------------------------------------

function Ensure-Dependencies([string]$groupName) {
  $deps = $GroupDepends[$groupName]
  if (-not $deps) { return }
  foreach ($dep in $deps) {
    if (-not (Test-NetworkExists $dep)) {
      Write-Host "! '$groupName' butuh network '$dep' - nyalain dulu..." -ForegroundColor Yellow
      Invoke-Compose $dep @("up", "-d")
    }
  }
}

function Invoke-StartOne([string]$groupName) {
  Ensure-Dependencies $groupName
  $svcs = $SvcGroups[$groupName]
  Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
  Write-Host "docker compose -f $($GroupFile[$groupName]) start $($svcs -join ' ')"
  # `start` only works on containers that already exist - first-ever run falls back to
  # `up -d` to actually create them.
  Invoke-Compose $groupName (@("start") + $svcs)
  if ($LASTEXITCODE -ne 0) { Invoke-Compose $groupName @("up", "-d") }
}

# Accepts zero, one, or many group names (e.g. `cpg start db ai messaging`). Zero ->
# pick-from-menu (single choice, as before). One or more -> each is resolved and
# started independently; a bad name in the middle just gets skipped (with a message)
# instead of aborting the rest of the batch.
function Invoke-Start([string[]]$groupNames) {
  $groupNames = @($groupNames | Where-Object { $_ })
  if ($groupNames.Count -eq 0) {
    $candidates = $SvcGroups.Keys | Where-Object { (Get-GroupState $_).State -ne "up" }
    if (-not $candidates) {
      Write-Host "✓ Semua grup udah nyala semua." -ForegroundColor Green
      return
    }
    $picked = Select-FromMenu "Grup mana yang mau di-start?" @($candidates)
    if (-not $picked) { Write-Host "(batal)" -ForegroundColor DarkGray; return }
    $groupNames = @($picked)
  }
  foreach ($g in $groupNames) {
    $resolved = Resolve-GroupOrDie $g
    if (-not $resolved) { continue }
    Invoke-StartOne $resolved
  }
}

function Invoke-StopOne([string]$groupName) {
  $svcs = $SvcGroups[$groupName]
  Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
  Write-Host "docker compose -f $($GroupFile[$groupName]) stop $($svcs -join ' ')"
  Invoke-Compose $groupName (@("stop") + $svcs)
}

function Invoke-Stop([string[]]$groupNames) {
  $groupNames = @($groupNames | Where-Object { $_ })
  if ($groupNames.Count -eq 0) {
    $candidates = $SvcGroups.Keys | Where-Object { (Get-GroupState $_).State -ne "down" }
    if (-not $candidates) {
      Write-Host "! Emang lagi gak ada yang jalan." -ForegroundColor Yellow
      return
    }
    $picked = Select-FromMenu "Grup mana yang mau di-stop?" @($candidates)
    if (-not $picked) { Write-Host "(batal)" -ForegroundColor DarkGray; return }
    $groupNames = @($picked)
  }
  foreach ($g in $groupNames) {
    $resolved = Resolve-GroupOrDie $g
    if (-not $resolved) { continue }
    Invoke-StopOne $resolved
  }
}

function Invoke-RestartOne([string]$groupName) {
  Ensure-Dependencies $groupName
  $svcs = $SvcGroups[$groupName]
  Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
  Write-Host "docker compose -f $($GroupFile[$groupName]) restart $($svcs -join ' ')"
  Invoke-Compose $groupName (@("restart") + $svcs)
}

function Invoke-Restart([string[]]$groupNames) {
  $groupNames = @($groupNames | Where-Object { $_ })
  if ($groupNames.Count -eq 0) {
    $picked = Select-FromMenu "Grup mana yang mau di-restart?" @($SvcGroups.Keys)
    if (-not $picked) { Write-Host "(batal)" -ForegroundColor DarkGray; return }
    $groupNames = @($picked)
  }
  foreach ($g in $groupNames) {
    $resolved = Resolve-GroupOrDie $g
    if (-not $resolved) { continue }
    Invoke-RestartOne $resolved
  }
}

# Connection info per service - host/port/user/pass/URI, whatever you'd need to
# actually connect from a client or another app. Static reference text (matches what's
# baked into the compose files), not queried live from the containers.
function Show-Detail([string]$groupName) {
  if ($groupName) {
    $groupName = Resolve-GroupOrDie $groupName
    if (-not $groupName) { return }
  } else {
    $groupName = Select-FromMenu "Grup mana yang mau dilihat detailnya?" @($SvcGroups.Keys)
    if (-not $groupName) { Write-Host "(batal)" -ForegroundColor DarkGray; return }
  }

  switch ($groupName) {
    "database" {
      Write-Host @"
=== database ===

postgres  (master, read/write, always on)
  host: localhost   port: 5432   user: admin   pass: password   db: sample
  psql:  psql -h localhost -p 5432 -U admin -d sample
  jdbc:  jdbc:postgresql://localhost:5432/sample

postgres-replica-1  (read-only standby, profile: postgres-replica)
  host: localhost   port: 5443   user: admin   pass: password   db: sample

postgres-replica-2  (read-only standby, profile: postgres-replica)
  host: localhost   port: 5444   user: admin   pass: password   db: sample

pgpool  (round-robin read routing across replicas, writes -> master, profile: postgres-replica)
  host: localhost   port: 5433   user: admin   pass: password   db: sample
  psql:  psql -h localhost -p 5433 -U admin -d sample
  admin UI login: admin / password

timescaledb
  host: localhost   port: 6543   user: admin   pass: password   db: sample
  psql:  psql -h localhost -p 6543 -U admin -d sample

mongo-primary  (always on, doubles as replica set primary)
  host: localhost   port: 27017   user: admin   pass: password   db: sample (authSource=admin)
  uri:   mongodb://admin:password@localhost:27017/sample?authSource=admin

mongo-replica-1 / mongo-replica-2  (profile: mongo-cluster)
  host: localhost   port: 27019 / 27020   user: admin   pass: password (inherited from primary)
  full replica set uri:
    mongodb://admin:password@localhost:27017,localhost:27019,localhost:27020/sample?replicaSet=rs0&authSource=admin

mongo-express  (web UI for mongo-primary)
  url: http://localhost:8888
  basic auth login: admin / admin   <- NOT the same as mongo's creds above
"@
    }
    "cache" {
      Write-Host @"
=== cache ===

redis
  host: localhost   port: 6379   pass: password
  cli:  redis-cli -h localhost -p 6379 -a password

redis-insight  (web UI, no login by default)
  url: http://localhost:5540
  add connection inside using: host=localhost, port=6379, pass=password

redis-cluster-1..6  (profile: redis-cluster)
  hosts: localhost:7000-7005   pass: password
  cli:   redis-cli -c -h localhost -p 7000 -a password   (-c follows MOVED redirects)
"@
    }
    "messaging" {
      Write-Host @"
=== messaging ===

rabbitmq
  amqp:  amqp://admin:password@localhost:5672
  management UI: http://localhost:15672   login: admin / password
"@
    }
    "observability" {
      Write-Host @"
=== observability ===

otel-collector  (no auth)
  grpc: localhost:4317
  http: localhost:4318

tempo  (no auth)
  url: http://localhost:3200

prometheus  (no auth)
  url: http://localhost:9090

grafana
  url: http://localhost:3000
  default login: admin / admin   (Grafana forces a password change on first login)
"@
    }
    "quality" {
      Write-Host @"
=== quality ===

sonarqube
  url: http://localhost:9000
  default login: admin / admin   (SonarQube forces a password change on first login)
"@
    }
    "ai" {
      Write-Host @"
=== ai ===

chromadb  (no auth by default)
  url: http://localhost:8100
  heartbeat: http://localhost:8100/api/v2/heartbeat
"@
    }
  }
}

# git pull the repo this script lives in, then re-run install.ps1 so the cpg wrapper
# itself picks up any changes (renamed script, new install logic, etc). Never touches
# your containers.
function Invoke-Update {
  Push-Location $PSScriptRoot
  try {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "$PSScriptRoot isn't a git repo - can't self-update this way."
      Write-Host "Re-clone from https://github.com/ndri-nr/cpg-cli or download the latest release."
      return
    }

    $before = (git rev-parse --short HEAD).Trim()
    Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
    Write-Host "git pull (in $PSScriptRoot)"
    git pull --ff-only
    if ($LASTEXITCODE -ne 0) {
      Write-Host "✗ Update gagal - local changes atau conflict kayaknya. Cek manual: git -C `"$PSScriptRoot`" status" -ForegroundColor Red
      return
    }
    $after = (git rev-parse --short HEAD).Trim()

    if ($before -eq $after) {
      Write-Host "✓ Udah versi terbaru ($after)." -ForegroundColor Green
      return
    }

    Write-Host "✓ Updated $before -> $after." -ForegroundColor Green
    if (Test-Path "./install.ps1") {
      Write-Host "Re-running install.ps1 to refresh the cpg wrapper..."
      & "./install.ps1"
    }

    # A running shell keeps the OLD code in memory even after the file on disk
    # changes - relaunch instead of making you exit/reopen `cpg` by hand. Only when
    # actually in the interactive shell; a one-shot `cpg update` has nothing to
    # "restart" into.
    if ($script:IsRepl) {
      Write-Host "Restarting cpg..." -ForegroundColor DarkGray
      & $PSCommandPath
      exit
    }
  } finally {
    Pop-Location
  }
}

# Removes the ~/.local/bin cpg wrapper - never touches this repo, running containers,
# or volumes/data (see uninstall.ps1's own comment).
function Invoke-Uninstall {
  $yn = Read-Host "? Uninstall the cpg command? Repo/containers/data stay untouched. (y/n)"
  if ($yn -notmatch '^[Yy]') {
    Write-Host "(batal)" -ForegroundColor DarkGray
    return
  }
  $script = Join-Path $PSScriptRoot "uninstall.ps1"
  if (Test-Path $script) {
    & $script
  } else {
    Write-Host "uninstall.ps1 not found in $PSScriptRoot."
  }
}

# --- REPL (bare cpg, no args) ---------------------------------------------

# Full-width divider re-queried every call, so it tracks a live terminal resize
# instead of being baked in once at REPL start.
function Get-Hr {
  $width = $Host.UI.RawUI.WindowSize.Width
  if (-not $width -or $width -lt 1) { $width = 40 }
  return ("─" * $width)
}

# Redraws just the top/bottom border rows around $origPos (the boxed-prompt input
# line's saved cursor position) without disturbing it - same idea as bash's
# _cpg_redraw_borders, just via CursorPosition instead of tput sc/cuu/cud/rc.
function Redraw-Borders($origPos) {
  try {
    $topPos = New-Object -TypeName System.Management.Automation.Host.Coordinates -ArgumentList 0, ([Math]::Max(0, $origPos.Y - 1))
    $Host.UI.RawUI.CursorPosition = $topPos
    Write-Host (Get-Hr) -ForegroundColor DarkGray
    $botPos = New-Object -TypeName System.Management.Automation.Host.Coordinates -ArgumentList 0, ($origPos.Y + 1)
    $Host.UI.RawUI.CursorPosition = $botPos
    Write-Host (Get-Hr) -ForegroundColor DarkGray
    $Host.UI.RawUI.CursorPosition = $origPos
  } catch { }
}

# Polls window width while idle at the boxed prompt (before the first keystroke),
# redrawing the borders live on resize. `[Console]::KeyAvailable` just peeks - it
# doesn't consume the key, so Read-Host still sees it normally right after this
# returns. Ceiling here (unlike bash's SIGWINCH, which really interrupts mid-line):
# .NET's Read-Host has no hook to interrupt an in-progress line edit, so once you
# start typing this can't catch further resizes until you hit Enter - idle-only.
function Wait-KeyOrResize {
  $origPos = $Host.UI.RawUI.CursorPosition
  $lastWidth = $Host.UI.RawUI.WindowSize.Width
  try {
    while (-not [Console]::KeyAvailable) {
      Start-Sleep -Milliseconds 150
      $w = $Host.UI.RawUI.WindowSize.Width
      if ($w -ne $lastWidth) {
        $lastWidth = $w
        Redraw-Borders $origPos
      }
    }
  } catch {
    # stdin redirected/piped (non-interactive runs, e.g. scripted smoke tests) -
    # KeyAvailable throws there. Just skip polling and let Read-Host read directly.
  }
}

function Show-Banner {
  Write-Host "╭─────────────────────────────────────╮" -ForegroundColor DarkYellow
  Write-Host -NoNewline "│ " -ForegroundColor DarkYellow
  Write-Host -NoNewline "✳  " -ForegroundColor DarkYellow
  Write-Host -NoNewline "cpg · compose playground control "
  Write-Host "│" -ForegroundColor DarkYellow
  Write-Host "╰─────────────────────────────────────╯" -ForegroundColor DarkYellow
  Write-Host "/help buat commands · /exit buat keluar" -ForegroundColor DarkGray
}

# Auto-CHECK for updates (never auto-applies anything - still requires `/update`).
# Zero added latency: only compares against whatever origin/main ref is already
# cached locally (no network call on the hot path). A real `git fetch` only fires in
# the background, at most once every 24h, so the cached ref catches up over time
# without ever blocking a command.
function Test-ForUpdate {
  $gitDir = git rev-parse --git-dir 2>$null
  if (-not $gitDir -or $LASTEXITCODE -ne 0) { return }
  $cacheFile = Join-Path $gitDir "cpg-last-update-check"
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $lastCheck = 0
  if (Test-Path $cacheFile) {
    $raw = Get-Content $cacheFile -Raw -ErrorAction SilentlyContinue
    if ($raw -match '^\d+$') { $lastCheck = [long]$raw }
  }

  if (($now - $lastCheck) -gt 86400) {
    Set-Content -Path $cacheFile -Value $now -NoNewline
    Start-Process -FilePath "git" -ArgumentList "fetch", "--quiet", "origin", "main" -WindowStyle Hidden
  }

  $behind = git rev-list --count HEAD..origin/main 2>$null
  if ($LASTEXITCODE -eq 0 -and $behind -match '^\d+$' -and [int]$behind -gt 0) {
    Write-Host "↑ Update tersedia ($behind commit baru) - ketik /update" -ForegroundColor Yellow
  }
}

function Start-Repl {
  $script:IsRepl = $true
  try { $Host.UI.RawUI.WindowTitle = "✳  cpg-cli" } catch { }
  Show-Banner
  Test-ForUpdate
  Write-Host ""
  Show-Status ""
  while ($true) {
    Write-Host ""
    # A framed input area, like Claude Code's own prompt box - both borders are
    # actually drawn (with a blank line reserved between them) BEFORE Read-Host
    # starts, then the console cursor is walked back up onto that blank line.
    # Read-Host only ever redraws its own current line, so the borders above and
    # below stay put while typing - no raw-mode console-reading loop needed for that
    # part. No inline vanish-on-type placeholder though - Read-Host has no hook to
    # draw one that disappears the moment you type. The hint line above is the safe
    # equivalent.
    Write-Host "contoh: /status, /start db, /detail, /help" -ForegroundColor DarkGray
    Write-Host (Get-Hr) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host (Get-Hr) -ForegroundColor DarkGray
    try {
      $pos = $Host.UI.RawUI.CursorPosition
      $pos.Y = [Math]::Max(0, $pos.Y - 2)
      $Host.UI.RawUI.CursorPosition = $pos
    } catch { }
    Write-Host -NoNewline "❯ " -ForegroundColor DarkYellow
    Wait-KeyOrResize
    $line = Read-Host
    if ($null -eq $line) { break }
    $line = $line.TrimStart("/")
    if (-not $line.Trim()) { continue }
    $parts = $line -split '\s+', 2
    $subCmd = $parts[0]
    $subArg = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    # start/stop/restart can take several groups at once (e.g. `/start db ai messaging`).
    $subArgs = @($subArg -split '\s+' | Where-Object { $_ })

    if ($subCmd -in @("exit", "quit", "q")) { break }
    if ($subCmd -in @("-h", "--help", "help")) { Show-Help; continue }
    if ($subCmd -in @("clear", "cls")) {
      Clear-Host
      Show-Banner
      Write-Host ""
      Show-Status ""
      continue
    }

    $resolved = Resolve-Choice $subCmd $CmdAlias $Cmds
    if (-not $resolved) {
      Write-Host "  (/help buat liat semua command)" -ForegroundColor DarkGray
      continue
    }
    switch ($resolved) {
      "status" { Show-Status $subArg }
      "start" { Invoke-Start $subArgs }
      "stop" { Invoke-Stop $subArgs }
      "restart" { Invoke-Restart $subArgs }
      "detail" { Show-Detail $subArg }
      "update" { Invoke-Update }
      "uninstall" { Invoke-Uninstall }
    }
  }
  Write-Host "Bye."
}

# --- entry ---------------------------------------------------------------

if ($Command -in @("-h", "--help", "help")) {
  Show-Help
  exit 0
}
if ($Command -in @("clear", "cls")) {
  Clear-Host
  exit 0
}

if ($Command -and $Command -notin $Cmds) {
  $resolvedCmd = Resolve-Choice $Command $CmdAlias $Cmds
  if (-not $resolvedCmd) {
    Show-Help
    exit 1
  }
  $Command = $resolvedCmd
}

switch ($Command) {
  "status" { Show-Status $Group[0] }
  "start" { Invoke-Start $Group }
  "stop" { Invoke-Stop $Group }
  "restart" { Invoke-Restart $Group }
  "detail" { Show-Detail $Group[0] }
  "update" { Invoke-Update }
  "uninstall" { Invoke-Uninstall }
  "" { Start-Repl }
}
