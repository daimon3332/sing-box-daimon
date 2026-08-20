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
UFW_RULES="$FIREWALL/ufw.rules"
STATE="$ROOT/state.json"
SUB_SERVER="$ROOT/sub_server.py"
SERVICE="$CASE_ROOT/sing-box.service"
SUB_SERVICE="$CASE_ROOT/sing-box-sub.service"
mkdir -p "$ROOT/bin" "$CONF" "$CERT" "$SUB" "$LOG" "$FIREWALL"

cat >"$CERT/self.crt" <<'EOF'
-----BEGIN CERTIFICATE-----
TEST-CERTIFICATE
-----END CERTIFICATE-----
EOF
cat >"$STATE" <<'EOF'
{
  "token": "compatToken",
  "sub_port": 2096,
  "sub_endpoint_host": "",
  "sub_domain": "",
  "sub_tls": false,
  "install_mode": "standard",
  "protocols": {
    "hysteria2": {"enabled": true, "endpoint_host": "2001:db8::10", "ip_version": "custom", "port": 28269, "password": "hy-pass", "sni": "www.bing.com"},
    "tuic": {"enabled": true, "endpoint_host": "2001:db8::10", "ip_version": "custom", "port": 28253, "uuid": "tuic-uuid", "password": "tuic-pass", "sni": "www.bing.com"},
    "mixed": {"enabled": true, "endpoint_host": "2001:db8::10", "ip_version": "custom", "port": 30000, "username": "user", "password": "pass"}
  }
}
EOF

public_ipv4() { return 1; }
public_ipv6() { return 1; }
cert_pin_sha256() { :; }
before_state="$(python3 - "$STATE" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), sort_keys=True, separators=(",", ":")))
PY
)"
generate_subscription
after_state="$(python3 - "$STATE" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), sort_keys=True, separators=(",", ":")))
PY
)"
[[ "$before_state" == "$after_state" ]]

python3 - "$SUB/v2rayn_raw.txt" <<'PY'
import base64, json, sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
items = {}
for line in lines:
    if line.startswith("v2rayn://"):
        scheme, encoded = line.rsplit("/", 1)
        items[scheme] = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))

assert items["v2rayn://hysteria2"]["AllowInsecure"] == "false"
assert items["v2rayn://hysteria2"]["Cert"].startswith("-----BEGIN CERTIFICATE-----")
assert items["v2rayn://tuic"]["AllowInsecure"] == "false"
assert items["v2rayn://tuic"]["Cert"].startswith("-----BEGIN CERTIFICATE-----")
assert items["v2rayn://hysteria2"]["CoreType"] == 24
assert items["v2rayn://tuic"]["CoreType"] == 24

socks = next(line for line in lines if line.startswith("socks://"))
prefix, fragment = socks.split("#", 1)
credentials, address = prefix[len("socks://"):].split("@", 1)
assert base64.b64decode(credentials).decode() == "user:pass"
assert address == "[2001:db8::10]:30000"
assert fragment == "Mixed-SOCKS5"
PY

lite_mode() { return 1; }
has_protocols() { return 0; }
printf 'v2rayn://socks/legacy\n' >"$SUB/v2rayn_raw.txt"
legacy_subscription_needs_refresh

refresh_calls=()
need_root() { :; }
ensure_state() { :; }
ensure_dirs() { :; }
lite_mode() { return 1; }
write_sub_server() { refresh_calls+=(write_sub_server); }
write_services() { [[ "${1:-}" == standard ]]; refresh_calls+=(write_services); }
generate_subscription() { refresh_calls+=(generate_subscription); }
restart_sub_service() { refresh_calls+=(restart_sub_service); }
refresh_installed
[[ "${refresh_calls[*]}" == "write_sub_server write_services generate_subscription restart_sub_service" ]]

printf 'SUBSCRIPTION_COMPAT_TEST=PASS\n'
