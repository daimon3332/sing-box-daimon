#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
APT_LOG="$CASE_ROOT/apt.log"
OPENSSL_READY=true
QRENCODE_READY=false
APT_INSTALL_RC=0

ca_certificates_ready() { return 0; }
has_cmd() {
  case "$1" in
    apt-get|curl|tar|gzip|python3|ss) return 0 ;;
    openssl) [[ "$OPENSSL_READY" == "true" ]] ;;
    qrencode) [[ "$QRENCODE_READY" == "true" ]] ;;
    *) return 1 ;;
  esac
}
apt-get() {
  printf '%s\n' "$*" >>"$APT_LOG"
  if [[ "$1" == "update" ]]; then
    return 100
  fi
  if [[ " $* " == *" install "* && "$APT_INSTALL_RC" -eq 0 ]]; then
    [[ " $* " != *" openssl "* ]] || OPENSSL_READY=true
    [[ " $* " != *" qrencode "* ]] || QRENCODE_READY=true
  fi
  return "$APT_INSTALL_RC"
}

install_dependencies standard
grep -Fxq 'install -y qrencode' "$APT_LOG"
! grep -Fxq 'update' "$APT_LOG"
[[ "$QRENCODE_READY" == "true" ]]

: >"$APT_LOG"
OPENSSL_READY=false
QRENCODE_READY=false
install_dependencies standard
grep -Fxq 'update' "$APT_LOG"
grep -Eq 'install .*openssl' "$APT_LOG"
grep -Fxq 'install -y qrencode' "$APT_LOG"
[[ "$OPENSSL_READY" == "true" ]]
[[ "$QRENCODE_READY" == "true" ]]

: >"$APT_LOG"
OPENSSL_READY=false
QRENCODE_READY=false
APT_INSTALL_RC=1
if install_dependencies standard; then
  printf 'missing required dependency unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fxq 'update' "$APT_LOG"
grep -Eq 'install .*openssl' "$APT_LOG"

: >"$APT_LOG"
OPENSSL_READY=true
QRENCODE_READY=false
if ! install_dependencies standard; then
  printf 'optional qrencode failure blocked required dependencies\n' >&2
  exit 1
fi
grep -Fxq 'install -y qrencode' "$APT_LOG"
! grep -Fxq 'update' "$APT_LOG"

printf 'STANDARD_DEPENDENCIES_TEST=PASS\n'
