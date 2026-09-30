#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"
command -v jq >/dev/null || { printf 'ALPINE_STATE_TEST=SKIP jq unavailable\n'; exit 0; }
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
is_alpine() { return 0; }
python3() { printf 'unexpected Python dependency\n' >&2; return 127; }
openssl() { printf 'unexpected OpenSSL dependency\n' >&2; return 127; }
public_ipv4() { :; }
public_ipv6() { :; }
apply_protocol_firewall() { :; }
ensure_state
set_state_value install_mode lite
set_state_value node_prefix 'NAT test'
set_protocol vless_reality port=443 uuid=test sni=www.bing.com private_key=private public_key=public short_id=deadbeef endpoint_host=2001:db8::1 ip_version=custom
[[ "$(state_value sub_tls true)" == false ]]
[[ "$(state_value node_prefix)" == 'NAT test' ]]
rebuild_configs
grep -Fq '@[2001:db8::1]:443?' "$SUB/raw.txt"
grep -Fq '#NAT%20test-Vless-reality' "$SUB/raw.txt"
[[ ! -e "$SUB/clash.yaml" && ! -e "$CERT/self.crt" ]]
jq -e '.inbounds[0].listen_port == 443' "$CONF/11_vless_reality.json" >/dev/null
before="$(sha256sum "$STATE")"
! apply_state_change subscription set_protocol vless_reality endpoint_host= ip_version=dual >/dev/null 2>&1 || exit 1
[[ "$(sha256sum "$STATE")" == "$before" ]]
printf 'ALPINE_STATE_TEST=PASS\n'
