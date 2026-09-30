#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"
CASE_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
STATE="$ROOT/state.json"
BIN="$ROOT/bin/sing-box"
CONF="$ROOT/conf"
CERT="$ROOT/cert"
SUB="$ROOT/sub"
LOG="$ROOT/log"
FIREWALL="$ROOT/firewall"
UFW_RULES="$FIREWALL/ufw.rules"
apply_protocol_firewall() { :; }
show_protocol_details() { :; }
public_ipv4() { printf '198.51.100.1'; }
public_ipv6() { printf '2001:db8::1'; }
require_core_installed() { :; }
restart_if_running() { printf 'RESTART\n'; }
ensure_state
printf '%s\n' '#!/usr/bin/env bash' 'exit "${CHECK_RC:-0}"' >"$BIN"
chmod +x "$BIN"
set_protocol mixed port=30000 username=true password=false endpoint_host=example.com ip_version=custom
set_protocol vless_reality port=443 uuid=test-uuid sni=www.bing.com private_key=private public_key=public short_id=deadbeef endpoint_host=example.com ip_version=custom
rebuild_configs
python3 - "$STATE" "$CONF/10_mixed.json" <<'PY'
import json, sys
s, c = [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]
assert s["protocols"]["mixed"]["username"] == "true"
assert s["protocols"]["mixed"]["password"] == "false"
assert c["inbounds"][0]["users"][0]["password"] == "false"
PY

snapshot() { sha256sum "$STATE" "$CONF"/*.json "$SUB"/*; }
before="$(snapshot)"
export CHECK_RC=23
! apply_state_change config set_protocol mixed port=10000 >/dev/null 2>&1 || exit 1
[[ "$(snapshot)" == "$before" ]]
export CHECK_RC=0
fail_action() { return 1; }
! apply_state_change config fail_action || exit 1
[[ "$(snapshot)" == "$before" ]]
public_ipv6() { :; }
! apply_state_change subscription set_protocol vless_reality endpoint_host= ip_version=ipv6 >/dev/null 2>&1 || exit 1
[[ "$(snapshot)" == "$before" ]]
public_ipv6() { printf '2001:db8::1'; }

apply_state_change config set_protocol mixed 'password=a"b\c'
python3 - "$CONF/10_mixed.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
assert c["inbounds"][0]["users"][0]["password"] == 'a"b\\c'
PY

before="$(snapshot)"
printf '3 bad\n0\n' | delete_protocol_menu >/dev/null || true
[[ "$(snapshot)" == "$before" ]]
printf '1\nn\n' | delete_protocol_menu >/dev/null || true
[[ "$(snapshot)" == "$before" ]]
printf '01\n0\n' | change_protocol_config >/dev/null || true
[[ "$(snapshot)" == "$before" ]]
printf '2\n1\n\n' | change_protocol_config >/dev/null || true
[[ "$(snapshot)" == "$before" ]]

(
  CONF="$CASE_ROOT/write-failure"
  mkdir -p "$CONF"
  cat() { return 1; }
  ! write_base_configs || exit 1
)

output="$(printf '6\n2\n2\n' | change_subscription_config)"
! grep -Fq RESTART <<<"$output" || exit 1
[[ "$(proto_value vless_reality ip_version)" == ipv6 ]]
[[ "$(proto_value vless_reality uuid)" == test-uuid ]]
[[ "$(proto_value vless_reality port)" == 443 ]]
[[ "$(proto_value mixed ip_version)" == custom ]]
grep -Fq '@[2001:db8::1]:443?' "$SUB/raw.txt"

output="$(printf '1,1\ny\n' | delete_protocol_menu)"
grep -Fq '协议已删除 1 个' <<<"$output"
! protocol_exists mixed || exit 1
protocol_exists vless_reality
[[ ! -e "$CONF/10_mixed.json" ]]
[[ -s "$CONF/11_vless_reality.json" ]]
[[ -z "$(find "$ROOT" -maxdepth 1 -name '.change.*' -print)" ]]
printf 'TRANSACTION_MENUS_TEST=PASS\n'
