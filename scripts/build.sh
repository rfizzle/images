#!/usr/bin/env bash
# Build one image x one stream x one variant. Used by CI and by `make`.
#
#   scripts/build.sh <image> <stream> [variant]      variant is "" or "dev"
#
# <stream> is "" (an empty argument) for images with `unversioned: true` in
# versions.yaml, and must be one of the listed streams for every other image.
#
# Env: PUSH=0|1 (default 0)    REGISTRY (required when PUSH=1, e.g. ghcr.io/alice)
#      ARCHS (default amd64,arm64)   OUT (default ./out)   SKIP_TESTS=0|1
#      SOURCE_URL   BUILD_DATE (YYYYMMDD, default today UTC)
#      LOCK_ONLY=1  stop after the lock step and print the resolved version
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUSH="${PUSH:-0}"
ARCHS="${ARCHS:-amd64,arm64}"
OUT="${OUT:-$PWD/out}"
SKIP_TESTS="${SKIP_TESTS:-0}"
LOCK_ONLY="${LOCK_ONLY:-0}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"

die() { echo "error: $*" >&2; exit 1; }

# ---- 1. Validate arguments and read the stream from versions.yaml ----------
parse_args() {
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "usage: build.sh <image> <stream> [variant]"
  IMAGE="$1"
  STREAM="$2"
  VARIANT="${3:-}"
  case "$VARIANT" in "" | dev) ;; *) die "variant must be empty or 'dev', got '$VARIANT'" ;; esac
  IMAGE_DIR="$root/images/$IMAGE"
  [ -d "$IMAGE_DIR" ] || die "no such image: $IMAGE"
  if [ "$PUSH" = 1 ] && [ -z "${REGISTRY:-}" ]; then die "REGISTRY is required when PUSH=1"; fi

  local versions="$IMAGE_DIR/versions.yaml" found
  UNVERSIONED="$(yq '.unversioned // false' "$versions")"
  if [ "$UNVERSIONED" = true ]; then
    # No upstream version: no stream, package family or pin; always tagged latest.
    [ -z "$STREAM" ] || die "$IMAGE is unversioned; pass an empty stream, got '$STREAM'"
    PACKAGE=""
    PIN=""
    LATEST=true
  else
    [ -n "$STREAM" ] || die "$IMAGE is versioned; a stream is required"
    found="$(S="$STREAM" yq '.streams[] | select(.stream == strenv(S)) | .stream' "$versions")"
    [ -n "$found" ] || die "stream '$STREAM' is not listed in $versions"
    PACKAGE="$(yq '.package' "$versions")"
    PIN="$(S="$STREAM" yq '.streams[] | select(.stream == strenv(S)) | .pin // ""' "$versions")"
    LATEST="$(S="$STREAM" yq '.streams[] | select(.stream == strenv(S)) | .latest // false' "$versions")"
    [ -z "$PIN" ] || PIN="~$PIN"
  fi

  SUFFIX=""
  CONFIG_SRC="$IMAGE_DIR/apko.yaml"
  if [ -n "$VARIANT" ]; then
    SUFFIX="-dev"
    CONFIG_SRC="$IMAGE_DIR/apko.dev.yaml"
    [ -f "$CONFIG_SRC" ] || die "$IMAGE has no dev variant (missing $CONFIG_SRC)"
  fi
  NAME="$IMAGE-$STREAM$SUFFIX"
  if [ "$UNVERSIONED" = true ]; then NAME="$IMAGE$SUFFIX"; fi
  mkdir -p "$OUT"
}

# ---- 2. Render ${STREAM}, ${PIN}, ${SOURCE_URL} into a working copy --------
# Unversioned images do not use ${STREAM} or ${PIN}; the substitutions are no-ops.
default_source_url() {
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    echo "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
    return
  fi
  local remote
  remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  if [ -n "$remote" ]; then
    # git@github.com:o/r.git -> https://github.com/o/r
    remote="${remote%.git}"
    remote="${remote/#git@github.com:/https://github.com/}"
    remote="${remote/#ssh:\/\/git@github.com\//https://github.com/}"
    echo "$remote"
    return
  fi
  echo "https://github.com/rfizzle/images"
}

# Escape a value for the right-hand side of a sed s|||g expression.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

render() {
  SOURCE_URL="${SOURCE_URL:-$(default_source_url)}"
  CONFIG="$OUT/$NAME.apko.yaml"
  sed -e "s|\${STREAM}|$(sed_escape "$STREAM")|g" \
    -e "s|\${PIN}|$(sed_escape "$PIN")|g" \
    -e "s|\${SOURCE_URL}|$(sed_escape "$SOURCE_URL")|g" "$CONFIG_SRC" >"$CONFIG"
  # shellcheck disable=SC2016 # literal ${ is intended
  if grep -n '\${' "$CONFIG"; then die "unrendered placeholder left in $CONFIG"; fi
}

# ---- 3. Lock: resolve every package now, read the stream's version ---------
lock() {
  LOCKFILE="$OUT/$NAME.lock.json"
  apko lock "$CONFIG" --output "$LOCKFILE" >&2

  # Unversioned images have no stream package to read a version from.
  if [ "$UNVERSIONED" = true ]; then
    RESOLVED=""
    FULL=""
    return 0
  fi

  local pkg="$PACKAGE-$STREAM" versions count
  versions="$(P="$pkg" yq -p json -o yaml '.contents.packages[] | select(.name == strenv(P)) | .architecture + " " + .version' "$LOCKFILE")"
  [ -n "$versions" ] || die "package $pkg not found in $LOCKFILE"

  # Every arch must resolve the same version.
  count="$(cut -d' ' -f2 <<<"$versions" | sort -u | wc -l | tr -d ' ')"
  [ "$count" = 1 ] || die "architectures resolved different versions of $pkg: $(tr '\n' ';' <<<"$versions")"

  RESOLVED="$(head -n1 <<<"$versions" | cut -d' ' -f2)" # e.g. 1.27.2-r0, 3.15.0_git20261010-r0
  FULL="${RESOLVED%-r*}"                                  # e.g. 1.27.2
  FULL="${FULL%%_*}"                                      # drop snapshot suffix: 3.15.0
  case "$FULL" in
    "$STREAM".*) ;;
    *) die "resolved version $FULL does not start with '$STREAM.'" ;;
  esac
}

# ---- 4. Tags ---------------------------------------------------------------
make_tags() {
  if [ "$UNVERSIONED" = true ]; then
    TAGS=("latest$SUFFIX" "$BUILD_DATE$SUFFIX")
    printf '%s\n' "${TAGS[@]}" >"$OUT/$NAME.tags"
    return
  fi
  TAGS=("$STREAM$SUFFIX" "$FULL$SUFFIX")
  TAGS+=("$FULL-$BUILD_DATE$SUFFIX")
  if [ "$LATEST" = true ]; then TAGS+=("latest$SUFFIX"); fi
  printf '%s\n' "${TAGS[@]}" >"$OUT/$NAME.tags"
}

# ---- 5. Build the multi-arch image and SBOMs -------------------------------
build() {
  SBOM_DIR="$OUT/sbom-$NAME"
  mkdir -p "$SBOM_DIR"
  TAR="$OUT/$NAME.tar"
  apko build "$CONFIG" "${TAGS[0]}" "$TAR" \
    --lockfile "$LOCKFILE" --arch "$ARCHS" --sbom-path "$SBOM_DIR" >&2
}

# ---- 6. Test a single-arch build of the host architecture ------------------
test_image() {
  if [ "$SKIP_TESTS" = 1 ]; then
    echo "skipping tests (SKIP_TESTS=1)" >&2
    return
  fi
  command -v docker >/dev/null 2>&1 || die "docker is required for tests; install it or set SKIP_TESTS=1"
  local host
  case "$(uname -m)" in
    x86_64 | amd64) host=amd64 ;;
    aarch64 | arm64) host=arm64 ;;
    *) die "unsupported host arch $(uname -m)" ;;
  esac
  local ref="localhost/$IMAGE:${TAGS[0]}"
  local host_tar="$OUT/$NAME.$host.tar" sbom_tmp
  sbom_tmp="$(mktemp -d)"
  apko build "$CONFIG" "$ref" "$host_tar" \
    --lockfile "$LOCKFILE" --arch "$host" --sbom-path "$sbom_tmp" >&2
  rm -rf "$sbom_tmp"
  docker load -i "$host_tar" >&2
  # apko names the loaded single-arch image <ref>-<arch>. Retag it to plain <ref>
  # so the tag still ends in "-dev" for the dev variant (test.sh relies on that).
  docker tag "$ref-$host" "$ref"
  "$IMAGE_DIR/test.sh" "$ref" "$STREAM" >&2
  docker rmi -f "$ref" "$ref-$host" >/dev/null 2>&1 || true
}

# ---- 7. Publish with apko, then check the pushed digest --------------------
tar_index_digest() {
  # index.json at the top of the build tar IS the multi-arch OCI index; its
  # sha256 is the digest the registry reports for the pushed index.
  local sum
  if command -v sha256sum >/dev/null 2>&1; then sum=sha256sum; else sum="shasum -a 256"; fi
  # shellcheck disable=SC2086 # $sum is a command plus optional flags
  tar -xOf "$TAR" index.json 2>/dev/null | $sum | sed 's/^\([0-9a-f]*\).*/sha256:\1/' || true
}

publish() {
  DIGEST=""
  [ "$PUSH" = 1 ] || return 0
  local refs="$OUT/$NAME.refs" args=() t
  for t in "${TAGS[@]}"; do args+=("$REGISTRY/$IMAGE:$t"); done
  apko publish "$CONFIG" "${args[@]}" \
    --lockfile "$LOCKFILE" --sbom-path "$SBOM_DIR" --image-refs "$refs" >&2

  # apko lists one reference per architecture and then the index. The index we
  # tested has the digest of the tar's index.json, so look for exactly that
  # reference: finding it proves the registry now holds the image we tested.
  local built
  built="$(tar_index_digest)"
  [ -n "$built" ] || die "could not read the index digest from $TAR"
  if ! grep -q "@$built\$" "$refs"; then
    die "published refs in $refs do not contain the tested index $built"
  fi
  DIGEST="$built"
  echo "$DIGEST" >"$OUT/$NAME.digest"
}

# ---- 8. Summary ------------------------------------------------------------
summary() {
  local tags_joined="${TAGS[*]}"
  printf '\n%-10s %-7s %-22s %-8s %s\n' IMAGE STREAM RESOLVED VARIANT DIGEST
  printf '%-10s %-7s %-22s %-8s %s\n' "$IMAGE" "${STREAM:--}" "${RESOLVED:--}" "${VARIANT:--}" "${DIGEST:--}"
  echo "tags: $tags_joined"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if [ ! -s "$GITHUB_STEP_SUMMARY" ]; then
      printf '| Image | Stream | Resolved | Variant | Tags | Digest |\n|---|---|---|---|---|---|\n' >>"$GITHUB_STEP_SUMMARY"
    fi
    # shellcheck disable=SC2016 # backticks are literal markdown
    printf '| %s | %s | %s | %s | %s | %s |\n' "$IMAGE" "${STREAM:--}" "${RESOLVED:--}" "${VARIANT:--}" \
      "$(printf '`%s` ' "${TAGS[@]}")" "${DIGEST:+\`$DIGEST\`}" >>"$GITHUB_STEP_SUMMARY"
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "tags=$tags_joined"
      echo "digest=$DIGEST"
      echo "resolved=$FULL"
    } >>"$GITHUB_OUTPUT"
  fi
}

main() {
  need yq
  need apko
  parse_args "$@"
  render
  lock
  if [ "$LOCK_ONLY" = 1 ]; then
    if [ "$UNVERSIONED" = true ]; then
      echo "$IMAGE${VARIANT:+ $VARIANT}: unversioned, locked $LOCKFILE"
    else
      echo "$IMAGE $STREAM${VARIANT:+ $VARIANT}: $PACKAGE-$STREAM resolved to $FULL ($RESOLVED)"
    fi
    return 0
  fi
  make_tags
  build
  test_image
  publish
  summary
}

main "$@"
