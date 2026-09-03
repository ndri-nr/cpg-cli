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
#   ./cpg-cli.sh start [group...]   start 1+ groups (no group = pick from what's not fully up)
#   ./cpg-cli.sh stop  [group...]   stop 1+ groups  (no group = pick from what's running)
#   ./cpg-cli.sh restart [group...]
#   ./cpg-cli.sh detail [group]  connection info (host/port/user/pass/URI) per service
#   ./cpg-cli.sh help
set -uo pipefail

# Associative arrays (and the pinned prompt's fractional `read -t`) are bash 4+.
# macOS still ships bash 3.2 as /bin/bash, where this used to die with a bare
# "database: unbound variable" - say what's actually wrong instead.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "cpg butuh bash 4+ (ini bash ${BASH_VERSION})." >&2
  echo "macOS ships bash 3.2 - install a newer one: brew install bash" >&2
  exit 1
fi

set -e

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
# Services that only exist once a compose profile is switched on (replicas, cluster
# nodes). Two jobs: status must not count a service nobody ever created - counting
# them is what pinned `database` at 4/9 forever, unreachable by `cpg start db` - and
# `start --all` needs to know which profiles bring the whole group up.
declare -A SVC_PROFILE=(
  [postgres-replica-1]=postgres-replica [postgres-replica-2]=postgres-replica
  [pgpool]=postgres-replica
  [mongo-replica-1]=mongo-cluster [mongo-replica-2]=mongo-cluster
  [redis-cluster-1]=redis-cluster [redis-cluster-2]=redis-cluster
  [redis-cluster-3]=redis-cluster [redis-cluster-4]=redis-cluster
  [redis-cluster-5]=redis-cluster [redis-cluster-6]=redis-cluster
)
declare -A GROUP_PROFILES=(
  [database]="postgres-replica mongo-cluster"
  [cache]="redis-cluster"
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
ALL_FLAG=0; FLAG_REST=() # filled by _take_flags
IN_REPL=0 # flipped to 1 inside repl() - lets do_update know whether to self-relaunch
G_RUNNING=0; G_TOTAL=0; G_DORMANT=0; G_ACTIVE=() # filled by group_scan

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

# "<service> <state>" per existing container, one `compose ps` for the whole group.
# `-a` on purpose: a created-but-stopped container still proves its profile was
# switched on at some point, which is what the denominator below keys off.
group_ps() {
  dc "$1" ps -a --format '{{.Service}} {{.State}}' 2>/dev/null
}

network_exists() {
  docker network inspect "cpg-$1" >/dev/null 2>&1
}

# One `compose ps` per group, feeding every number the status view needs, in globals
# (a command substitution would run this in a subshell and throw the arrays away):
#   G_RUNNING / G_TOTAL - the counts
#   G_ACTIVE            - the services those counts cover
#   G_DORMANT           - profile-gated services that don't exist yet
#
# The denominator is what's actually reachable, not every service in the file:
# profile-gated services join it only once a container for them exists (someone ran
# `start --all` or a manual `--profile` compose command). Counting them regardless is
# what pinned `database` at 4/9 forever - 5 of its 9 services live behind
# `postgres-replica` / `mongo-cluster`, so plain `cpg start db` could never reach 9.
group_scan() {
  local group="$1" svc s st
  local -A state=()
  G_RUNNING=0; G_TOTAL=0; G_DORMANT=0; G_ACTIVE=()
  # `if`, not `[[ ... ]] && ...`: a group with no containers at all feeds one empty
  # line here, and a false test as the loop body's last command makes the whole
  # `while` return 1 - which `set -e` turns into a silent exit mid-status.
  while read -r s st; do
    if [[ -n "$s" ]]; then state[$s]="$st"; fi
  done <<<"$(group_ps "$group")"
  for svc in ${SVC_GROUPS[$group]}; do
    if [[ -z "${state[$svc]:-}" && -n "${SVC_PROFILE[$svc]:-}" ]]; then
      G_DORMANT=$((G_DORMANT + 1))
      continue
    fi
    G_TOTAL=$((G_TOTAL + 1))
    G_ACTIVE+=("$svc")
    if [[ "${state[$svc]:-}" == "running" ]]; then G_RUNNING=$((G_RUNNING + 1)); fi
  done
}

# group_counts <group> -> prints "running total" (space-separated)
group_counts() {
  group_scan "$1"
  echo "$G_RUNNING $G_TOTAL"
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

# One status line, fitted to the CURRENT terminal width. Split out of print_status so
# a resize can re-render the same line at the new width instead of replaying the old
# text (which then wrapped onto two rows) - see _cpg_status_refit.
#
# Full member list lives in `/detail <group>`; showing all of them here made the line
# unreadably wide on anything but a maximized terminal. So: fit as many names as
# actually fit, "+N lainnya" for the rest, "N container" if not even one name fits.
_cpg_group_line() {
  local group="$1" running="$2" total="$3" dormant="$4"
  local svc_arr=() && read -ra svc_arr <<<"$5"
  local total_svc=${#svc_arr[@]}
  local state color plain_prefix dormant_note="" services
  state=$(group_state "$running" "$total")
  color=$(state_color "$state")
  printf -v plain_prefix "  ● %-15s%2s/%-2s  " "$group" "$running" "$total"
  # "+N profil" = services waiting behind a compose profile (see group_scan). Kept out
  # of the counts on purpose, but worth advertising - it's the discoverable hint that
  # those services exist at all.
  (( dormant > 0 )) && dormant_note=", +$dormant profil"
  local avail=$(( _CPG_COLS - ${#plain_prefix} - ${#dormant_note} ))
  (( avail < 0 )) && avail=0

  local shown=0 cur_str="" i candidate tentative remaining tentative_full
  for (( i = 0; i < total_svc; i++ )); do
    candidate="${svc_arr[$i]}"
    if [[ -n "$cur_str" ]]; then tentative="$cur_str, $candidate"; else tentative="$candidate"; fi
    remaining=$(( total_svc - (i + 1) ))
    tentative_full="$tentative"
    (( remaining > 0 )) && tentative_full="$tentative, +$remaining lainnya"
    (( ${#tentative_full} > avail )) && break
    cur_str="$tentative"
    shown=$(( shown + 1 ))
  done

  if (( shown == 0 )); then
    services="$total_svc container"
  else
    services="$cur_str"
    remaining=$(( total_svc - shown ))
    (( remaining > 0 )) && services="$services, +$remaining lainnya"
  fi
  services="$services$dormant_note"

  printf "  %s●%s %-15s%s%2s/%-2s%s  %s%s%s\n" \
    "$color" "$C_RESET" "$group" \
    "$color" "$running" "$total" "$C_RESET" \
    "$C_DIM" "$services" "$C_RESET"
}

print_status() {
  local filter="${1:-}"
  if [[ -n "$filter" ]]; then
    if ! filter=$(resolve_group_or_die "$filter"); then return 1; fi
  fi
  _cpg_term_size
  # Snapshot for the resize repaint: the counts and member list per group, so those
  # lines can be re-fitted to a new width without re-querying docker. Written to a
  # file, not a variable - print_status runs inside _cpg_out's pipeline (a subshell).
  local snap=""
  [[ -n "$_CPG_LOG" ]] && snap="$_CPG_LOG.status"
  [[ -n "$snap" && -z "$filter" ]] && : > "$snap"

  for group in "${GROUP_ORDER[@]}"; do
    [[ -n "$filter" && "$group" != "$filter" ]] && continue
    group_scan "$group"
    if [[ -n "$snap" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$group" "$G_RUNNING" "$G_TOTAL" "$G_DORMANT" "${G_ACTIVE[*]:-}" >> "$snap"
    fi
    _cpg_group_line "$group" "$G_RUNNING" "$G_TOTAL" "$G_DORMANT" "${G_ACTIVE[*]:-}"
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
  $0 start  [grup] [--no-all]  nyalain grup (tanpa nama -> pilih dari yg belum full up)
  $0 stop   [grup]      matiin grup  (tanpa nama -> pilih dari yg lagi jalan)
  $0 restart [grup] [--no-all]
  $0 detail [grup]      connection info (host/port/user/pass/URI) per service
  $0 update             git pull cpg-cli itself + refresh the cpg wrapper
  $0 uninstall          remove the cpg command (repo/containers/data untouched)
  $0 clear              clear the terminal (in the shell: also redraws the banner+status)

Grup: ${GROUP_ORDER[*]}
Boleh ketik alias/singkatan juga, misal: db, redis, rabbit, obs, sonar, chroma, up, down.
Typo dikit juga ketauan - bakal ditanya "maksud lu ini?" kalo mirip.
Di dalem shell interaktif, Tab bisa buat autocomplete command & nama grup.
Scroll (wheel / PgUp-PgDn) geser area output doang - kotak input tetep di bawah.
End atau langsung ngetik = balik ke output terbaru. CPG_ALTSCREEN=0 kalo mau
balik ke layar normal (scroll-nya jadi geser window kayak biasa).

Catatan: grup 'ai' (chromadb) butuh network dari 'database' & 'cache' - kalo itu
belum nyala, cpg nyalain otomatis dulu sebelum start 'ai'.

start/restart default-nya nyalain SEMUA, termasuk yang di balik compose profile:
replica Postgres + pgpool (profile postgres-replica), replica set Mongo
(mongo-cluster), 6 node Redis cluster (redis-cluster). Mau yang inti doang:
--no-all (alias: --core, --lean, --min). Yang dilewatin gak kebikin containernya,
jadi status gak ngitung mereka - keliatan sbg "+N profil" di belakang list.
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

# Splits the profile flag out of a group list: sets ALL_FLAG and FLAG_REST (globals,
# so the caller keeps the array - a command substitution would flatten it).
#
# Profiles are ON by default: `cpg start db` brings up the replicas and cluster nodes
# too, because a group that can't reach its own full member count is the confusing
# case ("why is database 4/9?"). `--no-all` (aka --core/--lean/--min) is the opt-out
# for when you only want the always-on services. `--all` is still accepted, it just
# doesn't change anything now.
_take_flags() {
  local w
  ALL_FLAG=1
  FLAG_REST=()
  for w in "$@"; do
    case "$w" in
      --all|-a|all|full|semua) ALL_FLAG=1 ;;
      --no-all|--core|--lean|--min|core|lean|min|minimal) ALL_FLAG=0 ;;
      *) FLAG_REST+=("$w") ;;
    esac
  done
}

# Every early-out below uses `return`, never `exit` - these run inside the REPL loop
# too, where `exit` would kill the whole shell instead of just aborting one command.
_start_one() {
  local group="$1" all="${2:-0}" p profile_args=()
  ensure_dependencies "$group"

  if [[ "$all" == "1" ]]; then
    for p in ${GROUP_PROFILES[$group]:-}; do profile_args+=(--profile "$p"); done
  fi
  if (( ${#profile_args[@]} > 0 )); then
    # Straight to `up -d`, no `start` first: with profiles on, the containers usually
    # don't exist yet and `up` is what creates them (and pulls their images). Profile
    # flags belong before the subcommand: `docker compose --profile x up -d`.
    echo "${C_ACCENT}▸${C_RESET} docker compose -f ${GROUP_FILE[$group]} ${profile_args[*]} up -d"
    dc "$group" "${profile_args[@]}" up -d
    return
  fi

  echo "${C_ACCENT}▸${C_RESET} docker compose -f ${GROUP_FILE[$group]} start ${SVC_GROUPS[$group]}"
  # `start` only works on containers that already exist - first-ever run falls back to
  # `up -d` to actually create them. Only the fallback's stderr is worth hiding here.
  # shellcheck disable=SC2086
  if ! dc "$group" start ${SVC_GROUPS[$group]}; then
    dc "$group" up -d
  fi
  # Only reachable via --no-all now, but say it out loud where it's actionable: this
  # start deliberately left the profile-gated services (replicas, cluster nodes)
  # alone, so the group will read "up" without them.
  group_scan "$group"
  if (( G_DORMANT > 0 )); then
    echo "${C_DIM}  (+$G_DORMANT service di balik profile dilewatin - 'cpg start $group' tanpa --no-all buat nyalain semua)${C_RESET}"
  fi
}

# Accepts zero, one, or many group names (e.g. `/start db ai messaging`). Zero ->
# pick-from-menu (single choice, as before). One or more -> each is resolved and
# started independently; a bad name in the middle just gets skipped (with a message)
# instead of aborting the rest of the batch.
do_start() {
  _take_flags "$@"
  local groups=("${FLAG_REST[@]+"${FLAG_REST[@]}"}")
  if [[ ${#groups[@]} -eq 0 ]]; then
    local candidates=()
    for g in "${GROUP_ORDER[@]}"; do
      read -r running total <<<"$(group_counts "$g")"
      [[ "$(group_state "$running" "$total")" != "up" ]] && candidates+=("$g")
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
      echo "${C_GREEN}✓${C_RESET} Semua grup udah nyala semua."
      return 0
    fi
    local picked
    if ! picked=$(menu "Grup mana yang mau di-start?" "${candidates[@]}"); then echo "${C_DIM}(batal)${C_RESET}"; return 1; fi
    groups=("$picked")
  fi

  local g resolved rc=0
  for g in "${groups[@]}"; do
    if ! resolved=$(resolve_group_or_die "$g"); then rc=1; continue; fi
    _start_one "$resolved" "$ALL_FLAG"
  done
  return "$rc"
}

_stop_one() {
  local group="$1"
  echo "${C_ACCENT}▸${C_RESET} docker compose -f ${GROUP_FILE[$group]} stop ${SVC_GROUPS[$group]}"
  # shellcheck disable=SC2086
  dc "$group" stop ${SVC_GROUPS[$group]}
}

do_stop() {
  # `stop` needs no profile flags (compose stops profile-gated containers by name
  # just fine), but accept and drop the token so `/stop db --all` isn't read as a
  # group named "--all".
  _take_flags "$@"
  local groups=("${FLAG_REST[@]+"${FLAG_REST[@]}"}")
  if [[ ${#groups[@]} -eq 0 ]]; then
    local candidates=()
    for g in "${GROUP_ORDER[@]}"; do
      read -r running total <<<"$(group_counts "$g")"
      [[ "$(group_state "$running" "$total")" != "down" ]] && candidates+=("$g")
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
      echo "${C_YELLOW}!${C_RESET} Emang lagi gak ada yang jalan."
      return 0
    fi
    local picked
    if ! picked=$(menu "Grup mana yang mau di-stop?" "${candidates[@]}"); then echo "${C_DIM}(batal)${C_RESET}"; return 1; fi
    groups=("$picked")
  fi

  local g resolved rc=0
  for g in "${groups[@]}"; do
    if ! resolved=$(resolve_group_or_die "$g"); then rc=1; continue; fi
    _stop_one "$resolved"
  done
  return "$rc"
}

_restart_one() {
  local group="$1" all="${2:-0}"
  ensure_dependencies "$group"
  if [[ "$all" == "1" ]]; then
    # `restart` can't create anything, and with --all the profile-gated containers
    # may not exist yet - so stop what's up and bring the whole group up instead.
    # shellcheck disable=SC2086
    dc "$group" stop ${SVC_GROUPS[$group]} >/dev/null 2>&1 || true
    _start_one "$group" 1
    return
  fi
  echo "${C_ACCENT}▸${C_RESET} docker compose -f ${GROUP_FILE[$group]} restart ${SVC_GROUPS[$group]}"
  # shellcheck disable=SC2086
  dc "$group" restart ${SVC_GROUPS[$group]}
}

do_restart() {
  _take_flags "$@"
  local groups=("${FLAG_REST[@]+"${FLAG_REST[@]}"}")
  if [[ ${#groups[@]} -eq 0 ]]; then
    local picked
    if ! picked=$(menu "Grup mana yang mau di-restart?" "${GROUP_ORDER[@]}"); then echo "${C_DIM}(batal)${C_RESET}"; return 1; fi
    groups=("$picked")
  fi

  local g resolved rc=0
  for g in "${groups[@]}"; do
    if ! resolved=$(resolve_group_or_die "$g"); then rc=1; continue; fi
    _restart_one "$resolved" "$ALL_FLAG"
  done
  return "$rc"
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
  hosts: localhost:17001-17006   pass: password   (bus: 27001-27006)
  cli:   redis-cli -c -h localhost -p 17001 -a password  (-c follows MOVED redirects)
  ports geser dari 7000-7005 - macOS AirPlay Receiver nempatin 7000 & 5000
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

  # A running shell keeps the OLD code in memory even after the file on disk changes -
  # `exec` replaces this process with a fresh one instead of making you exit/reopen
  # `cpg` by hand. Only when actually in the interactive shell; a one-shot `cpg update`
  # has nothing to "restart" into.
  if [[ "$IN_REPL" == "1" ]]; then
    echo "${C_DIM}Restarting cpg...${C_RESET}"
    # `exec` never runs the EXIT trap, so the scroll region has to be released by
    # hand here or the replacement process inherits a half-scrolling terminal.
    _cpg_region_off
    _cpg_alt_off
    exec bash "$0"
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

# Tab-completion core, shared by both prompts: reads the line/cursor from
# _CPG_CL/_CPG_CP, rewrites them in place when a completion is unambiguous, and
# leaves every candidate in _CPG_CMATCH so the caller decides how to show a list
# (readline can just printf; the pinned prompt has to route it into the scroll
# region instead). Completes /command names, then group names once a command word
# is typed.
_cpg_complete_core() {
  local prefix="${_CPG_CL:0:_CPG_CP}" c
  _CPG_CMATCH=()

  if [[ "$prefix" =~ ^/?([a-zA-Z_-]*)$ ]]; then
    local word="${BASH_REMATCH[1]}"
    for c in "${CMDS[@]}"; do [[ "$c" == "$word"* ]] && _CPG_CMATCH+=("$c"); done
    if [[ ${#_CPG_CMATCH[@]} -eq 1 ]]; then
      _CPG_CL="/${_CPG_CMATCH[0]} "
      _CPG_CP=${#_CPG_CL}
    fi
  elif [[ "$prefix" =~ ^/?([a-zA-Z_-]+)\ ([a-zA-Z_-]*)$ ]]; then
    local word="${BASH_REMATCH[2]}"
    for c in "${GROUP_ORDER[@]}"; do [[ "$c" == "$word"* ]] && _CPG_CMATCH+=("$c"); done
    if [[ ${#_CPG_CMATCH[@]} -eq 1 ]]; then
      _CPG_CL="${_CPG_CL:0:_CPG_CP-${#word}}${_CPG_CMATCH[0]}"
      _CPG_CP=${#_CPG_CL}
    fi
  fi
  :
}

# Readline hook for the classic prompt, wired up with `bind -x` (bash 4+ -
# READLINE_LINE/READLINE_POINT let a bound function read/rewrite the current line
# in place).
# NOTE: only ever verified by scripted (non-tty) tests here - genuinely press Tab in
# a real terminal to confirm the feel; `bind -x` + READLINE_LINE is standard bash but
# untested by us against a live keyboard.
_cpg_tab_complete() {
  _CPG_CL="$READLINE_LINE"
  _CPG_CP="$READLINE_POINT"
  _cpg_complete_core
  READLINE_LINE="$_CPG_CL"
  READLINE_POINT="$_CPG_CP"
  if [[ ${#_CPG_CMATCH[@]} -gt 1 ]]; then
    printf "\n  %s\n" "${_CPG_CMATCH[*]}"
  fi
  :
}

print_banner() {
  echo "${C_ACCENT}╭─────────────────────────────────────╮${C_RESET}"
  echo "${C_ACCENT}│${C_RESET} ${C_ACCENT}✳${C_RESET}  ${C_BOLD}cpg${C_RESET} · compose playground control ${C_ACCENT}│${C_RESET}"
  echo "${C_ACCENT}╰─────────────────────────────────────╯${C_RESET}"
  # Short commit in the banner: a running cpg keeps the OLD code in memory, so after
  # a `git pull` the only way to tell what you're actually looking at is a version
  # marker (asked "is this the new build?" one time too many).
  local ver=""
  ver=$(git rev-parse --short HEAD 2>/dev/null) || ver=""
  echo "${C_DIM}/help buat commands · /exit buat keluar${ver:+ · $ver}${C_RESET}"
}

# Auto-CHECK for updates (never auto-applies anything - still requires `/update`).
# Zero added latency: only compares against whatever origin/main ref is already
# cached locally (no network call on the hot path). A real `git fetch` only fires in
# the background, at most once every 24h, so the cached ref catches up over time
# without ever blocking a command.
check_for_update() {
  local git_dir cache_file last_check now
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  cache_file="$git_dir/cpg-last-update-check"
  now=$(date +%s)
  last_check=0
  [[ -f "$cache_file" ]] && last_check=$(cat "$cache_file" 2>/dev/null) 2>/dev/null
  [[ "$last_check" =~ ^[0-9]+$ ]] || last_check=0

  if (( now - last_check > 86400 )); then
    echo "$now" > "$cache_file" 2>/dev/null
    ( git fetch --quiet origin main >/dev/null 2>&1 & disown ) 2>/dev/null
  fi

  local behind
  behind=$(git rev-list --count HEAD..origin/main 2>/dev/null) || return 0
  if [[ "$behind" =~ ^[0-9]+$ ]] && (( behind > 0 )); then
    echo "${C_YELLOW}↑${C_RESET} Update tersedia ($behind commit baru) - ketik ${C_BOLD}/update${C_RESET}"
  fi
}

# Full-width divider re-queried every call, so it tracks a live terminal resize
# instead of being baked in once at REPL start.
hr() {
  _cpg_term_size
  printf '%s\n' "$_CPG_BAR"
}

# --- pinned bottom input (DECSTBM scroll region + raw keystroke loop) ------
#
# True split-pane REPL: the terminal's own scroll region (DECSTBM, `ESC [ top;bot r`)
# is shrunk to everything ABOVE the input box, so command output scrolls in the top
# pane while the bottom 4 rows (hint, border, input line, border) never move. No
# output buffer of our own - the terminal keeps its scrollback; we only choose where
# output lands (always the region's bottom margin, so content rises out of the input
# box like a chat log).
#
# This has to own the terminal outright, so `read -e`/readline is gone in this mode:
# keys arrive one at a time (`read -rsn1`) and cursor motion, history and completion
# are handled by hand. readline plus a custom scroll region fight over who owns the
# cursor - that fight is what killed the earlier SIGWINCH border redraw (see git
# log). repl_classic() stays as the fallback for terminals that can't do this
# (non-tty, tiny window, unmeasurable size, or CPG_PINNED=0 to force it).

_CPG_PINNED=0 # 1 only while the scroll region is actually installed
_CPG_RESERVED=4 # hint + top border + input line + bottom border
_CPG_ROWS=24; _CPG_COLS=80; _CPG_BOTTOM=20; _CPG_BAR=""
_CPG_BUF=""; _CPG_POS=0; _CPG_LINE=""
_CPG_HIST=(); _CPG_CL=""; _CPG_CP=0; _CPG_CMATCH=()
_CPG_WINCH=0
_CPG_HINT="contoh: /status, /start db, /detail, /help"
_CPG_LOG="" # mirror of everything printed into the pane, so a resize can repaint it
_CPG_ALT=0 # 1 while the alternate screen is in use (own scrollback, fixed box)
_CPG_SCROLL=0 # how many lines the pane is scrolled up from the newest output

# Single source of truth for the terminal's size, re-measured on demand.
# `stty size` reads the window off stdin; `tput lines/cols` asks *stderr* on some
# platforms (macOS ncurses), so the usual `tput cols 2>/dev/null` silently answers
# with the terminfo default (24x80) instead of the real window - measured that here,
# it's why the old dividers were always 80 wide on a Mac. stty first, tput only as a
# fallback for shells that lack it.
_cpg_term_size() {
  local size=""
  size=$(stty size 2>/dev/null) || size=""
  if [[ "$size" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    _CPG_ROWS=${BASH_REMATCH[1]}
    _CPG_COLS=${BASH_REMATCH[2]}
  else
    _CPG_ROWS=$(tput lines 2>/dev/null) || _CPG_ROWS=0
    _CPG_COLS=$(tput cols 2>/dev/null) || _CPG_COLS=0
  fi
  [[ "$_CPG_ROWS" =~ ^[0-9]+$ ]] && (( _CPG_ROWS > 0 )) || _CPG_ROWS=24
  [[ "$_CPG_COLS" =~ ^[0-9]+$ ]] && (( _CPG_COLS > 0 )) || _CPG_COLS=80
  _CPG_BOTTOM=$(( _CPG_ROWS - _CPG_RESERVED ))
  (( _CPG_BOTTOM < 1 )) && _CPG_BOTTOM=1
  # Cached instead of rebuilt per keystroke - the render runs on every single key.
  _CPG_BAR=$(printf '─%.0s' $(seq 1 "$_CPG_COLS"))
  :
}

# Pinned mode needs a real terminal it can measure and address with escapes.
# CPG_PINNED=0 is the escape hatch if some emulator renders it wrong.
_cpg_pinned_ok() {
  [[ "${CPG_PINNED:-1}" != "0" ]] || return 1
  [[ -t 0 && -t 1 ]] || return 1
  [[ "${TERM:-dumb}" != "dumb" ]] || return 1
  _cpg_term_size
  (( _CPG_ROWS >= 10 && _CPG_COLS >= 24 ))
}

# The alternate screen is what actually pins the box against scrolling: on the main
# screen the wheel moves the *terminal's* viewport, and no application can stop the
# box from sliding out of view with it. Here the app owns the screen, the wheel is
# delivered to us as input (SGR mouse reports), and scrolling means repainting the
# pane from the mirror - the box never moves. Costs: the pane's scrollback is ours,
# not the terminal's (dumped back to the main screen on exit, so nothing is lost),
# and selecting text with the mouse needs the terminal's modifier (Option-drag in
# Terminal.app/iTerm2) while mouse reporting is on. CPG_ALTSCREEN=0 opts out.
_cpg_alt_on() {
  [[ "${CPG_ALTSCREEN:-1}" != "0" ]] || return 0
  _CPG_ALT=1
  # ?1049h = alternate screen, ?1000h = report button presses, ?1006h = report them
  # in SGR form (`ESC [ < b ; x ; y M`), which is the only encoding that survives
  # coordinates past column 223.
  printf '\033[?1049h\033[?1000h\033[?1006h'
}

_cpg_alt_off() {
  [[ "$_CPG_ALT" == "1" ]] || return 0
  _CPG_ALT=0
  printf '\033[?1006l\033[?1000l\033[?1049l'
  # Back on the main screen the session's output would be gone, so hand it over -
  # the pane's own scrollback, dropped into the real one.
  if [[ -s "$_CPG_LOG" ]]; then
    tail -n 500 "$_CPG_LOG"
  fi
}

_cpg_region_on() {
  _CPG_PINNED=1
  # DECSTBM homes the cursor, hence the explicit move down into the region after it.
  printf '\033[1;%dr\033[%d;1H' "$_CPG_BOTTOM" "$_CPG_BOTTOM"
}

# MUST run before leaving pinned mode (EXIT trap, and before do_update's exec) -
# forget it and the user is left in a terminal that only scrolls its top rows.
_cpg_region_off() {
  [[ "$_CPG_PINNED" == "1" ]] || return 0
  _CPG_PINNED=0
  printf '\033[r\033[%d;1H\033[0m\n' "$_CPG_ROWS"
}

# Runs a command with its output landing at the scroll region's bottom margin, so it
# rises above the input box. Re-asserts the region first: `clear`, docker's progress
# renderer or anything else that resets the margins behind our back gets corrected
# here. The leading newline scrolls one blank row in, which also separates each
# command's output like the old prompt's blank line did.
#
# Output is also teed into $_CPG_LOG, and that mirror is what makes a resize
# survivable: the emulator reflows the pane however it likes (Terminal.app keeps the
# bottom and pushes everything up, stranding a copy of our box in the pane at every
# step of a drag), and with no copy of the output the only choices are leaving that
# mess on screen or wiping the pane. With one, a resize just repaints. The cost: the
# pane is a pipe rather than a tty, so `docker compose` prints plain progress lines
# instead of its live-redrawing ones.
_cpg_out() {
  local sep=0
  # New output goes at the bottom; if the pane was scrolled up, come back first.
  _cpg_scroll_reset
  [[ -s "$_CPG_LOG" ]] && sep=1
  # DECRC (ESC 8) puts the cursor back where the last pane output ended, so a fresh
  # or just-cleared pane fills from the TOP and only starts scrolling once it's full
  # - output used to be nailed to the bottom margin, which left the banner floating
  # at the bottom of an otherwise empty screen. DECSTBM homes the cursor, hence the
  # restore right after it. The terminal is the one tracking that position, so it
  # stays right through wrapped lines.
  printf '\033[1;%dr\0338' "$_CPG_BOTTOM"
  if [[ -z "$_CPG_LOG" ]]; then
    (( sep )) && printf '\n'
    "$@"
    printf '\0337'
    return
  fi
  # Bounded: only the last screenful is ever replayed, so keep the tail and drop the
  # rest once the file gets big.
  # The mirror is the pane's scrollback now, so keep a useful amount of it.
  if [[ -s "$_CPG_LOG" ]] && (( $(wc -c < "$_CPG_LOG") > 4194304 )); then
    tail -n 5000 "$_CPG_LOG" > "$_CPG_LOG.trim" 2>/dev/null && mv "$_CPG_LOG.trim" "$_CPG_LOG"
  fi
  # pipefail (set at the top of the script) keeps the command's own status instead of
  # tee's, so `/exit` still reports "leave the REPL" through this. The blank
  # separator line is skipped while the pane is still empty, so the banner starts on
  # row 1 rather than row 2.
  { (( sep )) && printf '\n'; "$@" 2>&1; } | tee -a "$_CPG_LOG"
  local rc=$?
  printf '\0337'
  return "$rc"
}

# Wipes the screen and replays the last screenful of the mirror, ending at the scroll
# region's bottom margin (where fresh output lands too). Used after a resize, once the
# emulator has reflowed the pane and left our old box rows sitting in it.
# Strips the colour escapes off a mirrored line, so it can be pattern-matched.
# Regex, not `${s//pattern/}`: in a glob, `[0-9;]*` means "one of those, then
# anything", so it happily ate the rest of the line (measured: the group name too).
_cpg_plain() {
  local s="$1" out=""
  while [[ "$s" =~ ^([^$'\033']*)$'\033'\[[0-9\;]*[a-zA-Z](.*)$ ]]; do
    out+="${BASH_REMATCH[1]}"
    s="${BASH_REMATCH[2]}"
  done
  printf '%s' "$out$s"
}

# A replayed status line is text laid out for the OLD width, so after a resize it
# wrapped onto two rows. Re-render it instead, from the snapshot print_status left
# behind: same fit-as-many logic, new width, still exactly one row. Anything else
# (docker output, /detail) replays as-is - it's plain prose, not a fitted list.
_cpg_status_refit() {
  local line="$1" plain group running total dormant services snap="$_CPG_LOG.status"
  [[ -s "$snap" ]] || { printf '%s\n' "$line"; return 0; }
  plain=$(_cpg_plain "$line")
  if [[ ! "$plain" =~ ^[[:space:]]+●[[:space:]]+([a-z][a-z-]*)[[:space:]] ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  group="${BASH_REMATCH[1]}"
  while IFS=$'\t' read -r g running total dormant services; do
    if [[ "$g" == "$group" ]]; then
      _cpg_group_line "$group" "$running" "$total" "$dormant" "$services"
      return 0
    fi
  done < "$snap"
  printf '%s\n' "$line"
}

_cpg_repaint_pane() {
  printf '\033[r\033[1;1H\033[0J\033[1;%dr\033[1;1H' "$_CPG_BOTTOM"
  # Replayed from row 1 down, same as a fresh pane: short output stays at the top,
  # a full screenful scrolls itself into place. DECSC (ESC 7) at the end hands the
  # position back to _cpg_out for the next command.
  if [[ -s "$_CPG_LOG" ]]; then
    local line
    # _CPG_SCROLL lines back from the newest output, one screenful of it.
    while IFS= read -r line; do
      _cpg_status_refit "$line"
    done < <(tail -n "$(( _CPG_BOTTOM + _CPG_SCROLL ))" "$_CPG_LOG" | head -n "$_CPG_BOTTOM")
  fi
  printf '\0337'
}

# Scrolls the pane by $1 lines (negative = back towards the newest output) and
# repaints. Only possible on the alternate screen: on the main screen the terminal's
# own viewport does the scrolling and the mirror isn't involved at all.
_cpg_scroll_by() {
  [[ "$_CPG_ALT" == "1" && -s "$_CPG_LOG" ]] || return 0
  local total max want
  total=$(wc -l < "$_CPG_LOG")
  max=$(( total - _CPG_BOTTOM ))
  (( max < 0 )) && max=0
  want=$(( _CPG_SCROLL + $1 ))
  (( want < 0 )) && want=0
  (( want > max )) && want=$max
  (( want == _CPG_SCROLL )) && return 0
  _CPG_SCROLL=$want
  _cpg_repaint_pane
}

# Any new output belongs at the bottom, so jump back there first.
_cpg_scroll_reset() {
  (( _CPG_SCROLL == 0 )) && return 0
  _CPG_SCROLL=0
  _cpg_repaint_pane
}

# Repaints the 4 pinned rows (hint, box top, input, box bottom) and parks the cursor
# inside the box. Long input scrolls horizontally (the window ends at the cursor)
# instead of wrapping - a wrapped line would grow into the border row.
_cpg_render() {
  local avail=$(( _CPG_COLS - 6 )) start=0 view bar out
  (( avail < 8 )) && avail=8
  (( _CPG_POS > avail )) && start=$(( _CPG_POS - avail ))
  view="${_CPG_BUF:start:avail}"
  bar="${_CPG_BAR:0:$(( _CPG_COLS - 2 ))}"
  # Built as one string and written once, with the cursor hidden across it. Six
  # separate printfs let the terminal paint half-finished states - visible as a
  # flicker on every keystroke, and as a stuttering box while dragging a resize.
  local hint="$_CPG_HINT"
  (( _CPG_SCROLL > 0 )) && hint="↑ $_CPG_SCROLL baris ke atas · End/PgDn buat balik ke bawah"
  printf -v out '\033[?25l\033[%d;1H\033[2K%s%s%s\033[%d;1H\033[2K%s╭%s╮%s\033[%d;1H\033[2K%s│%s %s❯%s %s\033[%d;%dH%s│%s\033[%d;1H\033[2K%s╰%s╯%s\033[%d;%dH\033[?25h' \
    $(( _CPG_ROWS - 3 )) "$C_DIM" "${hint:0:_CPG_COLS}" "$C_RESET" \
    $(( _CPG_ROWS - 2 )) "$C_DIM" "$bar" "$C_RESET" \
    $(( _CPG_ROWS - 1 )) "$C_DIM" "$C_RESET" "$C_ACCENT" "$C_RESET" "$view" \
    $(( _CPG_ROWS - 1 )) "$_CPG_COLS" "$C_DIM" "$C_RESET" \
    "$_CPG_ROWS" "$C_DIM" "$bar" "$C_RESET" \
    $(( _CPG_ROWS - 1 )) $(( _CPG_POS - start + 5 ))
  printf '%s' "$out"
}

# Pushes the whole visible screen up into the scrollback: margins off (a full-screen
# scroll is the only kind the emulator keeps), one newline per row, done. Used after a
# shrink, where the old box rows get reflowed up into the scroll pane and would sit
# there as leftover borders stacking under the new box - the emulator never says how
# it reflowed, and nothing here mirrors the pane's content to repaint it. The output
# isn't lost, it's one scroll up.
# Re-measures and repaints only when the window really changed.
_cpg_poll_resize() {
  local pr=$_CPG_ROWS pc=$_CPG_COLS
  _cpg_term_size
  if (( pr == _CPG_ROWS && pc == _CPG_COLS )); then
    return 0
  fi
  # Don't try to patch up whatever the emulator did to the pane - wipe it and replay
  # from the mirror. Terminal.app in particular keeps the bottom of the screen and
  # pushes the rest up, so a drag leaves a stack of old hint lines and top borders.
  _cpg_repaint_pane
  _cpg_render
}

# Raw line editor: everything `read -e` gave us for free, by hand. Sets _CPG_LINE and
# returns 0 on Enter; returns 1 on Ctrl-C / Ctrl-D / EOF (i.e. "leave the REPL").
_cpg_read_line() {
  _CPG_BUF=""; _CPG_POS=0
  local key seq junk rc saved="" ticks=0 hidx=${#_CPG_HIST[@]}
  _cpg_render
  while true; do
    rc=0
    # Short timeout, not a blocking read: a resize has to be noticed while idle at
    # the prompt. bash runs the WINCH trap only after the read returns (it doesn't
    # interrupt it), so the tick length *is* the resize latency - 1s felt like the
    # box lagging behind the window while dragging. Typing is unaffected: a keypress
    # returns at once.
    IFS= read -rsn1 -t 0.2 key || rc=$?
    if (( rc != 0 )); then
      # >128 = timeout or interrupting signal; anything else is a real EOF.
      if (( rc > 128 )); then
        # `stty size` costs a subprocess, so only measure when SIGWINCH says the
        # window moved - or once a second regardless, for shells/terminals where
        # that signal never arrives.
        ticks=$(( ticks + 1 ))
        if (( _CPG_WINCH || ticks >= 5 )); then
          _CPG_WINCH=0
          ticks=0
          _cpg_poll_resize
        fi
        continue
      fi
      _CPG_LINE=""
      return 1
    fi
    case "$key" in
      ""|$'\r'|$'\n') _CPG_LINE="$_CPG_BUF"; return 0 ;; # Enter (ICRNL turns CR into NL)
      $'\003') _CPG_LINE=""; return 1 ;;                # Ctrl-C
      $'\004') # Ctrl-D: quit on an empty line, delete-forward otherwise
        if [[ -z "$_CPG_BUF" ]]; then
          _CPG_LINE=""
          return 1
        fi
        _CPG_BUF="${_CPG_BUF:0:_CPG_POS}${_CPG_BUF:_CPG_POS+1}" ;;
      $'\177'|$'\010') # Backspace (DEL on most terminals, BS on a few)
        if (( _CPG_POS > 0 )); then
          _CPG_BUF="${_CPG_BUF:0:_CPG_POS-1}${_CPG_BUF:_CPG_POS}"
          _CPG_POS=$(( _CPG_POS - 1 ))
        fi ;;
      $'\001') _CPG_POS=0 ;;                            # Ctrl-A
      $'\005') _CPG_POS=${#_CPG_BUF} ;;                 # Ctrl-E
      $'\013') _CPG_BUF="${_CPG_BUF:0:_CPG_POS}" ;;     # Ctrl-K
      $'\025') _CPG_BUF="${_CPG_BUF:_CPG_POS}"; _CPG_POS=0 ;; # Ctrl-U
      $'\014') # Ctrl-L: wipe the pane, and the mirror with it - otherwise the next
        # resize replays exactly what was just cleared. Pane cursor goes back to the
        # top, so the next command's output starts there.
        [[ -n "$_CPG_LOG" ]] && : > "$_CPG_LOG"
        _CPG_SCROLL=0
        printf '\033[1;1H\033[0J\0337' ;;
      $'\t')
        _cpg_scroll_reset
        _CPG_CL="$_CPG_BUF"; _CPG_CP=$_CPG_POS
        _cpg_complete_core
        _CPG_BUF="$_CPG_CL"; _CPG_POS=$_CPG_CP
        if (( ${#_CPG_CMATCH[@]} > 1 )); then
          _cpg_out printf '  %s\n' "${_CPG_CMATCH[*]}"
        fi ;;
      $'\033')
        # Arrow/Home/End/Delete arrive as multi-byte escape sequences. The short
        # timeout keeps a bare Escape keypress from hanging the loop.
        seq=""
        IFS= read -rsn2 -t 0.05 seq || true
        case "$seq" in
          '[A'|'OA') # history back
            if (( hidx > 0 )); then
              if (( hidx == ${#_CPG_HIST[@]} )); then saved="$_CPG_BUF"; fi
              hidx=$(( hidx - 1 ))
              _CPG_BUF="${_CPG_HIST[hidx]}"
              _CPG_POS=${#_CPG_BUF}
            fi ;;
          '[B'|'OB') # history forward, back to whatever was half-typed
            if (( hidx < ${#_CPG_HIST[@]} )); then
              hidx=$(( hidx + 1 ))
              if (( hidx == ${#_CPG_HIST[@]} )); then
                _CPG_BUF="$saved"
              else
                _CPG_BUF="${_CPG_HIST[hidx]}"
              fi
              _CPG_POS=${#_CPG_BUF}
            fi ;;
          # `if`, not `test && assign`: a false test as the last command in a case
          # branch makes the branch (and this whole loop body) return 1, and `set -e`
          # then kills the REPL - pressing Left at column 0 used to do exactly that.
          '[C'|'OC') if (( _CPG_POS < ${#_CPG_BUF} )); then _CPG_POS=$(( _CPG_POS + 1 )); fi ;;
          '[D'|'OD') if (( _CPG_POS > 0 )); then _CPG_POS=$(( _CPG_POS - 1 )); fi ;;
          '[H'|'OH') _CPG_POS=0 ;;
          # End doubles as "back to the newest output" while the pane is scrolled -
          # that's what the scroll indicator tells you to press.
          '[F'|'OF') _cpg_scroll_reset; _CPG_POS=${#_CPG_BUF} ;;
          '[5') IFS= read -rsn1 -t 0.05 junk || true   # PageUp: half a screen back
                _cpg_scroll_by $(( _CPG_BOTTOM / 2 )) ;;
          '[6') IFS= read -rsn1 -t 0.05 junk || true   # PageDown
                _cpg_scroll_by $(( - _CPG_BOTTOM / 2 )) ;;
          '[<') # SGR mouse report: ESC [ < button ; col ; row M/m. Wheel up is
                # button 64, wheel down 65; everything else (clicks, drags) is read
                # to the end of the report and dropped, so it can't leak into the
                # input line. `if`/`: ;;` rather than `&&`: a false test as the last
                # command in here would make the case return 1, which `set -e` reads
                # as a failure and kills the REPL.
            local mouse="" mc=""
            while IFS= read -rsn1 -t 0.05 mc; do
              mouse+="$mc"
              if [[ "$mc" == [Mm] ]]; then break; fi
            done
            case "$mouse" in
              64*) _cpg_scroll_by 3 ;;
              65*) _cpg_scroll_by -3 ;;
              *) : ;;
            esac ;;
          '[M') # X10 mouse report: ESC [ M then 3 bytes (button+32, x+32, y+32).
                # What a terminal falls back to when it doesn't do SGR (?1006) - and
                # the bytes MUST be eaten either way, or they land in the input line
                # as garbage characters.
            local b="" bx="" by=""
            IFS= read -rsn1 -t 0.05 b || true
            IFS= read -rsn1 -t 0.05 bx || true
            IFS= read -rsn1 -t 0.05 by || true
            case "$b" in
              '`') _cpg_scroll_by 3 ;;   # 96 = 64 (wheel up) + 32
              a) _cpg_scroll_by -3 ;;    # 97 = 65 (wheel down) + 32
              *) : ;;
            esac ;;
          # `ESC [ n ~` keys: the trailing `~` is still unread, so eat it.
          '[1'|'[7') IFS= read -rsn1 -t 0.05 junk || true; _CPG_POS=0 ;;
          '[4'|'[8') IFS= read -rsn1 -t 0.05 junk || true; _CPG_POS=${#_CPG_BUF} ;;
          '[3')
            IFS= read -rsn1 -t 0.05 junk || true
            _CPG_BUF="${_CPG_BUF:0:_CPG_POS}${_CPG_BUF:_CPG_POS+1}" ;;
        esac ;;
      *)
        # Anything else printable gets inserted; stray control bytes are dropped so
        # they can't garble the input line.
        if [[ "$key" == *[[:cntrl:]]* ]]; then
          continue
        fi
        # Typing means you're done reading scrollback.
        _cpg_scroll_reset
        _CPG_BUF="${_CPG_BUF:0:_CPG_POS}$key${_CPG_BUF:_CPG_POS}"
        _CPG_POS=$(( _CPG_POS + 1 )) ;;
    esac
    _cpg_render
  done
}

# --- REPL bodies ----------------------------------------------------------

# One typed line -> one command. Shared by both prompts. Returns 1 when the line
# means "leave the REPL".
_cpg_dispatch() {
  local line="${1#/}" sub_cmd sub_arg resolved_cmd
  [[ -n "${line// }" ]] || return 0
  read -r sub_cmd sub_arg <<<"$line"
  # sub_args: word-split so start/stop/restart can take multiple groups at once
  # (e.g. `/start db ai messaging`); status/detail just use the first word.
  local sub_args=()
  read -ra sub_args <<<"$sub_arg"

  case "$sub_cmd" in
    exit|quit|q) return 1 ;;
    -h|--help|help) show_help; return 0 ;;
    clear|cls)
      # The mirror goes too, same reason as Ctrl-L. (This runs inside _cpg_out's
      # pipeline, so truncating the file works where a variable assignment wouldn't.)
      [[ -n "$_CPG_LOG" ]] && : > "$_CPG_LOG"
      clear; print_banner; echo; print_status; return 0 ;;
  esac

  if ! resolved_cmd=$(resolve_choice "$sub_cmd" CMD_ALIAS "${CMDS[@]}"); then
    echo "${C_DIM}  (/help buat liat semua command)${C_RESET}"
    return 0
  fi

  case "$resolved_cmd" in
    status) print_status "${sub_args[0]:-}" || true ;;
    start) do_start "${sub_args[@]}" || true ;;
    stop) do_stop "${sub_args[@]}" || true ;;
    restart) do_restart "${sub_args[@]}" || true ;;
    detail) show_detail "${sub_args[0]:-}" || true ;;
    update) do_update || true ;;
    uninstall) do_uninstall || true ;;
  esac
  return 0
}

_cpg_intro() {
  print_banner
  check_for_update
  echo
  print_status
}

# Echoes the submitted line into the output pane before running it, so the scrollback
# reads like a shell session (the input box itself is cleared for the next command).
_cpg_run_line() {
  printf '%s❯%s %s\n' "$C_ACCENT" "$C_RESET" "$1"
  _cpg_dispatch "$1"
}

repl_pinned() {
  _cpg_term_size
  _CPG_LOG=$(mktemp -t cpg-pane 2>/dev/null) || _CPG_LOG=""
  trap '_cpg_region_off; _cpg_alt_off; [[ -n "$_CPG_LOG" ]] && rm -f "$_CPG_LOG" "$_CPG_LOG.trim" "$_CPG_LOG.status"' EXIT
  trap '_CPG_WINCH=1' WINCH
  _cpg_alt_on
  printf '\033[2J\033[H\0337' # start clean, pane cursor at the top of the screen
  _cpg_region_on
  _cpg_out _cpg_intro
  local line
  while true; do
    if ! _cpg_read_line; then break; fi
    line="$_CPG_LINE"
    [[ -n "${line// }" ]] || continue
    _CPG_HIST+=("$line")
    if ! _cpg_out _cpg_run_line "$line"; then break; fi
  done
  _cpg_region_off
  _cpg_alt_off
  [[ -n "$_CPG_LOG" ]] && rm -f "$_CPG_LOG" "$_CPG_LOG.trim" "$_CPG_LOG.status"
  trap - EXIT WINCH
  echo "Bye."
}

# Fallback prompt for terminals that can't take the pinned box: the box is redrawn
# per turn instead of staying put, and `read -e` (readline) does the line editing.
repl_classic() {
  _cpg_intro
  history -c
  # `bind` refuses ("line editing not enabled") unless emacs/vi line-editing mode is
  # on - off by default in a non-interactive script (which this is, even run via the
  # `cpg` wrapper) regardless of `read -e` working fine on its own.
  set -o emacs
  bind -x '"\t": _cpg_tab_complete' 2>/dev/null || true
  local line rc
  while true; do
    echo
    # A framed input area, like Claude Code's own prompt box - both borders are
    # actually drawn (with a blank line reserved between them) BEFORE `read -e`
    # starts, then the cursor is walked back up onto that blank line with `tput cuu`.
    # `read -e`/readline only ever redraws its own current line, so the borders above
    # and below stay put while typing.
    echo "${C_DIM}${_CPG_HINT}${C_RESET}"
    echo "${C_DIM}$(hr)${C_RESET}"
    echo
    echo "${C_DIM}$(hr)${C_RESET}"
    tput cuu 2 2>/dev/null || true
    # `-e` turns on readline for this read - without it, arrow keys just dump raw
    # escape bytes into the buffer (garbled input, cursor jumps around but doesn't
    # actually navigate). `history -s` after each line makes up/down arrow recall
    # previous commands too, like a real shell.
    # `|| rc=$?` (not `; rc=$?`) because `set -e` is on: a bare failing command
    # outside a tested context would kill the whole script before `rc` is read.
    rc=0
    read -e -rp "${C_ACCENT}❯${C_RESET} " line || rc=$?
    if [[ $rc -ne 0 ]]; then
      echo
      break
    fi
    [[ -n "${line// }" ]] && history -s "$line"
    if ! _cpg_dispatch "$line"; then break; fi
  done
  echo "Bye."
}

repl() {
  IN_REPL=1
  printf '\033]0;%s\007' "✳  cpg-cli" 2>/dev/null || true
  if _cpg_pinned_ok; then
    repl_pinned
  else
    repl_classic
  fi
}

# --- entry ------------------------------------------------------------

cmd="${1:-}"
arg="${2:-}"
args=("${@:2}") # everything after the command - start/stop/restart can take several

case "$cmd" in
  -h|--help|help) show_help; exit 0 ;;
  clear|cls) clear; exit 0 ;;
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
  start) do_start "${args[@]}" ;;
  stop) do_stop "${args[@]}" ;;
  restart) do_restart "${args[@]}" ;;
  detail) show_detail "$arg" ;;
  update) do_update ;;
  uninstall) do_uninstall ;;
  "") repl ;;
esac
