#!/usr/bin/env bash
# Interactive start/stop/restart by group. Each group is its OWN docker-compose project
# (compose/<group>.yml), so this wraps `docker compose -f compose/<group>.yml ...` per
# group instead of filtering services within one file.
#
# Forgiving input: case-insensitive, understands common aliases (db, redis, rabbit,
# sonar, chroma, up/down, ...), unique prefixes (e.g. "obs" -> observability), and for
# an unrecognized-but-close typo it asks "did you mean X?" instead of just failing.
#
# Usage:
#   ./cpg-cli.sh                 interactive menu (asks start or stop, then group)
#   ./cpg-cli.sh status          show every group + running/total count
#   ./cpg-cli.sh status [group]  show just that group's status
#   ./cpg-cli.sh start [group]   start a group (no group = pick from what's not fully up)
#   ./cpg-cli.sh stop  [group]   stop a group  (no group = pick from what's running)
#   ./cpg-cli.sh restart [group]
#   ./cpg-cli.sh detail [group]  connection info (host/port/user/pass/URI) per service
#   ./cpg-cli.sh help
set -euo pipefail

cd "$(dirname "$0")"

# group -> compose file (relative to repo root)
declare -A GROUP_FILE=(
  [database]="compose/database.yml"
  [cache]="compose/cache.yml"
  [messaging]="compose/messaging.yml"
  [observability]="compose/observability.yml"
  [quality]="compose/quality.yml"
  [ai]="compose/ai.yml"
)
# group -> its services (space-separated). Only used for status/start/stop lists -
# `compose ps`/`start`/`stop` with no service args already means "every service in the
# file". Deliberately excludes one-shot bootstrap jobs (mongo-cluster-init,
# redis-cluster-init) - they're supposed to exit 0 and stay exited, so counting them
# would make a fully-healthy group show as "partial" forever. `up -d` (the first-run
# fallback in do_start) still creates them fine, this list just isn't used for that.
declare -A SVC_GROUPS=(
  [database]="postgres postgres-replica-1 postgres-replica-2 pgpool timescaledb mongo-primary mongo-replica-1 mongo-replica-2 mongo-express"
  [cache]="redis redis-insight redis-cluster-1 redis-cluster-2 redis-cluster-3 redis-cluster-4 redis-cluster-5 redis-cluster-6"
  [messaging]="rabbitmq"
  [observability]="otel-collector tempo prometheus grafana"
  [quality]="sonarqube"
  [ai]="chromadb"
)
# ai's chromadb attaches to database's and cache's networks (external, cross-project) -
# those two must be up (or at least have created their network) before ai can start.
declare -A GROUP_DEPENDS=(
  [ai]="database cache"
)
GROUP_ORDER=(database cache messaging observability quality ai)

declare -A GROUP_ALIAS=(
  [db]=database [postgres]=database [pg]=database [sql]=database [mongo]=database
  [redis]=cache [caching]=cache
  [rabbit]=messaging [rabbitmq]=messaging [mq]=messaging [broker]=messaging [queue]=messaging
  [monitoring]=observability [monitor]=observability [obs]=observability
  [grafana]=observability [metrics]=observability [tracing]=observability
  [sonar]=quality [sonarqube]=quality [codequality]=quality
  [vector]=ai [chroma]=ai [chromadb]=ai [vectordb]=ai [llm]=ai
)

declare -A CMD_ALIAS=(
  [up]=start [on]=start [run]=start [nyalain]=start [hidupkan]=start
  [down]=stop [off]=stop [kill]=stop [matiin]=stop [matikan]=stop
  [reboot]=restart [rs]=restart [re]=restart
  [st]=status [ls]=status [list]=status [stat]=status [stats]=status [cek]=status [check]=status
  [info]=detail [conn]=detail [connection]=detail [creds]=detail [credentials]=detail [cred]=detail
  [upgrade]=update [self-update]=update [pull]=update [upd]=update
  [remove]=uninstall [unlink]=uninstall
)
CMDS=(status start stop restart detail update uninstall)

if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_ACCENT=$'\033[38;5;209m' # warm coral/orange, closer to Claude's own accent than plain cyan
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_ACCENT=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

dc() { docker compose -f "${GROUP_FILE[$1]}" "${@:2}"; }

# --- fuzzy matching -------------------------------------------------------

levenshtein() {
  local s1="$1" s2="$2"
  local len1=${#s1} len2=${#s2}
  local -A d
  local i j cost del ins sub min
  for ((i = 0; i <= len1; i++)); do d[$i,0]=$i; done
  for ((j = 0; j <= len2; j++)); do d[0,$j]=$j; done
  for ((i = 1; i <= len1; i++)); do
    for ((j = 1; j <= len2; j++)); do
      [[ "${s1:i-1:1}" == "${s2:j-1:1}" ]] && cost=0 || cost=1
      del=$(( d[$((i-1)),$j] + 1 ))
      ins=$(( d[$i,$((j-1))] + 1 ))
      sub=$(( d[$((i-1)),$((j-1))] + cost ))
      min=$del
      (( ins < min )) && min=$ins
      (( sub < min )) && min=$sub
      d[$i,$j]=$min
    done
  done
  echo "${d[$len1,$len2]}"
}

# resolve_choice <input> <alias-map-name> <option...>
# Prints the resolved canonical option on success (exact match, alias, unique prefix,
# or a confirmed close-typo guess). Returns 1 if it can't figure it out - but not
# silently: prints the closest options ranked by similarity, so a totally-off guess
# still gets a useful recommendation instead of just "not found".
resolve_choice() {
  local input="${1,,}" alias_map="$2"; shift 2
  local options=("$@")
  local -n aliases="$alias_map"

  for o in "${options[@]}"; do [[ "$o" == "$input" ]] && { echo "$o"; return 0; }; done
  [[ -n "${aliases[$input]:-}" ]] && { echo "${aliases[$input]}"; return 0; }

  local matches=()
  for o in "${options[@]}"; do [[ "$o" == "$input"* ]] && matches+=("$o"); done
  if [[ ${#matches[@]} -eq 1 ]]; then echo "${matches[0]}"; return 0; fi

  local scored=() o d
  for o in "${options[@]}"; do
    d=$(levenshtein "$input" "$o")
    scored+=("$d:$o")
  done
  IFS=$'\n' scored=($(sort -t: -k1,1n <<<"${scored[*]}")); unset IFS

  local bestd="${scored[0]%%:*}" best="${scored[0]#*:}"
  if (( bestd <= 2 )); then
    echo -n "${C_YELLOW}?${C_RESET} Gak nemu persis '$input'. Maksud lu ${C_BOLD}${best}${C_RESET}? (y/n) " >&2
    local yn; read -r yn
    if [[ "$yn" =~ ^[Yy] ]]; then echo "$best"; return 0; fi
  else
    local i suggestions=()
    for i in "${scored[@]:0:3}"; do suggestions+=("${i#*:}"); done
    local IFS=', '
    echo "${C_RED}✗${C_RESET} Gak ngerti '$input'. Mirip² gini: ${C_BOLD}${suggestions[*]}${C_RESET}" >&2
  fi
  return 1
}

# Prints the resolved group name and returns 0, or returns 1 - never exits the
# process (needed so the REPL loop can recover from a bad group name instead of the
# whole shell dying). resolve_choice already told the user what it's close to; this
# just adds the full list as a last-resort fallback.
resolve_group_or_die() {
  local input="$1"
  [[ -n "${SVC_GROUPS[$input]:-}" ]] && { echo "$input"; return 0; }
  local resolved
  if resolved=$(resolve_choice "$input" GROUP_ALIAS "${GROUP_ORDER[@]}"); then
    echo "$resolved"; return 0
  fi
  echo "${C_DIM}  (grup yang ada: ${GROUP_ORDER[*]})${C_RESET}" >&2
  return 1
}

# --- status helpers --------------------------------------------------------

running_services_of() {
  dc "$1" ps --services --status running 2>/dev/null
}

network_exists() {
  docker network inspect "cpg-$1" >/dev/null 2>&1
}

# group_counts <group> -> prints "running total" (space-separated)
group_counts() {
  local group="$1" running_list total=0 running=0
  running_list="$(running_services_of "$group")"
  for svc in ${SVC_GROUPS[$group]}; do
    total=$((total + 1))
    grep -qx "$svc" <<<"$running_list" && running=$((running + 1))
  done
  echo "$running $total"
}

# state: up | down | partial
group_state() {
  local running="$1" total="$2"
  if (( running == 0 )); then echo down
  elif (( running == total )); then echo up
  else echo partial
  fi
}

state_color() {
  case "$1" in
    up) echo -n "$C_GREEN" ;;
    partial) echo -n "$C_YELLOW" ;;
    down) echo -n "$C_RED" ;;
  esac
}

print_status() {
  local filter="${1:-}"
  if [[ -n "$filter" ]]; then
    if ! filter=$(resolve_group_or_die "$filter"); then return 1; fi
  fi
  for group in "${GROUP_ORDER[@]}"; do
    [[ -n "$filter" && "$group" != "$filter" ]] && continue
    read -r running total <<<"$(group_counts "$group")"
    local state; state=$(group_state "$running" "$total")
    local color; color=$(state_color "$state")
    local services="${SVC_GROUPS[$group]// /, }"
    printf "  %s●%s %-15s%s%2s/%-2s%s  %s%s%s\n" \
      "$color" "$C_RESET" "$group" \
      "$color" "$running" "$total" "$C_RESET" \
      "$C_DIM" "$services" "$C_RESET"
  done
}

# menu <prompt> <choice...> -> echoes chosen value, empty (exit 1) if cancelled
menu() {
  local prompt="$1"; shift
  local choices=("$@")
  echo "${C_ACCENT}?${C_RESET} $prompt" >&2
  local i=1
  for c in "${choices[@]}"; do
    echo "  ${C_DIM}$i)${C_RESET} $c" >&2
    i=$((i + 1))
  done
  echo "  ${C_DIM}0) cancel${C_RESET}" >&2
  local pick
  read -rp "  ${C_BOLD}❯${C_RESET} " pick
  if [[ "$pick" == "0" || -z "$pick" ]]; then return 1; fi
  if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#choices[@]} )); then
    echo "${C_RED}✗${C_RESET} Pilihan gak valid." >&2
    return 1
  fi
  echo "${choices[$((pick - 1))]}"
}

show_help() {
  cat <<EOF
Kelola service docker-compose per grup (start/stop/restart/status). Tiap grup itu
project compose terpisah (compose/<grup>.yml) - keliatan sbg baris sendiri2 di
'docker compose ls' / Docker Desktop.

Usage:
  $0                    masuk interactive shell (prompt cpg>, ketik /status /start dst berulang)
  $0 status [grup]      liat status (semua grup, atau 1 grup doang)
  $0 start  [grup]      nyalain grup (tanpa nama -> pilih dari yg belum full up)
  $0 stop   [grup]      matiin grup  (tanpa nama -> pilih dari yg lagi jalan)
  $0 restart [grup]
  $0 detail [grup]      connection info (host/port/user/pass/URI) per service
  $0 update             git pull cpg-cli itself + refresh the cpg wrapper
  $0 uninstall          remove the cpg command (repo/containers/data untouched)

Grup: ${GROUP_ORDER[*]}
Boleh ketik alias/singkatan juga, misal: db, redis, rabbit, obs, sonar, chroma, up, down.
Typo dikit juga ketauan - bakal ditanya "maksud lu ini?" kalo mirip.

Catatan: grup 'ai' (chromadb) butuh network dari 'database' & 'cache' - kalo itu
belum nyala, cpg nyalain otomatis dulu sebelum start 'ai'.
EOF
}

# --- actions --------------------------------------------------------------

ensure_dependencies() {
  local group="$1"
  local deps="${GROUP_DEPENDS[$group]:-}"
  [[ -z "$deps" ]] && return 0
  for dep in $deps; do
    if ! network_exists "$dep"; then
      echo "${C_YELLOW}'$group' butuh network '$dep' - nyalain dulu...${C_RESET}"
      dc "$dep" up -d
    fi
  done
}

# Every early-out below uses `return`, never `exit` - these run inside the REPL loop
# too, where `exit` would kill the whole shell instead of just aborting one command.
do_start() {
  local group="${1:-}"
  if [[ -n "$group" ]]; then
    if ! group=$(resolve_group_or_die "$group"); then return 1; fi
  fi

  if [[ -z "$group" ]]; then
    local candidates=()
    for g in "${GROUP_ORDER[@]}"; do
      read -r running total <<<"$(group_counts "$g")"
      [[ "$(group_state "$running" "$total")" != "up" ]] && candidates+=("$g")
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
      echo "${C_GREEN}✓${C_RESET} Semua grup udah nyala semua."
      return 0
    fi
    if ! group=$(menu "Grup mana yang mau di-start?" "${candidates[@]}"); then echo "${C_DIM}(batal)${C_RESET}"; return 1; fi
  fi

  ensure_dependencies "$group"
  echo "${C_ACCENT}▸${C_RESET} docker compose -f ${GROUP_FILE[$group]} start ${SVC_GROUPS[$group]}"
  # `start` only works on containers that already exist - first-ever run falls back to
  # `up -d` to actually create them. Only the fallback's stderr is worth hiding here.
  # shellcheck disable=SC2086
  if ! dc "$group" start ${SVC_GROUPS[$group]}; then
    dc "$group" up -d
  fi
}

do_stop() {
  local group="${1:-}"
  if [[ -n "$group" ]]; then
    if ! group=$(resolve_group_or_die "$group"); then return 1; fi
  fi

  if [[ -z "$group" ]]; then
    local candidates=()
    for g in "${GROUP_ORDER[@]}"; do
      read -r running total <<<"$(group_counts "$g")"
      [[ "$(group_state "$running" "$total")" != "down" ]] && candidates+=("$g")
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
      echo "${C_YELLOW}!${C_RESET} Emang lagi gak ada yang jalan."
      return 0
    fi
    if ! group=$(menu "Grup mana yang mau di-stop?" "${candidates[@]}"); then echo "${C_DIM}(batal)${C_RESET}"; return 1; fi
  fi

  echo "${C_ACCENT}▸${C_RESET} docker compose -f ${GROUP_FILE[$group]} stop ${SVC_GROUPS[$group]}"
  # shellcheck disable=SC2086
  dc "$group" stop ${SVC_GROUPS[$group]}
}

do_restart() {
  local group="${1:-}"
  if [[ -n "$group" ]]; then
    if ! group=$(resolve_group_or_die "$group"); then return 1; fi
  fi
  if [[ -z "$group" ]]; then
    if ! group=$(menu "Grup mana yang mau di-restart?" "${GROUP_ORDER[@]}"); then echo "${C_DIM}(batal)${C_RESET}"; return 1; fi
  fi
  ensure_dependencies "$group"
  echo "${C_ACCENT}▸${C_RESET} docker compose -f ${GROUP_FILE[$group]} restart ${SVC_GROUPS[$group]}"
  # shellcheck disable=SC2086
  dc "$group" restart ${SVC_GROUPS[$group]}
}

# Connection info per service - host/port/user/pass/URI, whatever you'd need to
# actually connect from a client or another app. Static reference text (matches what's
# baked into the compose files), not queried live from the containers.
show_detail() {
  local group="${1:-}"
  if [[ -n "$group" ]]; then
    if ! group=$(resolve_group_or_die "$group"); then return 1; fi
  else
    if ! group=$(menu "Grup mana yang mau dilihat detailnya?" "${GROUP_ORDER[@]}"); then echo "${C_DIM}(batal)${C_RESET}"; return 1; fi
  fi

  case "$group" in
    database)
      cat <<'EOF'
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
EOF
      ;;
    cache)
      cat <<'EOF'
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
EOF
      ;;
    messaging)
      cat <<'EOF'
=== messaging ===

rabbitmq
  amqp:  amqp://admin:password@localhost:5672
  management UI: http://localhost:15672   login: admin / password
EOF
      ;;
    observability)
      cat <<'EOF'
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
EOF
      ;;
    quality)
      cat <<'EOF'
=== quality ===

sonarqube
  url: http://localhost:9000
  default login: admin / admin   (SonarQube forces a password change on first login)
EOF
      ;;
    ai)
      cat <<'EOF'
=== ai ===

chromadb  (no auth by default)
  url: http://localhost:8100
  heartbeat: http://localhost:8100/api/v2/heartbeat
EOF
      ;;
  esac
}

# git pull the repo this script lives in (cwd is already the repo root - see the `cd`
# at the top of the file), then re-run install.sh so the cpg wrapper itself picks up
# any changes (renamed script, new install logic, etc). Never touches your containers.
do_update() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$(pwd) isn't a git repo - can't self-update this way."
    echo "Re-clone from https://github.com/ndri-nr/cpg-cli or download the latest release."
    return 1
  fi

  local before after
  before=$(git rev-parse --short HEAD)
  echo "${C_ACCENT}▸${C_RESET} git pull (in $(pwd))"
  if ! git pull --ff-only; then
    echo "Update gagal - local changes atau conflict kayaknya. Cek manual: git -C \"$(pwd)\" status"
    return 1
  fi
  after=$(git rev-parse --short HEAD)

  if [[ "$before" == "$after" ]]; then
    echo "${C_GREEN}✓${C_RESET} Udah versi terbaru ($after)."
    return 0
  fi

  echo "${C_GREEN}✓${C_RESET} Updated $before -> $after."
  if [[ -f ./install.sh ]]; then
    echo "Re-running install.sh to refresh the cpg wrapper..."
    bash ./install.sh
  fi
}

# Removes the ~/.local/bin cpg wrapper - never touches this repo, running containers,
# or volumes/data (see uninstall.sh's own comment).
do_uninstall() {
  local yn
  read -rp "${C_YELLOW}?${C_RESET} Uninstall the cpg command? Repo/containers/data stay untouched. (y/n) " yn
  if [[ ! "$yn" =~ ^[Yy] ]]; then
    echo "${C_DIM}(batal)${C_RESET}"
    return 1
  fi
  if [[ -f ./uninstall.sh ]]; then
    bash ./uninstall.sh
  else
    echo "uninstall.sh not found in $(pwd)."
    return 1
  fi
}

# --- REPL (bare `cpg`, no args) --------------------------------------------

repl() {
  echo "${C_ACCENT}╭────────────────────────────────────╮${C_RESET}"
  echo "${C_ACCENT}│${C_RESET} ${C_ACCENT}✳${C_RESET} ${C_BOLD}cpg${C_RESET} · compose playground control ${C_ACCENT}│${C_RESET}"
  echo "${C_ACCENT}╰────────────────────────────────────╯${C_RESET}"
  echo "${C_DIM}/help buat commands · /exit buat keluar${C_RESET}"
  echo
  print_status
  history -c
  while true; do
    echo
    # `-e` turns on readline for this read - without it, arrow keys just dump raw
    # escape bytes into the buffer (garbled input, cursor jumps around but doesn't
    # actually navigate). `history -s` after each line makes up/down arrow recall
    # previous commands too, like a real shell.
    if ! read -e -rp "${C_ACCENT}❯${C_RESET} " line; then
      echo
      break
    fi
    [[ -n "${line// }" ]] && history -s "$line"
    line="${line#/}"
    [[ -z "$line" ]] && continue
    read -r sub_cmd sub_arg <<<"$line"

    case "$sub_cmd" in
      exit|quit|q) break ;;
      -h|--help|help) show_help; continue ;;
    esac

    if ! resolved_cmd=$(resolve_choice "$sub_cmd" CMD_ALIAS "${CMDS[@]}"); then
      echo "${C_DIM}  (/help buat liat semua command)${C_RESET}"
      continue
    fi

    case "$resolved_cmd" in
      status) print_status "$sub_arg" || true ;;
      start) do_start "$sub_arg" || true ;;
      stop) do_stop "$sub_arg" || true ;;
      restart) do_restart "$sub_arg" || true ;;
      detail) show_detail "$sub_arg" || true ;;
      update) do_update || true ;;
      uninstall) do_uninstall || true ;;
    esac
  done
  echo "Bye."
}

# --- entry ------------------------------------------------------------

cmd="${1:-}"
arg="${2:-}"

case "$cmd" in
  -h|--help|help) show_help; exit 0 ;;
esac

if [[ -n "$cmd" ]]; then
  case "$cmd" in
    status|start|stop|restart|detail|update|uninstall) : ;;
    *)
      resolved_cmd=$(resolve_choice "$cmd" CMD_ALIAS "${CMDS[@]}") || {
        show_help
        exit 1
      }
      cmd="$resolved_cmd"
      ;;
  esac
fi

case "$cmd" in
  status) print_status "$arg" ;;
  start) do_start "$arg" ;;
  stop) do_stop "$arg" ;;
  restart) do_restart "$arg" ;;
  detail) show_detail "$arg" ;;
  update) do_update ;;
  uninstall) do_uninstall ;;
  "") repl ;;
esac
