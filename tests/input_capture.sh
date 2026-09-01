#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT

# These helpers return their value on stdout, so any prompt or diagnostic they
# print must go to stderr. Otherwise the caller's read/command substitution
# captures the message text as the value: an invalid menu entry produced a
# choice no case branch matched, a rejected port was written into state.json
# where int() then threw, and a bad hop range was stored as hop_start and
# emitted into subscriptions as mport=<error text>-.

PY=python3
"$PY" -c 'import sys' >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { printf 'INPUT_CAPTURE_TEST=SKIP no python\n'; exit 0; }

# Static guarantee for every function whose stdout is captured somewhere.
"$PY" - "$REPO_ROOT/sb.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
funcs, cur, start = {}, None, 0
for i, l in enumerate(lines):
    m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{', l)
    if m:
        cur, start = m.group(1), i
    elif l == '}' and cur:
        funcs[cur] = lines[start + 1:i]
        cur = None
captured = {n for n in funcs
           if re.search(r'\$\(\s*' + n + r'\b', src) or re.search(r'<\(\s*' + n + r'\b', src)}
offenders = []
for name in sorted(captured):
    for ln in funcs[name]:
        s = ln.strip()
        if re.match(r'^(warn|info|fail|title)\s', s) and '>&2' not in s:
            offenders.append(f"{name}: {s[:70]}")
if offenders:
    raise SystemExit("stdout-captured function prints to stdout:\n  " + "\n  ".join(offenders))
PY

# Functional: a rejected entry followed by a good one must yield only the value.
ask_menu_out="$(printf 'abc\n99\n3\n' | ask_menu "choose: " 14 2>/dev/null)"
[[ "$ask_menu_out" == "3" ]]

port_used() { return 1; }
next_free_port() { printf '%s' "$1"; }
ask_port_out="$(printf '99999\nnotaport\n30000\n' | ask_port "Mixed" 30000 2>/dev/null)"
[[ "$ask_port_out" == "30000" ]]

valid_domain_out="$(printf '4\nnot a domain\nexample.com\n' | pick_sni "" 2>/dev/null)"
[[ "$valid_domain_out" == "example.com" ]]

# ask_hopping returns a tab-separated pair; a rejected range must not leak in.
ask_yes_no() { return 0; }
proto_value() { printf 'false'; }
IFS=$'\t' read -r hop_start hop_end < <(printf 'bogus\n48000:50000\n' | ask_hopping "Hysteria-2" 2>/dev/null)
[[ "$hop_start" == "48000" ]]
[[ "$hop_end" == "50000" ]]

# Declining hopping yields two empty fields, not a stray message.
ask_yes_no() { return 1; }
IFS=$'\t' read -r hop_start hop_end < <(ask_hopping "Hysteria-2" 2>/dev/null)
[[ -z "$hop_start" && -z "$hop_end" ]]

# A hop range covering another enabled UDP protocol's port must be rejected:
# the REDIRECT rule would swallow that protocol's traffic.
proto_value() {
  case "$1:$2" in
    tuic:enabled) printf 'true' ;;
    tuic:port) printf '45000' ;;
    mixed:enabled) printf 'false' ;;
    hysteria2:enabled) printf 'true' ;;
    hysteria2:port) printf '59940' ;;
    *) printf 'false' ;;
  esac
}
conflict="$(hopping_range_conflicts hysteria2 40000 50000)"
[[ "$conflict" == *"tuic(45000)"* ]]
# Its own port is never a conflict, and a clear range reports nothing.
[[ -z "$(hopping_range_conflicts hysteria2 20000 21000)" ]]
[[ -z "$(hopping_range_conflicts tuic 44000 46000)" ]]

# The interactive loop must refuse the colliding range and accept a clean one.
ask_yes_no() { return 0; }
IFS=$'\t' read -r hop_start hop_end < <(printf '40000:50000\n20000:21000\n' | ask_hopping "Hysteria-2" 2>/dev/null)
[[ "$hop_start" == "20000" && "$hop_end" == "21000" ]]

printf 'INPUT_CAPTURE_TEST=PASS\n'
