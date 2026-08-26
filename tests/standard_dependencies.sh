#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
APT_LOG="$CASE_ROOT/apt.log"
OPENSSL_READY=true
APT_INSTALL_RC=0

ca_certificates_ready() { return 0; }
has_cmd() {
  case "$1" in
    apt-get|curl|tar|gzip|python3|ss) return 0 ;;
    openssl) [[ "$OPENSSL_READY" == "true" ]] ;;
    qrencode) return 1 ;;
    *) return 1 ;;
  esac
}
apt-get() {
  printf '%s\n' "$*" >>"$APT_LOG"
  if [[ "$1" == "update" ]]; then
    return 100
  fi
  if [[ " $* " == *" install "* && "$APT_INSTALL_RC" -eq 0 ]]; then
    OPENSSL_READY=true
  fi
  return "$APT_INSTALL_RC"
}

install_dependencies standard
[[ ! -e "$APT_LOG" ]]

OPENSSL_READY=false
install_dependencies standard
grep -Fxq 'update' "$APT_LOG"
grep -Eq 'install .*openssl' "$APT_LOG"
[[ "$OPENSSL_READY" == "true" ]]

: >"$APT_LOG"
OPENSSL_READY=false
APT_INSTALL_RC=1
if install_dependencies standard; then
  printf 'missing required dependency unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fxq 'update' "$APT_LOG"
grep -Eq 'install .*openssl' "$APT_LOG"

printf 'STANDARD_DEPENDENCIES_TEST=PASS\n'
