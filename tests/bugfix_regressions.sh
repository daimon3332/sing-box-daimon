#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
BIN="$ROOT/bin/sing-box"
CONF="$ROOT/conf"
CERT="$ROOT/cert"
SUB="$ROOT/sub"
LOG="$ROOT/log"
FIREWALL="$ROOT/firewall"
UFW_RULES="$FIREWALL/ufw.rules"
STATE="$ROOT/state.json"
SCRIPT="$ROOT/sb.sh"
SUB_SERVER="$ROOT/sub_server.py"
SERVICE="$CASE_ROOT/sing-box.service"
SUB_SERVICE="$CASE_ROOT/sing-box-sub.service"
TMPDIR="$CASE_ROOT/tmp"
mkdir -p "$ROOT/bin" "$CONF" "$CERT" "$SUB" "$LOG" "$FIREWALL" "$TMPDIR"
json() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(repr(eval(sys.argv[2],{'d':d})))" "$STATE" "$1"; }

# A missing state.json must fail quietly instead of printing a traceback.
out="$(load_state_cache 2>&1 || true)"
[[ -z "$out" ]]

cat >"$STATE" <<'EOF'
{"token":"t0","install_mode":"standard","sub_tls":false,"protocols":{}}
EOF

# "true"/"false" are strings everywhere except real boolean keys.
set_state_value token true
[[ "$(json "d['token']")" == "'true'" ]]
set_state_value node_prefix false
[[ "$(json "d['node_prefix']")" == "'false'" ]]
set_state_value sub_tls true
[[ "$(json "d['sub_tls']")" == "True" ]]
set_protocol mixed port=30000 username=true password=false
[[ "$(json "d['protocols']['mixed']['password']")" == "'false'" ]]
[[ "$(json "d['protocols']['mixed']['username']")" == "'true'" ]]
[[ "$(json "d['protocols']['mixed']['enabled']")" == "True" ]]
set_protocol vmess_ws port=40000 uuid=u tls=true
[[ "$(json "d['protocols']['vmess_ws']['tls']")" == "True" ]]

# Shadowsocks listens on UDP too, so UFW must open both.
set_protocol shadowsocks port=41000 password=p method=aes-128-gcm
[[ "$(protocol_ufw_rules shadowsocks | tr '\n' ' ')" == "41000/tcp 41000/udp " ]]

# The hop range owner arrives as the display label; its own port is fine.
set_protocol hysteria2 port=49000 password=p hop_start= hop_end=
[[ -z "$(hopping_range_conflicts Hysteria-2 48000 50000)" ]]
[[ "$(hopping_range_conflicts Hysteria-2 40000 42000)" == "shadowsocks(41000) " ]]

# Ports inside an active hop range count as used.
tcp_udp_used() { return 1; }
set_protocol hysteria2 hop_start=48000 hop_end=50000
hop_range_used 48500
! hop_range_used 47999 || exit 1
port_used 48500
[[ "$(next_free_port 48000)" == 50001 ]]

# BusyBox fallback: IPv4 check matches ipaddress semantics.
(
  is_alpine() { return 0; }
  valid_ip_address 1.2.3.4 4
  valid_ip_address 255.255.255.0 4
  ! valid_ip_address 1.2.3.4. 4 || exit 1
  ! valid_ip_address 01.2.3.4 4 || exit 1
  ! valid_ip_address 256.1.1.1 4 || exit 1
  ! valid_ip_address 1.2.3 4 || exit 1
)

# Downloaded scripts must be complete before they replace the manager.
printf '' >"$CASE_ROOT/empty.sh"
printf '<html>404</html>\n' >"$CASE_ROOT/html.sh"
printf '#!/usr/bin/env bash\nSCRIPT_VERSION="9.9.9"\necho ok\n' >"$CASE_ROOT/good.sh"
! valid_script_file "$CASE_ROOT/empty.sh" || exit 1
! valid_script_file "$CASE_ROOT/html.sh" || exit 1
valid_script_file "$CASE_ROOT/good.sh"

# Running from the installed copy must not download over it.
printf '#!/usr/bin/env bash\nSCRIPT_VERSION="1.0.0"\n' >"$SCRIPT"
curl() { printf 'curl-called\n' >"$CASE_ROOT/curl-called"; return 1; }
(
  SCRIPT_SOURCE="$SCRIPT"
  write_managed_script
)
[[ ! -e "$CASE_ROOT/curl-called" ]]
grep -q 'SCRIPT_VERSION="1.0.0"' "$SCRIPT"
unset -f curl

# Only free or already-managed shortcuts are replaced.
printf 'real binary\n' >"$CASE_ROOT/foreign"
link_shortcut_if_managed "$CASE_ROOT/foreign"
[[ ! -L "$CASE_ROOT/foreign" ]]
link_shortcut_if_managed "$CASE_ROOT/free"
[[ "$(readlink -f "$CASE_ROOT/free")" == "$SCRIPT" ]]

# The service reapplies hopping rules before every start.
(
  is_alpine() { return 1; }
  systemctl() { return 0; }
  write_services standard
)
grep -Fq "ExecStartPre=-/bin/bash $SCRIPT --apply-hopping" "$SERVICE"

# nginx listens on IPv6 as well when the kernel has it.
(
  NGINX_SUB_CONF="$CASE_ROOT/nginx.conf"
  NGINX_SUB_LINK="$CASE_ROOT/nginx.link"
  mkdir() { command mkdir -p "$CASE_ROOT/nginx-dirs"; }
  nginx() { return 0; }
  systemctl() { return 0; }
  host_has_ipv6() { return 0; }
  write_nginx_subscription_config sub.example.com 2096
  grep -Fq 'listen [::]:80;' "$NGINX_SUB_CONF"
  grep -Fq 'listen [::]:443 ssl http2;' "$NGINX_SUB_CONF"
  host_has_ipv6() { return 1; }
  write_nginx_subscription_config sub.example.com 2096
  ! grep -Fq '[::]' "$NGINX_SUB_CONF" || exit 1
)

# A failed dependency step aborts the install even under "|| true".
(
  need_root() { :; }
  is_alpine() { return 1; }
  install_dependencies() { return 1; }
  download_core() { printf 'reached\n' >"$CASE_ROOT/download-reached"; }
  install_sing_box >/dev/null 2>&1 || true
)
[[ ! -e "$CASE_ROOT/download-reached" ]]

# A failed add is reported as a failure, not as "协议已添加".
(
  require_core_installed() { return 0; }
  maybe_set_node_prefix() { :; }
  protocol_menu_items() { AVAILABLE_PROTOCOLS=(mixed); }
  ask_menu() { printf '1'; }
  add_mixed() { return 1; }
  restart_if_running() { printf 'restarted\n' >"$CASE_ROOT/restarted"; }
  out="$(add_protocol_menu 2>&1)" && exit 1
  [[ "$out" == *"协议添加失败"* && "$out" != *"协议已添加"* ]]
)
[[ ! -e "$CASE_ROOT/restarted" ]]

# The version check no longer touches state.json.
before="$(sha256sum "$STATE")"
fetch_latest_script() { printf 'SCRIPT_VERSION="9.9.9"\n'; }
refresh_version_cache
[[ "$(sha256sum "$STATE")" == "$before" ]]
[[ "$(version_status)" == *"发现新版本:9.9.9"* ]]

# An abandoned lock older than two minutes is reclaimed.
lock="$TMPDIR/stale.lock"
mkdir "$lock"
touch -d '10 minutes ago' "$lock"
acquire_async_lock "$lock"
! acquire_async_lock "$lock" || exit 1

printf 'BUGFIX_REGRESSIONS_TEST=PASS\n'
