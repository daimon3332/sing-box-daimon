#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB_PATH="${SB_PATH:-$REPO_ROOT/sb.sh}"
eval "$(sed -n '/^core_download_url() {/,/^}/p' "$SB_PATH")"
eval "$(sed -n '/^download_core() {/,/^}/p' "$SB_PATH")"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
BIN="$ROOT/bin/sing-box"
VERSION_MARKER="$CASE_ROOT/version-called"
mkdir -p "$ROOT/bin"
export VERSION_MARKER

arch_name() {
  printf 'amd64'
}

is_alpine() {
  return 1
}

fail() {
  printf '%s\n' "$*" >&2
}

curl() {
  if [[ "$*" == *api.github.com* ]]; then
    printf '%s\n' '"browser_download_url": "https://example.test/sing-box-linux-amd64.tar.gz"'
    return
  fi
  local output=""
  while (( $# )); do
    if [[ "$1" == "-o" ]]; then
      output="$2"
      break
    fi
    shift
  done
  [[ -n "$output" ]]
  : >"$output"
}

tar() {
  local destination=""
  while (( $# )); do
    if [[ "$1" == "-C" ]]; then
      destination="$2"
      break
    fi
    shift
  done
  mkdir -p "$destination/release"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ "${FAIL_VERSION:-false}" == "true" ]] && exit 1' \
    ': >"$VERSION_MARKER"' >"$destination/release/sing-box"
  printf 'cronet' >"$destination/release/libcronet.so"
}

install() {
  printf 'download_core must not copy the extracted core\n' >&2
  return 1
}

sync() { :; }

printf 'old-core' >"$BIN"
download_core
[[ -x "$BIN" ]] || { printf 'downloaded core is not executable\n' >&2; exit 1; }
[[ -f "$VERSION_MARKER" ]] || { printf 'candidate core was not validated\n' >&2; exit 1; }
[[ -f "$ROOT/bin/libcronet.so" ]] || { printf 'libcronet was not installed\n' >&2; exit 1; }

printf 'old-core' >"$BIN"
chmod 0755 "$BIN"
FAIL_VERSION=true
export FAIL_VERSION
if download_core; then
  printf 'invalid candidate unexpectedly installed\n' >&2
  exit 1
fi
[[ "$(cat "$BIN")" == "old-core" ]] || { printf 'failed update replaced the existing core\n' >&2; exit 1; }

printf 'DOWNLOAD_CORE_ATOMIC_TEST=PASS\n'
