#!/usr/bin/env bash
# Smoke test: test.sh <image-ref> <stream>   (<stream> is empty for unversioned images)
set -euo pipefail
ref="${1:?image ref}"

cid=""
cleanup() {
  if [ -n "$cid" ]; then docker rm -f "$cid" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# The image has no executables, so inspect it and read its filesystem instead.
user="$(docker inspect --format '{{.Config.User}}' "$ref")"
[ "$user" = 65532 ] || { echo "FAIL: expected user 65532, got '$user'" >&2; exit 1; }

# docker create does not run the command, so any path will do.
cid="$(docker create "$ref" /nonexistent)"

files="$(docker export "$cid" | tar -t)"
for f in etc/ssl/certs/ca-certificates.crt usr/share/zoneinfo/UTC etc/passwd; do
  grep -qx "$f" <<<"$files" || { echo "FAIL: $f missing from the image" >&2; exit 1; }
done

passwd="$(docker cp "$cid:/etc/passwd" - | tar -xO)"
case "$passwd" in *"nonroot:x:65532:65532"*) ;; *) echo "FAIL: nonroot 65532 not in /etc/passwd" >&2; echo "$passwd" >&2; exit 1 ;; esac
echo "static ok"
