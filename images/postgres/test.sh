#!/usr/bin/env bash
# Smoke test: test.sh <image-ref> <stream>
set -euo pipefail
ref="${1:?image ref}"
stream="${2:?stream}"

cid=""
cleanup() {
  if [ -n "$cid" ]; then docker rm -f "$cid" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

cid="$(docker run -d -e POSTGRES_PASSWORD=test "$ref")"

# The entrypoint first runs a temporary init-only server that listens on the
# unix socket alone, then starts the real server. Checking over TCP therefore
# waits for the real server and not the init phase.
ready=0
for _ in $(seq 1 60); do
  if docker exec "$cid" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  echo "FAIL: postgres not ready after 60s" >&2
  docker logs "$cid" >&2 || true
  exit 1
fi

version="$(docker exec "$cid" psql -h 127.0.0.1 -U postgres -tAc 'select version()')"
echo "$version"
case "$version" in *"PostgreSQL $stream."*) ;; *) echo "FAIL: expected PostgreSQL $stream." >&2; exit 1 ;; esac

one="$(docker exec "$cid" psql -h 127.0.0.1 -U postgres -tAc 'select 1')"
[ "$one" = 1 ] || { echo "FAIL: select 1 returned '$one'" >&2; exit 1; }
echo "postgres ok"
