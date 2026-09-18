#!/usr/bin/env bash
# Start / restart the local dev stack reliably.
#   ./dev.sh restart   rebuild nothing, just bounce api + web
#   ./dev.sh reset     drop and rebuild the database, then bounce
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PGHOST=${PGHOST:-/var/run/postgresql} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGDATABASE=${PGDATABASE:-schooldb}

stop() {
  for port in 3001 5173; do
    for pid in $(ss -lptn "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+'); do
      kill "$pid" 2>/dev/null
    done
  done
  # Belt and braces: anything still holding our entrypoints.
  pkill -f 'tsx src/server.ts' 2>/dev/null
  pkill -f 'vite --port 5173' 2>/dev/null
  sleep 2
}

case "${1:-restart}" in
  reset)
    stop
    psql -d postgres -tAc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$PGDATABASE';" >/dev/null
    "$HERE/db/rebuild.sh"
    ;;
  stop) stop; echo "stopped"; exit 0 ;;
  *) stop ;;
esac

( cd "$HERE/api" && NODE_ENV=development PORT=3001 nohup npx tsx src/server.ts > /tmp/api.log 2>&1 & )
( cd "$HERE/web" && nohup npx vite --port 5173 --host 0.0.0.0 > /tmp/web.log 2>&1 & )

for i in $(seq 1 30); do
  if curl -sf localhost:3001/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -sf localhost:3001/health >/dev/null 2>&1 && echo "api  ready on :3001" || { echo "api FAILED"; tail -5 /tmp/api.log; }
for i in $(seq 1 20); do
  if curl -sf localhost:5173/ >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -sf localhost:5173/ >/dev/null 2>&1 && echo "web  ready on :5173" || echo "web not ready (fine if you only need the api)"
