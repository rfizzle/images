#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts. Puts ./.bin first on PATH.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$root/.bin:$PATH"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: $1 not found; run 'make tools' (or install it)" >&2
    exit 1
  }
}
