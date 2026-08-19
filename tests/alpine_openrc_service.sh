#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
BIN="$ROOT/bin/sing-box"
CONF="$ROOT/conf"
LOG="$ROOT/log"
SERVICE="$CASE_ROOT/init.d/sing-box"
SUB_SERVICE="$CASE_ROOT/init.d/sing-box-sub"
SUB_SERVER="$ROOT/sub_server.py"
mkdir -p "$ROOT/bin" "$CONF" "$LOG" "$(dirname "$SERVICE")"

is_alpine() { return 0; }
managed_service_disable_now() { [[ "$1" == sing-box-sub ]]; }

write_services lite
[[ -x "$SERVICE" ]]
grep -Fq '#!/sbin/openrc-run' "$SERVICE"
grep -Fq "command=\"$BIN\"" "$SERVICE"
grep -Fq "command_args=\"run -C $CONF\"" "$SERVICE"
grep -Fq 'supervisor="supervise-daemon"' "$SERVICE"
grep -Fq 'respawn_max=0' "$SERVICE"
! grep -Fq '[Unit]' "$SERVICE"
[[ ! -e "$SUB_SERVICE" && ! -e "$SUB_SERVER" ]]

printf 'ALPINE_OPENRC_SERVICE_TEST=PASS\n'
