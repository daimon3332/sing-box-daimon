#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

ensure_state() { :; }
require_core_installed() { :; }
protocol_exists() { [[ "$1" == vless_reality ]]; }
proto_value() {
  case "$2" in
    port) printf 443 ;;
    ip_version) printf ipv4 ;;
    *) printf '%s' "${3:-}" ;;
  esac
}
lite_mode() { return 1; }
is_alpine() { return 1; }
state_value() { printf '%s' "${2:-test-token}"; }
show_subscription_links() { :; }

for fn in change_protocol_config delete_protocol_menu; do
  output="$(printf '0\n' | "$fn" || true)"
  grep -Fq Vless-reality <<<"$output"
  if grep -Eq '[0-9]+\. (Mixed|Vmess-ws|Hysteria-2|Tuic-v5|Anytls|Trojan|Shadowsocks|Vmess-tcp|Vmess-http)' <<<"$output"; then
    printf 'uninstalled protocols offered by %s\n' "$fn" >&2
    exit 1
  fi
done

output="$(printf '0\n' | change_subscription_config || true)"
grep -Eq 'IPv4.*IPv6' <<<"$output"

protocol_exists() { return 1; }
for fn in change_protocol_config delete_protocol_menu; do
  output="$("$fn" </dev/null || true)"
  grep -Fq '尚未添加协议' <<<"$output"
  ! grep -Fq '删除所有协议' <<<"$output" || exit 1
done

[[ "$(printf '01\n' | ask_menu 'choose: ' 15)" == 1 ]]
[[ "$(printf '08\n' | ask_menu 'choose: ' 15)" == 8 ]]
[[ "$(printf '99999999999999999999999999999\n2\n' | ask_menu 'choose: ' 15 2>/dev/null)" == 2 ]]

is_alpine() { return 0; }
clear_screen() { :; }
load_state_cache() { :; }
show_status_header() { :; }
show_protocols() { :; }
output="$(printf '0\n' | main_menu)"
! grep -Fq '标准安装 Sing-box' <<<"$output" || exit 1
! grep -Fq '一键添加协议' <<<"$output" || exit 1
grep -Fq 'NAT' <<<"$output"

printf 'INTERACTION_MENUS_TEST=PASS\n'
