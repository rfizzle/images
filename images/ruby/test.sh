#!/usr/bin/env bash
# Smoke test: test.sh <image-ref> <stream>
set -euo pipefail
ref="${1:?image ref}"
stream="${2:?stream}"

v="$(docker run --rm "$ref" --version)"
echo "$v"
case "$v" in "ruby $stream."*) ;; *) echo "FAIL: expected ruby $stream.*, got $v" >&2; exit 1 ;; esac

got="$(docker run --rm "$ref" -e 'puts 1+1')"
[ "$got" = 2 ] || { echo "FAIL: expected 2, got '$got'" >&2; exit 1; }

case "$ref" in
  *-dev)
    docker run --rm --entrypoint bundle "$ref" --version
    docker run --rm --entrypoint gem "$ref" --version
    ;;
esac
echo "ruby ok"
