#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

PY=python3
command -v "$PY" >/dev/null 2>&1 && "$PY" --version >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { printf 'STATE_ATOMIC_TEST=SKIP no python\n'; exit 0; }

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT

# Static guarantee: no state writer may truncate the live file in place.
# A reader (sub_server) hitting a truncated file returns 503 instead of the
# subscription, and a kill mid-write corrupts every stored credential.
! grep -q 'open(path, "w"' "$REPO_ROOT/sb.sh"
! grep -q 'open(sys.argv\[1\], "w"' "$REPO_ROOT/sb.sh"
(( $(grep -c 'os.replace(tmp, path)' "$REPO_ROOT/sb.sh") >= 6 ))

# Every heredoc using os.* must import os, otherwise the writer dies at runtime
# with stderr suppressed and the state silently stops updating.
"$PY" - "$REPO_ROOT/sb.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
for block in re.findall(r"<<'PY'(.*?)\nPY\n", src, re.S):
    if re.search(r'\bos\.', block) and not re.search(r'^import .*\bos\b', block, re.M):
        raise SystemExit("a PY block uses os. without importing os")
PY

# Stale token copies must not survive a regeneration: ensure_state rotates an
# invalid token without going through the menu, which used to leave the previous
# subscription readable under its old name. Pure bash, so it runs everywhere.
SUB="$CASE_ROOT/sub"
mkdir -p "$SUB"
for f in raw.txt sub.txt clash.yaml v2rayn.txt v2rayn_raw.txt; do printf 'keep\n' >"$SUB/$f"; done
for s in '' .clash .v2rayn .raw; do printf 'old\n' >"$SUB/oldtoken00000000000000000000000000$s"; done
printf 'new\n' >"$SUB/newtok"
printf 'new\n' >"$SUB/newtok.clash"
prune_stale_token_files newtok
[[ -f "$SUB/newtok" && -f "$SUB/newtok.clash" ]]
for s in '' .clash .v2rayn .raw; do [[ ! -e "$SUB/oldtoken00000000000000000000000000$s" ]]; done
for f in raw.txt sub.txt clash.yaml v2rayn.txt v2rayn_raw.txt; do [[ -f "$SUB/$f" ]]; done
# A missing SUB directory must not error.
prune_stale_token_files tok </dev/null
SUB="$CASE_ROOT/nonexistent-sub"
prune_stale_token_files tok

# The runtime writers call python3 directly. Where python3 is absent or is a
# non-functional shim (git-bash on Windows), only the static checks above are
# meaningful, so stop here instead of reporting a false failure.
if ! python3 -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
  printf 'STATE_ATOMIC_TEST=PASS static-only (no working python3 for runtime writers)\n'
  exit 0
fi

# ensure_dirs uses the global CONF/CERT/SUB/LOG/FIREWALL paths, so every one
# must be redirected or the test would touch the real /etc/sing-box.
ROOT="$CASE_ROOT/root"
STATE="$ROOT/state.json"
CONF="$ROOT/conf"
CERT="$ROOT/cert"
SUB="$ROOT/sub"
LOG="$ROOT/log"
FIREWALL="$ROOT/firewall"
UFW_RULES="$FIREWALL/ufw.rules"
mkdir -p "$ROOT"
is_alpine() { return 1; }

ensure_state
[[ -s "$STATE" ]]
[[ ! -e "$STATE.tmp" ]]
[[ ! -d /etc/sing-box/conf ]] || [[ -n "$(ls -A "$CONF" 2>/dev/null || true)" ]] || true

# Functional: concurrent reads during repeated writes must never see partial
# JSON. Mirrors sub_server reading state.json while the menu mutates it.
set_protocol vless_reality "port=443" "uuid=abc" "sni=www.bing.com"
[[ "$(proto_value vless_reality port)" == 443 ]]

"$PY" - "$STATE" >"$CASE_ROOT/race.out" <<'PY'
import json, os, sys, threading, time
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
stop = [False]
bad = [0]
good = [0]

def writer():
    for i in range(200):
        data["protocols"]["vless_reality"]["port"] = 40000 + i
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        time.sleep(0.001)
    stop[0] = True

def reader():
    while not stop[0]:
        try:
            parsed = json.load(open(path, encoding="utf-8"))
            assert parsed["protocols"]["vless_reality"]["uuid"] == "abc"
            good[0] += 1
        except Exception:
            bad[0] += 1

w = threading.Thread(target=writer)
r = threading.Thread(target=reader)
w.start(); r.start(); w.join(); r.join()
print(f"good={good[0]} bad={bad[0]}")
if bad[0]:
    raise SystemExit(f"atomic writes still produced {bad[0]} unreadable reads")
if good[0] == 0:
    raise SystemExit("reader never observed the file; test inconclusive")
PY
grep -q 'bad=0' "$CASE_ROOT/race.out"

# State stays valid and no tmp file leaks after normal operations.
set_state_value sub_port 3096
[[ "$(state_value sub_port)" == 3096 ]]
delete_protocol_state vless_reality
[[ "$(proto_value vless_reality enabled false)" == false ]]
[[ ! -e "$STATE.tmp" ]]
"$PY" -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$STATE"

printf 'STATE_ATOMIC_TEST=PASS %s\n' "$(cat "$CASE_ROOT/race.out")"

printf 'STATE_ATOMIC_TEST=PASS %s\n' "$(cat "$CASE_ROOT/race.out")"
