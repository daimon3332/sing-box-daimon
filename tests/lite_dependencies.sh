#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
APT_MARKER="$CASE_ROOT/apt-called"
DPKG_MARKER="$CASE_ROOT/dpkg-called"
READY=true
mkdir -p "$ROOT"

lite_dependencies_ready() { [[ "$READY" == "true" ]]; }
has_cmd() { [[ "$1" == "apt-get" ]]; }
apt-get() {
  local cache="" arg
  : >"$APT_MARKER"
  for arg in "$@"; do
    case "$arg" in
      Dir::Cache::archives=*) cache="${arg#*=}" ;;
    esac
  done
  [[ -n "$cache" ]]
  mkdir -p "$cache/partial"
  printf 'package' >"$cache/python3.deb"
}
dpkg-deb() { printf 'python3\n'; }
dpkg-query() {
  [[ "$READY" == "true" ]] || return 1
  printf 'ii '
}
dpkg() {
  case "$1" in
    --audit|--configure) return 0 ;;
    -i)
      READY=true
      : >"$DPKG_MARKER"
      ;;
  esac
}

install_dependencies lite
[[ ! -e "$APT_MARKER" ]]

READY=false
install_dependencies lite
[[ -e "$APT_MARKER" ]]
[[ -e "$DPKG_MARKER" ]]
[[ "$READY" == "true" ]]
[[ -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name '.packages.*' -print)" ]]

printf 'LITE_DEPENDENCIES_TEST=PASS\n'
