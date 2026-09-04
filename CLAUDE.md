# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`cpg-cli`: a local dev "everything box" of Docker services (Postgres w/ replication,
Redis single+cluster, RabbitMQ, MongoDB, TimescaleDB, an OTel/Tempo/Prometheus/Grafana
observability stack, SonarQube, ChromaDB), controlled group-by-group through one
interactive CLI (`cpg`, implemented twice: `cpg-cli.sh` for bash, `cpg-cli.ps1` for
PowerShell — kept in behavioral parity, see below).

There is no application code / build / test suite here — this is pure infra tooling
(shell scripts + docker-compose files). "Testing a change" means running the CLI or
compose commands directly and checking the output, not `npm test`.

## Architecture

**Each group is its own docker-compose project** (`compose/<group>.yml`, `name:` set
inside each file), on its **own Docker network** (`cpg-<group>`) — containers in one
group cannot resolve containers in another by design. This is what makes each group
show as a separate collapsible entry in `docker compose ls` / Docker Desktop.

Six groups, defined identically (name, compose file, member services, aliases) in
**three places that must stay in sync**: `cpg-cli.sh`'s `GROUP_FILE`/`SVC_GROUPS`/
`GROUP_ALIAS` associative arrays, `cpg-cli.ps1`'s equivalent hashtables, and
`compose/<group>.yml` itself. Adding/removing a service means updating the compose
file *and* both scripts' service lists.

- `database` — postgres (master), postgres-replica-1/2 (`--profile postgres-replica`,
  streaming replication via `pg_basebackup`), pgpool (round-robin read routing,
  writes→master), timescaledb, mongo-primary (replica set primary), mongo-replica-1/2
  (`--profile mongo-cluster`), mongo-express.
- `cache` — redis (single-node), redis-cluster-1..6 (`--profile redis-cluster`, real
  3 masters + 3 replicas), redis-insight.
- `messaging` — rabbitmq.
- `observability` — otel-collector, tempo, prometheus, grafana.
- `quality` — sonarqube.
- `ai` — chromadb only. **Exception to the network-isolation rule**: attaches to
  `cpg-database` and `cpg-cache` as *external* networks (needs both Postgres and
  Redis). Cross-project `depends_on` doesn't exist in Compose, so `cpg start ai`
  auto-starts `database`/`cache` first if their networks aren't up yet
  (`GROUP_DEPENDS` in the CLI scripts) — starting `compose/ai.yml` directly with plain
  `docker compose up -d` fails with "network cpg-database not found" otherwise.

Default creds everywhere: `admin` / `password` (local-dev only, not for anything real).

## Common commands

```bash
./cpg-cli.sh status [group]         # or cpg-cli.ps1 on Windows; installed globally as `cpg`
./cpg-cli.sh start [group...]       # no group -> interactive pick from what's not fully up
./cpg-cli.sh stop  [group...]
./cpg-cli.sh restart [group...]
./cpg-cli.sh detail [group]         # host/port/user/pass/URI per service
./cpg-cli.sh                        # bare -> interactive REPL shell
```

Raw compose, per group (no cross-group `up`/`down` — there is no single "everything"
compose file, that's the point):

```bash
docker compose -f compose/database.yml up -d
docker compose -f compose/database.yml --profile postgres-replica up -d
docker compose -f compose/cache.yml --profile redis-cluster up -d
```

First-time Postgres replication needs a manual role (volume is pre-initialized, so
`/docker-entrypoint-initdb.d` never fires — see comment above the `postgres` service
in `compose/database.yml`):
```bash
docker compose -f compose/database.yml exec postgres psql -U admin -d sample -c \
  "CREATE ROLE repl_user WITH REPLICATION LOGIN PASSWORD 'repl_password';"
```

Install/uninstall the global `cpg` wrapper: `./install.sh` / `./install.ps1` (drops a
thin wrapper into `~/.local/bin` pointing back at this repo's script — checks for
Docker + compose plugin first, offers a per-OS install if missing).
`install-remote.sh`/`.ps1` are the curl-to-bash one-liners (clone + install).

## Editing `cpg-cli.sh` / `cpg-cli.ps1`

- Both scripts implement the same command set, group table, alias table, and fuzzy
  matching independently — **a behavior change in one needs the equivalent change in
  the other** unless it's platform-specific (see quirks below).
- Fuzzy input resolution (`resolve_choice` / equivalent): exact match → alias → unique
  prefix → Levenshtein distance ≤2 asks "did you mean X?" → else prints the top-3
  closest as a suggestion. Applies to both command names and group names.
- Every action function (`_start_one`, `do_stop`, etc.) returns/early-outs, never
  calls `exit` — they run inside the REPL loop, where `exit` would kill the whole
  shell instead of just aborting one command.
- `SVC_GROUPS` deliberately excludes one-shot bootstrap jobs (`mongo-cluster-init`,
  `redis-cluster-init`): they exit 0 and stay exited by design, so counting them in
  status would make a healthy group show "partial" forever.
- **`cpg-cli.ps1` must keep its UTF-8 BOM.** Windows PowerShell 5.1 parses a BOM-less
  `.ps1` with the system ANSI codepage, which mangles the non-ASCII icons (✳●▸❯) and
  breaks parsing (including here-strings). If a tool strips the BOM on save, restore
  it: `Set-Content -Path cpg-cli.ps1 -Value (Get-Content -Raw -Encoding UTF8 cpg-cli.ps1) -Encoding UTF8 -NoNewline`
- Live mid-prompt terminal resize is PowerShell-only (`Wait-KeyOrResize` polls window
  width before `Read-Host` starts). A bash `SIGWINCH` trap for the same was tried and
  reverted — it desyncs GNU readline's internal cursor model (`tput` poking the
  terminal behind readline's back piles up borders instead of redrawing). See
  `docs/pinned-bottom-input-plan.md` for what a real fix would need (raw-keystroke
  input loop replacing `read -e`). Don't re-attempt the trap approach without reading
  that doc first.

## Known image/infra quirks (don't re-debug these)

- `postgres:18.2-alpine3.23`'s baked-in `PGDATA` is `/var/lib/postgresql/18/docker`,
  not the classic path — `compose/database.yml` overrides `PGDATA` explicitly on the
  `postgres` service. Any new Postgres 18+ service needs the same override or the
  volume mount silently binds nothing and data vanishes on container recreation.
- `chromadb/chroma:latest` has no healthcheck (bare Rust binary + `dash`, no curl/wget/
  python/nc/`/dev/tcp` inside — no HTTP/TCP check is possible without a sidecar).
- `pgpool` image is `bitnamilegacy/pgpool:latest`, not `bitnami/pgpool` (Bitnami moved
  old free-tier tags to the unmaintained legacy repo).
- MongoDB needs `--keyFile` once `--replSet` + auth are both on. The keyfile's strict
  permissions can't survive a Windows bind-mount, so `mongo/mongo-entrypoint.sh` copies
  it into the container and fixes ownership before starting `mongod` (same trick as
  `postgres/replica-entrypoint.sh`).
