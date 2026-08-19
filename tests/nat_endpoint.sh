#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! python3 -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
  python3() { python "$@"; }
fi
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT"
BIN="$CASE_ROOT/bin/sing-box"
CONF="$CASE_ROOT/conf"
CERT="$CASE_ROOT/cert"
SUB="$CASE_ROOT/sub"
LOG="$CASE_ROOT/log"
FIREWALL="$CASE_ROOT/firewall"
UFW_RULES="$FIREWALL/ufw.rules"
STATE="$CASE_ROOT/state.json"
mkdir -p "$CONF" "$CERT" "$SUB" "$LOG" "$FIREWALL"
ensure_state

INPUTS=()
SAFE_READ_COUNT=0
safe_read() {
  local _prompt="$1" variable="$2"
  ((${#INPUTS[@]} > 0)) || { printf 'test input exhausted\n' >&2; return 1; }
  SAFE_READ_COUNT=$((SAFE_READ_COUNT + 1))
  printf -v "$variable" '%s' "${INPUTS[0]}"
  INPUTS=("${INPUTS[@]:1}")
}

public_ipv4() { printf '198.51.100.10'; }
public_ipv6() { return 1; }

INPUTS=(1)
choose_node_ip_version "自动 IPv4" >/dev/null
[[ "$SELECTED_IP_VERSION" == "ipv4" && -z "$SELECTED_ENDPOINT_HOST" ]]
set_selected_protocol vless_reality "port=56668" "uuid=test-uuid" "sni=www.apple.com" "short_id=test"
[[ -z "$(proto_value vless_reality endpoint_host "")" ]]

public_ipv4() { return 1; }
public_ipv6() { return 1; }
INPUTS=(ph2.1card.cc)
choose_node_ip_version "NAT 域名" >/dev/null
[[ "$SELECTED_IP_VERSION" == "custom" && "$SELECTED_ENDPOINT_HOST" == "ph2.1card.cc" ]]
set_selected_protocol vless_reality "port=56668" "uuid=test-uuid" "sni=www.apple.com" "short_id=test"
select_protocol_hosts vless_reality
[[ "$PROTOCOL_HOST" == "ph2.1card.cc" ]]

public_ipv4() { return 1; }
public_ipv6() { return 1; }
cert_pin_sha256() { :; }
generate_subscription
grep -Fq 'ph2.1card.cc:56668' "$SUB/raw.txt"

set_protocol vless_reality "enabled=true" "port=56668" "uuid=test-uuid" "sni=www.apple.com" "short_id=test" "public_key=test" "endpoint_host=2a13:b487:4f06:1314::1f" "ip_version=custom"
line="$(protocol_link_rows)"
[[ "$line" == *'@[2a13:b487:4f06:1314::1f]:56668?'* ]]

public_ipv4() { return 1; }
public_ipv6() { return 1; }
generate_subscription
grep -Fq 'server: "2a13:b487:4f06:1314::1f"' "$SUB/clash.yaml"

set_protocol vless_reality "endpoint_host=" "ip_version=ipv4"
PUBLIC_IPS_DETECTED=false
PUBLIC_IPS_CHECKED=0
DETECTED_PUBLIC_IPV4=""
DETECTED_PUBLIC_IPV6=""
public_ipv4() { printf '203.0.113.10'; }
public_ipv6() { return 1; }
select_protocol_hosts vless_reality
[[ "$PROTOCOL_HOST" == "203.0.113.10" ]]

python3 - "$STATE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["protocols"] = {}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f)
PY
public_ipv4() { return 1; }
public_ipv6() { return 1; }
require_core_installed() { :; }
reality_keypair() { printf 'private-key\npublic-key\n'; }
rebuild_configs() { :; }
show_protocol_details() { :; }
PUBLIC_IPS_DETECTED=false
PUBLIC_IPS_CHECKED=0
SAFE_READ_COUNT=0
INPUTS=(ph2.1card.cc)
add_all_protocols >/dev/null
[[ "$SAFE_READ_COUNT" == "1" ]]
for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls; do
  [[ "$(proto_value "$proto" endpoint_host "")" == "ph2.1card.cc" ]]
  [[ "$(proto_value "$proto" ip_version "")" == "custom" ]]
done

is_alpine() { return 0; }
valid_ip_address '2a0e:97c0:3f0:1::1c9e' 6
valid_ip_address '::1' 6
valid_ip_address '2001:db8:0:1:2:3:4:5' 6
! valid_ip_address ':2001:db8:0:1:2:3:4:5' 6
! valid_ip_address '2001:db8:0:1:2:3:4:5:' 6
! valid_ip_address '2001:db8::1::2' 6

printf 'NAT_ENDPOINT_TEST=PASS\n'
