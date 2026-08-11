#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB_PATH="${SB_PATH:-$REPO_ROOT/sb.sh}"
eval "$(sed -n '/^download_core() {/,/^}/p' "$SB_PATH")"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
mkdir -p "$CASE_ROOT/downloads"

BIN="$CASE_ROOT/bin/sing-box"
CHMOD_MARKER="$CASE_ROOT/chmod-called"
VERSION_MARKER="$CASE_ROOT/version-called"
TMPDIR="$CASE_ROOT/downloads"
mkdir -p "$(dirname "$BIN")"
export VERSION_MARKER TMPDIR

arch_name() {
  printf 'amd64'
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
  printf '%s\n' '#!/usr/bin/env bash' ': >"$VERSION_MARKER"' >"$destination/release/sing-box"
  command chmod 0755 "$destination/release/sing-box"
}

install() {
  local source="${@: -2:1}" destination="${@: -1}"
  command cp "$source" "$destination"
  command chmod 0600 "$destination"
}

chmod() {
  if [[ "$1" == "0755" && "$2" == "$BIN" ]]; then
    : >"$CHMOD_MARKER"
  fi
  command chmod "$@"
}

download_core

[[ -f "$CHMOD_MARKER" ]] || { printf 'download_core did not enforce mode 0755\n' >&2; exit 1; }
[[ -x "$BIN" ]] || { printf 'downloaded core is not executable\n' >&2; exit 1; }
[[ -f "$VERSION_MARKER" ]] || { printf 'download_core did not execute sing-box version\n' >&2; exit 1; }
