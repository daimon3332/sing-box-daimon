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
STATE="$ROOT/state.json"
TMPDIR="$CASE_ROOT/tmp"
mkdir -p "$ROOT/bin" "$CONF" "$CERT" "$SUB" "$LOG" "$FIREWALL" "$TMPDIR"
json() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d$2)" "$1"; }
write_state() { printf '%s\n' "$1" >"$STATE"; invalidate_state_cache; }

# Target parsing: domain, IPv4 and bracketed IPv6 with a port; anything else is rejected.
[[ "$(split_reality_target www.cs.umd.edu:443)" == $'www.cs.umd.edu\t443' ]]
[[ "$(split_reality_target 127.0.0.1:8443)" == $'127.0.0.1\t8443' ]]
[[ "$(split_reality_target '[2001:db8::1]:443')" == $'2001:db8::1\t443' ]]
for bad in www.cs.umd.edu 'a b:443' example.com:0 example.com:70000 2001:db8::1:443 ':443' 'https://x.com:443'; do
  ! split_reality_target "$bad" >/dev/null 2>&1 || { printf 'accepted bad target: %s\n' "$bad" >&2; exit 1; }
done

# An empty target follows the SNI; a custom target is kept as entered.
write_state '{"token":"t","install_mode":"standard","protocols":{"vless_reality":{"enabled":true,"sni":"www.bing.com","target":""}}}'
[[ "$(reality_target_value)" == www.bing.com:443 ]]
write_state '{"token":"t","install_mode":"standard","protocols":{"vless_reality":{"enabled":true,"sni":"www.bing.com"}}}'
[[ "$(reality_target_value)" == www.bing.com:443 ]]
write_state '{"token":"t","install_mode":"standard","protocols":{"vless_reality":{"enabled":true,"sni":"my.domain","target":"127.0.0.1:8443"}}}'
[[ "$(reality_target_value)" == 127.0.0.1:8443 ]]
[[ -z "$(reality_target_state_value www.bing.com www.bing.com:443)" ]]
[[ "$(reality_target_state_value my.domain 127.0.0.1:8443)" == 127.0.0.1:8443 ]]

# The handshake uses the target host and port; the SNI list stays the SNI.
write_vless_config 40000 u my.domain k sid 127.0.0.1:8443
cfg="$CONF/11_vless_reality.json"
[[ "$(json "$cfg" "['inbounds'][0]['tls']['reality']['handshake']['server']")" == 127.0.0.1 ]]
[[ "$(json "$cfg" "['inbounds'][0]['tls']['reality']['handshake']['server_port']")" == 8443 ]]
[[ "$(json "$cfg" "['inbounds'][0]['tls']['server_name']")" == my.domain ]]
write_vless_config 40000 u www.apple.com k sid ""
[[ "$(json "$cfg" "['inbounds'][0]['tls']['reality']['handshake']['server']")" == www.apple.com ]]
[[ "$(json "$cfg" "['inbounds'][0]['tls']['reality']['handshake']['server_port']")" == 443 ]]
! write_vless_config 40000 u www.apple.com k sid "bad target" >/dev/null 2>&1 || exit 1

# One-click add uses the SNI typed at the prompt, and a random built-in one otherwise.
tcp_udp_used() { return 1; }
reality_keypair() { printf 'priv\npub\n'; }
write_state '{"token":"t","install_mode":"standard","sub_tls":false,"protocols":{}}'
ONE_CLICK_REALITY_SNI=www.cs.umd.edu ONE_CLICK_REALITY_TARGET=127.0.0.1:8443 add_missing_protocols
invalidate_state_cache
[[ "$(proto_value vless_reality sni)" == www.cs.umd.edu ]]
[[ "$(proto_value vless_reality target "")" == 127.0.0.1:8443 ]]
write_state '{"token":"t","install_mode":"standard","sub_tls":false,"protocols":{}}'
ONE_CLICK_REALITY_SNI="" ONE_CLICK_REALITY_TARGET="" add_missing_protocols
invalidate_state_cache
[[ " ${SNI_OPTIONS[*]} " == *" $(proto_value vless_reality sni) "* ]]
[[ -z "$(proto_value vless_reality target "")" ]]

[[ "$(printf '\n' | ask_reality_target my.domain)" == my.domain:443 ]]
[[ "$(printf 'bad\n127.0.0.1:8443\n' | ask_reality_target my.domain 2>/dev/null)" == 127.0.0.1:8443 ]]

# A target that fails the TLS 1.3/h2 check needs an explicit yes.
reality_target_usable() { return 1; }
! printf '\n' | confirm_reality_target a.com a.com:443 >/dev/null 2>&1 || exit 1
printf 'y\n' | confirm_reality_target a.com a.com:443 >/dev/null 2>&1

# Finder: dataset validation, candidate generation, CDN filters and ranking (offline).
[[ "$(reality_finder --selftest)" == REALITY_FINDER_SELFTEST=PASS ]]
python3 - "$TMPDIR/ds.json" <<'PY'
import json, sys
json.dump([{"alpha_two_code": "JP", "domains": ["u-tokyo.ac.jp"]}] * 1200, open(sys.argv[1], "w"))
PY
[[ "$(reality_finder --validate "$TMPDIR/ds.json")" == 1200 ]]
printf '[]' >"$TMPDIR/bad.json"
! reality_finder --validate "$TMPDIR/bad.json" >/dev/null 2>&1 || exit 1
out="$(reality_finder --validate "$TMPDIR/missing.json" 2>&1 || true)"
[[ "$out" == *"invalid dataset"* && "$out" != *Traceback* ]]
# The cache directory is created on demand.
reality_finder --country ZZ --cache "$TMPDIR/new/dir/u.json" --max-age 100000 2>/dev/null || true
! reality_finder --country JPN --cache "$TMPDIR/ds.json" >/dev/null 2>&1 || exit 1

# SNI chooser for manual and one-click add: Enter = random, 2 = scan, 3 = custom.
reality_target_usable() { return 0; }
reality_scan_available() { return 0; }
detect_country_code() { printf JP; }
public_ipv4() { printf 203.0.113.1; }
reality_finder() {
  [[ " $* " == *" --country JP "* ]] || return 1
  printf 'www.do-johodai.ac.jp\t198.51.100.1\t3.6\t51.4\t396982\tGOOGLE-CLOUD\t云托管\n'
  printf 'www.example.ac.jp\t198.51.100.2\t4.0\t60.0\t2907\tSINET\t\n'
}
pair="$(printf '\n' | choose_reality_sni 2>/dev/null)"
[[ " ${SNI_OPTIONS[*]} " == *" ${pair%%$'\t'*} "* && -z "${pair#*$'\t'}" ]]
pair="$(printf '2\n\n2\n' | choose_reality_sni 2>/dev/null)"
[[ "$pair" == $'www.example.ac.jp\t' ]]
pair="$(printf '3\nnot a domain\nmy.domain\n127.0.0.1:8443\n' | choose_reality_sni 2>/dev/null)"
[[ "$pair" == $'my.domain\t127.0.0.1:8443' ]]
pair="$(printf '3\nwww.cs.jhu.edu\n\n' | choose_reality_sni 2>/dev/null)"
[[ "$pair" == $'www.cs.jhu.edu\t' ]]
! printf '0\n' | choose_reality_sni >/dev/null 2>&1 || exit 1
reality_scan_available() { return 1; }
out="$(printf '2\n1\n' | choose_reality_sni 2>&1 >/dev/null)"
! grep -Fq '2. 扫描' <<<"$out" || exit 1
grep -Fq '不支持扫描' <<<"$out"
reality_scan_available() { return 0; }

# Menu: results are listed and the chosen site becomes SNI with an SNI:443 target.
require_core_installed() { :; }
detect_country_code() { printf JP; }
public_ipv4() { printf 203.0.113.1; }
restart_if_running() { :; }
show_protocol_details() { :; }
apply_state_change() { shift; "$@"; }
reality_finder() {
  [[ " $* " == *" --country JP "* ]] || return 1
  printf 'www.do-johodai.ac.jp\t198.51.100.1\t3.6\t51.4\t396982\tGOOGLE-CLOUD\t云托管\n'
  printf 'www.example.ac.jp\t198.51.100.2\t4.0\t60.0\t2907\tSINET\t\n'
}
write_state '{"token":"t","install_mode":"standard","protocols":{"vless_reality":{"enabled":true,"sni":"www.bing.com","target":"1.1.1.1:443"}}}'
out="$(printf '\n2\ny\n' | find_reality_target_menu 2>&1)"
grep -Fq 'www.do-johodai.ac.jp' <<<"$out"
grep -Fq '云托管' <<<"$out"
invalidate_state_cache
[[ "$(proto_value vless_reality sni)" == www.example.ac.jp ]]
[[ "$(reality_target_value)" == www.example.ac.jp:443 ]]

# Hidden where Python is not available.
lite_mode() { return 0; }
main_menu_item_hidden 16
! find_reality_target_menu </dev/null >/dev/null 2>&1 || exit 1

printf 'REALITY_TARGET_TEST=PASS\n'
