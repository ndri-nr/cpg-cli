<#
.SYNOPSIS
  Interactive start/stop/restart by group. Each group is its OWN docker-compose project
  (compose/<group>.yml), so this wraps `docker compose -f compose/<group>.yml ...` per
  group instead of filtering services within one file.

  Forgiving input: case-insensitive, understands common aliases (db, redis, rabbit,
  sonar, chroma, up/down, ...), unique prefixes (e.g. "obs" -> observability), and for
  an unrecognized-but-close typo it asks "did you mean X?" instead of just failing.

.EXAMPLE
  ./docker-group.ps1                  interactive menu (asks start or stop, then group)
  ./docker-group.ps1 status           show every group + running/total count
  ./docker-group.ps1 status cache     show just that group's status
  ./docker-group.ps1 start            pick from groups that aren't fully up
  ./docker-group.ps1 start db         start a specific group (alias for database)
  ./docker-group.ps1 stop             pick from groups that have something running
  ./docker-group.ps1 stop rabbit
  ./docker-group.ps1 restart [group]
  ./docker-group.ps1 help
#>
param(
  [Parameter(Position = 0)]
  [string]$Command = "",

  [Parameter(Position = 1)]
  [string]$Group = ""
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

$SvcGroups = [ordered]@{
  database      = @("postgres", "postgres-replica-1", "postgres-replica-2", "pgpool", "timescaledb", "mongodb", "mongo-express")
  cache         = @("redis", "redis-insight", "redis-cluster-1", "redis-cluster-2", "redis-cluster-3", "redis-cluster-4", "redis-cluster-5", "redis-cluster-6", "redis-cluster-init")
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
}
$Cmds = @("status", "start", "stop", "restart", "detail")

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

function Resolve-Choice([string]$val, [hashtable]$aliasMap, [string[]]$options) {
  $val = $val.ToLowerInvariant()
  if ($options -contains $val) { return $val }
  if ($aliasMap.ContainsKey($val)) { return $aliasMap[$val] }

  $prefixMatches = $options | Where-Object { $_.StartsWith($val) }
  if (@($prefixMatches).Count -eq 1) { return $prefixMatches }

  $best = $null; $bestDist = [int]::MaxValue
  foreach ($o in $options) {
    $dist = Get-Levenshtein $val $o
    if ($dist -lt $bestDist) { $bestDist = $dist; $best = $o }
  }
  if ($best -and $bestDist -le 2) {
    $yn = Read-Host "Gak nemu persis '$val'. Maksud lu '$best'? (y/n)"
    if ($yn -match '^[Yy]') { return $best }
  }
  return $null
}

# Returns the resolved group name, or $null (after printing why) if it can't figure
# it out - never exits the process, so the REPL loop can recover from a bad name
# instead of the whole shell dying.
function Resolve-GroupOrDie([string]$val) {
  if ($SvcGroups.Contains($val)) { return $val }
  $resolved = Resolve-Choice $val $GroupAlias @($SvcGroups.Keys)
  if ($resolved) { return $resolved }
  Write-Host "Gak nemu grup '$val'. Grup yang ada: $($SvcGroups.Keys -join ', ')"
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
  Write-Host -NoNewline ("{0,-16}" -f $info.Group)
  Write-Host -NoNewline "[$($info.Running)/$($info.Total) running]  " -ForegroundColor $color
  Write-Host ($info.Services -join " ") -ForegroundColor DarkGray
}

function Show-Status([string]$filter) {
  if ($filter) {
    $filter = Resolve-GroupOrDie $filter
    if (-not $filter) { return }
  }
  Write-Host "GROUP            STATUS"
  foreach ($g in $SvcGroups.Keys) {
    if ($filter -and $g -ne $filter) { continue }
    Write-GroupLine (Get-GroupState $g)
  }
}

function Select-FromMenu([string]$prompt, [string[]]$choices) {
  Write-Host $prompt
  for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host "  $($i + 1)) $($choices[$i])" }
  Write-Host "  0) cancel"
  $pick = Read-Host "Pilih nomor"
  if ($pick -eq "0" -or [string]::IsNullOrWhiteSpace($pick)) { return $null }
  if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $choices.Count) {
    Write-Host "Pilihan gak valid."
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
  ./docker-group.ps1                    masuk interactive shell (prompt cpg>, ketik /status /start dst berulang)
  ./docker-group.ps1 status [grup]      liat status (semua grup, atau 1 grup doang)
  ./docker-group.ps1 start  [grup]      nyalain grup (tanpa nama -> pilih dari yg belum full up)
  ./docker-group.ps1 stop   [grup]      matiin grup  (tanpa nama -> pilih dari yg lagi jalan)
  ./docker-group.ps1 restart [grup]
  ./docker-group.ps1 detail [grup]      connection info (host/port/user/pass/URI) per service

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
      Write-Host "'$groupName' butuh network '$dep' - nyalain dulu..." -ForegroundColor Yellow
      Invoke-Compose $dep @("up", "-d")
    }
  }
}

# These `return` on every early-out, never `exit` - they run inside the REPL loop too,
# where `exit` would kill the whole shell instead of just aborting one command.
function Invoke-Start([string]$groupName) {
  if ($groupName) {
    $groupName = Resolve-GroupOrDie $groupName
    if (-not $groupName) { return }
  }
  if (-not $groupName) {
    $candidates = $SvcGroups.Keys | Where-Object { (Get-GroupState $_).State -ne "up" }
    if (-not $candidates) {
      Write-Host "Semua grup udah nyala semua." -ForegroundColor Green
      return
    }
    $groupName = Select-FromMenu "Grup mana yang mau di-start?" @($candidates)
    if (-not $groupName) { Write-Host "Batal."; return }
  }
  Ensure-Dependencies $groupName
  $svcs = $SvcGroups[$groupName]
  Write-Host "==> docker compose -f $($GroupFile[$groupName]) start $($svcs -join ' ')"
  # `start` only works on containers that already exist - first-ever run falls back to
  # `up -d` to actually create them.
  Invoke-Compose $groupName (@("start") + $svcs)
  if ($LASTEXITCODE -ne 0) { Invoke-Compose $groupName @("up", "-d") }
}

function Invoke-Stop([string]$groupName) {
  if ($groupName) {
    $groupName = Resolve-GroupOrDie $groupName
    if (-not $groupName) { return }
  }
  if (-not $groupName) {
    $candidates = $SvcGroups.Keys | Where-Object { (Get-GroupState $_).State -ne "down" }
    if (-not $candidates) {
      Write-Host "Emang lagi gak ada yang jalan." -ForegroundColor Yellow
      return
    }
    $groupName = Select-FromMenu "Grup mana yang mau di-stop?" @($candidates)
    if (-not $groupName) { Write-Host "Batal."; return }
  }
  $svcs = $SvcGroups[$groupName]
  Write-Host "==> docker compose -f $($GroupFile[$groupName]) stop $($svcs -join ' ')"
  Invoke-Compose $groupName (@("stop") + $svcs)
}

function Invoke-Restart([string]$groupName) {
  if ($groupName) {
    $groupName = Resolve-GroupOrDie $groupName
    if (-not $groupName) { return }
  }
  if (-not $groupName) {
    $groupName = Select-FromMenu "Grup mana yang mau di-restart?" @($SvcGroups.Keys)
    if (-not $groupName) { Write-Host "Batal."; return }
  }
  Ensure-Dependencies $groupName
  $svcs = $SvcGroups[$groupName]
  Write-Host "==> docker compose -f $($GroupFile[$groupName]) restart $($svcs -join ' ')"
  Invoke-Compose $groupName (@("restart") + $svcs)
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
    if (-not $groupName) { Write-Host "Batal."; return }
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

mongodb
  host: localhost   port: 27017   user: admin   pass: password   db: sample (authSource=admin)
  uri:   mongodb://admin:password@localhost:27017/sample?authSource=admin

mongo-express  (web UI for mongodb)
  url: http://localhost:8888
  basic auth login: admin / admin   <- NOT the same as mongodb's creds above
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

# --- REPL (bare cpg, no args) ---------------------------------------------

function Start-Repl {
  Write-Host "cpg interactive shell. /help buat commands, /exit buat keluar." -ForegroundColor White
  Write-Host ""
  Show-Status ""
  while ($true) {
    Write-Host ""
    $line = Read-Host "cpg>"
    if ($null -eq $line) { break }
    $line = $line.TrimStart("/")
    if (-not $line.Trim()) { continue }
    $parts = $line -split '\s+', 2
    $subCmd = $parts[0]
    $subArg = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    if ($subCmd -in @("exit", "quit", "q")) { break }
    if ($subCmd -in @("-h", "--help", "help")) { Show-Help; continue }

    $resolved = Resolve-Choice $subCmd $CmdAlias $Cmds
    if (-not $resolved) {
      Write-Host "Gak ngerti command '$subCmd'. /help buat liat commands."
      continue
    }
    switch ($resolved) {
      "status" { Show-Status $subArg }
      "start" { Invoke-Start $subArg }
      "stop" { Invoke-Stop $subArg }
      "restart" { Invoke-Restart $subArg }
      "detail" { Show-Detail $subArg }
    }
  }
  Write-Host "Bye."
}

# --- entry ---------------------------------------------------------------

if ($Command -in @("-h", "--help", "help")) {
  Show-Help
  exit 0
}

if ($Command -and $Command -notin $Cmds) {
  $resolvedCmd = Resolve-Choice $Command $CmdAlias $Cmds
  if (-not $resolvedCmd) {
    Write-Host "Gak ngerti command '$Command'."
    Show-Help
    exit 1
  }
  $Command = $resolvedCmd
}

switch ($Command) {
  "status" { Show-Status $Group }
  "start" { Invoke-Start $Group }
  "stop" { Invoke-Stop $Group }
  "restart" { Invoke-Restart $Group }
  "detail" { Show-Detail $Group }
  "" { Start-Repl }
}
