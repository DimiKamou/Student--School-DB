#!/usr/bin/env bash
# Rebuild, load the synthetic year with planted ground truth, and score the
# analytics engine against it. Every assertion must report PASS.
set -euo pipefail
export PGHOST=${PGHOST:-/var/run/postgresql} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
DB=${DB:-schooldb_test}
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"

echo "== rebuilding schema into $DB =="
DB="$DB" WITH_SEED=0 "$ROOT/rebuild.sh"

echo "== generating synthetic year =="
(cd "$(dirname "$ROOT")" && python3 db/test/generate_synthetic.py)

echo "== loading =="
psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$HERE/synthetic.sql"

echo "== refreshing analytics =="
time psql -d "$DB" -q -c "SELECT analytics.refresh_all(false);"

echo "== assertions =="
psql -d "$DB" -f "$HERE/assertions.sql" | tee /tmp/assert_out.txt
if grep -q FAIL /tmp/assert_out.txt; then echo "!! ASSERTIONS FAILED"; exit 1; fi
echo "== all assertions passed =="
