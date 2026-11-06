#!/usr/bin/env bash
# Deploy one git revision of an application to its host, with backup, health check
# and automatic rollback. Deterministic: no model runs any of this.
#
#   bash deploy.sh <config.env> <git sha>          # deploy
#   bash deploy.sh <config.env> <git sha> --check  # preconditions only, changes nothing
#
# Phases (each prints "PHASE <name>: ok|FAIL <why>"; the last line is DEPLOY: OK|ROLLED_BACK|FAILED):
#   preflight   host reachable, DIR and DIR/.env exist, checkout clean, sha exists on origin, disk,
#               docker compose >= 2.30, DIR/data exists (created) and is uid 1000 (the container's app)
#   record      current sha, image ids (tagged :rollback), alembic version (only with PG_CONTAINER)
#   backup      BACKUP_CMD on the host, which prints "wrote <path>" (e.g. backup-sqlite.sh), skipped when unset
#   switch      git fetch + checkout <sha> (detached)
#   build       compose build BUILD_SERVICES
#   up          compose up -d (migrations, if any, run in the app's entrypoint)
#   health      HEALTH_URL returns 200 within HEALTH_TIMEOUT, SMOKE_URLS return 200, containers up
#   rollback    only on failure: previous sha + :rollback images + up; with PG_CONTAINER, database
#               restored from the backup dump if the alembic version had changed; health checked again
#
# Config (see production.env.example): SSH DIR COMPOSE APP_CONTAINER IMAGES HEALTH_URL required;
# APP_SERVICE (default agentos) BUILD_SERVICES SMOKE_URLS BACKUP_CMD HEALTH_TIMEOUT optional;
# PG_CONTAINER optional: empty = no database, so no alembic record/compare and no DB restore.
set -uo pipefail
CONFIG="${1:?config.env}"; SHA="${2:?git sha}"; MODE="${3:-}"
# shellcheck disable=SC1090
. "$CONFIG"
: "${SSH:?}" "${DIR:?}" "${COMPOSE:?}" "${APP_CONTAINER:?}" "${IMAGES:?}" "${HEALTH_URL:?}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"; PG_CONTAINER="${PG_CONTAINER:-}"; APP_SERVICE="${APP_SERVICE:-agentos}"
# cd failing stops the remote command (so a "set -o pipefail; ..." prefix never runs elsewhere).
remote(){ $SSH "cd $DIR || exit 1; $*"; }
say(){ echo "[deploy $(date '+%H:%M:%S')] $*"; }
phase_ok(){ echo "PHASE $1: ok${2:+ $2}"; }
phase_fail(){ echo "PHASE $1: FAIL $2"; }

wait_health(){
  local limit="$1" t0; t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$limit" ]; do
    [ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$HEALTH_URL")" = "200" ] && return 0
    sleep 5
  done
  return 1
}
# docker compose >= this: `!reset` in compose.prod.yaml (2.24) and env_file `format: raw` (2.30).
COMPOSE_MIN="2.30"

# ---------------------------------------------------------------- preflight
pre_fail(){ phase_fail preflight "$1"; echo "DEPLOY: FAILED"; exit 1; }
$SSH "true" >/dev/null 2>&1 || pre_fail "host unreachable"
remote "true" >/dev/null 2>&1 || pre_fail "$DIR missing on the host (git clone the repo there first)"
remote "test -f .env" || pre_fail "$DIR/.env missing on the host (copy example.env and fill it in)"
dirty=$(remote "git status --short | wc -l"); cur=$(remote "git rev-parse HEAD"); branch=$(remote "git branch --show-current")
remote "git fetch -q origin" || pre_fail "git fetch"
remote "git cat-file -e $SHA^{commit}" 2>/dev/null || pre_fail "sha $SHA not on origin"
[ "$dirty" = "0" ] || pre_fail "checkout has $dirty uncommitted files (nothing is deployed over local edits)"
free_gb=$(remote "df -BG --output=avail / | tail -1 | tr -dc 0-9")
[ "${free_gb:-0}" -ge 5 ] || pre_fail "only ${free_gb}G free"
compose_v=$($SSH "docker compose version --short" 2>/dev/null | tr -d 'v\r' | head -1)
[ -n "$compose_v" ] || pre_fail "docker compose not available on the host"
[ "$(printf '%s\n%s\n' "$COMPOSE_MIN" "$compose_v" | sort -V | head -1)" = "$COMPOSE_MIN" ] \
  || pre_fail "docker compose $compose_v on the host, need >= $COMPOSE_MIN"
# data/ is bind-mounted into the container, whose user app is uid 1000 = ubuntu on EC2.
if [ "$MODE" = "--check" ]; then
  data_note=$(remote "test -d data && echo 'data/ present' || echo 'data/ would be created'")
else
  remote "mkdir -p data" || pre_fail "mkdir $DIR/data"
  data_note="data/ present"
fi
data_uid=$(remote "stat -c %u data 2>/dev/null")
[ -z "$data_uid" ] || [ "$data_uid" = "1000" ] || pre_fail "$DIR/data owned by uid $data_uid; the container user app is uid 1000"
phase_ok preflight "at ${cur:0:7}${branch:+ ($branch)}, target ${SHA:0:7}, ${free_gb}G free, compose $compose_v, $data_note, $(remote "git log --oneline $cur..$SHA | wc -l") commits ahead"
if [ "$cur" = "$(remote "git rev-parse $SHA")" ]; then
  # Short-circuit only when the app is up; a fresh clone at the target sha still needs build/up.
  if wait_health 1; then echo "DEPLOY: OK (already at $SHA)"; exit 0; fi
  say "already at ${SHA:0:7} but $HEALTH_URL is not healthy: not short-circuiting (build + up)"
fi
if [ "$MODE" = "--check" ]; then
  echo "would deploy:"; remote "git log --oneline $cur..$SHA" | sed 's/^/  /' | head -20
  [ "$cur" = "$(remote "git rev-parse $SHA")" ] && echo "  (no new commits; would build and start ${SHA:0:7})"
  echo "DEPLOY: OK (check only)"; exit 0
fi

# ---------------------------------------------------------------- record
# The alembic version; empty without PG_CONTAINER (or without alembic).
alembic(){ [ -n "$PG_CONTAINER" ] || return 0; $SSH "docker exec $PG_CONTAINER psql -U $pg_user -d $pg_db -tAc 'select version_num from alembic_version'" 2>/dev/null; }
pg_user=""; pg_db=""
if [ -n "$PG_CONTAINER" ]; then
  pg_user=$($SSH "docker exec $PG_CONTAINER printenv POSTGRES_USER"); pg_db=$($SSH "docker exec $PG_CONTAINER printenv POSTGRES_DB")
fi
alembic_before=$(alembic)
for img in $IMAGES; do $SSH "docker tag $img:latest $img:rollback" 2>/dev/null || true; done
phase_ok record "sha ${cur:0:7}, ${PG_CONTAINER:+alembic $alembic_before, }images tagged :rollback"

# ---------------------------------------------------------------- backup
# Contract: BACKUP_CMD prints "wrote <path>" (the file it made on the host); that path is
# taken literally, and with PG_CONTAINER it is the pg_restore dump used on rollback.
dump=""
if [ -n "${BACKUP_CMD:-}" ]; then
  out=$($SSH "$BACKUP_CMD" 2>&1); rc=$?
  dump=$(echo "$out" | sed -n 's/^.*wrote \([^ ]*\).*$/\1/p' | tail -1)
  if [ $rc -ne 0 ] || [ -z "$dump" ]; then phase_fail backup "$(echo "$out" | tail -2 | tr '\n' ' ')"; echo "DEPLOY: FAILED"; exit 1; fi
  phase_ok backup "wrote $dump"
else
  phase_ok backup "skipped (no BACKUP_CMD)"
fi

rollback(){
  local why="$1"
  say "rolling back: $why"
  remote "git checkout -q --detach $cur" || true
  for img in $IMAGES; do $SSH "docker tag $img:rollback $img:latest" 2>/dev/null || true; done
  remote "$COMPOSE up -d --no-build >/dev/null 2>&1" || true
  alembic_now=$(alembic)
  if [ -n "$PG_CONTAINER" ] && [ -n "$dump" ] && [ "$alembic_now" != "$alembic_before" ]; then
    say "schema changed ($alembic_before -> $alembic_now); restoring the database from $(basename "$dump")"
    remote "$COMPOSE stop $APP_SERVICE >/dev/null 2>&1; docker exec $PG_CONTAINER psql -U $pg_user -d postgres -qc \"select pg_terminate_backend(pid) from pg_stat_activity where datname='$pg_db' and pid<>pg_backend_pid();\" >/dev/null; docker exec $PG_CONTAINER dropdb -U $pg_user $pg_db && docker exec $PG_CONTAINER createdb -U $pg_user -O $pg_user $pg_db && docker cp $dump $PG_CONTAINER:/tmp/rb.dump && docker exec $PG_CONTAINER pg_restore -U $pg_user -d $pg_db --no-owner --no-privileges -j 2 /tmp/rb.dump; docker exec $PG_CONTAINER rm -f /tmp/rb.dump; $COMPOSE up -d --no-build >/dev/null 2>&1"
  fi
  if wait_health 120; then phase_ok rollback "back at ${cur:0:7}, health ok"; echo "DEPLOY: ROLLED_BACK ($why)"; exit 2
  else phase_fail rollback "health still failing after rollback; manual attention needed"; echo "DEPLOY: FAILED ($why; rollback unhealthy)"; exit 3; fi
}
# ---------------------------------------------------------------- switch / build / up
remote "git checkout -q --detach $SHA" || rollback "git checkout failed"
phase_ok switch "checked out ${SHA:0:7}"
# pipefail on the host so rc is compose's, not tail's/grep's (grep finding nothing is fine).
build_out=$(remote "set -o pipefail; $COMPOSE build ${BUILD_SERVICES:-} 2>&1 | tail -3"); rc=$?
[ $rc -eq 0 ] || { echo "$build_out"; rollback "build failed"; }
phase_ok build "$(echo "$build_out" | grep -c Built) images built"
remote "set -o pipefail; $COMPOSE up -d 2>&1 | { grep -E 'Started|Recreated|Error' || true; } | tail -5" || rollback "compose up failed"
phase_ok up "containers (re)started"

# ---------------------------------------------------------------- health
wait_health "$HEALTH_TIMEOUT" || rollback "health check did not return 200 within ${HEALTH_TIMEOUT}s"
for u in ${SMOKE_URLS:-}; do
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$u"); [ "$code" = "200" ] || rollback "smoke $u returned $code"
done
# Every container of the compose project (APP_CONTAINER minus its "-<service>-<n>" suffix).
down=$($SSH "docker ps -a --filter name=^${APP_CONTAINER%-*-*}- --format '{{.Names}} {{.Status}}' | grep -vc ' Up '")
[ "$down" = "0" ] || rollback "$down container(s) not up"
alembic_after=$(alembic)
phase_ok health "health 200, smoke ok, all containers up${PG_CONTAINER:+, alembic $alembic_before -> $alembic_after}"
echo "DEPLOY: OK (${cur:0:7} -> ${SHA:0:7}, backup $(basename "${dump:-none}"))"
