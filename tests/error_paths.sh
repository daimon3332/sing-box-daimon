#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

require_core_installed() { :; }
lite_mode() { return 1; }
is_alpine() { return 1; }
maybe_set_node_prefix() { :; }
protocol_exists() { return 1; }
detect_public_ips() { DETECTED_PUBLIC_IPV4=198.51.100.1; DETECTED_PUBLIC_IPV6=""; return 0; }
restart_if_running() { printf 'UNEXPECTED_RESTART\n'; }
show_protocol_details() { :; }
output="$(printf '1\n' | add_protocol_menu || true)"
! grep -Fq UNEXPECTED_RESTART <<<"$output" || exit 1
! grep -Fq '协议已添加' <<<"$output" || exit 1

managed_service_start() { return 1; }
managed_service_exists() { return 0; }
BIN="$(command -v true)"
pause() { :; }
output="$(printf '1\n0\n' | run_manage || true)"
! grep -Eq '已启动。|服务启动成功' <<<"$output" || exit 1

(
  ensure_dirs() { :; }
  python3() { return 23; }
  STATE="$REPO_ROOT/sb.sh"
  ! ensure_state || exit 1
  ensure_state() { :; }
  invalidate_state_cache() { :; }
  ! set_protocol vless_reality port=443 || exit 1
  ! set_state_value sub_port 2096 || exit 1
  ! delete_protocol_state vless_reality || exit 1
)

! ask_text 'value' default </dev/null || exit 1
! ask_yes_no 'confirm' y </dev/null || exit 1
! pick_sni example.com </dev/null || exit 1
port_used() { return 1; }
! ask_port test 443 </dev/null || exit 1

(
  source "$REPO_ROOT/sb.sh"
  proto_value() { printf false; }
  delete_hopping_rules() { :; }
  save_firewall_rules() { :; }
  sync_ufw_ports() { return 1; }
  if apply_protocol_firewall; then
    printf 'Firewall synchronization failure was ignored\n' >&2
    exit 1
  fi
)

(
  source "$REPO_ROOT/sb.sh"
  UFW_RULES="$(mktemp)"
  trap 'rm -f -- "$UFW_RULES"' EXIT
  ensure_dirs() { :; }
  ufw_active() { return 0; }
  ufw() { return 1; }
  required_ufw_rules() { printf '443/tcp\n'; }
  managed_ufw_rules() { :; }
  if sync_ufw_ports; then
    printf 'Failed UFW rule was reported as synchronized\n' >&2
    exit 1
  fi
  [[ ! -s "$UFW_RULES" ]]
)

printf 'ERROR_PATHS_TEST=PASS\n'
