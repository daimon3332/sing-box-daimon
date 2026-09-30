#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT

# An empty prefix skips instead of looping on "前缀不能为空".
node_prefix() { printf ''; }
set_node_prefix() { printf 'set\n' >"$CASE_ROOT/prefix-set"; return 1; }
printf '\n\n' | maybe_set_node_prefix
[[ ! -e "$CASE_ROOT/prefix-set" ]]

# Enter takes the marked default.
[[ "$(printf '\n' | ask_menu "x: " 4 2)" == 2 ]]
[[ "$(printf '\n' | pick_sni "${SNI_OPTIONS[2]}" 2>/dev/null)" == "${SNI_OPTIONS[2]}" ]]
[[ "$(printf '\n\n' | pick_sni custom.example.com 2>/dev/null)" == custom.example.com ]]
detect_public_ips() { DETECTED_PUBLIC_IPV4=1.1.1.1; DETECTED_PUBLIC_IPV6=2001:db8::1; }
printf '\n' | { choose_node_ip_version t 2>/dev/null; [[ "$SELECTED_IP_VERSION" == dual ]]; }
detect_public_ips() { DETECTED_PUBLIC_IPV4=1.1.1.1; DETECTED_PUBLIC_IPV6=""; }
printf '\n' | { choose_node_ip_version t 2>/dev/null; [[ "$SELECTED_IP_VERSION" == ipv4 ]]; }

# Leaving a submenu with 0 skips the pause; a finished action keeps it.
pause() { printf 'paused\n'; }
MENU_CANCELLED=false
menu_cancel || true
[[ -z "$(menu_pause)" ]]
MENU_CANCELLED=false
[[ "$(menu_pause)" == paused ]]

# Hidden main-menu entries are not selectable.
is_alpine() { return 1; }
lite_mode() { return 0; }
main_menu_item_hidden 6
! main_menu_item_hidden 7 || exit 1

# Updating to an identical script changes nothing.
ROOT="$CASE_ROOT/root"
SCRIPT="$ROOT/sb.sh"
mkdir -p "$ROOT"
cp "$REPO_ROOT/sb.sh" "$SCRIPT"
need_root() { :; }
ensure_dirs() { :; }
fetch_latest_script() { cat "$SCRIPT"; }
ln() { printf 'linked\n' >"$CASE_ROOT/linked"; }
out="$(update_script 2>&1)"
[[ "$out" == *"已是最新版本"* && ! -e "$CASE_ROOT/linked" ]]

printf 'INTERACTION_DEFAULTS_TEST=PASS\n'
