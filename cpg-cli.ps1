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

# Without this, Windows PowerShell 5.1's console decodes our UTF-8 box-drawing/emoji
# output (─╭╮╰╯●▸❯✳) as the system ANSI codepage (usually 1252) instead of UTF-8 -
# each multi-byte char splits into mojibake (e.g. "─" -> "â"?"). Setting both
# OutputEncoding vars up front fixes it for the whole session. Wrapped in try/catch:
# redirected/piped output (non-interactive runs, e.g. scripted smoke tests) can't set
# Console.OutputEncoding and throws - safe to skip in that case, nothing renders icons
# there anyway.
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

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

# Services that only exist once a compose profile is switched on (replicas, cluster
# nodes). Two jobs: status must not count a service nobody ever created - counting
# them is what pinned `database` at 4/9 forever, unreachable by `cpg start db` - and
# `start --all` needs to know which profiles bring the whole group up.
$SvcProfile = @{
  "postgres-replica-1" = "postgres-replica"; "postgres-replica-2" = "postgres-replica"
  "pgpool" = "postgres-replica"
  "mongo-replica-1" = "mongo-cluster"; "mongo-replica-2" = "mongo-cluster"
  "redis-cluster-1" = "redis-cluster"; "redis-cluster-2" = "redis-cluster"
  "redis-cluster-3" = "redis-cluster"; "redis-cluster-4" = "redis-cluster"
  "redis-cluster-5" = "redis-cluster"; "redis-cluster-6" = "redis-cluster"
}
$GroupProfiles = @{
  database = @("postgres-replica", "mongo-cluster")
  cache    = @("redis-cluster")
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

# --- pane output ------------------------------------------------------------
#
# Everything the shell prints has to be mirrored to a file, because that mirror is
# what a resize or a scroll repaints the pane from. Rather than rewrite ~70 call
# sites, this shadows the Write-Host cmdlet: same calls, same colours, but the text
# is written as VT (so the mirror holds exactly what the screen holds) and appended
# to $script:PaneLog. Outside the live prompt it just writes, same as before.
$script:PaneLog = ""
# Colour goes out as VT codes now, so it has to be suppressed when output isn't a
# terminal - otherwise `cpg status | grep` would be reading escape sequences.
$script:OutRedirected = $false
try { $script:OutRedirected = [Console]::IsOutputRedirected } catch { }
$script:VtColor = @{
  Green = "32"; Yellow = "33"; Red = "31"; DarkYellow = "38;5;209"
  DarkGray = "2"; Gray = "37"; White = "97"; Cyan = "36"; Blue = "34"; Magenta = "35"
  DarkGreen = "32"; DarkRed = "31"; DarkCyan = "36"; DarkBlue = "34"; DarkMagenta = "35"
}

function Write-Host {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
    [object[]]$Object,
    [switch]$NoNewline,
    [object]$Separator = " ",
    [object]$ForegroundColor,
    [object]$BackgroundColor
  )
  process {
    $text = if ($null -eq $Object) { "" } else { ($Object | ForEach-Object { "$_" }) -join $Separator }
    if ($ForegroundColor -and -not $script:OutRedirected) {
      $code = $script:VtColor["$ForegroundColor"]
      if ($code) { $text = "$([char]27)[$($code)m$text$([char]27)[0m" }
    }
    if (-not $NoNewline) { $text += "`r`n" }
    [Console]::Out.Write($text)
    if ($script:PaneLog) {
      try { [System.IO.File]::AppendAllText($script:PaneLog, $text) } catch { }
    }
  }
}

function Invoke-Compose {
  param([string]$GroupName, [string[]]$Rest, [switch]$Capture)
  # -Capture: the caller wants the text back (status queries), so return it and print
  # nothing. Otherwise the output belongs on screen, and it goes through the writer
  # so it reaches the mirror a repaint replays from. Cost of that: stdout is a pipe,
  # so compose prints plain progress lines instead of live-redrawing ones.
  # $LASTEXITCODE still comes from docker either way.
  if ($Capture) {
    return (docker compose -f $GroupFile[$GroupName] @Rest)
  }
  if ($script:PaneLog) {
    & docker compose -f $GroupFile[$GroupName] @Rest 2>&1 | ForEach-Object { Write-Host "$_" }
  } else {
    docker compose -f $GroupFile[$GroupName] @Rest
  }
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
  (Invoke-Compose $groupName @("ps", "--services", "--status", "running") -Capture 2>$null) -split "`n" | Where-Object { $_ -ne "" }
}

function Test-NetworkExists([string]$groupName) {
  docker network inspect "cpg-$groupName" *> $null
  return $LASTEXITCODE -eq 0
}

# "<service> <state>" per existing container, one `compose ps` for the whole group.
# `-a` on purpose: a created-but-stopped container still proves its profile was
# switched on at some point, which is what the denominator below keys off.
function Get-GroupPs([string]$groupName) {
  $map = @{}
  $lines = (Invoke-Compose $groupName @("ps", "-a", "--format", "{{.Service}} {{.State}}") -Capture 2>$null) -split "`n"
  foreach ($line in $lines) {
    $parts = $line.Trim() -split '\s+', 2
    if ($parts[0]) { $map[$parts[0]] = if ($parts.Count -gt 1) { $parts[1] } else { "" } }
  }
  return $map
}

# The denominator is what's actually reachable, not every service in the file:
# profile-gated services join it only once a container for them exists (someone ran
# `start --all` or a manual `--profile` compose command). Counting them regardless is
# what pinned `database` at 4/9 forever - 5 of its 9 services live behind
# `postgres-replica` / `mongo-cluster`, so plain `cpg start db` could never reach 9.
function Get-GroupState($groupName) {
  $state = Get-GroupPs $groupName
  $active = [System.Collections.Generic.List[string]]::new()
  $running = 0
  $dormant = 0
  foreach ($svc in $SvcGroups[$groupName]) {
    if (-not $state.ContainsKey($svc) -and $SvcProfile.ContainsKey($svc)) {
      $dormant++
      continue
    }
    $active.Add($svc)
    if ($state[$svc] -eq "running") { $running++ }
  }
  $total = $active.Count
  $st = if ($running -eq 0) { "down" } elseif ($running -eq $total) { "up" } else { "partial" }
  [PSCustomObject]@{ Group = $groupName; Running = $running; Total = $total; State = $st; Services = $active; Dormant = $dormant }
}

# One status line as a string, fitted to the CURRENT width. A string rather than a
# series of Write-Hosts because the resize/scroll repaint has to re-render the same
# line at a new width instead of replaying text laid out for the old one.
function Get-GroupLineText($info) {
  $e = [char]27
  $code = switch ($info.State) { "up" { "32" }; "partial" { "33" }; "down" { "31" } }
  if ($script:OutRedirected) {
    # Plain text when piped: same layout, no escapes.
    return ("  ● {0}{1}  {2}" -f ("{0,-15}" -f $info.Group), ("{0,2}/{1,-2}" -f $info.Running, $info.Total), (Get-GroupServiceText $info))
  }
  return ("  {0}●{1} {2}{0}{3}{1}  {4}{5}{1}" -f `
    "$e[$($code)m", "$e[0m", ("{0,-15}" -f $info.Group), `
    ("{0,2}/{1,-2}" -f $info.Running, $info.Total), "$e[2m", (Get-GroupServiceText $info))
}

# The member list for one status line, fitted to the current width: as many names as
# fit, "+N lainnya" for the rest, "+N profil" for the profile-gated ones.
function Get-GroupServiceText($info) {
  $plainPrefix = "  ● {0,-15}{1,2}/{2,-2}  " -f $info.Group, $info.Running, $info.Total
  $width = $script:PinnedCols
  if (-not $width -or $width -lt 1) { $width = 80 }
  # "+N profil" = services waiting behind a compose profile (see Get-GroupState).
  # Kept out of the counts on purpose, but worth advertising - that's the
  # discoverable hint that `start <group> --all` exists.
  $dormantNote = if ($info.Dormant -gt 0) { ", +$($info.Dormant) profil" } else { "" }
  $avail = [Math]::Max(0, $width - $plainPrefix.Length - $dormantNote.Length)

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
  return ($svcText + $dormantNote)
}

function Write-GroupLine($info) {
  # Remembered per group so a repaint can re-fit the line without asking docker.
  $script:LastStatus[$info.Group] = $info
  Write-Host (Get-GroupLineText $info)
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
  ./cpg-cli.ps1 start  [grup] [--no-all]  nyalain grup (tanpa nama -> pilih dari yg belum full up)
  ./cpg-cli.ps1 stop   [grup]      matiin grup  (tanpa nama -> pilih dari yg lagi jalan)
  ./cpg-cli.ps1 restart [grup] [--no-all]
  ./cpg-cli.ps1 detail [grup]      connection info (host/port/user/pass/URI) per service
  ./cpg-cli.ps1 update             git pull cpg-cli itself + refresh the cpg wrapper
  ./cpg-cli.ps1 uninstall          remove the cpg command (repo/containers/data untouched)
  ./cpg-cli.ps1 clear              clear the terminal (in the shell: also redraws the banner+status)

Grup: $($SvcGroups.Keys -join ', ')
Boleh ketik alias/singkatan juga, misal: db, redis, rabbit, obs, sonar, chroma, up, down.
Typo dikit juga ketauan - bakal ditanya "maksud lu ini?" kalo mirip.
Di dalem shell interaktif, Tab bisa buat autocomplete command & nama grup.
Scroll area output: Fn+↑ / Fn+↓ (setengah layar), Option/Shift+↑ / ↓ (3 baris), atau
Ctrl+B / Ctrl+F (satu layar). Kotak input tetep di bawah, gak kegeser. Ngetik apa
aja = balik ke output terbaru. Select/copy normal. CPG_CLEAR_SCROLLBACK=1 kalo mau
scroll mouse gak bisa nembus ke atas layar cpg. CPG_ALTSCREEN=0 = layar biasa.

Catatan: grup 'ai' (chromadb) butuh network dari 'database' & 'cache' - kalo itu
belum nyala, cpg nyalain otomatis dulu sebelum start 'ai'.

start/restart default-nya nyalain SEMUA, termasuk yang di balik compose profile:
replica Postgres + pgpool (profile postgres-replica), replica set Mongo
(mongo-cluster), 6 node Redis cluster (redis-cluster). Mau yang inti doang:
--no-all (alias: --core, --lean, --min). Yang dilewatin gak kebikin containernya,
jadi status gak ngitung mereka - keliatan sbg "+N profil" di belakang list.
"@
}

# --- actions -----------------------------------------------------------

function Test-DockerRunning {
  docker info *> $null
  return $LASTEXITCODE -eq 0
}

# `start`/`restart` are the only actions that actually need Docker running (`stop`
# on an already-off daemon has nothing to do; `status`/`detail` just show 0/N). If
# Docker isn't up, offer to launch Docker Desktop instead of failing the whole
# command with a raw "error during connect" message.
function Ensure-DockerRunning {
  if (Test-DockerRunning) { return $true }
  Write-Host "! Docker keliatannya mati." -ForegroundColor Yellow

  $exe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
  if (-not (Test-Path $exe)) {
    Write-Host "  Gak nemu Docker Desktop di '$exe' - nyalain manual, terus ulangi command tadi." -ForegroundColor DarkGray
    return $false
  }

  $yn = Read-Host "? Nyalain Docker sekarang ($exe)? (y/n)"
  if ($yn -notmatch '^[Yy]') {
    Write-Host "(batal)" -ForegroundColor DarkGray
    return $false
  }

  Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
  Write-Host "Start-Process `"$exe`""
  Start-Process -FilePath $exe | Out-Null

  Write-Host -NoNewline "Nunggu Docker nyala"
  for ($i = 0; $i -lt 60; $i++) {
    if (Test-DockerRunning) {
      Write-Host " ✓" -ForegroundColor Green
      return $true
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 2
  }
  Write-Host " ✗" -ForegroundColor Red
  Write-Host "  Masih mati setelah ~2 menit nunggu - cek Docker Desktop manual, terus ulangi command tadi." -ForegroundColor DarkGray
  return $false
}

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

# Splits the profile flag out of a group list -> @{ All = $bool; Rest = @() }.
#
# Profiles are ON by default: `cpg start db` brings up the replicas and cluster nodes
# too, because a group that can't reach its own full member count is the confusing
# case ("why is database 4/9?"). `--no-all` (aka --core/--lean/--min) is the opt-out
# for when you only want the always-on services. `--all` is still accepted, it just
# doesn't change anything now.
function Split-AllFlag([string[]]$words) {
  $all = $true
  $rest = [System.Collections.Generic.List[string]]::new()
  foreach ($w in @($words | Where-Object { $_ })) {
    if ($w -in @("--all", "-a", "all", "full", "semua")) { $all = $true }
    elseif ($w -in @("--no-all", "--core", "--lean", "--min", "core", "lean", "min", "minimal")) { $all = $false }
    else { $rest.Add($w) }
  }
  return @{ All = $all; Rest = @($rest) }
}

function Invoke-StartOne([string]$groupName, [bool]$All = $false) {
  Ensure-Dependencies $groupName
  $svcs = $SvcGroups[$groupName]

  $profileArgs = @()
  if ($All) {
    foreach ($p in @($GroupProfiles[$groupName])) {
      if ($p) { $profileArgs += @("--profile", $p) }
    }
  }
  if ($profileArgs.Count -gt 0) {
    # Straight to `up -d`, no `start` first: with profiles on, the containers usually
    # don't exist yet and `up` is what creates them (and pulls their images). Profile
    # flags belong before the subcommand: `docker compose --profile x up -d`.
    Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
    Write-Host "docker compose -f $($GroupFile[$groupName]) $($profileArgs -join ' ') up -d"
    Invoke-Compose $groupName ($profileArgs + @("up", "-d"))
    return
  }

  Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
  Write-Host "docker compose -f $($GroupFile[$groupName]) start $($svcs -join ' ')"
  # `start` only works on containers that already exist - first-ever run falls back to
  # `up -d` to actually create them.
  Invoke-Compose $groupName (@("start") + $svcs)
  if ($LASTEXITCODE -ne 0) { Invoke-Compose $groupName @("up", "-d") }
  # Only reachable via --no-all now, but say it out loud where it's actionable: this
  # start deliberately left the profile-gated services (replicas, cluster nodes)
  # alone, so the group will read "up" without them.
  $dormant = (Get-GroupState $groupName).Dormant
  if ($dormant -gt 0) {
    Write-Host "  (+$dormant service di balik profile dilewatin - 'cpg start $groupName' tanpa --no-all buat nyalain semua)" -ForegroundColor DarkGray
  }
}

# Accepts zero, one, or many group names (e.g. `cpg start db ai messaging`). Zero ->
# pick-from-menu (single choice, as before). One or more -> each is resolved and
# started independently; a bad name in the middle just gets skipped (with a message)
# instead of aborting the rest of the batch.
function Invoke-Start([string[]]$groupNames) {
  if (-not (Ensure-DockerRunning)) { return }
  $flags = Split-AllFlag $groupNames
  $groupNames = $flags.Rest
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
    Invoke-StartOne $resolved $flags.All
  }
}

function Invoke-StopOne([string]$groupName) {
  $svcs = $SvcGroups[$groupName]
  Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
  Write-Host "docker compose -f $($GroupFile[$groupName]) stop $($svcs -join ' ')"
  Invoke-Compose $groupName (@("stop") + $svcs)
}

function Invoke-Stop([string[]]$groupNames) {
  # `stop` needs no profile flags (compose stops profile-gated containers by name
  # just fine), but accept and drop the token so `/stop db --all` isn't read as a
  # group named "--all".
  $groupNames = (Split-AllFlag $groupNames).Rest
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

function Invoke-RestartOne([string]$groupName, [bool]$All = $false) {
  Ensure-Dependencies $groupName
  $svcs = $SvcGroups[$groupName]
  if ($All) {
    # `restart` can't create anything, and with --all the profile-gated containers
    # may not exist yet - so stop what's up and bring the whole group up instead.
    Invoke-Compose $groupName (@("stop") + $svcs) *> $null
    Invoke-StartOne $groupName $true
    return
  }
  Write-Host -NoNewline "▸ " -ForegroundColor DarkYellow
  Write-Host "docker compose -f $($GroupFile[$groupName]) restart $($svcs -join ' ')"
  Invoke-Compose $groupName (@("restart") + $svcs)
}

function Invoke-Restart([string[]]$groupNames) {
  if (-not (Ensure-DockerRunning)) { return }
  $flags = Split-AllFlag $groupNames
  $groupNames = $flags.Rest
  if ($groupNames.Count -eq 0) {
    $picked = Select-FromMenu "Grup mana yang mau di-restart?" @($SvcGroups.Keys)
    if (-not $picked) { Write-Host "(batal)" -ForegroundColor DarkGray; return }
    $groupNames = @($picked)
  }
  foreach ($g in $groupNames) {
    $resolved = Resolve-GroupOrDie $g
    if (-not $resolved) { continue }
    Invoke-RestartOne $resolved $flags.All
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
[host] semua alamat di bawah = akses dari LUAR docker (Windows/host tool langsung -
psql, mongo-express di browser, dst). Connect dari CONTAINER lain di project ini
(join network cpg-database)? Pake nama service (postgres, mongo-primary, dst) bukan
localhost, dan port INTERNAL container-nya (liat compose/database.yml), bukan port
yang di-map ke host di bawah ini - beda buat beberapa service (misal pgpool).

postgres  (master, read/write, always on)
  host: localhost   port: 5432   user: admin   pass: password   db: sample
  psql:  psql -h localhost -p 5432 -U admin -d sample
  jdbc:  jdbc:postgresql://localhost:5432/sample
  uri:   postgresql://admin:password@localhost:5432/sample

postgres-replica-1  (read-only standby, profile: postgres-replica)
  host: localhost   port: 5443   user: admin   pass: password   db: sample
  uri:   postgresql://admin:password@localhost:5443/sample

postgres-replica-2  (read-only standby, profile: postgres-replica)
  host: localhost   port: 5444   user: admin   pass: password   db: sample
  uri:   postgresql://admin:password@localhost:5444/sample

pgpool  (round-robin read routing across replicas, writes -> master, profile: postgres-replica)
  host: localhost   port: 5433   user: admin   pass: password   db: sample
  psql:  psql -h localhost -p 5433 -U admin -d sample
  uri:   postgresql://admin:password@localhost:5433/sample
  admin UI login: admin / password

timescaledb
  host: localhost   port: 6543   user: admin   pass: password   db: sample
  psql:  psql -h localhost -p 6543 -U admin -d sample
  uri:   postgresql://admin:password@localhost:6543/sample

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
  [container] konek cuma ke mongo-primary, GAK cluster-aware (ME_CONFIG_MONGODB_SERVER
    di-set ke satu host doang) - dan gak bisa gampang dibikin cluster-aware: replica
    set member ini self-announce sbg 127.0.0.1 (trik biar kebuka dari Windows host),
    jadi kalo mongo-express (atau container lain) nyoba connect pake replicaSet=rs0,
    discovery-nya nyasar connect ke DIRINYA SENDIRI (udah dicoba: MongoNetworkError
    ECONNREFUSED 127.0.0.1:27017). Gapapa sih - primary punya semua data (replica
    cuma mirror), browsing tetep lengkap. Mau cek replica spesifik? mongosh langsung:
    mongosh "mongodb://admin:password@localhost:27019"   (ganti 27020 buat replica-2)
"@
    }
    "cache" {
      Write-Host @"
=== cache ===
[host] semua alamat di bawah = akses dari LUAR docker. Dari CONTAINER lain di
project ini (join network cpg-cache), pake nama service (redis) bukan localhost.

redis
  host: localhost   port: 6379   pass: password
  cli:  redis-cli -h localhost -p 6379 -a password
  uri:  redis://:password@localhost:6379

redis-insight  (web UI, no login by default)
  url: http://localhost:5540   <- [host] buka ini di browser
  [container] tapi field koneksi DI DALEM redis-insight sendiri: redis-insight jalan
    sbg container juga di network cpg-cache, jadi "localhost" di situ = dirinya
    sendiri, bukan redis. Isi: host=redis, port=6379, username=(kosongin), pass=password

redis-cluster-1..6  (profile: redis-cluster)
  hosts: localhost:17001-17006   pass: password   (bus: 27001-27006)
  cli:   redis-cli -c -h localhost -p 17001 -a password  (-c follows MOVED redirects)
  seed uri: redis://:password@localhost:17001   (client harus cluster-aware buat
    ngikutin MOVED ke node lain - satu seed URI ini gak cukup buat client biasa)
  [container] nambahin ke redis-insight: JANGAN pilih tipe "Cluster" - node-node ini
    self-announce sbg 127.0.0.1 (trik biar kebuka dari Windows host), jadi discovery
    cluster-mode dari container lain nyasar connect ke dirinya sendiri (udah dicoba,
    ECONNREFUSED). Tambahin tiap node satu2 sbg koneksi "Standalone" biasa: semua 6
    node numpang network redis-cluster-1 (network_mode: service:redis-cluster-1),
    jadi host-nya SAMA buat semua - host=redis-cluster-1, port=17001 (ulangi utk
    17002..17006), pass=password.
  ports geser dari 7000-7005 - macOS AirPlay Receiver nempatin 7000 & 5000
"@
    }
    "messaging" {
      Write-Host @"
=== messaging ===
[host] alamat di bawah = akses dari LUAR docker. Dari container lain di project ini
(join network cpg-messaging), pake nama service (rabbitmq) bukan localhost.

rabbitmq
  amqp:  amqp://admin:password@localhost:5672
  management UI: http://localhost:15672   login: admin / password
"@
    }
    "observability" {
      Write-Host @"
=== observability ===
[host] alamat di bawah = akses dari LUAR docker. App yang lo develop DI DALEM
container lain (join network cpg-observability) kirim trace/metric ke nama service
(otel-collector) bukan localhost - app yang jalan langsung di host tetep pake
localhost seperti biasa.

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
[host] alamat di bawah = akses dari LUAR docker (browser di Windows).

sonarqube
  url: http://localhost:9000
  default login: admin / admin   (SonarQube forces a password change on first login)
"@
    }
    "ai" {
      Write-Host @"
=== ai ===

chromadb  (no auth by default)
  url: http://localhost:8100   <- [host] akses dari luar docker
  heartbeat: http://localhost:8100/api/v2/heartbeat
  [container] app lo sendiri jalan sbg container yang di-join ke cpg-database +
    cpg-cache (kayak chromadb sendiri, liat compose/ai.yml)? Pake host=chromadb,
    port=8100 - bukan localhost.
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
      # The relaunch + `exit` below never unwinds Start-ReplPinned's finally block,
      # so the scroll region and the alternate screen are released by hand here.
      Disable-PinnedRegion
      Disable-AltScreen
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
  # Short commit in the banner: a running cpg keeps the OLD code in memory, so after
  # a `git pull` the only way to tell what you're actually looking at is a version
  # marker.
  $ver = git rev-parse --short HEAD 2>$null
  $suffix = if ($LASTEXITCODE -eq 0 -and $ver) { " · $($ver.Trim())" } else { "" }
  Write-Host "/help buat commands · /exit buat keluar$suffix" -ForegroundColor DarkGray
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

# --- pinned bottom input (DECSTBM scroll region + raw key loop) ------------
#
# Same split-pane idea as the bash side: the terminal's own scroll region
# (DECSTBM, `ESC [ top;bot r`) is shrunk to everything ABOVE the input box, so
# command output scrolls in the top pane while the bottom 4 rows (hint, box top,
# input line, box bottom) never move. The terminal keeps its own scrollback - we
# only choose where output lands (always the region's bottom margin, so content
# rises out of the input box like a chat log).
#
# Read-Host can't live in here (no way to hook its line editing), so keys are read
# one at a time with [Console]::ReadKey and cursor motion, history and completion
# are done by hand. Start-ReplClassic stays as the fallback.

$script:PinnedOn = $false
$script:PinnedRows = 24
$script:PinnedCols = 80
$script:PinnedBottom = 20
$script:PinnedReserved = 4 # hint + box top + input line + box bottom
$script:PinnedHint = "contoh: /status, /start db, /detail, /help"
$script:CpgHistory = @()
$script:PaneEmpty = $true # fresh/just-cleared pane fills from the top, not the bottom
$script:AltOn = $false
$script:Scroll = 0        # lines the pane is scrolled back from the newest output
$script:LastStatus = @{}  # group -> last Get-GroupState, for re-fitting on repaint
$script:ReplQuit = $false
$script:E = [char]27

# Console.Out.Write, not Write-Host: no trailing newline, no host-side wrapping of
# the escape sequences.
function Write-Vt([string]$s) {
  [Console]::Out.Write($s)
}

function Update-TermSize {
  $w = 80
  $h = 24
  try {
    $sz = $Host.UI.RawUI.WindowSize
    if ($sz.Width -gt 0) { $w = $sz.Width }
    if ($sz.Height -gt 0) { $h = $sz.Height }
  } catch { }
  $script:PinnedCols = $w
  $script:PinnedRows = $h
  $script:PinnedBottom = [Math]::Max(1, $h - $script:PinnedReserved)
}

# The scroll region is a *terminal* feature: Windows Terminal and any VT-enabled
# host honour it, legacy conhost ignores it outright (output would scroll straight
# over the input box), so this only turns on where VT is really available.
# CPG_PINNED=0 is the escape hatch if some host still renders it wrong.
function Test-PinnedSupport {
  if ($env:CPG_PINNED -eq "0") { return $false }
  try {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
  } catch {
    return $false
  }
  $vt = $false
  try { $vt = [bool]$Host.UI.SupportsVirtualTerminal } catch { $vt = $false }
  if (-not $vt -and -not $env:WT_SESSION) { return $false }
  Update-TermSize
  return ($script:PinnedRows -ge 10 -and $script:PinnedCols -ge 24)
}

# The alternate screen is what makes the box unmovable: with no scrollback of its
# own there is nothing to scroll it out of view, and looking back through output is
# Option/Fn+arrows instead, repainted from the mirror. No mouse tracking is armed -
# that would take drags away from the terminal and break text selection.
function Enable-AltScreen {
  if ($env:CPG_ALTSCREEN -eq "0") { return }
  $script:AltOn = $true
  # The wheel can still reach the main screen's scrollback in some terminals, so
  # scrolling up can leave cpg's screen. CPG_CLEAR_SCROLLBACK=1 wipes that
  # scrollback and stops it dead - opt-in, because it destroys what was in the
  # window before cpg started.
  if ($env:CPG_CLEAR_SCROLLBACK -and $env:CPG_CLEAR_SCROLLBACK -ne "0") {
    Write-Vt "$($script:E)[H$($script:E)[2J$($script:E)[3J"
  }
  Write-Vt "$($script:E)[?1049h"
}

# MUST run before leaving (finally block, and before Invoke-Update relaunches): back
# to the main screen, with the session's output handed to the real scrollback so
# leaving doesn't throw it away.
function Disable-AltScreen {
  if (-not $script:AltOn) { return }
  $script:AltOn = $false
  Write-Vt "$($script:E)[?1049l"
  if ($script:PaneLog -and (Test-Path $script:PaneLog)) {
    try {
      $tail = Get-Content -LiteralPath $script:PaneLog -Tail 500 -Encoding UTF8 -ErrorAction Stop
      foreach ($line in $tail) { [Console]::Out.Write("$line`r`n") }
    } catch { }
  }
}

function Enable-PinnedRegion {
  $script:PinnedOn = $true
  # DECSTBM homes the cursor, hence the explicit move back down into the region.
  Write-Vt "$($script:E)[1;$($script:PinnedBottom)r$($script:E)[$($script:PinnedBottom);1H"
}

# MUST run before leaving pinned mode (the finally block, and before Invoke-Update
# relaunches) - skip it and the user is left in a terminal that only scrolls its
# top rows.
function Disable-PinnedRegion {
  if (-not $script:PinnedOn) { return }
  $script:PinnedOn = $false
  Write-Vt "$($script:E)[r$($script:E)[$($script:PinnedRows);1H$($script:E)[0m`r`n"
}

# Puts the cursor back where the last pane output ended (DECRC, ESC 8), so a fresh or
# just-cleared pane fills from the TOP and only starts scrolling once it's full -
# output nailed to the bottom margin left the banner floating at the bottom of an
# otherwise empty screen. Re-asserts the region first: Clear-Host, docker's progress
# renderer or anything else that resets the margins behind our back gets corrected
# here (DECSTBM homes the cursor, hence the restore right after it). The blank
# separator row is skipped while the pane is still empty.
function Enter-Pane {
  Reset-Scroll
  $out = "$($script:E)[1;$($script:PinnedBottom)r$($script:E)8"
  if (-not $script:PaneEmpty) { $out += "`r`n" }
  Write-Vt $out
}

# Hands the pane cursor back for the next Enter-Pane (DECSC, ESC 7). The terminal is
# the one tracking it, so it stays right through wrapped lines.
function Save-PaneCursor {
  $script:PaneEmpty = $false
  Write-Vt "$($script:E)7"
}

# Strips the colour escapes off a line, so it can be measured and matched.
function Get-PlainText([string]$text) {
  return ($text -replace "$([char]27)\[[0-9;]*[A-Za-z]", "")
}

# How many screen rows a line takes: wider than the terminal means it wraps.
function Get-LineRows([string]$text) {
  $len = (Get-PlainText $text).Length
  $h = [Math]::Ceiling($len / [double]$script:PinnedCols)
  if ($h -lt 1) { $h = 1 }
  return [int]$h
}

# A replayed status line was laid out for the width it was printed at, so re-render
# it from the remembered snapshot instead: same fit-as-many logic, current width,
# still exactly one row. Everything else replays as-is.
function Get-RefittedLine([string]$line) {
  $plain = Get-PlainText $line
  if ($plain -match '^\s+●\s+([a-z][a-z-]*)\s') {
    $info = $script:LastStatus[$Matches[1]]
    if ($info) { return (Get-GroupLineText $info) }
  }
  return $line
}

# Wipes the pane and replays a screenful of the mirror, $script:Scroll lines back
# from the newest output. Rows are counted, not lines: a screenful containing a
# wrapped line needs more rows than the pane has, and the overflow would scroll the
# top line out of view.
function Repaint-Pane {
  $e = $script:E
  Write-Vt "$e[r$e[1;1H$e[0J$e[1;$($script:PinnedBottom)r$e[1;1H"
  if (-not $script:PaneLog -or -not (Test-Path $script:PaneLog)) {
    Write-Vt "$e`7"
    return
  }
  $all = @(Get-Content -LiteralPath $script:PaneLog -Encoding UTF8 -ErrorAction SilentlyContinue)
  if ($all.Count -eq 0) {
    Write-Vt "$e`7"
    return
  }
  $end = $all.Count - $script:Scroll
  if ($end -lt 1) { $end = 1 }
  $from = [Math]::Max(0, $end - ($script:PinnedBottom * 2))
  $cand = @()
  for ($i = $from; $i -lt $end; $i++) { $cand += (Get-RefittedLine $all[$i]) }

  $rows = 0
  $start = $cand.Count
  for ($i = $cand.Count - 1; $i -ge 0; $i--) {
    $h = Get-LineRows $cand[$i]
    if ($rows + $h -gt $script:PinnedBottom) { break }
    $rows += $h
    $start = $i
  }
  $out = ""
  for ($i = $start; $i -lt $cand.Count; $i++) {
    if ($i -gt $start) { $out += "`r`n" }
    $out += $cand[$i]
  }
  # DECSC hands the position back to Enter-Pane for the next command.
  Write-Vt ($out + "$e`7")
  $script:PaneEmpty = $false
}

# Furthest scroll offset that still fills the pane, counted in lines but measured in
# rows - so the oldest output is actually reachable even when lines wrap.
function Get-ScrollMax {
  if (-not $script:PaneLog -or -not (Test-Path $script:PaneLog)) { return 0 }
  $all = @(Get-Content -LiteralPath $script:PaneLog -Encoding UTF8 -ErrorAction SilentlyContinue)
  if ($all.Count -eq 0) { return 0 }
  $rows = 0
  $k = 0
  foreach ($line in $all) {
    $h = Get-LineRows $line
    if ($rows + $h -gt $script:PinnedBottom) { break }
    $rows += $h
    $k++
  }
  if ($k -lt 1) { $k = 1 }
  return [Math]::Max(0, $all.Count - $k)
}

function Move-Scroll([int]$delta) {
  $max = Get-ScrollMax
  $want = $script:Scroll + $delta
  if ($want -lt 0) { $want = 0 }
  if ($want -gt $max) { $want = $max }
  if ($want -eq $script:Scroll) { return }
  $script:Scroll = $want
  Repaint-Pane
}

function Reset-Scroll {
  if ($script:Scroll -eq 0) { return }
  $script:Scroll = 0
  Repaint-Pane
}

# Repaints the 4 pinned rows and parks the cursor inside the box. Long input scrolls
# horizontally (the window ends at the cursor) instead of wrapping - a wrapped line
# would grow into the border row.
function Show-PinnedPrompt([string]$buf, [int]$pos) {
  $e = $script:E
  $rows = $script:PinnedRows
  $cols = $script:PinnedCols
  $avail = [Math]::Max(8, $cols - 6)
  $start = 0
  if ($pos -gt $avail) { $start = $pos - $avail }
  $view = ""
  if ($buf.Length -gt $start) {
    $view = $buf.Substring($start, [Math]::Min($avail, $buf.Length - $start))
  }
  $hint = $script:PinnedHint
  if ($script:Scroll -gt 0) {
    $hint = "↑ $($script:Scroll) baris · Fn/Option+↓ buat balik, atau langsung ngetik"
  }
  if ($hint.Length -gt $cols) { $hint = $hint.Substring(0, $cols) }
  $bar = "─" * [Math]::Max(1, $cols - 2)
  $dim = "$e[2m"
  $accent = "$e[38;5;209m"
  $reset = "$e[0m"
  # Cursor hidden across the write, so a repaint can't be seen half-finished (that
  # shows up as a flicker per keystroke and a stuttering box while dragging a resize).
  $out = "$e[?25l"
  $out += "$e[$($rows - 3);1H$e[2K$dim$hint$reset"
  $out += "$e[$($rows - 2);1H$e[2K$dim╭$bar╮$reset"
  $out += "$e[$($rows - 1);1H$e[2K$dim│$reset $accent❯$reset $view"
  $out += "$e[$($rows - 1);${cols}H$dim│$reset"
  $out += "$e[$rows;1H$e[2K$dim╰$bar╯$reset"
  $out += "$e[$($rows - 1);$($pos - $start + 5)H$e[?25h"
  Write-Vt $out
}

# Tab-completion: /command names first, then group names once a command word is
# typed. Returns the (possibly rewritten) line, the new cursor point, and every
# candidate so the caller can list them when it's ambiguous.
function Complete-CpgLine([string]$line, [int]$point) {
  $prefix = $line.Substring(0, $point)
  $cands = @()
  if ($prefix -match '^/?([a-zA-Z_-]*)$') {
    $word = $Matches[1]
    $cands = @($Cmds | Where-Object { $_.StartsWith($word) })
    if ($cands.Count -eq 1) {
      $newLine = "/$($cands[0]) "
      return @{ Line = $newLine; Point = $newLine.Length; Matches = $cands }
    }
  } elseif ($prefix -match '^/?([a-zA-Z_-]+)\s+([a-zA-Z_-]*)$') {
    $word = $Matches[2]
    $cands = @(@($SvcGroups.Keys) | Where-Object { $_.StartsWith($word) })
    if ($cands.Count -eq 1) {
      $newLine = $line.Substring(0, $point - $word.Length) + $cands[0]
      return @{ Line = $newLine; Point = $newLine.Length; Matches = $cands }
    }
  }
  return @{ Line = $line; Point = $point; Matches = $cands }
}

# Raw line editor: everything Read-Host gave us for free, by hand. Returns the
# submitted line, or $null for Ctrl-C / Ctrl-D (i.e. "leave the REPL").
function Read-PinnedLine {
  $buf = ""
  $pos = 0
  $saved = ""
  $hidx = $script:CpgHistory.Count
  Show-PinnedPrompt $buf $pos
  while ($true) {
    # Idle poll instead of a straight blocking ReadKey: a resize has to be noticed
    # while waiting at the prompt. KeyAvailable only peeks, so the keystroke is
    # still there for ReadKey right after.
    while (-not [Console]::KeyAvailable) {
      Start-Sleep -Milliseconds 120
      $pr = $script:PinnedRows
      $pc = $script:PinnedCols
      Update-TermSize
      if ($pr -ne $script:PinnedRows -or $pc -ne $script:PinnedCols) {
        # Don't try to patch up however the emulator reflowed the pane - wipe it and
        # replay from the mirror at the new width, status lines re-fitted.
        Repaint-Pane
        Show-PinnedPrompt $buf $pos
      }
    }
    $k = [Console]::ReadKey($true)
    $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $shift = ($k.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
    $alt = ($k.Modifiers -band [ConsoleModifiers]::Alt) -ne 0
    # Scrolling the pane: Option/Alt or Shift with the arrows (3 lines), Fn+arrows
    # i.e. PageUp/PageDown (half a screen), Ctrl-B/Ctrl-F (a screen). The box itself
    # never moves - it lives outside the scroll region.
    if (($alt -or $shift) -and $k.Key -eq "UpArrow") { Move-Scroll 3; Show-PinnedPrompt $buf $pos; continue }
    if (($alt -or $shift) -and $k.Key -eq "DownArrow") { Move-Scroll -3; Show-PinnedPrompt $buf $pos; continue }
    if ($k.Key -eq "PageUp") { Move-Scroll ([int][Math]::Floor($script:PinnedBottom / 2)); Show-PinnedPrompt $buf $pos; continue }
    if ($k.Key -eq "PageDown") { Move-Scroll (-[int][Math]::Floor($script:PinnedBottom / 2)); Show-PinnedPrompt $buf $pos; continue }
    if ($ctrl -and $k.Key -eq "B") { Move-Scroll ($script:PinnedBottom - 2); Show-PinnedPrompt $buf $pos; continue }
    if ($ctrl -and $k.Key -eq "F") { Move-Scroll (-($script:PinnedBottom - 2)); Show-PinnedPrompt $buf $pos; continue }
    switch ($k.Key) {
      "Enter" { return $buf }
      "Backspace" {
        if ($pos -gt 0) {
          $buf = $buf.Remove($pos - 1, 1)
          $pos--
        }
      }
      "Delete" {
        if ($pos -lt $buf.Length) { $buf = $buf.Remove($pos, 1) }
      }
      "LeftArrow" { if ($pos -gt 0) { $pos-- } }
      "RightArrow" { if ($pos -lt $buf.Length) { $pos++ } }
      "Home" { $pos = 0 }
      "End" { $pos = $buf.Length }
      "UpArrow" {
        Reset-Scroll
        if ($hidx -gt 0) {
          if ($hidx -eq $script:CpgHistory.Count) { $saved = $buf }
          $hidx--
          $buf = $script:CpgHistory[$hidx]
          $pos = $buf.Length
        }
      }
      "DownArrow" {
        Reset-Scroll
        if ($hidx -lt $script:CpgHistory.Count) {
          $hidx++
          if ($hidx -eq $script:CpgHistory.Count) {
            $buf = $saved
          } else {
            $buf = $script:CpgHistory[$hidx]
          }
          $pos = $buf.Length
        }
      }
      "Escape" {
        $buf = ""
        $pos = 0
      }
      "Tab" {
        Reset-Scroll
        $r = Complete-CpgLine $buf $pos
        $buf = $r.Line
        $pos = $r.Point
        if ($r.Matches.Count -gt 1) {
          Enter-Pane
          Write-Host ("  " + ($r.Matches -join " ")) -ForegroundColor DarkGray
          Save-PaneCursor
        }
      }
      default {
        if ($ctrl) {
          switch ($k.Key) {
            "C" { return $null }
            "D" { if (-not $buf) { return $null } }
            "A" { $pos = 0 }
            "E" { $pos = $buf.Length }
            "U" {
              $buf = $buf.Substring($pos)
              $pos = 0
            }
            "K" { $buf = $buf.Substring(0, $pos) }
            "L" {
              # Wipe the pane, and the mirror with it - otherwise the next resize or
              # scroll replays exactly what was just cleared.
              if ($script:PaneLog) { try { Set-Content -LiteralPath $script:PaneLog -Value "" -NoNewline } catch { } }
              $script:Scroll = 0
              Write-Vt "$($script:E)[1;1H$($script:E)[0J$($script:E)7"
              $script:PaneEmpty = $true
            }
          }
        } elseif ($k.KeyChar -ne [char]0 -and -not [Char]::IsControl($k.KeyChar)) {
          # Typing means you're done reading back.
          Reset-Scroll
          $buf = $buf.Insert($pos, $k.KeyChar)
          $pos++
        }
      }
    }
    Show-PinnedPrompt $buf $pos
  }
}

# --- REPL bodies -----------------------------------------------------------

function Show-Intro {
  Show-Banner
  Test-ForUpdate
  Write-Host ""
  Show-Status ""
}

# One typed line -> one command. Shared by both prompts. Sets $script:ReplQuit when
# the line means "leave the REPL" - a flag rather than a return value, because any
# stray pipeline output from the commands it dispatches would ride along with a
# returned $true/$false and break the caller's test.
function Invoke-ReplLine([string]$line) {
  $line = $line.TrimStart("/")
  if (-not $line.Trim()) { return }
  $parts = $line -split '\s+', 2
  $subCmd = $parts[0]
  $subArg = if ($parts.Count -gt 1) { $parts[1] } else { "" }
  # start/stop/restart can take several groups at once (e.g. `/start db ai messaging`).
  $subArgs = @($subArg -split '\s+' | Where-Object { $_ })

  if ($subCmd -in @("exit", "quit", "q")) {
    $script:ReplQuit = $true
    return
  }
  if ($subCmd -in @("-h", "--help", "help")) {
    Show-Help
    return
  }
  if ($subCmd -in @("clear", "cls")) {
    # Pane cursor back to the top, so the banner lands there instead of at the
    # bottom margin (pinned mode only - Clear-Host is enough on its own otherwise).
    # The mirror goes too, or the next scroll/resize replays what was just cleared.
    $script:PaneEmpty = $true
    $script:Scroll = 0
    if ($script:PaneLog) { try { Set-Content -LiteralPath $script:PaneLog -Value "" -NoNewline } catch { } }
    Clear-Host
    Show-Banner
    Write-Host ""
    Show-Status ""
    return
  }

  $resolved = Resolve-Choice $subCmd $CmdAlias $Cmds
  if (-not $resolved) {
    Write-Host "  (/help buat liat semua command)" -ForegroundColor DarkGray
    return
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

function Start-ReplPinned {
  Update-TermSize
  $prevCtrlC = $false
  try { $prevCtrlC = [Console]::TreatControlCAsInput } catch { }
  try {
    $script:PaneLog = [System.IO.Path]::GetTempFileName()
    # Ctrl-C as a *signal* could kill the process mid-region and leave the terminal
    # only scrolling its top rows; as input it's just another key to handle.
    try { [Console]::TreatControlCAsInput = $true } catch { }
    Enable-AltScreen
    # Start clean, with the pane cursor seeded at the top of the screen.
    Write-Vt "$($script:E)[2J$($script:E)[H$($script:E)7"
    $script:PaneEmpty = $true
    Enable-PinnedRegion
    Enter-Pane
    Show-Intro
    Save-PaneCursor
    while ($true) {
      $line = Read-PinnedLine
      if ($null -eq $line) { break }
      if (-not $line.Trim()) { continue }
      $script:CpgHistory += $line
      # Echo the submitted line into the output pane, so the scrollback reads like a
      # shell session (the input box itself is cleared for the next command).
      Enter-Pane
      Write-Host -NoNewline "❯ " -ForegroundColor DarkYellow
      Write-Host $line
      Invoke-ReplLine $line
      Save-PaneCursor
      if ($script:ReplQuit) { break }
    }
  } finally {
    Disable-PinnedRegion
    Disable-AltScreen
    if ($script:PaneLog) {
      try { Remove-Item -LiteralPath $script:PaneLog -Force -ErrorAction SilentlyContinue } catch { }
      $script:PaneLog = ""
    }
    try { [Console]::TreatControlCAsInput = $prevCtrlC } catch { }
  }
  Write-Host "Bye."
}

# Fallback prompt for hosts that can't take the pinned box: the box is redrawn per
# turn instead of staying put, and Read-Host does the line editing.
function Start-ReplClassic {
  Show-Intro
  while ($true) {
    Write-Host ""
    # A framed input area, like Claude Code's own prompt box - both borders are
    # actually drawn (with a blank line reserved between them) BEFORE Read-Host
    # starts, then the console cursor is walked back up onto that blank line.
    # Read-Host only ever redraws its own current line, so the borders above and
    # below stay put while typing.
    Write-Host $script:PinnedHint -ForegroundColor DarkGray
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
    Invoke-ReplLine $line
    if ($script:ReplQuit) { break }
  }
  Write-Host "Bye."
}

function Start-Repl {
  $script:IsRepl = $true
  try { $Host.UI.RawUI.WindowTitle = "✳  cpg-cli" } catch { }
  if (Test-PinnedSupport) {
    Start-ReplPinned
  } else {
    Start-ReplClassic
  }
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
