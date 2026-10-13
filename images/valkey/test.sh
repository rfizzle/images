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

cid="$(docker run -d "$ref")"

ready=0
for _ in $(seq 1 30); do
  if [ "$(docker exec "$cid" valkey-cli ping 2>/dev/null || true)" = PONG ]; then ready=1; break; fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  echo "FAIL: valkey did not answer PONG within 30s" >&2
  docker logs "$cid" >&2 || true
  exit 1
fi

info="$(docker exec "$cid" valkey-cli info server)"
case "$info" in *"valkey_version:$stream."*) ;; *) echo "FAIL: expected valkey_version:$stream." >&2; echo "$info" >&2; exit 1 ;; esac
echo "valkey ok"
