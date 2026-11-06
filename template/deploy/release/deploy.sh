#!/usr/bin/env bash
# Deploy one git revision of an application to its host, with backup, health check
# and automatic rollback. Deterministic: no model runs any of this.
#
#   bash deploy.sh <config.env> <git sha>          # deploy
#   bash deploy.sh <config.env> <git sha> --check  # preconditions only, changes nothing
#
# Phases (each prints "PHASE <name>: ok|FAIL <why>"; the last line is DEPLOY: OK|ROLLED_BACK|FAILED):
#   preflight   host reachable, checkout clean, sha exists on origin, disk
#   record      current sha, image ids (tagged :rollback), alembic version (only with PG_CONTAINER)
#   backup      BACKUP_CMD on the host (database dump -> S3), skipped when unset
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
remote(){ $SSH "cd $DIR && $*"; }
say(){ echo "[deploy $(date '+%H:%M:%S')] $*"; }
phase_ok(){ echo "PHASE $1: ok${2:+ $2}"; }
phase_fail(){ echo "PHASE $1: FAIL $2"; }

# ---------------------------------------------------------------- preflight
if ! remote "true" >/dev/null 2>&1; then phase_fail preflight "host unreachable"; echo "DEPLOY: FAILED"; exit 1; fi
dirty=$(remote "git status --short | wc -l"); cur=$(remote "git rev-parse HEAD"); branch=$(remote "git branch --show-current")
remote "git fetch -q origin" || { phase_fail preflight "git fetch"; echo "DEPLOY: FAILED"; exit 1; }
if ! remote "git cat-file -e $SHA^{commit}" 2>/dev/null; then phase_fail preflight "sha $SHA not on origin"; echo "DEPLOY: FAILED"; exit 1; fi
if [ "$dirty" != "0" ]; then phase_fail preflight "checkout has $dirty uncommitted files (nothing is deployed over local edits)"; echo "DEPLOY: FAILED"; exit 1; fi
free_gb=$(remote "df -BG --output=avail / | tail -1 | tr -dc 0-9")
[ "${free_gb:-0}" -ge 5 ] || { phase_fail preflight "only ${free_gb}G free"; echo "DEPLOY: FAILED"; exit 1; }
phase_ok preflight "at ${cur:0:7}${branch:+ ($branch)}, target ${SHA:0:7}, ${free_gb}G free, $(remote "git log --oneline $cur..$SHA | wc -l") commits ahead"
if [ "$cur" = "$(remote "git rev-parse $SHA")" ]; then echo "DEPLOY: OK (already at $SHA)"; exit 0; fi
if [ "$MODE" = "--check" ]; then
  echo "would deploy:"; remote "git log --oneline $cur..$SHA" | sed 's/^/  /' | head -20
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
dump=""
if [ -n "${BACKUP_CMD:-}" ]; then
  out=$($SSH "$BACKUP_CMD" 2>&1); rc=$?
  dump=$(echo "$out" | grep -oE "wrote [^ ]+\.dump" | head -1 | cut -d' ' -f2)
  if [ $rc -ne 0 ] || [ -z "$dump" ]; then phase_fail backup "$(echo "$out" | tail -2 | tr '\n' ' ')"; echo "DEPLOY: FAILED"; exit 1; fi
  dump="$(dirname "$(echo "$out" | grep -oE '/[^ ]+\.dump' | head -1 || echo /home/ubuntu/backups/x)")/$dump"
  [ -f /dev/null ] && dump_path=$($SSH "ls -d /home/ubuntu/backups/*/$(basename "$dump") 2>/dev/null | head -1")
  dump="${dump_path:-$dump}"
  phase_ok backup "$(basename "$dump") uploaded to S3"
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
wait_health(){
  local limit="$1" t0; t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$limit" ]; do
    [ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$HEALTH_URL")" = "200" ] && return 0
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------- switch / build / up
remote "git checkout -q --detach $SHA" || rollback "git checkout failed"
phase_ok switch "checked out ${SHA:0:7}"
build_out=$(remote "$COMPOSE build ${BUILD_SERVICES:-} 2>&1 | tail -3"); rc=$?
[ $rc -eq 0 ] || { echo "$build_out"; rollback "build failed"; }
phase_ok build "$(echo "$build_out" | grep -c Built) images built"
remote "$COMPOSE up -d 2>&1 | grep -E 'Started|Recreated|Error' | tail -5" || rollback "compose up failed"
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
