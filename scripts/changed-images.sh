#!/usr/bin/env bash
# Usage: changed-images.sh <base-ref>
# Print the images whose directory changed since <base-ref>, one per line.
# A change under scripts/ or to build.yaml rebuilds every image.
set -euo pipefail
base="${1:?usage: changed-images.sh <base-ref>}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

changed="$(git diff --name-only "$base" HEAD)"

if grep -qE '^(scripts/|\.github/workflows/build\.yaml$)' <<<"$changed"; then
  find images -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
else
  { grep -E '^images/[^/]+/' <<<"$changed" || true; } | cut -d/ -f2 | sort -u |
    while read -r name; do
      # Skip images deleted in this change.
      if [ -d "images/$name" ]; then echo "$name"; fi
    done
fi
