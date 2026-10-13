#!/usr/bin/env bash
# Smoke test: test.sh <image-ref> <stream>
set -euo pipefail
ref="${1:?image ref}"
stream="${2:?stream}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

out="$(docker run --rm "$ref" version)"
echo "$out"
case "$out" in *"go$stream."*) ;; *) echo "FAIL: expected go$stream. in version output" >&2; exit 1 ;; esac

cat >"$tmp/main.go" <<'GO'
package main

import "fmt"

func main() { fmt.Println("hello") }
GO
cat >"$tmp/go.mod" <<GO
module hello

go $stream
GO
chmod -R a+rwX "$tmp"

docker run --rm -v "$tmp:/src" -w /src -e GOCACHE=/tmp/gocache "$ref" build -o hello .
got="$(docker run --rm -v "$tmp:/src" --entrypoint /src/hello "$ref")"
[ "$got" = hello ] || { echo "FAIL: expected 'hello', got '$got'" >&2; exit 1; }
echo "go ok"
