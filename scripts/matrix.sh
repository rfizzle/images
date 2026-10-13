#!/usr/bin/env bash
# Print the build matrix as a JSON array: one object per (image, stream, variant).
# Env filters: IMAGE, STREAM (empty means all). Streams past their `eol` date are skipped.
# The dev variant is emitted only if images/<name>/apko.dev.yaml exists. An image with
# `unversioned: true` in versions.yaml has no streams: one row per variant with
# "stream":"" and "latest":true.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need yq

filter_image="${IMAGE:-}"
filter_stream="${STREAM:-}"
today="$(date -u +%Y-%m-%d)"
rows=()

for file in "$root"/images/*/versions.yaml; do
  name="$(basename "$(dirname "$file")")"
  [ -z "$filter_image" ] || [ "$filter_image" = "$name" ] || continue

  variants=("")
  [ ! -f "$root/images/$name/apko.dev.yaml" ] || variants+=(dev)

  if [ "$(yq '.unversioned // false' "$file")" = true ]; then
    # No stream to filter on, so a STREAM filter selects nothing.
    [ -z "$filter_stream" ] || continue
    for variant in "${variants[@]}"; do
      rows+=("{\"image\":\"$name\",\"stream\":\"\",\"variant\":\"$variant\",\"latest\":true}")
    done
    continue
  fi

  if [ "$(yq '(.package // "") | length' "$file")" = 0 ] || [ "$(yq '(.streams // []) | length' "$file")" = 0 ]; then
    echo "error: $file is malformed: 'package' and a non-empty 'streams' list are required" >&2
    exit 1
  fi

  count="$(yq '.streams | length' "$file")"
  for ((i = 0; i < count; i++)); do
    stream="$(yq ".streams[$i].stream" "$file")"
    if [ "$stream" = null ]; then
      echo "error: $file: streams[$i] has no 'stream'" >&2
      exit 1
    fi
    [ -z "$filter_stream" ] || [ "$filter_stream" = "$stream" ] || continue
    eol="$(yq ".streams[$i].eol // \"\"" "$file")"
    # ISO dates compare correctly as strings.
    if [ -n "$eol" ] && [[ "$eol" < "$today" ]]; then
      continue
    fi
    latest="$(yq ".streams[$i].latest // false" "$file")"
    for variant in "${variants[@]}"; do
      rows+=("{\"image\":\"$name\",\"stream\":\"$stream\",\"variant\":\"$variant\",\"latest\":$latest}")
    done
  done
done

if [ "${#rows[@]}" -eq 0 ]; then
  echo "[]"
else
  (IFS=,; echo "[${rows[*]}]")
fi
