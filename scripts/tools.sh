#!/usr/bin/env bash
# Download pinned apko, yq (and optionally shellcheck, actionlint) into ./.bin,
# verifying sha256 against the checksums published with each release.
#   scripts/tools.sh          apko + yq
#   scripts/tools.sh lint     also shellcheck + actionlint
set -euo pipefail

APKO_VERSION=1.4.11
YQ_VERSION=4.54.1
ACTIONLINT_VERSION=1.7.12
SHELLCHECK_VERSION=0.11.0

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/.bin"
mkdir -p "$bin"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# verify FILE EXPECTED_SHA
verify() {
  local got
  got="$(sha256_of "$1")"
  if [ "$got" != "$2" ]; then
    echo "sha256 mismatch for $1: expected $2, got $got" >&2
    exit 1
  fi
}

install_apko() {
  local base="https://github.com/chainguard-dev/apko/releases/download/v${APKO_VERSION}"
  local file="apko_${APKO_VERSION}_${os}_${arch}.tar.gz"
  curl -sSfL -o "$tmp/checksums.txt" "$base/checksums.txt"
  curl -sSfL -o "$tmp/$file" "$base/$file"
  verify "$tmp/$file" "$(awk -v f="$file" '$2==f{print $1}' "$tmp/checksums.txt")"
  mkdir "$tmp/apko"
  tar -xzf "$tmp/$file" -C "$tmp/apko"
  install -m 0755 "$tmp/apko/apko_${APKO_VERSION}_${os}_${arch}/apko" "$bin/apko"
}

install_yq() {
  local base="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}"
  local file="yq_${os}_${arch}"
  curl -sSfL -o "$tmp/yq-checksums" "$base/checksums"
  curl -sSfL -o "$tmp/$file" "$base/$file"
  # The checksums file has one column per algorithm, in the order listed in
  # checksums_hashes_order. SHA-256 is the 18th algorithm, so field 19 (field 1 is the name).
  verify "$tmp/$file" "$(awk -v f="$file" '$1==f{print $19}' "$tmp/yq-checksums")"
  install -m 0755 "$tmp/$file" "$bin/yq"
}

install_actionlint() {
  local base="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}"
  local file="actionlint_${ACTIONLINT_VERSION}_${os}_${arch}.tar.gz"
  curl -sSfL -o "$tmp/al-checksums" "$base/actionlint_${ACTIONLINT_VERSION}_checksums.txt"
  curl -sSfL -o "$tmp/$file" "$base/$file"
  verify "$tmp/$file" "$(awk -v f="$file" '$2==f{print $1}' "$tmp/al-checksums")"
  mkdir "$tmp/al"
  tar -xzf "$tmp/$file" -C "$tmp/al"
  install -m 0755 "$tmp/al/actionlint" "$bin/actionlint"
}

install_shellcheck() {
  # The shellcheck release has no checksums file, so the digests are pinned here (computed at pin time).
  local sc_arch sum
  case "$os-$arch" in
    linux-amd64) sc_arch=linux.x86_64; sum="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198" ;;
    linux-arm64) sc_arch=linux.aarch64; sum="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588" ;;
    darwin-amd64) sc_arch=darwin.x86_64; sum="3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6" ;;
    darwin-arm64) sc_arch=darwin.aarch64; sum="56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79" ;;
  esac
  local file="shellcheck-v${SHELLCHECK_VERSION}.${sc_arch}.tar.xz"
  curl -sSfL -o "$tmp/$file" "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/$file"
  verify "$tmp/$file" "$sum"
  mkdir "$tmp/sc"
  tar -xJf "$tmp/$file" -C "$tmp/sc"
  install -m 0755 "$tmp/sc/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$bin/shellcheck"
}

install_apko
install_yq
if [ "${1:-}" = lint ]; then
  install_actionlint
  install_shellcheck
fi
"$bin/apko" version | grep -E 'GitVersion'
"$bin/yq" --version
