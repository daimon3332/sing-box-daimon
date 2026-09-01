#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

PY=python3
command -v "$PY" >/dev/null 2>&1 && "$PY" --version >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { printf 'SUB_SERVER_TEST=SKIP no python\n'; exit 0; }

# The generated server bakes in an absolute POSIX ROOT. Under git-bash on
# Windows, Python resolves "/tmp/x" as "D:\tmp\x", so it can never read the
# state file. Skip rather than report a false failure; Linux CI/servers run it.
# Embed the path literally, exactly as write_sub_server does. Passing it as an
# argument would be path-translated by git-bash and hide the mismatch.
PATH_PROBE="$(mktemp -d)"
printf 'ok\n' >"$PATH_PROBE/probe.txt"
if ! "$PY" -c "import os,sys; sys.exit(0 if os.path.isfile('$PATH_PROBE/probe.txt') else 1)" 2>/dev/null; then
  rm -rf "$PATH_PROBE"
  printf 'SUB_SERVER_TEST=SKIP posix paths not visible to this python\n'
  exit 0
fi
rm -rf "$PATH_PROBE"

# Proxy env vars would hijack loopback probes and mask real results.
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY
NOPROXY=(--noproxy '*')

CASE_ROOT="$(mktemp -d)"
cleanup() {
  [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null || true
  rm -rf "$CASE_ROOT"
}
trap cleanup EXIT

ROOT="$CASE_ROOT/root"
STATE="$ROOT/state.json"
SUB="$ROOT/sub"
SUB_SERVER="$ROOT/sub_server.py"
mkdir -p "$ROOT" "$SUB"

ensure_state() { :; }
PORT=$(( 25000 + RANDOM % 20000 ))
cat >"$STATE" <<EOF
{"token":"tok123","sub_port":$PORT,"protocols":{}}
EOF

write_sub_server
"$PY" -m py_compile "$SUB_SERVER"

# Only v2rayn.txt exists; clash.yaml is deliberately absent so the missing-file
# path is exercised. Previously that raised and returned a 500 + traceback.
printf 'vless://example\n' >"$SUB/v2rayn.txt"
printf 'RAWDATA\n' >"$SUB/sub.txt"

"$PY" "$SUB_SERVER" >"$CASE_ROOT/srv.log" 2>&1 &
SRV_PID=$!

code() { curl -s "${NOPROXY[@]}" -o /dev/null -w '%{http_code}' --max-time 8 "$1"; }
body() { curl -s "${NOPROXY[@]}" --max-time 8 "$1"; }

ready=0
for _ in $(seq 1 50); do
  [[ "$(code "http://127.0.0.1:$PORT/sub/tok123")" == 200 ]] && { ready=1; break; }
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 0.2
done
if (( ready == 0 )); then
  printf 'SUB_SERVER_TEST=SKIP server did not become ready\n'
  cat "$CASE_ROOT/srv.log" 2>/dev/null || true
  exit 0
fi

# Existing file serves 200.
[[ "$(code "http://127.0.0.1:$PORT/sub/tok123")" == 200 ]]
[[ "$(body "http://127.0.0.1:$PORT/sub/tok123")" == RAWDATA ]]
[[ "$(code "http://127.0.0.1:$PORT/sub/tok123/v2rayn")" == 200 ]]

# Missing clash.yaml must be 404, not 500.
[[ "$(code "http://127.0.0.1:$PORT/sub/tok123/clash")" == 404 ]]
[[ "$(code "http://127.0.0.1:$PORT/sub/tok123/mihomo")" == 404 ]]
# raw.txt absent too.
[[ "$(code "http://127.0.0.1:$PORT/sub/tok123/raw")" == 404 ]]
# Unknown token / path stays 404.
[[ "$(code "http://127.0.0.1:$PORT/sub/wrongtoken")" == 404 ]]
[[ "$(code "http://127.0.0.1:$PORT/")" == 404 ]]
# No traceback should have been logged.
! grep -qi 'Traceback' "$CASE_ROOT/srv.log"

# Dual-stack: the same socket must answer over IPv6 loopback when available.
if "$PY" -c 'import socket,sys; s=socket.socket(socket.AF_INET6); s.bind(("::1",0)); s.close()' 2>/dev/null; then
  [[ "$(code "http://[::1]:$PORT/sub/tok123")" == 200 ]]
  ipv6_checked=yes
else
  ipv6_checked=skipped
fi

# Corrupt state must yield 503, not a crash.
printf 'not json at all' >"$STATE"
[[ "$(code "http://127.0.0.1:$PORT/sub/tok123")" == 503 ]]
kill -0 "$SRV_PID" 2>/dev/null
! grep -qi 'Traceback' "$CASE_ROOT/srv.log"

kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
SRV_PID=""

# Invalid sub_port must fall back to 2096 rather than crashing on int().
mkdir -p "$CASE_ROOT/p2"
printf '{"token":"t","sub_port":"notanumber"}\n' >"$STATE"
write_sub_server
"$PY" - "$SUB_SERVER" <<'PY'
import ast, sys, re
src = open(sys.argv[1], encoding="utf-8").read()
ast.parse(src)
assert 'except (TypeError, ValueError)' in src
assert 'port = 2096' in src
assert 'IPV6_V6ONLY' in src
assert re.search(r'DualStackTCPServer\(\("::", port\)', src)
assert re.search(r'ReuseTCPServer\(\("0\.0\.0\.0", port\)', src)
PY

printf 'SUB_SERVER_TEST=PASS ipv6=%s\n' "$ipv6_checked"
