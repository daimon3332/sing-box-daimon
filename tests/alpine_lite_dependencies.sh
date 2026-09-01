#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
# ensure_dirs uses these globals, not $ROOT/..., so every one must be
# redirected or the test creates the real /etc/sing-box tree on the host.
CONF="$ROOT/conf"
CERT="$ROOT/cert"
SUB="$ROOT/sub"
LOG="$ROOT/log"
FIREWALL="$ROOT/firewall"
UFW_RULES="$FIREWALL/ufw.rules"
STATE="$ROOT/state.json"
ALPINE_PACKAGES="$ROOT/alpine-packages"
JQ_INSTALLED=false
APK_ADD_ARGS=""

is_alpine() { return 0; }
lite_dependencies_ready() { [[ "$JQ_INSTALLED" == true ]]; }
apk() {
  if [[ "$1" == info && "$2" == -e ]]; then
    [[ "$3" != jq || "$JQ_INSTALLED" == true ]]
    return
  fi
  if [[ "$1" == add ]]; then
    shift
    APK_ADD_ARGS="$*"
    [[ " $* " == *' jq '* ]]
    [[ " $* " != *' sing-box '* && " $* " != *' python3 '* ]]
    JQ_INSTALLED=true
    return
  fi
  return 1
}

install_alpine_lite_dependencies
[[ "$APK_ADD_ARGS" == '--no-cache jq' ]]
[[ "$(cat "$ALPINE_PACKAGES")" == jq ]]

APK_ADD_ARGS=""
install_alpine_lite_dependencies
[[ -z "$APK_ADD_ARGS" ]]

printf 'ALPINE_LITE_DEPENDENCIES_TEST=PASS\n'
