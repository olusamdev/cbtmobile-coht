#!/usr/bin/env bash
# Replays every migration on a scratch database and runs every SQL test.
#
#   su postgres -c "bash supabase/tests/run-local.sh"      (or run as any superuser)
#
# Exits non-zero on the first migration error or failed test.
set -uo pipefail
DB="${1:-cbt_test}"
HERE="$(cd "$(dirname "$0")" && pwd)"

dropdb --if-exists "$DB" >/dev/null 2>&1
createdb "$DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/local-stub.sql" >/dev/null || { echo "stub failed"; exit 1; }

echo "== migrations"
for f in "$HERE"/../migrations/*.sql; do
  out="$(psql -q -d "$DB" -f "$f" 2>&1 | grep -i 'error' | head -2)"
  if [ -n "$out" ]; then echo "FAILED: $(basename "$f")"; echo "$out"; exit 1; fi
done
echo "all migrations replayed with no errors"

echo "== tests"
fail=0
for t in "$HERE"/verify_*.sql; do
  out="$(psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$t" 2>&1)"
  if echo "$out" | grep -qiE "ALL .*PASSED|PASS: duplicate"; then
    printf "  ok    %s\n" "$(basename "$t")"
  else
    printf "  FAIL  %s\n" "$(basename "$t")"; echo "$out" | grep -iE "error|failure|context" | head -4; fail=1
  fi
done
exit $fail
