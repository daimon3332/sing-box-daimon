#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! python3 -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
  python3() { python "$@"; }
fi
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
STATE="$ROOT/state.json"
mkdir -p "$CONF" "$CERT" "$SUB" "$LOG" "$FIREWALL"
printf 'test certificate\n' >"$CERT/self.crt"
cat >"$STATE" <<'EOF'
{
  "token":"dualToken","node_prefix":"Oracle","install_mode":"standard",
  "protocols":{
    "vless_reality":{"enabled":true,"ip_version":"dual","endpoint_host":"","port":33529,"uuid":"test-uuid","sni":"www.bing.com","public_key":"test-key","short_id":"test-id"},
    "vmess_ws":{"enabled":true,"ip_version":"dual","endpoint_host":"","port":41461,"uuid":"test-vmess","tls":false},
    "hysteria2":{"enabled":true,"ip_version":"dual","endpoint_host":"","port":53245,"password":"hy-pass","sni":"www.bing.com"},
    "tuic":{"enabled":true,"ip_version":"dual","endpoint_host":"","port":48564,"uuid":"tuic-uuid","password":"tuic-pass","sni":"www.bing.com"},
    "anytls":{"enabled":true,"ip_version":"dual","endpoint_host":"","port":33437,"password":"any-pass","sni":"www.bing.com"},
    "mixed":{"enabled":true,"ip_version":"dual","endpoint_host":"","port":30000,"username":"user","password":"pass"}
  }
}
EOF

public_ipv4() { printf '198.51.100.10'; }
public_ipv6() { printf '2001:db8::10'; }
cert_pin_sha256() { :; }
generate_subscription
[[ "$(wc -l <"$SUB/raw.txt")" == 12 ]]
grep -Fq '@[2001:db8::10]:33529?' "$SUB/raw.txt"
grep -Fq '#Oracle-Vless-reality-IPv6' "$SUB/raw.txt"
grep -Fq '"Oracle-Vless-reality-IPv4"' "$SUB/clash.yaml"
grep -Fq '"Oracle-Vless-reality-IPv6"' "$SUB/clash.yaml"
grep -Fq 'server: "2001:db8::10"' "$SUB/clash.yaml"

python3 - "$SUB/v2rayn_raw.txt" <<'PY'
import base64, json, sys, urllib.parse
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 12, len(lines)
assert any("@[2001:db8::10]:33529" in x and x.endswith("#Oracle-Vless-reality-IPv6") for x in lines)
names = []
for link in lines:
    if link.startswith("vmess://"):
        item = json.loads(base64.b64decode(link[8:]))
        names.append(item["ps"])
        if item["ps"].endswith("-IPv6"):
            assert item["add"] == "2001:db8::10"
    elif link.startswith("v2rayn://"):
        encoded = link.rsplit("/", 1)[1]
        item = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        names.append(item["Remarks"])
        if item["Remarks"].endswith("-IPv6"):
            assert item["Address"] == "2001:db8::10"
    else:
        names.append(urllib.parse.unquote(urllib.parse.urlsplit(link).fragment))
assert len(set(names)) == 12
assert "Oracle-Tuic-v5-IPv6" in names
assert "Oracle-Mixed-SOCKS5-IPv6" in names
PY

set_protocol vless_reality 'ip_version=ipv6' 'endpoint_host='
generate_subscription
[[ "$(grep -c '^vless://' "$SUB/raw.txt")" == 1 ]]
grep -Fq '#Oracle-Vless-reality' "$SUB/raw.txt"
! grep -Fq 'Oracle-Vless-reality-IPv4' "$SUB/raw.txt"
[[ "$(proto_value vless_reality uuid)" == test-uuid ]]
set_protocol vless_reality 'ip_version=ipv4' 'endpoint_host='
generate_subscription
grep -Fq '@198.51.100.10:33529?' "$SUB/raw.txt"
set_protocol vless_reality 'ip_version=dual' 'endpoint_host='
INPUTS=(2 3)
safe_read() {
  local _prompt="$1" variable="$2"
  printf -v "$variable" '%s' "${INPUTS[0]}"
  INPUTS=("${INPUTS[@]:1}")
}
rebuild_configs() { :; }
restart_if_running() { :; }
show_protocol_details() { :; }
change_all_protocol_ip_version >/dev/null
for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls; do
  [[ "$(proto_value "$proto" ip_version)" == ipv6 ]]
done
public_ipv4() { return 1; }
PUBLIC_IPS_DETECTED=false
generate_subscription
[[ "$(wc -l <"$SUB/raw.txt")" == 6 ]]
INPUTS=(1 3)
choose_node_ip_version "仅 IPv6" >/dev/null
[[ "$SELECTED_IP_VERSION" == ipv6 ]]
public_ipv4() { printf '198.51.100.10'; }
PUBLIC_IPS_DETECTED=false
change_all_protocol_ip_version >/dev/null
for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls; do
  [[ "$(proto_value "$proto" ip_version)" == dual ]]
done
[[ "$(proto_value vless_reality uuid)" == test-uuid ]]
[[ "$(proto_value vless_reality port)" == 33529 ]]
public_ipv6() { return 1; }
PUBLIC_IPS_DETECTED=false
! generate_subscription >/dev/null 2>&1

printf 'DUAL_STACK_TEST=PASS\n'
