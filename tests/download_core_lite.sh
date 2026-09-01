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
STREAM_MARKER="$CASE_ROOT/stream-args"
TAR_MARKER="$CASE_ROOT/tar-args"
TAR_FAIL=false
mkdir -p "$ROOT/bin"
export VERSION_MARKER

arch_name() { printf 'amd64'; }
is_alpine() { return 1; }
info() { :; }
fail() { printf '%s\n' "$*" >&2; }
sync() { :; }
sleep() { :; }

curl() {
  if [[ "$*" == *api.github.com* ]]; then
    printf '%s\n' '"browser_download_url": "https://example.test/sing-box-linux-amd64.tar.gz"'
    return
  fi
  printf '%s\n' "$*" >"$STREAM_MARKER"
  printf 'streamed archive'
}

tar() {
  local destination=""
  printf '%s\n' "$*" >"$TAR_MARKER"
  cat >/dev/null
  while (($#)); do
    if [[ "$1" == "-C" ]]; then
      destination="$2"
      break
    fi
    shift
  done
  [[ "$TAR_FAIL" == "false" ]] || return 1
  mkdir -p "$destination/release"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    ': >"$VERSION_MARKER"' >"$destination/release/sing-box"
}

install() {
  printf 'download_core must not copy the extracted core\n' >&2
  return 1
}

printf 'old-core' >"$BIN"
download_core lite
[[ -x "$BIN" ]]
[[ -f "$VERSION_MARKER" ]]
[[ ! -e "$ROOT/bin/libcronet.so" ]]
grep -Fq -- '--limit-rate 1M' "$STREAM_MARKER"
grep -Fq -- "--checkpoint=100" "$TAR_MARKER"
grep -Fq -- "--checkpoint-action=exec=sync" "$TAR_MARKER"
grep -Fq -- '-xzf -' "$TAR_MARKER"
grep -Fq -- '--wildcards */sing-box' "$TAR_MARKER"

printf 'old-core' >"$BIN"
chmod 0755 "$BIN"
TAR_FAIL=true
if download_core lite; then
  printf 'failed stream unexpectedly installed a core\n' >&2
  exit 1
fi
[[ "$(cat "$BIN")" == "old-core" ]]

printf 'DOWNLOAD_CORE_LITE_TEST=PASS\n'
