#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
ROOT="$CASE_ROOT/root"
STATE="$ROOT/state.json"
mkdir -p "$ROOT"
cat >"$STATE" <<'EOF'
{"token":"legacy","protocols":{}}
EOF

TEST_PREFIX=""
node_prefix() { printf '%s' "$TEST_PREFIX"; }

[[ -z "$(node_prefix)" ]]
[[ "$(node_name vless_reality)" == "Vless-reality" ]]
TEST_PREFIX=Oracle
[[ "$(node_prefix)" == Oracle ]]
[[ "$(node_name vless_reality)" == "Oracle-Vless-reality" ]]
[[ "$(node_name mixed)" == "Oracle-Mixed-SOCKS5" ]]
! valid_node_prefix ''
! valid_node_prefix 'bad#name'
! valid_node_prefix "$(printf '123456789012345678901234567890123')"
TEST_PREFIX=""
[[ "$(node_name vless_reality)" == "Vless-reality" ]]
printf 'PREFIX_NAMES_TEST=PASS\n'
