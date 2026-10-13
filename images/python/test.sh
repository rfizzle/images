#!/usr/bin/env bash
# Smoke test: test.sh <image-ref> <stream>
set -euo pipefail
ref="${1:?image ref}"
stream="${2:?stream}"

v="$(docker run --rm "$ref" --version)"
echo "$v"
case "$v" in *"Python $stream."*) ;; *) echo "FAIL: expected Python $stream.*, got $v" >&2; exit 1 ;; esac

got="$(docker run --rm "$ref" -c 'import ssl, json; print(1+1)')"
[ "$got" = 2 ] || { echo "FAIL: expected 2, got '$got'" >&2; exit 1; }

case "$ref" in
  *-dev)
    docker run --rm --entrypoint pip "$ref" --version
    docker run --rm --entrypoint uv "$ref" --version
    ;;
esac
echo "python ok"
