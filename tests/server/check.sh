#!/usr/bin/env bash
# Read-only acceptance check for a real VPS. Run as root after updating
# /etc/sing-box/sb.sh (menu 1 or a manual copy) and doing a standard or NAT
# install. It changes nothing except re-running the idempotent hopping hook.
set -uo pipefail

ROOT=/etc/sing-box
SCRIPT="$ROOT/sb.sh"
STATE="$ROOT/state.json"
PASS=0
FAIL=0
ok() { printf '\033[32m[OK]\033[0m   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '\033[33m[SKIP]\033[0m %s\n' "$*"; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }
# grep -q exits on the first match; under pipefail the writer then dies of
# SIGPIPE and a large output reads as a failure. Drain the whole input.
has() { grep "$@" >/dev/null; }
sv() { # state value via jq or python
  if command -v jq >/dev/null 2>&1; then jq -r "$1 // empty" "$STATE" 2>/dev/null
  else python3 -c "import json,sys;d=json.load(open('$STATE'));v=eval(sys.argv[1],{'d':d});print('' if v is None else v)" "$2" 2>/dev/null; fi
}

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
alpine=false; grep -q '^ID=alpine' /etc/os-release 2>/dev/null && alpine=true
echo "== $(hostname) $(. /etc/os-release; echo "$PRETTY_NAME") alpine=$alpine =="

check "script syntax" bash -n "$SCRIPT"
ver="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$SCRIPT")"
[[ "$ver" == 1.11.1 ]] && ok "script version $ver" || bad "script version is '$ver', expected 1.11.1"
! grep -q 'network_tools_menu\|99-zz-sing-box-daimon' "$SCRIPT" && ok "network tuning removed" || bad "network tuning code still present"
[[ -s "$STATE" ]] || { bad "no $STATE — install first"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

mode="$(sv '.install_mode' "d.get('install_mode','standard')")"; mode="${mode:-standard}"
token="$(sv '.token' "d['token']")"
echo "mode=$mode"

# state types: token must be a string
ttype="$(if command -v jq >/dev/null; then jq -r '.token|type' "$STATE"; else python3 -c "import json;print(type(json.load(open('$STATE'))['token']).__name__)"; fi)"
[[ "$ttype" == string || "$ttype" == str ]] && ok "token stored as string" || bad "token stored as $ttype"

check "sing-box check" "$ROOT/bin/sing-box" check -C "$ROOT/conf"
if $alpine; then
  check "sing-box service running (openrc)" rc-service sing-box status
else
  check "sing-box service active" systemctl is-active --quiet sing-box
  grep -q 'ExecStartPre=-/bin/bash /etc/sing-box/sb.sh --apply-hopping' /etc/systemd/system/sing-box.service \
    && ok "unit reapplies hopping before start" || bad "ExecStartPre hook missing (run menu 1 to refresh the unit)"
fi
check "--apply-hopping exits 0" bash "$SCRIPT" --apply-hopping

# Hopping rules must match state.
hs="$(sv '.protocols.hysteria2.hop_start' "d.get('protocols',{}).get('hysteria2',{}).get('hop_start')")"
he="$(sv '.protocols.hysteria2.hop_end' "d.get('protocols',{}).get('hysteria2',{}).get('hop_end')")"
if command -v iptables >/dev/null 2>&1; then
  if [[ -n "$hs" && -n "$he" ]]; then
    iptables -t nat -S PREROUTING 2>/dev/null | has "dport $hs:$he .*sing-box-daimon-hysteria2-hopping" \
      && ok "hy2 hopping rule present ($hs:$he)" || bad "hy2 hopping rule missing for $hs:$he"
  else
    ! iptables -t nat -S PREROUTING 2>/dev/null | has sing-box-daimon- && ok "no stale hopping rules" || bad "stale hopping rules present"
  fi
else
  skip "iptables not installed"
fi

# The menu must render without a traceback or python noise.
menu_out="$(printf '0\n' | timeout 60 bash "$SCRIPT" 2>&1 || true)"
grep -Eq 'Traceback|command not found|unbound variable' <<<"$menu_out" && bad "menu printed errors: $(grep -Em1 'Traceback|command not found|unbound variable' <<<"$menu_out")" || ok "menu renders cleanly"

if [[ "$mode" == standard ]] && ! $alpine; then
  check "subscription service active" systemctl is-active --quiet sing-box-sub
  sp="$(sv '.sub_port' "d.get('sub_port',2096)")"; sp="${sp:-2096}"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$sp/sub/$token")"
  [[ "$code" == 200 ]] && ok "IPv4 subscription 200" || bad "IPv4 subscription returned $code"
  if grep -q . /proc/net/if_inet6 2>/dev/null; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://[::1]:$sp/sub/$token/clash")"
    [[ "$code" == 200 ]] && ok "IPv6 subscription 200" || bad "IPv6 subscription returned $code"
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$sp/sub/definitely-wrong")"
  [[ "$code" == 404 ]] && ok "wrong token 404" || bad "wrong token returned $code"
  curl -s "http://127.0.0.1:$sp/sub/$token/clash" | has '^proxies:' && ok "clash YAML has proxies" || bad "clash YAML broken"
  mport="$(sv '.protocols.mixed.port' "d.get('protocols',{}).get('mixed',{}).get('port')")"
  if [[ -n "$mport" ]]; then
    mu="$(sv '.protocols.mixed.username' "d['protocols']['mixed'].get('username','daimon')")"
    mp="$(sv '.protocols.mixed.password' "d['protocols']['mixed'].get('password','daimon')")"
    out="$(curl -s --max-time 15 -x "socks5h://$mu:$mp@127.0.0.1:$mport" https://www.cloudflare.com/cdn-cgi/trace)"
    grep -q '^ip=' <<<"$out" && ok "SOCKS5 via Mixed egress $(grep '^ip=' <<<"$out")" || bad "SOCKS5 via Mixed failed"
  fi
  ssport="$(sv '.protocols.shadowsocks.port' "d.get('protocols',{}).get('shadowsocks',{}).get('port')")"
  if [[ -n "$ssport" ]] && command -v ufw >/dev/null && ufw status | has 'Status: active'; then
    ufw status | has "^$ssport/udp" && ok "UFW opens Shadowsocks UDP" || bad "UFW missing $ssport/udp"
  fi
  if command -v ufw >/dev/null && ufw status | has 'Status: active'; then
    missing="$(printf '0\n' | timeout 60 bash "$SCRIPT" 2>/dev/null | grep -o '缺失放行:.*' || true)"
    [[ -z "$missing" ]] && ok "UFW rules complete" || bad "UFW $missing"
  fi
fi

echo "== PASS=$PASS FAIL=$FAIL =="
(( FAIL == 0 ))
