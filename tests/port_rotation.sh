#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
STATE="$ROOT/state.json"
PORT_HISTORY="$ROOT/port-history"
mkdir -p "$ROOT"
is_alpine() { return 1; }
lite_mode() { return 1; }
ensure_dirs() { mkdir -p "$ROOT"; }
port_used() { [[ " $BUSY " == *" $1 "* ]]; }

# History is appended, capped and read back.
record_port_history vless_reality 30001
record_port_history tuic 30002
port_history_used 30001
port_history_used 30002
! port_history_used 30003
for i in $(seq 1 205); do record_port_history mixed $((40000 + i)); done
[[ "$(wc -l <"$PORT_HISTORY")" == 200 ]]
! port_history_used 30001
grep -Fq 40205 <<<"$(show_port_history)"
record_port_history mixed not-a-port
! grep -q not-a-port "$PORT_HISTORY"

# Random picks avoid busy ports, history and ports taken earlier in the batch.
BUSY="21000"
seq_ports=(21000 40100 22000 22000 23000)
random_high_port() {
  local i
  i="$(cat "$CASE_ROOT/seq")"
  echo $((i + 1)) >"$CASE_ROOT/seq"
  printf '%s' "${seq_ports[i]}"
}
echo 0 >"$CASE_ROOT/seq"
first="$(random_rotation_port "")"
[[ "$first" == 22000 ]]
echo 0 >"$CASE_ROOT/seq"
second="$(random_rotation_port "22000")"
[[ "$second" == 23000 ]]
random_high_port() { printf 21000; }
! random_rotation_port "" >/dev/null

# The menu changes every selected protocol in one state change and records old ports.
cat >"$STATE" <<'EOF'
{"token":"t","protocols":{"vless_reality":{"enabled":true,"port":443},"tuic":{"enabled":true,"port":8443},"mixed":{"enabled":true,"port":1080}}}
EOF
require_core_installed() { :; }
restart_if_running() { :; }
apply_state_change() { shift; "$@"; }
proto_value() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["protocols"].get(sys.argv[2],{}).get(sys.argv[3],sys.argv[4]))' "$STATE" "$1" "$2" "${3:-}"; }
protocol_exists() { [[ "$(proto_value "$1" enabled false)" == True ]]; }
proto_ip_label() { printf 'IPv4'; }
random_rotation_port() { printf '%s' $((50001 + $(wc -w <<<"${1:-}"))); }
: >"$PORT_HISTORY"
output="$(printf '1,3\ny\n' | rotate_ports_menu)"
grep -Fq -- '-> 50001' <<<"$output"
[[ "$(proto_value mixed port)" == 50001 ]]
[[ "$(proto_value tuic port)" == 50002 ]]
[[ "$(proto_value vless_reality port)" == 443 ]]
port_history_used 1080
port_history_used 8443
! port_history_used 443

# "All" changes every protocol; declining leaves the state untouched.
before="$(cat "$STATE")"
printf '4\nn\n' | rotate_ports_menu >/dev/null || true
[[ "$(cat "$STATE")" == "$before" ]]
printf '4\ny\n' | rotate_ports_menu >/dev/null
[[ "$(proto_value vless_reality port)" != 443 ]]
port_history_used 443

# History option only displays, invalid input is rejected.
grep -Fq '历史端口' <<<"$(printf '5\n' | rotate_ports_menu)"
output="$(printf '9\n0\n' | rotate_ports_menu || true)"
grep -Fq '无效选择' <<<"$output"

printf 'PORT_ROTATION_TEST=PASS\n'
