#!/usr/bin/env bash
# Drop and rebuild the whole database from migrations + seeds. Dev only.
set -euo pipefail
export PGHOST=${PGHOST:-/var/run/postgresql} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
DB=${DB:-schooldb}
HERE="$(cd "$(dirname "$0")" && pwd)"
psql -tAc "DROP DATABASE IF EXISTS $DB;" >/dev/null
psql -tAc "CREATE DATABASE $DB;" >/dev/null
for f in "$HERE"/migrations/*.sql; do
  printf '  %-44s' "$(basename "$f")"
  psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" && echo "ok"
done
if [ "${WITH_SEED:-1}" = "1" ]; then
  for f in "$HERE"/seed/*.sql "$HERE"/seed/frameworks/*.sql; do
    [ -e "$f" ] || continue
    printf '  seed %-39s' "$(basename "$f")"
    psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" && echo "ok"
  done
fi
