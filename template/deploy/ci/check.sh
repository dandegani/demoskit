#!/usr/bin/env bash
# The checks for a product checkout: what `make check`, GitHub CI and the DemosOs sdd
# workflow all run.
#
#   bash deploy/ci/check.sh [repo dir, default .] [--tests <pytest path or -k expr>]
#
# A skipped test is not a pass. Exit code: 0 only if every check passed. Prints one
# SUMMARY line per check at the end, which the workflow parses.
set -uo pipefail
REPO="."; case "${1:-}" in ""|--*) ;; *) REPO="$1"; shift;; esac
REPO=$(cd "$REPO" && pwd)
TESTS="tests"
while [ $# -gt 0 ]; do case "$1" in --tests) TESTS="$2"; shift;; esac; shift; done
cd "$REPO" || exit 2
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
PYTHON="${PYTHON:-python}"
declare -A RESULT
say(){ echo "[check] $*"; }

say "pytest $TESTS"
# shellcheck disable=SC2086
out=$($PYTHON -m pytest -q -p no:cacheprovider -rs $TESTS 2>&1); rc=$?
echo "$out" | tail -25
line=$(echo "$out" | grep -E "passed|failed|error|no tests ran" | tail -1 | sed 's/=//g; s/^ *//')
skipped=$(echo "$out" | grep -oE "[0-9]+ skipped" | tail -1)
if [ $rc -eq 0 ] && [ -z "$skipped" ]; then RESULT[tests]="ok ($line)"
elif [ $rc -eq 0 ]; then RESULT[tests]="FAIL skipped tests are not a pass: $line"
else RESULT[tests]="FAIL ($line)"; fi

if [ -d openspec ]; then
  say "openspec validate --all --strict"
  out=$(${OPENSPEC:-openspec} validate --all --strict --no-interactive 2>&1); rc=$?
  [ $rc -eq 0 ] && RESULT[openspec]="ok" || { echo "$out" | tail -10; RESULT[openspec]="FAIL"; }
fi

echo; fail=0
for k in tests openspec; do
  [ -n "${RESULT[$k]:-}" ] || continue
  echo "SUMMARY $k: ${RESULT[$k]}"
  case "${RESULT[$k]}" in FAIL*) fail=1;; esac
done
echo "SUMMARY overall: $([ $fail = 0 ] && echo PASS || echo FAIL) ($SHA)"
exit $fail
