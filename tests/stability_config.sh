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
SUB_SERVER="$ROOT/sub_server.py"
SERVICE="$CASE_ROOT/sing-box.service"
SUB_SERVICE="$CASE_ROOT/sing-box-sub.service"
mkdir -p "$ROOT/bin" "$CONF" "$CERT" "$SUB" "$LOG" "$FIREWALL"

cat >"$CERT/self.crt" <<'EOF'
-----BEGIN CERTIFICATE-----
TEST-CERTIFICATE
-----END CERTIFICATE-----
EOF

ensure_cert() { :; }
write_tuic_config 4433 tuic-uuid tuic-pass
grep -Fq '"heartbeat": "10s"' "$CONF/14_tuic.json"

is_alpine() { return 1; }
systemctl() { return 0; }
write_services standard
grep -Fq 'Restart=always' "$SERVICE"
grep -Fq 'Restart=always' "$SUB_SERVICE"

printf 'STABILITY_CONFIG_TEST=PASS\n'
