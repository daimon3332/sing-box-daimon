#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if python3 -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif python -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  printf 'python3 is required for this test\n' >&2
  exit 1
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
SCRIPT="$ROOT/sb.sh"
SUB_SERVER="$ROOT/sub_server.py"
SERVICE="$CASE_ROOT/sing-box.service"
SUB_SERVICE="$CASE_ROOT/sing-box-sub.service"
mkdir -p "$ROOT"

INPUTS=(nat.example.com)
SAFE_READ_COUNT=0
DEPENDENCY_MODE=""
DEPENDENCIES_READY=false

python3() {
  [[ "$DEPENDENCIES_READY" == "true" ]] || {
    printf 'python3 used before lite dependencies were installed\n' >&2
    return 127
  }
  "$PYTHON_BIN" "$@"
}

openssl() {
  printf 'openssl must not be used by NAT lite install\n' >&2
  return 127
}

safe_read() {
  local _prompt="$1" variable="$2"
  ((${#INPUTS[@]} > 0)) || { printf 'test input exhausted\n' >&2; return 1; }
  SAFE_READ_COUNT=$((SAFE_READ_COUNT + 1))
  printf -v "$variable" '%s' "${INPUTS[0]}"
  INPUTS=("${INPUTS[@]:1}")
}

need_root() { :; }
install_dependencies() {
  DEPENDENCY_MODE="$1"
  DEPENDENCIES_READY=true
}
install_shortcuts() { :; }
sync_ufw_ports() { :; }
save_firewall_rules() { :; }
delete_hopping_rules() { :; }
public_ipv4() { return 1; }
public_ipv6() { return 1; }
random_free_port() { printf '45678'; }
reality_keypair() { printf 'private-key\npublic-key\n'; }
cert_pin_sha256() { printf 'certificate generation must not run\n' >&2; return 1; }
show_qr() { printf 'QR generation must not run\n' >&2; return 1; }

download_core() {
  mkdir -p "$(dirname "$BIN")"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$BIN"
  chmod 0755 "$BIN"
}

systemctl() {
  return 0
}

install_nat_lite >/dev/null

[[ "$DEPENDENCY_MODE" == "lite" ]]
[[ "$SAFE_READ_COUNT" == "1" ]]
[[ "$(state_value install_mode)" == "lite" ]]
[[ "$(proto_value vless_reality enabled false)" == "true" ]]
[[ "$(proto_value vless_reality endpoint_host "")" == "nat.example.com" ]]
[[ "$(proto_value vless_reality port)" == "45678" ]]
[[ "$(proto_value vless_reality short_id)" =~ ^[0-9a-f]{16}$ ]]
for proto in mixed vmess_ws hysteria2 tuic anytls trojan shadowsocks vmess_tcp vmess_http; do
  [[ "$(proto_value "$proto" enabled false)" == "false" ]]
done
[[ -s "$CONF/11_vless_reality.json" ]]
[[ -s "$SERVICE" ]]
! grep -Eq 'CAP_NET_ADMIN|CAP_NET_RAW' "$SERVICE"
[[ ! -e "$CERT/self.crt" && ! -e "$CERT/self.key" ]]
[[ ! -e "$SUB_SERVICE" && ! -e "$SUB_SERVER" ]]
grep -Fq '@nat.example.com:45678?' "$SUB/raw.txt"

printf 'NAT_LITE_INSTALL_TEST=PASS\n'
