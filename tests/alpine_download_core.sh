#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB_PATH="${SB_PATH:-$REPO_ROOT/sb.sh}"
eval "$(sed -n '/^download_core() {/,/^}/p' "$SB_PATH")"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
BIN="$ROOT/bin/sing-box"
APK_REPOSITORIES="$CASE_ROOT/repositories"
VERSION_MARKER="$CASE_ROOT/version-called"
CURL_LOG="$CASE_ROOT/curl.log"
APK_LOG="$CASE_ROOT/apk.log"
TAR_FAIL=false
mkdir -p "$ROOT/bin"
printf '%s\n' 'https://mirror.example/alpine/v3.24/community' >"$APK_REPOSITORIES"
export VERSION_MARKER

is_alpine() { return 0; }
info() { :; }
fail() { printf '%s\n' "$*" >&2; }
sync() { :; }
sleep() { command sleep 0.01; }
apk() {
  printf '%s\n' "$*" >>"$APK_LOG"
  case "$1" in
    --print-arch) printf 'x86_64\n' ;;
    verify) [[ -s "$2" ]] ;;
    *) return 1 ;;
  esac
}
curl() {
  printf '%s\n' "$*" >>"$CURL_LOG"
  local output="" index
  for ((index = 1; index <= $#; index++)); do
    if [[ "${!index}" == -o ]]; then
      index=$((index + 1))
      output="${!index}"
      break
    fi
  done
  if [[ -n "$output" ]]; then
    printf 'signed apk' >"$output"
  else
    printf 'stream\n'
  fi
}
tar() {
  if [[ "$*" == *APKINDEX* ]]; then
    cat >/dev/null
    printf 'C:checksum\nP:sing-box\nV:1.13.11-r1\nA:x86_64\n\n'
    return
  fi
  cat >/dev/null
  [[ "$TAR_FAIL" == false ]] || return 1
  local destination="" index
  for ((index = 1; index <= $#; index++)); do
    if [[ "${!index}" == -C ]]; then
      index=$((index + 1))
      destination="${!index}"
      break
    fi
  done
  mkdir -p "$destination/usr/bin"
  printf '%s\n' '#!/usr/bin/env bash' ': >"$VERSION_MARKER"' >"$destination/usr/bin/sing-box"
}

printf 'old-core' >"$BIN"
download_core lite
[[ -x "$BIN" && -f "$VERSION_MARKER" ]]
grep -Fq -- '--limit-rate 1M https://mirror.example/alpine/v3.24/community/x86_64/sing-box-1.13.11-r1.apk' "$CURL_LOG"
grep -Fq -- '--limit-rate 512K file://' "$CURL_LOG"
grep -Fq -- 'verify ' "$APK_LOG"
[[ ! -e "$ROOT/bin/libcronet.so" ]]

printf 'old-core' >"$BIN"
chmod 0755 "$BIN"
TAR_FAIL=true
if download_core lite; then
  printf 'failed Alpine extraction unexpectedly installed a core\n' >&2
  exit 1
fi
[[ "$(cat "$BIN")" == old-core ]]

printf 'ALPINE_DOWNLOAD_CORE_TEST=PASS\n'
