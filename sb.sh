#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/etc/sing-box"
SCRIPT_VERSION="1.3.0"
SCRIPT_URL="https://raw.githubusercontent.com/daimon3332/sing-box-daimon/main/sb.sh"
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
SERVICE="/etc/systemd/system/sing-box.service"
SUB_SERVICE="/etc/systemd/system/sing-box-sub.service"
NGINX_SUB_NAME="sing-box-daimon-sub"
NGINX_SUB_CONF="/etc/nginx/sites-available/$NGINX_SUB_NAME"
NGINX_SUB_LINK="/etc/nginx/sites-enabled/$NGINX_SUB_NAME"
SNI_OPTIONS=("www.bing.com" "www.amazon.com" "www.apple.com")

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
DIM='\033[2m'
NC='\033[0m'

info() { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*"; }
fail() { printf "${RED}%s${NC}\n" "$*"; }
title() { printf "${BLUE}%s${NC}\n" "$*"; }

color_status() {
  local value="$1"
  case "$value" in
    已运行|已是最新|正常|已配置|active|自签证书) printf "${GREEN}%s${NC}" "$value" ;;
    未运行|未安装|未开启|未配置|检测中|未知|无IPV4|无IPV6|未添加|TLS关闭) printf "${YELLOW}%s${NC}" "$value" ;;
    发现新版本:*|缺失*) printf "${YELLOW}%s${NC}" "$value" ;;
    *) printf "%s" "$value" ;;
  esac
}

clear_screen() {
  [[ -t 1 && -n "${TERM:-}" ]] && clear || true
}

safe_read() {
  stty erase '^?' 2>/dev/null || true
  if [[ -t 0 ]]; then
    read -r -e -p "$1" "$2"
  else
    read -r -p "$1" "$2"
  fi
}

pause() {
  local _
  safe_read "按回车继续..." _
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

need_root() {
  if ! is_root; then
    fail "请使用 root 权限执行。"
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

rand_hex() {
  openssl rand -hex "${1:-16}"
}

rand_b64() {
  openssl rand -base64 "${1:-18}" | tr -d '\n'
}

rand_token() {
  openssl rand -hex 16
}

rand_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif has_cmd uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  fi
}

url_encode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""), end="")
PY
}

b64() {
  base64 | tr -d '\n'
}

b64_url() {
  base64 | tr '+/' '-_' | tr -d '=\n'
}

ask_text() {
  local prompt="$1" default="${2:-}" value
  safe_read "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

ask_yes_no() {
  local prompt="$1" default="${2:-n}" value
  if [[ "$default" =~ ^[Yy]$ ]]; then
    safe_read "$prompt [Y/n]: " value
    value="${value:-y}"
  else
    safe_read "$prompt [y/N]: " value
    value="${value:-n}"
  fi
  [[ "$value" =~ ^[Yy]$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_port_range() {
  [[ "$1" =~ ^([0-9]+)[:-]([0-9]+)$ ]] || return 1
  local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
  valid_port "$start" && valid_port "$end" && (( start <= end ))
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_token() {
  [[ "$1" =~ ^[A-Za-z0-9]+$ ]]
}

valid_ip_address() {
  local address="$1" version="$2"
  python3 - "$address" "$version" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try:
  address = ipaddress.ip_address(sys.argv[1])
except ValueError:
  raise SystemExit(1)
raise SystemExit(0 if address.version == int(sys.argv[2]) else 1)
PY
}

ensure_dirs() {
  mkdir -p "$ROOT/bin" "$CONF" "$CERT" "$SUB" "$LOG" "$FIREWALL"
}

ensure_state() {
  ensure_dirs
  if [[ ! -s "$STATE" ]]; then
    python3 - "$STATE" <<'PY'
import json, secrets, sys
state = {
  "token": secrets.token_hex(16),
  "sub_port": 2096,
  "sub_domain": "",
  "sub_tls": False,
  "protocols": {}
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
  json.dump(state, f, indent=2, ensure_ascii=False)
  f.write("\n")
PY
  fi
  python3 - "$STATE" <<'PY' >/dev/null 2>&1 || true
import json, re, secrets, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
if not re.fullmatch(r"[A-Za-z0-9]+", str(data.get("token", ""))):
  data["token"] = secrets.token_hex(16)
with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
PY
}

has_protocols() {
  [[ -s "$STATE" ]] || return 1
  python3 - "$STATE" <<'PY'
import json, sys
try:
  data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
  raise SystemExit(1)
raise SystemExit(0 if any(v.get("enabled") for v in data.get("protocols", {}).values()) else 1)
PY
}

state_value() {
  local key="$1" default="${2:-}"
  [[ -s "$STATE" ]] || { printf '%s' "$default"; return; }
  python3 - "$STATE" "$key" "$default" <<'PY'
import json, sys
try:
  data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
  print(sys.argv[3], end="")
  raise SystemExit
cur = data
for part in sys.argv[2].split("."):
  if isinstance(cur, dict) and part in cur:
    cur = cur[part]
  else:
    print(sys.argv[3], end="")
    raise SystemExit
if isinstance(cur, bool):
  print(str(cur).lower(), end="")
else:
  print(cur if cur is not None else sys.argv[3], end="")
PY
}

proto_value() {
  local proto="$1" key="$2" default="${3:-}"
  state_value "protocols.$proto.$key" "$default"
}

set_state_value() {
  local key="$1" value="$2"
  ensure_state
  python3 - "$STATE" "$key" "$value" <<'PY'
import json, sys
path, key, value = sys.argv[1], sys.argv[2].split("."), sys.argv[3]
data = json.load(open(path, encoding="utf-8"))
cur = data
for part in key[:-1]:
  cur = cur.setdefault(part, {})
if key[-1] in {"sub_port"} and value.isdigit():
  cur[key[-1]] = int(value)
elif value in {"true", "false"}:
  cur[key[-1]] = value == "true"
else:
  cur[key[-1]] = value
with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
PY
}

fetch_latest_script() {
  local url="${1:-$SCRIPT_URL}"
  curl -fsSL --max-time 8 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "${url}?t=$(date +%s)" 2>/dev/null \
    || curl -fsSL --max-time 8 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$url" 2>/dev/null
}

refresh_version_cache() {
  local latest now
  latest="$(fetch_latest_script | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -n1 || true)"
  now="$(date +%s)"
  ensure_state
  python3 - "$STATE" "$latest" "$now" <<'PY' >/dev/null 2>&1 || true
import json, sys
path, latest, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
  data = json.load(open(path, encoding="utf-8"))
except Exception:
  raise SystemExit
version = data.setdefault("version", {})
if latest:
  version["latest"] = latest
version["checked"] = now
with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
PY
}

refresh_version_cache_async() {
  ( refresh_version_cache ) >/dev/null 2>&1 &
}

version_status() {
  local latest checked now age status
  latest="$(state_value version.latest "")"
  checked="$(state_value version.checked 0)"
  now="$(date +%s)"
  [[ "$checked" =~ ^[0-9]+$ ]] || checked=0
  age=$((now - checked))
  if (( age > 21600 )); then
    refresh_version_cache_async
  fi
  if [[ -z "$latest" ]]; then
    status="检测中"
  elif [[ "$latest" == "$SCRIPT_VERSION" || "$(printf '%s\n%s\n' "$latest" "$SCRIPT_VERSION" | sort -V | tail -n1)" == "$SCRIPT_VERSION" ]]; then
    status="已是最新"
  else
    status="发现新版本:$latest"
  fi
  printf "${CYAN}脚本版本:${NC}${GREEN}%s${NC}  ${CYAN}最新状态:${NC}%b" "$SCRIPT_VERSION" "$(color_status "$status")"
}

set_protocol() {
  local proto="$1"
  shift
  ensure_state
  python3 - "$STATE" "$proto" "$@" <<'PY'
import json, sys
path, proto, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
data = json.load(open(path, encoding="utf-8"))
item = data.setdefault("protocols", {}).setdefault(proto, {})
item["enabled"] = True
for pair in pairs:
  key, value = pair.split("=", 1)
  if key.endswith("port") or key in {"alter_id"}:
    item[key] = int(value)
  elif value in {"true", "false"}:
    item[key] = value == "true"
  else:
    item[key] = value
with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
PY
}

delete_protocol_state() {
  local proto="$1"
  [[ -s "$STATE" ]] || return 0
  python3 - "$STATE" "$proto" <<'PY'
import json, sys
path, proto = sys.argv[1], sys.argv[2]
data = json.load(open(path, encoding="utf-8"))
data.setdefault("protocols", {}).pop(proto, None)
with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
PY
}

hopping_comment() {
  printf 'sing-box-daimon-%s-hopping' "$1"
}

delete_hopping_rules() {
  local proto="$1" comment
  comment="$(hopping_comment "$proto")"
  while iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--comment $comment" >/dev/null; do
    iptables -t nat -S PREROUTING | grep -F -- "--comment $comment" | head -n1 | sed 's/^-A /-D /' | xargs -r iptables -t nat 2>/dev/null || break
  done
  while ip6tables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--comment $comment" >/dev/null; do
    ip6tables -t nat -S PREROUTING | grep -F -- "--comment $comment" | head -n1 | sed 's/^-A /-D /' | xargs -r ip6tables -t nat 2>/dev/null || break
  done
}

apply_hopping_rules() {
  local proto="$1" start="$2" end="$3" target="$4" comment
  [[ -n "$start" && -n "$end" ]] || return 0
  comment="$(hopping_comment "$proto")"
  delete_hopping_rules "$proto"
  iptables -t nat -A PREROUTING -p udp --dport "$start:$end" -m comment --comment "$comment" -j REDIRECT --to-ports "$target" 2>/dev/null || true
  ip6tables -t nat -A PREROUTING -p udp --dport "$start:$end" -m comment --comment "$comment" -j REDIRECT --to-ports "$target" 2>/dev/null || true
}

save_firewall_rules() {
  if has_cmd netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif has_cmd iptables-save && [[ -d /etc/iptables ]]; then
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    has_cmd ip6tables-save && ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
  fi
}

ufw_active() {
  has_cmd ufw && ufw status 2>/dev/null | awk 'NR==1{print tolower($0)}' | grep -Eq 'status:[[:space:]]+active$|状态.*激活'
}

ufw_allow_rule() {
  local rule="$1"
  [[ -n "$rule" ]] || return 0
  ufw allow "$rule" >/dev/null 2>&1 || warn "防火墙放行失败: $rule"
}

ufw_delete_rule() {
  local rule="$1" i
  [[ -n "$rule" ]] || return 0
  for i in {1..20}; do
    ufw --force delete allow "$rule" >/dev/null 2>&1 || break
  done
}

protocol_ufw_rules() {
  local proto="$1" port hop_start hop_end
  [[ "$(proto_value "$proto" enabled false)" == "true" ]] || return 0
  port="$(proto_value "$proto" port "")"
  case "$proto" in
    mixed)
      [[ -n "$port" ]] && printf '%s/tcp\n%s/udp\n' "$port" "$port"
      ;;
    hysteria2|tuic)
      [[ -n "$port" ]] && printf '%s/udp\n' "$port"
      ;;
    *)
      [[ -n "$port" ]] && printf '%s/tcp\n' "$port"
      ;;
  esac
  case "$proto" in
    hysteria2)
      hop_start="$(proto_value "$proto" hop_start "")"
      hop_end="$(proto_value "$proto" hop_end "")"
      [[ -n "$hop_start" && -n "$hop_end" ]] && printf '%s:%s/udp\n' "$hop_start" "$hop_end"
      ;;
  esac
  return 0
}

required_ufw_rules() {
  local sub_port
  if [[ -f "$SUB_SERVICE" || -x "$BIN" || -f "$SUB_SERVER" ]]; then
    sub_port="$(state_value sub_port 2096)"
    [[ -n "$sub_port" ]] && printf '%s/tcp\n' "$sub_port"
  fi
  if [[ -n "$(state_value sub_domain "")" && "$(state_value sub_tls false)" == "true" ]]; then
    printf '80/tcp\n443/tcp\n'
  fi
  protocol_ufw_rules mixed
  protocol_ufw_rules vless_reality
  protocol_ufw_rules vmess_ws
  protocol_ufw_rules hysteria2
  protocol_ufw_rules tuic
  protocol_ufw_rules anytls
  protocol_ufw_rules trojan
  protocol_ufw_rules shadowsocks
  protocol_ufw_rules vmess_tcp
  protocol_ufw_rules vmess_http
}

delete_protocol_ufw_rules() {
  local proto="$1"
  ufw_active || return 0
  protocol_ufw_rules "$proto" | awk 'NF && !seen[$0]++' | while read -r rule; do
    ufw_delete_rule "$rule"
  done
}

managed_ufw_rules() {
  [[ -s "$UFW_RULES" ]] && awk 'NF && !seen[$0]++' "$UFW_RULES"
}

rule_in_list() {
  local needle="$1" item
  shift || true
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

delete_all_ufw_rules() {
  ufw_active || return 0
  { managed_ufw_rules; required_ufw_rules; } | awk 'NF && !seen[$0]++' | while read -r rule; do
    ufw_delete_rule "$rule"
  done
  rm -f "$UFW_RULES"
}

ufw_rule_open() {
  local rule="$1"
  ufw status 2>/dev/null | awk -v r="$rule" '
    $1 == r || $1 == r"/tcp" || $1 == r"/udp" { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

ufw_missing_rules() {
  ufw_active || return 0
  required_ufw_rules | awk 'NF && !seen[$0]++' | while read -r rule; do
    ufw_rule_open "$rule" || printf '%s\n' "$rule"
  done
}

join_ufw_rules() {
  awk 'NF { printf "%s%s", sep, $0; sep = "、" }'
}

ufw_status_text() {
  local missing
  if ! has_cmd ufw; then
    printf "${CYAN}UFW状态:${NC}%b" "$(color_status 未安装)"
  elif ! ufw_active; then
    printf "${CYAN}UFW状态:${NC}%b" "$(color_status 未开启)"
  else
    missing="$(ufw_missing_rules | join_ufw_rules)"
    if [[ -n "$missing" ]]; then
      printf "${CYAN}UFW状态:${NC}${GREEN}已开启${NC}  ${CYAN}缺失放行:${NC}${YELLOW}%s${NC}" "$missing"
    else
      printf "${CYAN}UFW状态:${NC}${GREEN}已开启${NC}  ${CYAN}端口规则:${NC}${GREEN}正常${NC}"
    fi
  fi
}

sync_ufw_ports() {
  local desired=() managed=() rule
  ufw_active || return 0
  ensure_dirs
  mapfile -t desired < <(required_ufw_rules | awk 'NF && !seen[$0]++')
  mapfile -t managed < <(managed_ufw_rules)
  for rule in "${managed[@]}"; do
    rule_in_list "$rule" "${desired[@]}" || ufw_delete_rule "$rule"
  done
  for rule in "${desired[@]}"; do
    ufw_allow_rule "$rule"
  done
  if ((${#desired[@]} > 0)); then
    printf '%s\n' "${desired[@]}" >"$UFW_RULES"
  else
    : >"$UFW_RULES"
  fi
}

HTTPS_UFW_BOOTSTRAP=()

prepare_https_ufw_for_acme() {
  local rule
  HTTPS_UFW_BOOTSTRAP=()
  ufw_active || return 0
  for rule in 80/tcp 443/tcp; do
    if ! ufw_rule_open "$rule"; then
      ufw_allow_rule "$rule"
      HTTPS_UFW_BOOTSTRAP+=("$rule")
    fi
  done
}

rollback_https_ufw_for_acme() {
  local rule
  ufw_active || return 0
  for rule in "${HTTPS_UFW_BOOTSTRAP[@]:-}"; do
    ufw_delete_rule "$rule"
  done
  HTTPS_UFW_BOOTSTRAP=()
}

allow_missing_ufw_ports() {
  local rules=() rule failed=0 joined
  if ! has_cmd ufw; then
    warn "UFW未安装，无需放行。"
    return 0
  fi
  if ! ufw_active; then
    warn "UFW未开启，无需放行。"
    return 0
  fi
  mapfile -t rules < <(ufw_missing_rules)
  if ((${#rules[@]} == 0)); then
    info "没有缺失的防火墙端口。"
    return 0
  fi
  joined="$(printf '%s\n' "${rules[@]}" | join_ufw_rules)"
  for rule in "${rules[@]}"; do
    if ufw allow "$rule" >/dev/null 2>&1; then
      info "已放行: $rule"
    else
      warn "防火墙放行失败: $rule"
      failed=1
    fi
  done
  ((failed == 0)) && info "已放行所有缺失端口: $joined"
  return "$failed"
}

ask_hopping() {
  local proto="$1" current_start="${2:-}" current_end="${3:-}" range start end default_yn=n
  [[ -n "$current_start" && -n "$current_end" ]] && default_yn=y
  ask_yes_no "是否开启 ${proto} 跳跃端口？" "$default_yn" || { printf '\t\t'; return; }
  while true; do
    safe_read "请输入跳跃端口范围，格式 48000:50000${current_start:+ [$current_start:$current_end]}: " range
    range="${range:-${current_start:+$current_start:$current_end}}"
    if valid_port_range "$range"; then
      range="${range/-/:}"
      start="${range%%:*}"
      end="${range##*:}"
      printf '%s\t%s' "$start" "$end"
      return
    fi
    warn "端口范围格式错误。"
  done
}

tcp_udp_used() {
  local port="$1"
  ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && return 0
  ss -H -lun "sport = :$port" 2>/dev/null | grep -q . && return 0
  return 1
}

config_port_used() {
  local port="$1"
  [[ -d "$CONF" ]] || return 1
  python3 - "$CONF" "$port" <<'PY'
import json, pathlib, sys
root, wanted = pathlib.Path(sys.argv[1]), int(sys.argv[2])
keys = {"listen_port", "server_port", "local_port"}
def walk(obj):
  if isinstance(obj, dict):
    for k, v in obj.items():
      if k in keys and v == wanted:
        return True
      if walk(v):
        return True
  if isinstance(obj, list):
    return any(walk(x) for x in obj)
  return False
for file in root.glob("*.json"):
  try:
    if walk(json.load(open(file, encoding="utf-8"))):
      raise SystemExit(0)
  except json.JSONDecodeError:
    pass
raise SystemExit(1)
PY
}

state_port_used() {
  local port="$1"
  [[ -s "$STATE" ]] || return 1
  python3 - "$STATE" "$port" <<'PY'
import json, sys
try:
  data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
  raise SystemExit(1)
wanted = int(sys.argv[2])
for item in data.get("protocols", {}).values():
  if item.get("port") == wanted:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

port_used() {
  local port="$1" exclude="${2:-}"
  [[ -n "$exclude" && "$port" == "$exclude" ]] && return 1
  tcp_udp_used "$port" || config_port_used "$port" || state_port_used "$port"
}

next_free_port() {
  local port="$1" exclude="${2:-}"
  while port_used "$port" "$exclude"; do
    port=$((port + 1))
  done
  printf '%s' "$port"
}

random_high_port() {
  printf '%s' $((20000 + ((RANDOM * 2 + RANDOM) % 40000)))
}

random_free_port() {
  local exclude="${1:-}" port i
  for i in {1..100}; do
    port="$(random_high_port)"
    if ! port_used "$port" "$exclude"; then
      printf '%s' "$port"
      return
    fi
  done
  next_free_port 20000 "$exclude"
}

ask_port() {
  local name="$1" default="$2" exclude="${3:-}" port input
  port="$(next_free_port "$default" "$exclude")"
  while true; do
    safe_read "$name 端口 [$port]: " input
    input="${input:-$port}"
    if ! valid_port "$input"; then
      warn "端口范围必须是 1-65535。"
    elif port_used "$input" "$exclude"; then
      warn "端口 $input 已占用，请重新输入。"
    else
      printf '%s' "$input"
      return
    fi
  done
}

protocol_exists() {
  [[ "$(proto_value "$1" enabled false)" == "true" ]]
}

ask_menu() {
  local prompt="$1" max="$2" input
  while true; do
    safe_read "$prompt" input
    [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 0 && input <= max )) && { printf '%s' "$input"; return; }
    warn "请输入 0-$max 的数字。"
  done
}

menu_line() {
  printf "${BLUE}%2s.${NC} %s\n" "$1" "$2"
}

pick_sni() {
  local current="${1:-}" choice custom
  printf "1. %s\n2. %s\n3. %s\n4. 自定义\n" "${SNI_OPTIONS[@]}" >&2
  choice="$(ask_menu "请选择 SNI [1-4]: " 4)"
  case "$choice" in
    1) printf '%s' "${SNI_OPTIONS[0]}" ;;
    2) printf '%s' "${SNI_OPTIONS[1]}" ;;
    3) printf '%s' "${SNI_OPTIONS[2]}" ;;
    4)
      while true; do
        safe_read "请输入 SNI [${current:-www.bing.com}]: " custom
        custom="${custom:-${current:-www.bing.com}}"
        valid_domain "$custom" && { printf '%s' "$custom"; return; }
        warn "SNI 请输入有效域名。"
      done
      ;;
    *) printf '%s' "${SNI_OPTIONS[0]}" ;;
  esac
}

random_sni() {
  printf '%s' "${SNI_OPTIONS[$((RANDOM % ${#SNI_OPTIONS[@]}))]}"
}

cert_names() {
  printf '%s\n' "${SNI_OPTIONS[@]}"
  [[ -s "$STATE" ]] && python3 - "$STATE" <<'PY' 2>/dev/null || true
import json, sys
try:
  data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
  raise SystemExit
for item in data.get("protocols", {}).values():
  sni = item.get("sni")
  if sni:
    print(sni)
PY
}

ensure_cert() {
  local names san primary ext missing=0
  ensure_dirs
  mapfile -t names < <(cert_names | awk 'NF && !seen[$0]++')
  primary="${names[0]:-${SNI_OPTIONS[0]}}"
  san="$(printf '%s\n' "${names[@]}" | awk 'NF{printf "%sDNS:%s", sep, $0; sep=","}')"
  if [[ -s "$CERT/self.crt" && -s "$CERT/self.key" ]]; then
    ext="$(openssl x509 -noout -ext subjectAltName -in "$CERT/self.crt" 2>/dev/null || true)"
    for name in "${names[@]}"; do
      grep -q "DNS:$name" <<<"$ext" || { missing=1; break; }
    done
    (( missing == 0 )) && return 0
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT/self.key" \
    -out "$CERT/self.crt" \
    -days 3650 \
    -subj "/CN=$primary" \
    -addext "subjectAltName=$san" >/dev/null 2>&1
}

cert_pin_sha256() {
  ensure_cert
  openssl x509 -noout -fingerprint -sha256 -in "$CERT/self.crt" |
    awk -F= '{print tolower($2)}' |
    tr -d ':'
}

write_base_configs() {
  ensure_dirs
  cat >"$CONF/00_log.json" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true,
    "output": "$LOG/sing-box.log"
  }
}
EOF
  cat >"$CONF/01_outbounds.json" <<'EOF'
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
  cat >"$CONF/03_route.json" <<'EOF'
{
  "route": {
    "rules": [],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
}

write_mixed_config() {
  local port="$1" username="$2" password="$3"
  cat >"$CONF/10_mixed.json" <<EOF
{
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "username": "$username",
          "password": "$password"
        }
      ]
    }
  ]
}
EOF
}

write_vless_config() {
  local port="$1" uuid="$2" sni="$3" private_key="$4" short_id="$5"
  cat >"$CONF/11_vless_reality.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "daimon",
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$sni",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [
            "$short_id"
          ]
        }
      }
    }
  ]
}
EOF
}

write_vmess_config() {
  local port="$1" uuid="$2" tls_enabled="$3"
  local tls_block=""
  if [[ "$tls_enabled" == "true" ]]; then
    ensure_cert
    tls_block=',
      "tls": {
        "enabled": true,
        "certificate_path": "'"$CERT"'/self.crt",
        "key_path": "'"$CERT"'/self.key"
      }'
  fi
  cat >"$CONF/12_vmess_ws.json" <<EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "daimon",
          "uuid": "$uuid",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess"
      }$tls_block
    }
  ]
}
EOF
}

write_hysteria2_config() {
  local port="$1" password="$2"
  ensure_cert
  cat >"$CONF/13_hysteria2.json" <<EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "daimon",
          "password": "$password"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "$CERT/self.crt",
        "key_path": "$CERT/self.key"
      }
    }
  ]
}
EOF
}

write_tuic_config() {
  local port="$1" uuid="$2" password="$3"
  ensure_cert
  cat >"$CONF/14_tuic.json" <<EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "daimon",
          "uuid": "$uuid",
          "password": "$password"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "$CERT/self.crt",
        "key_path": "$CERT/self.key"
      }
    }
  ]
}
EOF
}

write_anytls_config() {
  local port="$1" password="$2"
  ensure_cert
  cat >"$CONF/15_anytls.json" <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "daimon",
          "password": "$password"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT/self.crt",
        "key_path": "$CERT/self.key"
      }
    }
  ]
}
EOF
}

write_trojan_config() {
  local port="$1" password="$2"
  ensure_cert
  cat >"$CONF/16_trojan.json" <<EOF
{
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "daimon",
          "password": "$password"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT/self.crt",
        "key_path": "$CERT/self.key"
      }
    }
  ]
}
EOF
}

write_shadowsocks_config() {
  local port="$1" password="$2" method="$3"
  cat >"$CONF/17_shadowsocks.json" <<EOF
{
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-in",
      "listen": "::",
      "listen_port": $port,
      "method": "$method",
      "password": "$password"
    }
  ]
}
EOF
}

write_vmess_tcp_config() {
  local port="$1" uuid="$2"
  cat >"$CONF/18_vmess_tcp.json" <<EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-tcp-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "daimon",
          "uuid": "$uuid",
          "alterId": 0
        }
      ]
    }
  ]
}
EOF
}

write_vmess_http_config() {
  local port="$1" uuid="$2" path="$3" host="$4"
  cat >"$CONF/19_vmess_http.json" <<EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-http-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "daimon",
          "uuid": "$uuid",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "http",
        "host": [
          "$host"
        ],
        "path": "$path"
      }
    }
  ]
}
EOF
}

rebuild_configs() {
  ensure_state
  write_base_configs
  rm -f "$CONF"/{10..29}_*.json
  if [[ "$(proto_value mixed enabled false)" == "true" ]]; then
    write_mixed_config "$(proto_value mixed port)" "$(proto_value mixed username daimon)" "$(proto_value mixed password daimon)"
  fi
  if [[ "$(proto_value vless_reality enabled false)" == "true" ]]; then
    write_vless_config "$(proto_value vless_reality port)" "$(proto_value vless_reality uuid)" "$(proto_value vless_reality sni)" "$(proto_value vless_reality private_key)" "$(proto_value vless_reality short_id)"
  fi
  if [[ "$(proto_value vmess_ws enabled false)" == "true" ]]; then
    write_vmess_config "$(proto_value vmess_ws port)" "$(proto_value vmess_ws uuid)" "$(proto_value vmess_ws tls false)"
  fi
  if [[ "$(proto_value hysteria2 enabled false)" == "true" ]]; then
    write_hysteria2_config "$(proto_value hysteria2 port)" "$(proto_value hysteria2 password)"
  fi
  if [[ "$(proto_value tuic enabled false)" == "true" ]]; then
    write_tuic_config "$(proto_value tuic port)" "$(proto_value tuic uuid)" "$(proto_value tuic password)"
  fi
  if [[ "$(proto_value anytls enabled false)" == "true" ]]; then
    write_anytls_config "$(proto_value anytls port)" "$(proto_value anytls password)"
  fi
  if [[ "$(proto_value trojan enabled false)" == "true" ]]; then
    write_trojan_config "$(proto_value trojan port)" "$(proto_value trojan password)"
  fi
  if [[ "$(proto_value shadowsocks enabled false)" == "true" ]]; then
    write_shadowsocks_config "$(proto_value shadowsocks port)" "$(proto_value shadowsocks password)" "$(proto_value shadowsocks method aes-128-gcm)"
  fi
  if [[ "$(proto_value vmess_tcp enabled false)" == "true" ]]; then
    write_vmess_tcp_config "$(proto_value vmess_tcp port)" "$(proto_value vmess_tcp uuid)"
  fi
  if [[ "$(proto_value vmess_http enabled false)" == "true" ]]; then
    write_vmess_http_config "$(proto_value vmess_http port)" "$(proto_value vmess_http uuid)" "$(proto_value vmess_http path /vmess-http)" "$(proto_value vmess_http host "${SNI_OPTIONS[0]}")"
  fi
  if [[ "$(proto_value hysteria2 enabled false)" == "true" ]]; then
    apply_hopping_rules hysteria2 "$(proto_value hysteria2 hop_start "")" "$(proto_value hysteria2 hop_end "")" "$(proto_value hysteria2 port)"
  else
    delete_hopping_rules hysteria2
  fi
  delete_hopping_rules tuic
  sync_ufw_ports
  save_firewall_rules
  generate_subscription
}

public_ipv4() {
  local ip
  ip="$(curl -4fs --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  valid_ip_address "$ip" 4 && printf '%s' "$ip" || true
}

public_ipv6() {
  local ip
  ip="$(curl -6fs --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  valid_ip_address "$ip" 6 && printf '%s' "$ip" || true
}

PUBLIC_IPS_DETECTED=false
PUBLIC_IPS_CHECKED=0
DETECTED_PUBLIC_IPV4=""
DETECTED_PUBLIC_IPV6=""
SELECTED_IP_VERSION=""
PROTOCOL_HOST=""
PROTOCOL_URL_HOST=""

detect_public_ips() {
  local force="${1:-false}" now
  now="$(date +%s)"
  if [[ "$force" != "true" && "$PUBLIC_IPS_DETECTED" == "true" && "$PUBLIC_IPS_CHECKED" =~ ^[0-9]+$ ]] && (( now - PUBLIC_IPS_CHECKED <= 30 )); then
    [[ -n "$DETECTED_PUBLIC_IPV4" || -n "$DETECTED_PUBLIC_IPV6" ]]
    return
  fi
  DETECTED_PUBLIC_IPV4="$(public_ipv4)"
  DETECTED_PUBLIC_IPV6="$(public_ipv6)"
  PUBLIC_IPS_DETECTED=true
  PUBLIC_IPS_CHECKED="$now"
  [[ -n "$DETECTED_PUBLIC_IPV4" || -n "$DETECTED_PUBLIC_IPV6" ]]
}

choose_node_ip_version() {
  local label="$1" choice
  SELECTED_IP_VERSION=""
  if ! detect_public_ips true; then
    fail "未检测到可用的公网 IPv4 或 IPv6，无法生成节点地址。" >&2
    return 1
  fi
  if [[ -n "$DETECTED_PUBLIC_IPV4" && -n "$DETECTED_PUBLIC_IPV6" ]]; then
    printf "请选择 %s 节点 IP 类型：\n1. IPv4  %s\n2. IPv6  %s\n" "$label" "$DETECTED_PUBLIC_IPV4" "$DETECTED_PUBLIC_IPV6" >&2
    while true; do
      safe_read "请选择 [1-2]: " choice
      case "$choice" in
        1) SELECTED_IP_VERSION=ipv4; return 0 ;;
        2) SELECTED_IP_VERSION=ipv6; return 0 ;;
        *) warn "请输入 1-2 的数字。" >&2 ;;
      esac
    done
  elif [[ -n "$DETECTED_PUBLIC_IPV4" ]]; then
    SELECTED_IP_VERSION=ipv4
    info "$label 自动使用 IPv4：$DETECTED_PUBLIC_IPV4" >&2
  else
    SELECTED_IP_VERSION=ipv6
    info "$label 自动使用 IPv6：$DETECTED_PUBLIC_IPV6" >&2
  fi
}

select_protocol_hosts() {
  local proto="$1" version
  detect_public_ips || {
    fail "未检测到可用的公网 IPv4 或 IPv6，无法生成节点地址。" >&2
    return 1
  }
  version="$(proto_value "$proto" ip_version auto)"
  case "$version" in
    ipv4)
      [[ -n "$DETECTED_PUBLIC_IPV4" ]] || {
        fail "$proto 已选择 IPv4，但当前未检测到公网 IPv4。" >&2
        return 1
      }
      PROTOCOL_HOST="$DETECTED_PUBLIC_IPV4"
      ;;
    ipv6)
      [[ -n "$DETECTED_PUBLIC_IPV6" ]] || {
        fail "$proto 已选择 IPv6，但当前未检测到公网 IPv6。" >&2
        return 1
      }
      PROTOCOL_HOST="$DETECTED_PUBLIC_IPV6"
      ;;
    *)
      PROTOCOL_HOST="${DETECTED_PUBLIC_IPV4:-$DETECTED_PUBLIC_IPV6}"
      ;;
  esac
  if [[ "$PROTOCOL_HOST" == *:* ]]; then
    PROTOCOL_URL_HOST="[$PROTOCOL_HOST]"
  else
    PROTOCOL_URL_HOST="$PROTOCOL_HOST"
  fi
}

validate_protocol_hosts() {
  local proto
  for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls trojan shadowsocks vmess_tcp vmess_http; do
    if protocol_exists "$proto"; then
      select_protocol_hosts "$proto" || return 1
    fi
  done
  return 0
}

proto_ip_label() {
  case "$(proto_value "$1" ip_version auto)" in
    ipv4) printf 'IPv4' ;;
    ipv6) printf 'IPv6' ;;
    *) printf '自动' ;;
  esac
}

server_host() {
  local ip
  ip="$(public_ipv4)"
  [[ -n "$ip" ]] || ip="$(public_ipv6)"
  printf '%s' "${ip:-未知地址}"
}

server_url_host() {
  local host
  host="$(server_host)"
  [[ "$host" == *:* && "$host" != \[*\] ]] && printf '[%s]' "$host" || printf '%s' "$host"
}

sub_http_link() {
  local kind="${1:-}" host token port base
  host="$(server_url_host)"
  token="$(state_value token)"
  port="$(state_value sub_port 2096)"
  base="$(printf 'http://%s:%s/sub/%s' "$host" "$port" "$token")"
  [[ -n "$kind" ]] && printf '%s/%s' "$base" "$kind" || printf '%s' "$base"
}

sub_https_link() {
  local kind="${1:-}" domain token base
  domain="$(state_value sub_domain "")"
  token="$(state_value token)"
  [[ -n "$domain" && "$(state_value sub_tls false)" == "true" ]] || return 1
  base="$(printf 'https://%s/sub/%s' "$domain" "$token")"
  [[ -n "$kind" ]] && printf '%s/%s' "$base" "$kind" || printf '%s' "$base"
}

sub_link() {
  sub_https_link "${1:-}" 2>/dev/null || sub_http_link "${1:-}"
}

show_subscription_links() {
  printf "${CYAN}HTTP/IP订阅链接(v2rayN默认):${NC}\n${MAGENTA}%s${NC}\n${CYAN}HTTP/IP Clash/Mihomo订阅链接:${NC}\n${MAGENTA}%s${NC}\n" "$(sub_http_link)" "$(sub_http_link clash)"
  if sub_https_link >/dev/null 2>&1; then
    printf "${CYAN}HTTPS域名订阅链接(v2rayN默认):${NC}\n${MAGENTA}%s${NC}\n${CYAN}HTTPS域名 Clash/Mihomo订阅链接:${NC}\n${MAGENTA}%s${NC}\n" "$(sub_https_link)" "$(sub_https_link clash)"
  fi
}

protocol_link_rows() {
  local host url_host
  if [[ "$(proto_value vless_reality enabled false)" == "true" ]]; then
    local port uuid sni public_key short_id
    select_protocol_hosts vless_reality || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    port="$(proto_value vless_reality port)"
    uuid="$(proto_value vless_reality uuid)"
    sni="$(proto_value vless_reality sni)"
    public_key="$(proto_value vless_reality public_key)"
    short_id="$(proto_value vless_reality short_id)"
    printf 'Vless-reality\tvless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#Vless-reality\n' "$uuid" "$url_host" "$port" "$sni" "$public_key" "$short_id"
  fi
  if [[ "$(proto_value vmess_ws enabled false)" == "true" ]]; then
    local port uuid tls vmess
    select_protocol_hosts vmess_ws || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    port="$(proto_value vmess_ws port)"
    uuid="$(proto_value vmess_ws uuid)"
    tls="$(proto_value vmess_ws tls false)"
    vmess="$(python3 - "$host" "$port" "$uuid" "$tls" <<'PY'
import base64, json, sys
host, port, uuid, tls = sys.argv[1:]
data = {"v":"2","ps":"Vmess-ws","add":host,"port":port,"id":uuid,"aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"/vmess","tls":"tls" if tls == "true" else ""}
print(base64.b64encode(json.dumps(data, separators=(",", ":")).encode()).decode())
PY
)"
    printf 'Vmess-ws\tvmess://%s\n' "$vmess"
  fi
  if [[ "$(proto_value hysteria2 enabled false)" == "true" ]]; then
    local hy_password hy_sni hy_port hy_hop_start hy_hop_end hy_mport
    select_protocol_hosts hysteria2 || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    hy_password="$(url_encode "$(proto_value hysteria2 password)")"
    hy_sni="$(proto_value hysteria2 sni "${SNI_OPTIONS[0]}")"
    hy_port="$(proto_value hysteria2 port)"
    hy_hop_start="$(proto_value hysteria2 hop_start "")"
    hy_hop_end="$(proto_value hysteria2 hop_end "")"
    [[ -n "$hy_hop_start" && -n "$hy_hop_end" ]] && hy_mport="&mport=$hy_hop_start-$hy_hop_end" || hy_mport=""
    printf 'Hysteria-2\thysteria2://%s@%s:%s?security=tls&alpn=h3&sni=%s&insecure=1&allowInsecure=1&allow_insecure=1&hop_interval=30s%s#Hysteria-2\n' "$hy_password" "$url_host" "$hy_port" "$hy_sni" "$hy_mport"
  fi
  if [[ "$(proto_value tuic enabled false)" == "true" ]]; then
    local tuic_auth tuic_sni
    select_protocol_hosts tuic || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    tuic_auth="$(python3 - "$(proto_value tuic uuid)" "$(proto_value tuic password)" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(f"{sys.argv[1]}:{sys.argv[2]}", safe=":"), end="")
PY
)"
    tuic_sni="$(proto_value tuic sni "${SNI_OPTIONS[0]}")"
    printf 'Tuic-v5\ttuic://%s@%s:%s?security=tls&sni=%s&alpn=h3&insecure=1&allowInsecure=1&allow_insecure=1&udp_relay_mode=native&congestion_control=bbr#Tuic-v5\n' "$tuic_auth" "$url_host" "$(proto_value tuic port)" "$tuic_sni"
  fi
  if [[ "$(proto_value anytls enabled false)" == "true" ]]; then
    local any_sni any_port any_password
    select_protocol_hosts anytls || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    any_sni="$(proto_value anytls sni "${SNI_OPTIONS[0]}")"
    any_port="$(proto_value anytls port)"
    any_password="$(url_encode "$(proto_value anytls password)")"
    printf 'Anytls\tanytls://%s@%s:%s?security=tls&sni=%s&insecure=1&allowInsecure=1&allow_insecure=1&fp=chrome#Anytls\n' "$any_password" "$url_host" "$any_port" "$any_sni"
  fi
  if [[ "$(proto_value trojan enabled false)" == "true" ]]; then
    local trojan_password trojan_sni
    select_protocol_hosts trojan || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    trojan_password="$(url_encode "$(proto_value trojan password)")"
    trojan_sni="$(proto_value trojan sni "${SNI_OPTIONS[0]}")"
    printf 'Trojan\ttrojan://%s@%s:%s?security=tls&sni=%s&insecure=1&allowInsecure=1&allow_insecure=1&type=tcp#Trojan\n' "$trojan_password" "$url_host" "$(proto_value trojan port)" "$trojan_sni"
  fi
  if [[ "$(proto_value shadowsocks enabled false)" == "true" ]]; then
    local ss_userinfo
    select_protocol_hosts shadowsocks || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    ss_userinfo="$(python3 - "$(proto_value shadowsocks method aes-128-gcm)" "$(proto_value shadowsocks password)" <<'PY'
import base64, sys
print(base64.urlsafe_b64encode(f"{sys.argv[1]}:{sys.argv[2]}".encode()).decode().rstrip("="), end="")
PY
)"
    printf 'Shadowsocks\tss://%s@%s:%s#Shadowsocks\n' "$ss_userinfo" "$url_host" "$(proto_value shadowsocks port)"
  fi
  if [[ "$(proto_value vmess_tcp enabled false)" == "true" ]]; then
    local vmess_tcp
    select_protocol_hosts vmess_tcp || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    vmess_tcp="$(python3 - "$host" "$(proto_value vmess_tcp port)" "$(proto_value vmess_tcp uuid)" <<'PY'
import base64, json, sys
host, port, uuid = sys.argv[1:]
data = {"v":"2","ps":"Vmess-tcp","add":host,"port":port,"id":uuid,"aid":"0","scy":"auto","net":"tcp","type":"none","host":"","path":"","tls":""}
print(base64.b64encode(json.dumps(data, separators=(",", ":")).encode()).decode())
PY
)"
    printf 'Vmess-tcp\tvmess://%s\n' "$vmess_tcp"
  fi
  if [[ "$(proto_value vmess_http enabled false)" == "true" ]]; then
    local vmess_http
    select_protocol_hosts vmess_http || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    vmess_http="$(python3 - "$host" "$(proto_value vmess_http port)" "$(proto_value vmess_http uuid)" "$(proto_value vmess_http host "${SNI_OPTIONS[0]}")" "$(proto_value vmess_http path /vmess-http)" <<'PY'
import base64, json, sys
host, port, uuid, http_host, path = sys.argv[1:]
data = {"v":"2","ps":"Vmess-http","add":host,"port":port,"id":uuid,"aid":"0","scy":"auto","net":"http","type":"none","host":http_host,"path":path,"tls":""}
print(base64.b64encode(json.dumps(data, separators=(",", ":")).encode()).decode())
PY
)"
    printf 'Vmess-http\tvmess://%s\n' "$vmess_http"
  fi
  if [[ "$(proto_value mixed enabled false)" == "true" ]]; then
    local user pass auth
    select_protocol_hosts mixed || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    user="$(url_encode "$(proto_value mixed username daimon)")"
    pass="$(url_encode "$(proto_value mixed password daimon)")"
    auth="${user}:${pass}"
    printf 'Mixed-SOCKS5\tsocks5://%s@%s:%s#Mixed-SOCKS5\n' "$auth" "$url_host" "$(proto_value mixed port)"
  fi
}

generate_subscription() {
  ensure_state
  ensure_dirs
  local token raw v2rayn_raw sub_file ipv4 ipv6 pin
  detect_public_ips || {
    fail "未检测到可用的公网 IPv4 或 IPv6，无法生成订阅。"
    return 1
  }
  validate_protocol_hosts || return 1
  token="$(state_value token)"
  ipv4="$DETECTED_PUBLIC_IPV4"
  ipv6="$DETECTED_PUBLIC_IPV6"
  pin="$(cert_pin_sha256)"
  raw="$SUB/raw.txt"
  v2rayn_raw="$SUB/v2rayn_raw.txt"
  sub_file="$SUB/sub.txt"
  protocol_link_rows | cut -f2- >"$raw"
  python3 - "$STATE" "$SUB/clash.yaml" "$v2rayn_raw" "$ipv4" "$ipv6" "$pin" "$CERT/self.crt" <<'PY'
import base64, json, sys, urllib.parse

state_path, clash_path, v2rayn_path, ipv4, ipv6, pin, cert_path = sys.argv[1:8]
data = json.load(open(state_path, encoding="utf-8"))
protos = data.get("protocols", {})
try:
    cert = "".join(line.rstrip("\n") + "\r\n" for line in open(cert_path, encoding="utf-8"))
except Exception:
    cert = ""

def q(s):
    return json.dumps(str(s), ensure_ascii=False)

def u(s, safe=""):
    return urllib.parse.quote(str(s), safe=safe)

def b64(s):
    return base64.b64encode(s.encode()).decode()

def b64url_json(obj):
    raw = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

def uri_host(s):
    s = str(s)
    return f"[{s}]" if ":" in s and not s.startswith("[") else s

def enabled(name):
    return protos.get(name, {}).get("enabled") is True

def val(name, key, default=""):
    return protos.get(name, {}).get(key, default)

def host_for(name):
    version = val(name, "ip_version", "auto")
    if version == "ipv4":
        if not ipv4:
            raise ValueError(f"{name} selected IPv4 but no public IPv4 was detected")
        return ipv4
    if version == "ipv6":
        if not ipv6:
            raise ValueError(f"{name} selected IPv6 but no public IPv6 was detected")
        return ipv6
    return ipv4 or ipv6

proxies = []
names = []

def add(name, lines):
    names.append(name)
    proxies.append([f"  - name: {q(name)}"] + lines)

if enabled("vless_reality"):
    add("Vless-reality", [
        "    type: vless",
        f"    server: {q(host_for('vless_reality'))}",
        f"    port: {val('vless_reality', 'port')}",
        f"    uuid: {q(val('vless_reality', 'uuid'))}",
        "    network: tcp",
        "    udp: true",
        "    tls: true",
        "    flow: xtls-rprx-vision",
        f"    servername: {q(val('vless_reality', 'sni'))}",
        "    client-fingerprint: chrome",
        "    reality-opts:",
        f"      public-key: {q(val('vless_reality', 'public_key'))}",
        f"      short-id: {q(val('vless_reality', 'short_id'))}",
    ])

if enabled("vmess_ws"):
    add("Vmess-ws", [
        "    type: vmess",
        f"    server: {q(host_for('vmess_ws'))}",
        f"    port: {val('vmess_ws', 'port')}",
        f"    uuid: {q(val('vmess_ws', 'uuid'))}",
        "    alterId: 0",
        "    cipher: auto",
        "    udp: true",
        "    tls: " + ("true" if val("vmess_ws", "tls", False) is True else "false"),
        "    network: ws",
        "    ws-opts:",
        "      path: /vmess",
    ])

if enabled("hysteria2"):
    hs, he = val("hysteria2", "hop_start"), val("hysteria2", "hop_end")
    lines = [
        "    type: hysteria2",
        f"    server: {q(host_for('hysteria2'))}",
        f"    port: {val('hysteria2', 'port')}",
        f"    password: {q(val('hysteria2', 'password'))}",
        f"    sni: {q(val('hysteria2', 'sni', 'www.bing.com'))}",
        "    alpn:",
        "      - h3",
        "    skip-cert-verify: true",
        "    up: 200 Mbps",
        "    down: 1000 Mbps",
    ]
    if hs and he:
        lines.insert(4, f"    ports: {hs}-{he}")
        lines.insert(5, "    hop-interval: 30")
    add("Hysteria-2", lines)

if enabled("tuic"):
    add("Tuic-v5", [
        "    type: tuic",
        f"    server: {q(host_for('tuic'))}",
        f"    port: {val('tuic', 'port')}",
        f"    uuid: {q(val('tuic', 'uuid'))}",
        f"    password: {q(val('tuic', 'password'))}",
        "    alpn:",
        "      - h3",
        "    reduce-rtt: true",
        "    request-timeout: 8000",
        "    udp-relay-mode: native",
        "    congestion-controller: bbr",
        f"    sni: {q(val('tuic', 'sni', 'www.bing.com'))}",
        "    skip-cert-verify: true",
    ])

if enabled("anytls"):
    add("Anytls", [
        "    type: anytls",
        f"    server: {q(host_for('anytls'))}",
        f"    port: {val('anytls', 'port')}",
        f"    password: {q(val('anytls', 'password'))}",
        "    client-fingerprint: chrome",
        "    udp: true",
        "    idle-session-check-interval: 30",
        "    idle-session-timeout: 30",
        f"    sni: {q(val('anytls', 'sni', 'www.bing.com'))}",
        "    skip-cert-verify: true",
        f"    fingerprint: {q(pin)}",
    ])

if enabled("trojan"):
    add("Trojan", [
        "    type: trojan",
        f"    server: {q(host_for('trojan'))}",
        f"    port: {val('trojan', 'port')}",
        f"    password: {q(val('trojan', 'password'))}",
        f"    sni: {q(val('trojan', 'sni', 'www.bing.com'))}",
        "    skip-cert-verify: true",
        "    udp: true",
    ])

if enabled("shadowsocks"):
    add("Shadowsocks", [
        "    type: ss",
        f"    server: {q(host_for('shadowsocks'))}",
        f"    port: {val('shadowsocks', 'port')}",
        f"    cipher: {q(val('shadowsocks', 'method', 'aes-128-gcm'))}",
        f"    password: {q(val('shadowsocks', 'password'))}",
        "    udp: true",
    ])

if enabled("vmess_tcp"):
    add("Vmess-tcp", [
        "    type: vmess",
        f"    server: {q(host_for('vmess_tcp'))}",
        f"    port: {val('vmess_tcp', 'port')}",
        f"    uuid: {q(val('vmess_tcp', 'uuid'))}",
        "    alterId: 0",
        "    cipher: auto",
        "    udp: true",
        "    tls: false",
        "    network: tcp",
    ])

if enabled("vmess_http"):
    add("Vmess-http", [
        "    type: vmess",
        f"    server: {q(host_for('vmess_http'))}",
        f"    port: {val('vmess_http', 'port')}",
        f"    uuid: {q(val('vmess_http', 'uuid'))}",
        "    alterId: 0",
        "    cipher: auto",
        "    udp: true",
        "    tls: false",
        "    network: http",
        "    http-opts:",
        "      method: GET",
        "      path:",
        f"        - {q(val('vmess_http', 'path', '/vmess-http'))}",
        "      headers:",
        "        Host:",
        f"          - {q(val('vmess_http', 'host', 'www.bing.com'))}",
    ])

if enabled("mixed"):
    add("Mixed-SOCKS5", [
        "    type: socks5",
        f"    server: {q(host_for('mixed'))}",
        f"    port: {val('mixed', 'port')}",
        f"    username: {q(val('mixed', 'username', 'daimon'))}",
        f"    password: {q(val('mixed', 'password', 'daimon'))}",
        "    udp: true",
    ])

out = [
    "mixed-port: 7890",
    "allow-lan: false",
    "mode: rule",
    "log-level: info",
    "proxies:",
]
for p in proxies:
    out.extend(p)
out.extend([
    "proxy-groups:",
    "  - name: PROXY",
    "    type: select",
    "    proxies:",
])
if names:
    out.extend([f"      - {q(n)}" for n in names])
else:
    out.append("      - DIRECT")
out.extend([
    "rules:",
    "  - MATCH,PROXY",
    "",
])
open(clash_path, "w", encoding="utf-8").write("\n".join(out))

v2 = []
if enabled("vless_reality"):
    v2.append("vless://{}@{}:{}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={}&fp=chrome&pbk={}&sid={}&type=tcp#Vless-reality".format(
        u(val("vless_reality", "uuid")), uri_host(host_for("vless_reality")), val("vless_reality", "port"), u(val("vless_reality", "sni")),
        u(val("vless_reality", "public_key")), u(val("vless_reality", "short_id"))))
if enabled("vmess_ws"):
    vm = {"v":"2","ps":"Vmess-ws","add":host_for("vmess_ws"),"port":str(val("vmess_ws", "port")),"id":val("vmess_ws", "uuid"),"aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"/vmess","tls":"tls" if val("vmess_ws", "tls", False) is True else ""}
    v2.append("vmess://" + b64(json.dumps(vm, separators=(",", ":"), ensure_ascii=False)))
if enabled("hysteria2"):
    extra = {"UpMbps": 200, "DownMbps": 1000}
    hs, he = val("hysteria2", "hop_start"), val("hysteria2", "hop_end")
    if hs and he:
        extra["Ports"] = f"{hs}-{he}"
        extra["HopInterval"] = "30"
    item = {"ConfigType":7,"CoreType":24,"ConfigVersion":4,"Remarks":"Hysteria-2","Address":host_for("hysteria2"),"Port":val("hysteria2", "port"),"Password":val("hysteria2", "password"),"StreamSecurity":"tls","AllowInsecure":"true","Sni":val("hysteria2", "sni", "www.bing.com"),"Alpn":"h3","ProtoExtraObj":extra}
    v2.append("v2rayn://hysteria2/" + b64url_json(item))
if enabled("tuic"):
    item = {"ConfigType":8,"CoreType":24,"ConfigVersion":4,"Remarks":"Tuic-v5","Address":host_for("tuic"),"Port":val("tuic", "port"),"Username":val("tuic", "uuid"),"Password":val("tuic", "password"),"StreamSecurity":"tls","AllowInsecure":"true","Sni":val("tuic", "sni", "www.bing.com"),"Alpn":"h3","ProtoExtraObj":{"CongestionControl":"bbr"}}
    v2.append("v2rayn://tuic/" + b64url_json(item))
if enabled("anytls"):
    item = {"ConfigType":11,"CoreType":24,"ConfigVersion":4,"Remarks":"Anytls","Address":host_for("anytls"),"Port":val("anytls", "port"),"Password":val("anytls", "password"),"StreamSecurity":"tls","AllowInsecure":"false","Sni":val("anytls", "sni", "www.bing.com"),"Fingerprint":"chrome","Cert":cert}
    v2.append("v2rayn://anytls/" + b64url_json(item))
if enabled("trojan"):
    v2.append("trojan://{}@{}:{}?security=tls&sni={}&insecure=1&allowInsecure=1&allow_insecure=1&type=tcp#Trojan".format(
        u(val("trojan", "password")), uri_host(host_for("trojan")), val("trojan", "port"), u(val("trojan", "sni", "www.bing.com"))))
if enabled("shadowsocks"):
    userinfo = base64.urlsafe_b64encode(f"{val('shadowsocks', 'method', 'aes-128-gcm')}:{val('shadowsocks', 'password')}".encode()).decode().rstrip("=")
    v2.append("ss://{}@{}:{}#Shadowsocks".format(userinfo, uri_host(host_for("shadowsocks")), val("shadowsocks", "port")))
if enabled("vmess_tcp"):
    vm = {"v":"2","ps":"Vmess-tcp","add":host_for("vmess_tcp"),"port":str(val("vmess_tcp", "port")),"id":val("vmess_tcp", "uuid"),"aid":"0","scy":"auto","net":"tcp","type":"none","host":"","path":"","tls":""}
    v2.append("vmess://" + b64(json.dumps(vm, separators=(",", ":"), ensure_ascii=False)))
if enabled("vmess_http"):
    vm = {"v":"2","ps":"Vmess-http","add":host_for("vmess_http"),"port":str(val("vmess_http", "port")),"id":val("vmess_http", "uuid"),"aid":"0","scy":"auto","net":"http","type":"none","host":val("vmess_http", "host", "www.bing.com"),"path":val("vmess_http", "path", "/vmess-http"),"tls":""}
    v2.append("vmess://" + b64(json.dumps(vm, separators=(",", ":"), ensure_ascii=False)))
if enabled("mixed"):
    item = {"ConfigType":4,"CoreType":24,"ConfigVersion":4,"Remarks":"Mixed-SOCKS5","Address":host_for("mixed"),"Port":val("mixed", "port"),"Username":val("mixed", "username", "daimon"),"Password":val("mixed", "password", "daimon")}
    v2.append("v2rayn://socks/" + b64url_json(item))
open(v2rayn_path, "w", encoding="utf-8").write("\n".join(v2) + ("\n" if v2 else ""))
PY
  b64 <"$v2rayn_raw" >"$SUB/v2rayn.txt"
  cp "$SUB/v2rayn.txt" "$sub_file"
  cp "$sub_file" "$SUB/$token"
  cp "$SUB/v2rayn.txt" "$SUB/$token.v2rayn"
  cp "$SUB/clash.yaml" "$SUB/$token.clash"
  cp "$raw" "$SUB/$token.raw"
}

show_qr() {
  local text="$1"
  if has_cmd qrencode; then
    qrencode -t ANSIUTF8 "$text"
  else
    warn "未安装 qrencode，无法显示二维码。"
  fi
}

show_protocol_links() {
  local label link found=0
  while IFS=$'\t' read -r label link; do
    [[ -n "${link:-}" ]] || continue
    found=1
    title "【 $label 】"
    printf "${MAGENTA}%s${NC}\n" "$link"
    show_qr "$link"
    printf "\n"
  done < <(protocol_link_rows)
  (( found == 1 )) || printf "暂无协议链接。\n\n"
}

write_sub_server() {
  ensure_state
  cat >"$SUB_SERVER" <<EOF
#!/usr/bin/env python3
import http.server
import json
import pathlib
import socketserver
from urllib.parse import urlparse

ROOT = pathlib.Path("$ROOT")
STATE = ROOT / "state.json"
SUB = ROOT / "sub"

class Handler(http.server.BaseHTTPRequestHandler):
    def send_subscription(self, send_body=True):
        token = json.load(open(STATE, encoding="utf-8")).get("token", "")
        path = urlparse(self.path).path.strip("/")
        ua = self.headers.get("User-Agent", "").lower()
        default_file = "clash.yaml" if ("clash" in ua or "mihomo" in ua) else "sub.txt"
        default_type = "text/yaml; charset=utf-8" if default_file == "clash.yaml" else "text/plain; charset=utf-8"
        variants = {
            f"sub/{token}": (default_file, default_type),
            token: (default_file, default_type),
            f"sub/{token}/v2rayn": ("v2rayn.txt", "text/plain; charset=utf-8"),
            f"{token}/v2rayn": ("v2rayn.txt", "text/plain; charset=utf-8"),
            f"sub/{token}/clash": ("clash.yaml", "text/yaml; charset=utf-8"),
            f"{token}/clash": ("clash.yaml", "text/yaml; charset=utf-8"),
            f"sub/{token}/mihomo": ("clash.yaml", "text/yaml; charset=utf-8"),
            f"{token}/mihomo": ("clash.yaml", "text/yaml; charset=utf-8"),
            f"sub/{token}/raw": ("raw.txt", "text/plain; charset=utf-8"),
            f"{token}/raw": ("raw.txt", "text/plain; charset=utf-8"),
        }
        if path not in variants:
            self.send_response(404)
            self.end_headers()
            return
        file_name, content_type = variants[path]
        data = (SUB / file_name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if send_body:
            self.wfile.write(data)
    def do_GET(self):
        self.send_subscription(True)
    def do_HEAD(self):
        self.send_subscription(False)
    def log_message(self, *_):
        return

class ReuseTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

port = int(json.load(open(STATE, encoding="utf-8")).get("sub_port", 2096))
with ReuseTCPServer(("0.0.0.0", port), Handler) as httpd:
    httpd.serve_forever()
EOF
  chmod +x "$SUB_SERVER"
}

write_managed_script() {
  local src tmp
  src="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if [[ -r "$src" && "$src" != "$SCRIPT" ]] && head -n 3 "$src" 2>/dev/null | grep -q "bash"; then
    install -m 0755 "$src" "$SCRIPT"
  else
    tmp="$ROOT/sb.sh.tmp"
    curl -fsSL "$SCRIPT_URL" -o "$tmp"
    install -m 0755 "$tmp" "$SCRIPT"
    rm -f "$tmp"
  fi
}

write_services() {
  cat >"$SERVICE" <<EOF
[Unit]
Description=sing-box service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=$BIN run -C $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
  cat >"$SUB_SERVICE" <<EOF
[Unit]
Description=sing-box daimon subscription service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 $SUB_SERVER
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

restart_sub_service() {
  local port i
  systemctl restart sing-box-sub >/dev/null 2>&1 || return 1
  port="$(state_value sub_port 2096)"
  for i in {1..20}; do
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && return 0
    sleep 0.2
  done
  systemctl is-active --quiet sing-box-sub
}

install_dependencies() {
  if has_cmd apt-get; then
    apt-get update
    apt-get install -y curl tar gzip openssl python3 iproute2 ca-certificates qrencode
  elif has_cmd dnf; then
    dnf install -y curl tar gzip openssl python3 iproute ca-certificates qrencode
  elif has_cmd yum; then
    yum install -y curl tar gzip openssl python3 iproute ca-certificates qrencode
  else
    warn "未识别包管理器，请确保 curl、tar、gzip、openssl、python3、ss、qrencode 已安装。"
  fi
}

acme_bin() {
  printf '%s/.acme.sh/acme.sh' "${HOME:-/root}"
}

subscription_cert_dir() {
  local domain="$1"
  printf '/root/domain/%s' "$domain"
}

install_nginx_acme_deps() {
  if has_cmd apt-get; then
    apt-get update
    apt-get install -y curl socat lsof dnsutils openssl nginx cron ca-certificates
  elif has_cmd dnf; then
    dnf install -y curl socat lsof bind-utils openssl nginx cronie ca-certificates || true
  elif has_cmd yum; then
    yum install -y curl socat lsof bind-utils openssl nginx cronie ca-certificates || true
  else
    warn "未识别包管理器，请手动安装 nginx、curl、socat、lsof、openssl。"
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1 || true
  systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1 || true
}

ensure_acme() {
  local acme email
  acme="$(acme_bin)"
  email="${1:-admin@example.com}"
  if [[ ! -x "$acme" ]]; then
    info "正在安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email="$email"
  fi
  [[ -x "$acme" ]] || { fail "acme.sh 安装失败。"; return 1; }
  "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

setup_acme_cron() {
  local acme cron_line
  acme="$(acme_bin)"
  cron_line="0 3 * * * $acme --cron --home ${HOME:-/root}/.acme.sh >/dev/null 2>&1"
  (crontab -l 2>/dev/null | grep -v "$acme --cron" || true; printf '%s\n' "$cron_line") | crontab -
}

show_domain_dns() {
  local domain="$1"
  if has_cmd dig; then
    warn "DNS A 记录: $(dig +short "$domain" A | tr '\n' ' ')"
    warn "DNS AAAA记录: $(dig +short "$domain" AAAA | tr '\n' ' ')"
  fi
}

stop_http_services_for_acme() {
  NGINX_WAS_RUNNING=false
  if systemctl is-active --quiet nginx; then
    NGINX_WAS_RUNNING=true
    systemctl stop nginx
  fi
  systemctl stop apache2 >/dev/null 2>&1 || true
  systemctl stop httpd >/dev/null 2>&1 || true
  sleep 1
  if lsof -iTCP:80 -sTCP:LISTEN >/dev/null 2>&1; then
    fail "80 端口仍被占用，无法使用 standalone 模式申请证书。"
    return 1
  fi
}

restart_nginx_after_acme() {
  systemctl start nginx >/dev/null 2>&1 || true
}

subscription_cert_exists() {
  local domain="$1" dir
  dir="$(subscription_cert_dir "$domain")"
  [[ -s "$dir/fullchain.pem" && -s "$dir/privkey.pem" ]]
}

issue_subscription_cert() {
  local domain="$1" acme dir
  acme="$(acme_bin)"
  dir="$(subscription_cert_dir "$domain")"
  mkdir -p "$dir"
  show_domain_dns "$domain"
  if subscription_cert_exists "$domain"; then
    info "检测到已有证书，直接复用。"
    return 0
  fi
  stop_http_services_for_acme || { restart_nginx_after_acme; return 1; }
  if ! "$acme" --issue -d "$domain" --standalone --server letsencrypt --force; then
    restart_nginx_after_acme
    return 1
  fi
  if ! "$acme" --install-cert -d "$domain" \
    --fullchain-file "$dir/fullchain.pem" \
    --key-file "$dir/privkey.pem" \
    --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || true" \
    --force; then
    restart_nginx_after_acme
    return 1
  fi
  restart_nginx_after_acme
  setup_acme_cron
  subscription_cert_exists "$domain"
}

write_nginx_subscription_config() {
  local domain="$1" port="$2" dir
  dir="$(subscription_cert_dir "$domain")"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat >"$NGINX_SUB_CONF" <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate $dir/fullchain.pem;
    ssl_certificate_key $dir/privkey.pem;

    location /sub/ {
        proxy_pass http://127.0.0.1:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }

    location / {
        return 404;
    }
}
EOF
  ln -sf "$NGINX_SUB_CONF" "$NGINX_SUB_LINK"
  if nginx -t; then
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
  else
    rm -f "$NGINX_SUB_CONF" "$NGINX_SUB_LINK"
    return 1
  fi
}

remove_subscription_nginx_and_cert() {
  local domain="${1:-}" acme dir
  rm -f "$NGINX_SUB_CONF" "$NGINX_SUB_LINK"
  if [[ -n "$domain" ]]; then
    acme="$(acme_bin)"
    [[ -x "$acme" ]] && "$acme" --remove -d "$domain" >/dev/null 2>&1 || true
    dir="$(subscription_cert_dir "$domain")"
    [[ -d "$dir" ]] && rm -rf "$dir"
  fi
  if has_cmd nginx; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
}

configure_https_subscription_domain() {
  local domain="$1" port email old_domain
  valid_domain "$domain" || { fail "域名格式不正确。"; return 1; }
  port="$(state_value sub_port 2096)"
  email="admin@$domain"
  old_domain="$(state_value sub_domain "")"
  if [[ -n "$old_domain" && "$old_domain" != "$domain" ]]; then
    remove_subscription_nginx_and_cert "$old_domain"
    set_state_value sub_domain ""
    set_state_value sub_tls false
  fi
  install_nginx_acme_deps
  ensure_acme "$email" || return 1
  prepare_https_ufw_for_acme
  if ! issue_subscription_cert "$domain"; then
    fail "证书申请失败，已停止配置 HTTPS 订阅。"
    remove_subscription_nginx_and_cert "$domain"
    rollback_https_ufw_for_acme
    [[ -n "$old_domain" && "$old_domain" != "$domain" ]] || { set_state_value sub_domain ""; set_state_value sub_tls false; }
    return 1
  fi
  if ! write_nginx_subscription_config "$domain" "$port"; then
    fail "nginx 配置失败，已停止配置 HTTPS 订阅。"
    remove_subscription_nginx_and_cert "$domain"
    rollback_https_ufw_for_acme
    [[ -n "$old_domain" && "$old_domain" != "$domain" ]] || { set_state_value sub_domain ""; set_state_value sub_tls false; }
    return 1
  fi
  set_state_value sub_domain "$domain"
  set_state_value sub_tls true
  generate_subscription
  sync_ufw_ports
  HTTPS_UFW_BOOTSTRAP=()
  restart_sub_service || true
  info "HTTPS 订阅域名已配置: https://$domain/sub/$(state_value token)"
}

delete_https_subscription_domain() {
  local domain
  domain="$(state_value sub_domain "")"
  [[ -n "$domain" ]] || { warn "当前未设置 HTTPS 订阅域名。"; return 0; }
  remove_subscription_nginx_and_cert "$domain"
  set_state_value sub_domain ""
  set_state_value sub_tls false
  generate_subscription
  sync_ufw_ports
  restart_sub_service || true
  info "HTTPS 订阅域名配置已删除，HTTP/IP 订阅仍保留。"
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l) printf 'armv7' ;;
    *) fail "暂不支持架构：$(uname -m)"; return 1 ;;
  esac
}

download_core() {
  local arch url tmp file
  arch="$(arch_name)"
  tmp="$(mktemp -d)"
  url="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest |
    grep browser_download_url |
    grep "linux-$arch.tar.gz" |
    grep -v '\.asc' |
    head -n1 |
    cut -d '"' -f4)"
  [[ -n "$url" ]] || { fail "未找到 sing-box 下载地址。"; return 1; }
  curl -fL "$url" -o "$tmp/sing-box.tar.gz"
  tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"
  file="$(find "$tmp" -type f -name sing-box | head -n1)"
  [[ -n "$file" ]] || { fail "压缩包内未找到 sing-box。"; return 1; }
  install -m 0755 "$file" "$BIN"
  rm -rf "$tmp"
}

install_shortcuts() {
  write_managed_script
  ln -sf "$SCRIPT" /usr/local/bin/sb
  if [[ -e /usr/local/bin/sing-box && ! "$(readlink -f /usr/local/bin/sing-box 2>/dev/null || true)" == "$SCRIPT" ]]; then
    local yn
    warn "/usr/local/bin/sing-box 已存在，可能不是本脚本管理。"
    safe_read "是否覆盖为管理脚本快捷命令？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return 0
  fi
  ln -sf "$SCRIPT" /usr/local/bin/sing-box
}

reality_keypair() {
  if [[ -x "$BIN" ]]; then
    "$BIN" generate reality-keypair 2>/dev/null | awk -F': ' '/PrivateKey|PublicKey/{print $2}'
  fi
}

require_core_installed() {
  [[ -x "$BIN" ]] && return 0
  warn "尚未安装 sing-box 内核，请先执行 1. 一键安装 Sing-box。"
  return 1
}

add_mixed() {
  local port username password
  choose_node_ip_version "Mixed" || return 1
  port="$(ask_port "Mixed" 30000)"
  username="$(ask_text "Mixed 用户名" "daimon")"
  password="$(ask_text "Mixed 密码" "daimon")"
  set_protocol mixed "port=$port" "username=$username" "password=$password" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_vless_reality() {
  local port uuid sni short_id keys private_key public_key
  require_core_installed || return 1
  choose_node_ip_version "Vless-reality" || return 1
  port="$(ask_port "Vless-reality" "$(random_free_port)")"
  uuid="$(ask_text "Vless-reality UUID" "$(rand_uuid)")"
  sni="$(pick_sni "$(random_sni)")"
  short_id="$(rand_hex 8)"
  keys="$(reality_keypair || true)"
  private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
  public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  if [[ -z "$private_key" || -z "$public_key" ]]; then
    fail "Reality 密钥生成失败，请确认 sing-box 内核可用。"
    return 1
  fi
  set_protocol vless_reality "port=$port" "uuid=$uuid" "sni=$sni" "short_id=$short_id" "private_key=$private_key" "public_key=$public_key" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_vmess_ws() {
  local port uuid yn tls
  choose_node_ip_version "Vmess-ws" || return 1
  port="$(ask_port "Vmess-ws" "$(random_free_port)")"
  uuid="$(ask_text "Vmess-ws UUID" "$(rand_uuid)")"
  ask_yes_no "是否开启 VMess-WS TLS？" n && tls=true || tls=false
  set_protocol vmess_ws "port=$port" "uuid=$uuid" "tls=$tls" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_hysteria2() {
  local port password sni hop_start hop_end
  choose_node_ip_version "Hysteria-2" || return 1
  port="$(ask_port "Hysteria-2" "$(random_free_port)")"
  password="$(ask_text "Hysteria-2 密码" "$(rand_uuid)")"
  sni="$(pick_sni "$(random_sni)")"
  IFS=$'\t' read -r hop_start hop_end < <(ask_hopping "Hysteria-2")
  set_protocol hysteria2 "port=$port" "password=$password" "sni=$sni" "hop_start=$hop_start" "hop_end=$hop_end" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_tuic() {
  local port uuid password sni
  choose_node_ip_version "Tuic-v5" || return 1
  port="$(ask_port "Tuic-v5" "$(random_free_port)")"
  uuid="$(ask_text "Tuic-v5 UUID" "$(rand_uuid)")"
  password="$(ask_text "Tuic-v5 密码" "$uuid")"
  sni="$(pick_sni "$(random_sni)")"
  set_protocol tuic "port=$port" "uuid=$uuid" "password=$password" "sni=$sni" "hop_start=" "hop_end=" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_anytls() {
  local port password sni
  choose_node_ip_version "Anytls" || return 1
  port="$(ask_port "Anytls" "$(random_free_port)")"
  password="$(ask_text "Anytls 密码" "$(rand_uuid)")"
  sni="$(pick_sni "$(random_sni)")"
  set_protocol anytls "port=$port" "password=$password" "sni=$sni" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_trojan() {
  local port password sni
  choose_node_ip_version "Trojan" || return 1
  port="$(ask_port "Trojan" "$(random_free_port)")"
  password="$(ask_text "Trojan 密码" "$(rand_uuid)")"
  sni="$(pick_sni "$(random_sni)")"
  set_protocol trojan "port=$port" "password=$password" "sni=$sni" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_shadowsocks() {
  local port password method
  choose_node_ip_version "Shadowsocks" || return 1
  port="$(ask_port "Shadowsocks" "$(random_free_port)")"
  password="$(ask_text "Shadowsocks 密码" "$(rand_uuid)")"
  method="$(ask_text "Shadowsocks 加密方式" "aes-128-gcm")"
  set_protocol shadowsocks "port=$port" "password=$password" "method=$method" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_vmess_tcp() {
  local port uuid
  choose_node_ip_version "Vmess-tcp" || return 1
  port="$(ask_port "Vmess-tcp" "$(random_free_port)")"
  uuid="$(ask_text "Vmess-tcp UUID" "$(rand_uuid)")"
  set_protocol vmess_tcp "port=$port" "uuid=$uuid" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_vmess_http() {
  local port uuid host path
  choose_node_ip_version "Vmess-http" || return 1
  port="$(ask_port "Vmess-http" "$(random_free_port)")"
  uuid="$(ask_text "Vmess-http UUID" "$(rand_uuid)")"
  host="$(pick_sni "$(random_sni)")"
  path="$(ask_text "Vmess-http 路径" "/vmess-http")"
  [[ "$path" == /* ]] || path="/$path"
  set_protocol vmess_http "port=$port" "uuid=$uuid" "host=$host" "path=$path" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
}

add_all_protocols() {
  local proto needs_ip=false
  ensure_state
  require_core_installed || return 1
  for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls; do
    if ! protocol_exists "$proto"; then
      needs_ip=true
      break
    fi
  done
  [[ "$needs_ip" == "false" ]] || choose_node_ip_version "一键添加协议" || return 1
  [[ "$(proto_value mixed enabled false)" == "true" ]] || set_protocol mixed "port=$(next_free_port 30000)" "username=daimon" "password=daimon" "ip_version=$SELECTED_IP_VERSION"
  [[ "$(proto_value vless_reality enabled false)" == "true" ]] || {
    local keys private_key public_key
    keys="$(reality_keypair || true)"
    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
    [[ -n "$private_key" && -n "$public_key" ]] || { fail "Reality 密钥生成失败，请确认 sing-box 内核可用。"; return 1; }
    set_protocol vless_reality "port=$(random_free_port)" "uuid=$(rand_uuid)" "sni=$(random_sni)" "short_id=$(rand_hex 8)" "private_key=$private_key" "public_key=$public_key" "ip_version=$SELECTED_IP_VERSION"
  }
  [[ "$(proto_value vmess_ws enabled false)" == "true" ]] || set_protocol vmess_ws "port=$(random_free_port)" "uuid=$(rand_uuid)" "tls=false" "ip_version=$SELECTED_IP_VERSION"
  [[ "$(proto_value hysteria2 enabled false)" == "true" ]] || set_protocol hysteria2 "port=$(random_free_port)" "password=$(rand_uuid)" "sni=$(random_sni)" "hop_start=" "hop_end=" "ip_version=$SELECTED_IP_VERSION"
  if [[ "$(proto_value tuic enabled false)" != "true" ]]; then
    local tuic_uuid
    tuic_uuid="$(rand_uuid)"
    set_protocol tuic "port=$(random_free_port)" "uuid=$tuic_uuid" "password=$tuic_uuid" "sni=$(random_sni)" "hop_start=" "hop_end=" "ip_version=$SELECTED_IP_VERSION"
  fi
  [[ "$(proto_value anytls enabled false)" == "true" ]] || set_protocol anytls "port=$(random_free_port)" "password=$(rand_uuid)" "sni=$(random_sni)" "ip_version=$SELECTED_IP_VERSION"
  rebuild_configs
  info "一键协议已生成。"
  show_protocol_details
}

install_sing_box() {
  need_root
  install_dependencies
  ensure_dirs
  ensure_state
  download_core
  ensure_cert
  write_base_configs
  write_sub_server
  write_services
  install_shortcuts
  sync_ufw_ports
  systemctl enable sing-box sing-box-sub >/dev/null 2>&1 || true
  if systemctl restart sing-box sing-box-sub >/dev/null 2>&1 &&
    systemctl is-active --quiet sing-box &&
    systemctl is-active --quiet sing-box-sub; then
    info "安装完成，Sing-box 已启动。可继续添加协议。"
  else
    fail "安装完成，但 Sing-box 未能启动。请在运行管理中查看状态/日志。"
    systemctl status sing-box --no-pager 2>/dev/null || true
    return 1
  fi
}

uninstall_sing_box() {
  need_root
  local yn
  safe_read "确认删除所有协议并卸载 Sing-box？管理脚本会保留。[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || return 0
  systemctl disable --now sing-box sing-box-sub >/dev/null 2>&1 || true
  remove_subscription_nginx_and_cert "$(state_value sub_domain "")"
  delete_all_ufw_rules
  delete_hopping_rules hysteria2
  delete_hopping_rules tuic
  save_firewall_rules
  rm -f "$SERVICE" "$SUB_SERVICE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$ROOT/bin" "$CONF" "$CERT" "$SUB" "$LOG"
  rm -f "$STATE" "$SUB_SERVER"
  ensure_dirs
  info "Sing-box 和所有协议已卸载，管理脚本已保留。"
}

delete_script() {
  need_root
  local yn
  safe_read "确认删除脚本、所有协议和 Sing-box？此操作不可恢复。[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || return 0
  systemctl disable --now sing-box sing-box-sub >/dev/null 2>&1 || true
  remove_subscription_nginx_and_cert "$(state_value sub_domain "")"
  delete_all_ufw_rules
  delete_hopping_rules hysteria2
  delete_hopping_rules tuic
  save_firewall_rules
  rm -f "$SERVICE" "$SUB_SERVICE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  [[ "$(readlink -f /usr/local/bin/sb 2>/dev/null || true)" == "$SCRIPT" ]] && rm -f /usr/local/bin/sb
  [[ "$(readlink -f /usr/local/bin/sing-box 2>/dev/null || true)" == "$SCRIPT" ]] && rm -f /usr/local/bin/sing-box
  [[ "$ROOT" == "/etc/sing-box" ]] && rm -rf "$ROOT"
  info "脚本、Sing-box 和所有协议已删除。"
  exit 0
}

update_script() {
  need_root
  local tmp latest
  ensure_dirs
  tmp="$ROOT/sb.sh.update"
  info "正在下载最新脚本..."
  if ! fetch_latest_script >"$tmp"; then
    rm -f "$tmp"
    fail "脚本更新失败：下载失败。"
    return 1
  fi
  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    fail "脚本更新失败：新脚本语法检查未通过。"
    return 1
  fi
  latest="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n1)"
  install -m 0755 "$tmp" "$SCRIPT"
  rm -f "$tmp"
  write_sub_server
  write_services
  ln -sf "$SCRIPT" /usr/local/bin/sb
  ln -sf "$SCRIPT" /usr/local/bin/sing-box
  systemctl daemon-reload >/dev/null 2>&1 || true
  restart_sub_service || true
  refresh_version_cache >/dev/null 2>&1 || true
  info "脚本已更新：${SCRIPT_VERSION} -> ${latest:-未知}。正在重新载入新版脚本..."
  sleep 1
  exec "$SCRIPT"
}

systemd_unit_exists() {
  systemctl list-unit-files "$1" >/dev/null 2>&1 || systemctl status "$1" >/dev/null 2>&1
}

restart_if_running() {
  if systemd_unit_exists sing-box.service; then
    if has_protocols; then
      if [[ ! -x "$BIN" ]]; then
        warn "sing-box 内核不存在，未启动服务。"
      elif ! "$BIN" check -C "$CONF" >/dev/null 2>&1; then
        fail "sing-box 配置检查失败，未重启服务。"
        "$BIN" check -C "$CONF" || true
      else
        systemctl reset-failed sing-box >/dev/null 2>&1 || true
        if systemctl restart sing-box >/dev/null 2>&1 && systemctl is-active --quiet sing-box; then
          info "Sing-box 已应用新配置并运行。"
        else
          fail "Sing-box 重启失败，请查看运行管理日志。"
          systemctl status sing-box --no-pager 2>/dev/null || true
        fi
      fi
    else
      systemctl stop sing-box >/dev/null 2>&1 || true
      systemctl reset-failed sing-box >/dev/null 2>&1 || true
      info "未启用协议，Sing-box 已停止。"
    fi
  fi
  if systemd_unit_exists sing-box-sub.service; then
    systemctl reset-failed sing-box-sub >/dev/null 2>&1 || true
    restart_sub_service || warn "订阅服务重启失败。"
  fi
}

add_protocol_menu() {
  require_core_installed || return 0
  title "添加协议"
  printf "1. Mixed\n2. Vless-reality\n3. Vmess-ws\n4. Hysteria-2\n5. Tuic-v5\n6. Anytls\n7. Trojan\n8. Shadowsocks\n9. Vmess-tcp\n10. Vmess-http\n0. 返回\n"
  case "$(ask_menu "请选择: " 10)" in
    1) add_mixed ;;
    2) add_vless_reality ;;
    3) add_vmess_ws ;;
    4) add_hysteria2 ;;
    5) add_tuic ;;
    6) add_anytls ;;
    7) add_trojan ;;
    8) add_shadowsocks ;;
    9) add_vmess_tcp ;;
    10) add_vmess_http ;;
    0) return 1 ;;
  esac
  restart_if_running
  info "协议已添加。"
  show_protocol_details
  return 0
}

change_protocol_ip_version() {
  local proto="$1" label="$2"
  choose_node_ip_version "$label" || return 1
  set_protocol "$proto" "ip_version=$SELECTED_IP_VERSION"
}

change_protocol_config() {
  ensure_state
  require_core_installed || return 0
  title "更改协议配置"
  printf "1. Mixed\n2. Vless-reality\n3. Vmess-ws\n4. Hysteria-2\n5. Tuic-v5\n6. Anytls\n7. Trojan\n8. Shadowsocks\n9. Vmess-tcp\n10. Vmess-http\n0. 返回\n"
  local proto label choice field port value hop_start hop_end
  choice="$(ask_menu "请选择协议: " 10)"
  case "$choice" in
    1) proto=mixed; label=Mixed ;;
    2) proto=vless_reality; label=Vless-reality ;;
    3) proto=vmess_ws; label=Vmess-ws ;;
    4) proto=hysteria2; label=Hysteria-2 ;;
    5) proto=tuic; label=Tuic-v5 ;;
    6) proto=anytls; label=Anytls ;;
    7) proto=trojan; label=Trojan ;;
    8) proto=shadowsocks; label=Shadowsocks ;;
    9) proto=vmess_tcp; label=Vmess-tcp ;;
    10) proto=vmess_http; label=Vmess-http ;;
    0) return 1 ;;
  esac
  protocol_exists "$proto" || { warn "$label 尚未添加。"; return 0; }
  case "$proto" in
    mixed)
      printf "1. 修改端口\n2. 修改用户名\n3. 修改密码\n4. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)"
      case "$field" in
        1) port="$(ask_port "$label" "$(proto_value mixed port 30000)" "$(proto_value mixed port)")"; set_protocol mixed "port=$port" ;;
        2) value="$(ask_text "Mixed 用户名" "$(proto_value mixed username daimon)")"; set_protocol mixed "username=$value" ;;
        3) value="$(ask_text "Mixed 密码" "$(proto_value mixed password daimon)")"; set_protocol mixed "password=$value" ;;
        4) change_protocol_ip_version mixed "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    vless_reality)
      printf "1. 修改端口\n2. 修改 UUID\n3. 修改 SNI\n4. 重新生成 Reality 密钥\n5. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 5)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value vless_reality port)")" "$(proto_value vless_reality port)")"; set_protocol vless_reality "port=$port" ;;
        2) value="$(ask_text "Vless-reality UUID" "$(proto_value vless_reality uuid)")"; set_protocol vless_reality "uuid=$value" ;;
        3) value="$(pick_sni "$(proto_value vless_reality sni)")"; set_protocol vless_reality "sni=$value" ;;
        4)
          local keys private_key public_key
          keys="$(reality_keypair || true)"
          private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
          public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
          [[ -n "$private_key" && -n "$public_key" ]] || { fail "Reality 密钥生成失败。"; return 0; }
          set_protocol vless_reality "private_key=$private_key" "public_key=$public_key" "short_id=$(rand_hex 8)"
          ;;
        5) change_protocol_ip_version vless_reality "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    vmess_ws)
      printf "1. 修改端口\n2. 修改 UUID\n3. 开关 TLS\n4. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value vmess_ws port)")" "$(proto_value vmess_ws port)")"; set_protocol vmess_ws "port=$port" ;;
        2) value="$(ask_text "Vmess-ws UUID" "$(proto_value vmess_ws uuid)")"; set_protocol vmess_ws "uuid=$value" ;;
        3) ask_yes_no "是否开启 VMess-WS TLS？" "$([[ "$(proto_value vmess_ws tls false)" == "true" ]] && printf y || printf n)" && set_protocol vmess_ws "tls=true" || set_protocol vmess_ws "tls=false" ;;
        4) change_protocol_ip_version vmess_ws "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    hysteria2)
      printf "1. 修改端口\n2. 修改密码\n3. 修改 SNI\n4. 设置跳跃端口\n5. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 5)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value hysteria2 port)")" "$(proto_value hysteria2 port)")"; set_protocol hysteria2 "port=$port" ;;
        2) value="$(ask_text "Hysteria-2 密码" "$(proto_value hysteria2 password)")"; set_protocol hysteria2 "password=$value" ;;
        3) value="$(pick_sni "$(proto_value hysteria2 sni "${SNI_OPTIONS[0]}")")"; set_protocol hysteria2 "sni=$value" ;;
        4) IFS=$'\t' read -r hop_start hop_end < <(ask_hopping "$label" "$(proto_value hysteria2 hop_start "")" "$(proto_value hysteria2 hop_end "")"); set_protocol hysteria2 "hop_start=$hop_start" "hop_end=$hop_end" ;;
        5) change_protocol_ip_version hysteria2 "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    tuic)
      printf "1. 修改端口\n2. 修改 UUID\n3. 修改密码\n4. 修改 SNI\n5. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 5)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value tuic port)")" "$(proto_value tuic port)")"; set_protocol tuic "port=$port" ;;
        2) value="$(ask_text "Tuic-v5 UUID" "$(proto_value tuic uuid)")"; set_protocol tuic "uuid=$value" ;;
        3) value="$(ask_text "Tuic-v5 密码" "$(proto_value tuic password)")"; set_protocol tuic "password=$value" ;;
        4) value="$(pick_sni "$(proto_value tuic sni "${SNI_OPTIONS[0]}")")"; set_protocol tuic "sni=$value" ;;
        5) change_protocol_ip_version tuic "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    anytls)
      printf "1. 修改端口\n2. 修改密码\n3. 修改 SNI\n4. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value anytls port)")" "$(proto_value anytls port)")"; set_protocol anytls "port=$port" ;;
        2) value="$(ask_text "Anytls 密码" "$(proto_value anytls password)")"; set_protocol anytls "password=$value" ;;
        3) value="$(pick_sni "$(proto_value anytls sni "${SNI_OPTIONS[0]}")")"; set_protocol anytls "sni=$value" ;;
        4) change_protocol_ip_version anytls "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    trojan)
      printf "1. 修改端口\n2. 修改密码\n3. 修改 SNI\n4. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value trojan port)")" "$(proto_value trojan port)")"; set_protocol trojan "port=$port" ;;
        2) value="$(ask_text "Trojan 密码" "$(proto_value trojan password)")"; set_protocol trojan "password=$value" ;;
        3) value="$(pick_sni "$(proto_value trojan sni "${SNI_OPTIONS[0]}")")"; set_protocol trojan "sni=$value" ;;
        4) change_protocol_ip_version trojan "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    shadowsocks)
      printf "1. 修改端口\n2. 修改密码\n3. 修改加密方式\n4. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value shadowsocks port)")" "$(proto_value shadowsocks port)")"; set_protocol shadowsocks "port=$port" ;;
        2) value="$(ask_text "Shadowsocks 密码" "$(proto_value shadowsocks password)")"; set_protocol shadowsocks "password=$value" ;;
        3) value="$(ask_text "Shadowsocks 加密方式" "$(proto_value shadowsocks method aes-128-gcm)")"; set_protocol shadowsocks "method=$value" ;;
        4) change_protocol_ip_version shadowsocks "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    vmess_tcp)
      printf "1. 修改端口\n2. 修改 UUID\n3. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 3)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value vmess_tcp port)")" "$(proto_value vmess_tcp port)")"; set_protocol vmess_tcp "port=$port" ;;
        2) value="$(ask_text "Vmess-tcp UUID" "$(proto_value vmess_tcp uuid)")"; set_protocol vmess_tcp "uuid=$value" ;;
        3) change_protocol_ip_version vmess_tcp "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
    vmess_http)
      printf "1. 修改端口\n2. 修改 UUID\n3. 修改 Host\n4. 修改路径\n5. 修改节点 IP 类型\n0. 返回\n"
      field="$(ask_menu "请选择: " 5)"
      case "$field" in
        1) port="$(ask_port "$label" "$(random_free_port "$(proto_value vmess_http port)")" "$(proto_value vmess_http port)")"; set_protocol vmess_http "port=$port" ;;
        2) value="$(ask_text "Vmess-http UUID" "$(proto_value vmess_http uuid)")"; set_protocol vmess_http "uuid=$value" ;;
        3) value="$(pick_sni "$(proto_value vmess_http host "${SNI_OPTIONS[0]}")")"; set_protocol vmess_http "host=$value" ;;
        4) value="$(ask_text "Vmess-http 路径" "$(proto_value vmess_http path /vmess-http)")"; [[ "$value" == /* ]] || value="/$value"; set_protocol vmess_http "path=$value" ;;
        5) change_protocol_ip_version vmess_http "$label" || return 1 ;;
        0) return 1 ;;
      esac
      ;;
  esac
  rebuild_configs
  restart_if_running
  info "配置已更新。"
  show_protocol_details
  return 0
}

change_subscription_config() {
  ensure_state
  local choice old_port new_port old_token new_token input domain
  title "更改综合订阅配置"
  printf "当前订阅端口:%s\n当前订阅token:%s\n当前HTTPS订阅域名:%s\nHTTPS状态:%s\n\n" \
    "$(state_value sub_port 2096)" "$(state_value token)" "$(state_value sub_domain "未设置")" \
    "$([[ "$(state_value sub_tls false)" == "true" ]] && printf '已配置' || printf '未配置')"
  show_subscription_links
  printf "\n1. 修改综合订阅端口\n2. 指定或重新生成 token\n3. 设置/更改 HTTPS 订阅域名\n4. 删除 HTTPS 订阅域名配置\n0. 返回\n"
  choice="$(ask_menu "请选择: " 4)"
  case "$choice" in
    1)
      old_port="$(state_value sub_port 2096)"
      new_port="$(ask_port "综合订阅" "$old_port" "$old_port")"
      [[ "$new_port" == "$old_port" ]] && { info "订阅端口未变化。"; return 0; }
      ufw_active && ufw_delete_rule "$old_port"
      set_state_value sub_port "$new_port"
      write_sub_server
      generate_subscription
      sync_ufw_ports
      restart_sub_service || true
      if [[ -n "$(state_value sub_domain "")" && "$(state_value sub_tls false)" == "true" ]]; then
        write_nginx_subscription_config "$(state_value sub_domain)" "$new_port" || warn "HTTPS 订阅 nginx 反代端口同步失败，请重新配置 HTTPS 订阅域名。"
      fi
      info "综合订阅端口已更新为 $new_port。"
      ;;
    2)
      old_token="$(state_value token)"
      while true; do
        safe_read "请输入新 token，直接回车随机生成: " input
        new_token="${input:-$(rand_token)}"
        if valid_token "$new_token"; then
          break
        fi
        warn "token 只能包含字母和数字。"
      done
      rm -f "$SUB/$old_token" "$SUB/$old_token.v2rayn" "$SUB/$old_token.clash" "$SUB/$old_token.raw"
      set_state_value token "$new_token"
      generate_subscription
      restart_sub_service || true
      info "综合订阅 token 已更新。"
      ;;
    3)
      while true; do
        safe_read "请输入 HTTPS 订阅域名: " domain
        if [[ -n "$domain" ]] && valid_domain "$domain"; then
          break
        fi
        warn "域名不能为空，请输入有效域名。"
      done
      configure_https_subscription_domain "$domain" || return 1
      ;;
    4)
      ask_yes_no "确认删除 HTTPS 订阅域名配置、nginx 反代和该域名证书？" n || return 1
      delete_https_subscription_domain
      ;;
    0) return 1 ;;
  esac
  printf "\n当前订阅链接如下：\n"
  show_subscription_links
  printf "\n"
  return 0
}

delete_protocol_menu() {
  local input item proto yn protocols=() deleted=0
  title "删除协议"
  printf "1. Mixed\n2. Vless-reality\n3. Vmess-ws\n4. Hysteria-2\n5. Tuic-v5\n6. Anytls\n7. Trojan\n8. Shadowsocks\n9. Vmess-tcp\n10. Vmess-http\n11. 删除所有协议\n0. 返回\n"
  safe_read "请选择，可多选，如 1 3 5 或 1,3,5: " input
  input="${input//,/ }"
  [[ "$input" =~ (^|[[:space:]])0($|[[:space:]]) ]] && return 1
  if [[ "$input" =~ (^|[[:space:]])11($|[[:space:]]) ]]; then
    protocols=(mixed vless_reality vmess_ws hysteria2 tuic anytls trojan shadowsocks vmess_tcp vmess_http)
  else
    for item in $input; do
      case "$item" in
        1) proto=mixed ;;
        2) proto=vless_reality ;;
        3) proto=vmess_ws ;;
        4) proto=hysteria2 ;;
        5) proto=tuic ;;
        6) proto=anytls ;;
        7) proto=trojan ;;
        8) proto=shadowsocks ;;
        9) proto=vmess_tcp ;;
        10) proto=vmess_http ;;
        *) warn "无效选择: $item"; return 1 ;;
      esac
      [[ " ${protocols[*]} " == *" $proto "* ]] || protocols+=("$proto")
    done
  fi
  ((${#protocols[@]} > 0)) || return 1
  safe_read "确认删除选中的 ${#protocols[@]} 个协议？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || return 1
  for proto in "${protocols[@]}"; do
    if protocol_exists "$proto"; then
      delete_protocol_ufw_rules "$proto"
      delete_protocol_state "$proto"
      deleted=$((deleted + 1))
    fi
  done
  rebuild_configs
  restart_if_running
  info "协议已删除 $deleted 个。"
  return 0
}

os_name() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    printf '%s' "${PRETTY_NAME:-未知}"
  else
    printf '未知'
  fi
}

region_name() {
  local text
  text="$(curl -fs --max-time 5 https://myip.ipip.net 2>/dev/null || true)"
  [[ -n "$text" ]] && printf '%s' "$text" | sed 's/^[^：:]*[：:] *//;s/[[:space:]]*$//' || printf '未知'
}

sing_box_status() {
  if [[ ! -x "$BIN" && ! -f "$SERVICE" ]]; then
    printf '未安装'
  elif systemctl is-active --quiet sing-box 2>/dev/null; then
    printf '已运行'
  else
    printf '未运行'
  fi
}

show_status_header() {
  local os kernel arch virt bbr qdisc ipv4 ipv6 region active
  os="$(os_name)"
  kernel="$(uname -r)"
  arch="$(uname -m)"
  virt="$(systemd-detect-virt 2>/dev/null || printf '未知')"
  bbr="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知')"
  ipv4="$(public_ipv4)"
  ipv6="$(public_ipv6)"
  region="$(region_name)"
  active="$(sing_box_status)"
  printf "${CYAN}系统:${NC}%s  ${CYAN}内核:${NC}%s  ${CYAN}处理器:${NC}%s  ${CYAN}虚拟化:${NC}%s  ${CYAN}BBR算法:${NC}%s ${CYAN}队列算法:${NC}%s\n" "$os" "$kernel" "$arch" "$virt" "$bbr" "$qdisc"
  printf "%s\n" "$(version_status)"
  printf "${CYAN}本地IPV4地址:${NC}${MAGENTA}%s${NC}   ${CYAN}本地IPV6地址:${NC}%b\n" "${ipv4:-无IPV4}" "$(color_status "${ipv6:-无IPV6}")"
  printf "${CYAN}服务器地区:${NC}${MAGENTA}%s${NC}\n" "${region:-未知}"
  printf "%s\n" "$(ufw_status_text)"
  printf "${CYAN}Sing-box状态:${NC}%b\n\n" "$(color_status "$active")"
}

show_protocols() {
  title "Sing-box节点关键信息、已分流域名情况如下："
  if ! has_protocols; then
    if [[ -s "$STATE" ]]; then
      printf "暂无协议。\n\n"
      show_subscription_links
      printf "\n"
    else
      printf "暂无协议。\n\n综合订阅链接:\n未生成\n\n"
    fi
    return
  fi
  [[ "$(proto_value vless_reality enabled false)" == "true" ]] &&
    printf "${YELLOW}【 Vless-reality 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}Reality域名证书伪装地址:${NC}${MAGENTA}%s${NC}\n" "$(proto_value vless_reality port)" "$(proto_ip_label vless_reality)" "$(proto_value vless_reality sni)"
  [[ "$(proto_value vmess_ws enabled false)" == "true" ]] &&
    printf "${YELLOW}【   Vmess-ws    】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}%b\n" "$(proto_value vmess_ws port)" "$(proto_ip_label vmess_ws)" "$(color_status "$([[ "$(proto_value vmess_ws tls false)" == "true" ]] && printf '自签证书' || printf 'TLS关闭')")"
  if [[ "$(proto_value hysteria2 enabled false)" == "true" ]]; then
    local hy_hop="未添加"
    [[ -n "$(proto_value hysteria2 hop_start "")" && -n "$(proto_value hysteria2 hop_end "")" ]] && hy_hop="$(proto_value hysteria2 hop_start)-$(proto_value hysteria2 hop_end)"
    printf "${YELLOW}【  Hysteria-2   】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}自签证书  ${CYAN}转发多端口:${NC}%b\n" "$(proto_value hysteria2 port)" "$(proto_ip_label hysteria2)" "$(color_status "$hy_hop")"
  fi
  if [[ "$(proto_value tuic enabled false)" == "true" ]]; then
    printf "${YELLOW}【    Tuic-v5    】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}自签证书\n" "$(proto_value tuic port)" "$(proto_ip_label tuic)"
  fi
  [[ "$(proto_value anytls enabled false)" == "true" ]] &&
    printf "${YELLOW}【    Anytls     】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}自签证书\n" "$(proto_value anytls port)" "$(proto_ip_label anytls)"
  [[ "$(proto_value trojan enabled false)" == "true" ]] &&
    printf "${YELLOW}【    Trojan     】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}自签证书\n" "$(proto_value trojan port)" "$(proto_ip_label trojan)"
  [[ "$(proto_value shadowsocks enabled false)" == "true" ]] &&
    printf "${YELLOW}【 Shadowsocks  】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}加密方式:${NC}%s\n" "$(proto_value shadowsocks port)" "$(proto_ip_label shadowsocks)" "$(proto_value shadowsocks method aes-128-gcm)"
  [[ "$(proto_value vmess_tcp enabled false)" == "true" ]] &&
    printf "${YELLOW}【   Vmess-tcp   】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}%b\n" "$(proto_value vmess_tcp port)" "$(proto_ip_label vmess_tcp)" "$(color_status TLS关闭)"
  [[ "$(proto_value vmess_http enabled false)" == "true" ]] &&
    printf "${YELLOW}【  Vmess-http   】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}Host:${NC}${MAGENTA}%s${NC}  ${CYAN}路径:${NC}%s\n" "$(proto_value vmess_http port)" "$(proto_ip_label vmess_http)" "$(proto_value vmess_http host "${SNI_OPTIONS[0]}")" "$(proto_value vmess_http path /vmess-http)"
  [[ "$(proto_value mixed enabled false)" == "true" ]] &&
    printf "${YELLOW}【    Mixed      】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}包含:${NC}HTTP/SOCKS5\n" "$(proto_value mixed port)" "$(proto_ip_label mixed)"
  printf "\n"
  show_subscription_links
  printf "\n"
}

show_protocol_details() {
  title "单个协议链接和二维码如下："
  if [[ ! -s "$STATE" ]]; then
    printf "暂无协议。\n\n"
    return
  fi
  show_protocol_links
  printf "${CYAN}HTTP/IP订阅链接(v2rayN默认):${NC}\n${MAGENTA}%s${NC}\n\n" "$(sub_http_link)"
  show_qr "$(sub_http_link)"
  printf "\n${CYAN}HTTP/IP Clash/Mihomo订阅链接:${NC}\n${MAGENTA}%s${NC}\n\n" "$(sub_http_link clash)"
  show_qr "$(sub_http_link clash)"
  if sub_https_link >/dev/null 2>&1; then
    printf "\n${CYAN}HTTPS域名订阅链接(v2rayN默认):${NC}\n${MAGENTA}%s${NC}\n\n" "$(sub_https_link)"
    show_qr "$(sub_https_link)"
    printf "\n${CYAN}HTTPS域名 Clash/Mihomo订阅链接:${NC}\n${MAGENTA}%s${NC}\n\n" "$(sub_https_link clash)"
    show_qr "$(sub_https_link clash)"
  fi
}

view_protocols() {
  show_protocol_details
  pause
}

run_manage() {
  while true; do
    title "Sing-box运行管理"
    printf "1. 启动 Sing-box\n2. 停止 Sing-box\n3. 重启 Sing-box\n4. 查看状态\n5. 查看日志\n6. 开机自启\n7. 关闭开机自启\n8. 检查配置\n0. 返回上一界面\n"
    case "$(ask_menu "请选择: " 8)" in
      1) systemctl start sing-box sing-box-sub; info "已启动。"; pause ;;
      2) systemctl stop sing-box sing-box-sub; info "已停止。"; pause ;;
      3) systemctl restart sing-box sing-box-sub; info "已重启。"; pause ;;
      4) systemctl status sing-box --no-pager; pause ;;
      5) journalctl -u sing-box -n 80 --no-pager; pause ;;
      6) systemctl enable sing-box sing-box-sub; info "已开启开机自启。"; pause ;;
      7) systemctl disable sing-box sing-box-sub; info "已关闭开机自启。"; pause ;;
      8) "$BIN" check -C "$CONF"; pause ;;
      0) return ;;
    esac
  done
}

main_menu() {
  while true; do
    clear_screen
    show_status_header
    show_protocols
    printf "\n"
    menu_line 0 "退出脚本"
    menu_line 1 "更新脚本"
    menu_line 2 "删除脚本"
    printf "${DIM}%s${NC}\n" '----------------------------------------'
    menu_line 3 "一键安装 Sing-box"
    menu_line 4 "删除卸载 Sing-box"
    menu_line 5 "Sing-box运行管理"
    printf "${DIM}%s${NC}\n" '----------------------------------------'
    menu_line 6 "一键添加协议：Mixed / Vless-reality / Vmess-ws / Hysteria-2 / Tuic-v5 / Anytls"
    menu_line 7 "添加协议"
    menu_line 8 "修改协议"
    menu_line 9 "删除协议"
    printf "${DIM}%s${NC}\n" '----------------------------------------'
    menu_line 10 "查看协议和综合订阅链接"
    menu_line 11 "更改综合订阅配置"
    menu_line 12 "一键放行所有缺失端口"
    case "$(ask_menu "请选择: " 12)" in
      1) update_script; pause ;;
      2) delete_script ;;
      3) install_sing_box; pause ;;
      4) uninstall_sing_box; pause ;;
      5) run_manage ;;
      6) add_all_protocols && restart_if_running; pause ;;
      7) add_protocol_menu && pause ;;
      8) change_protocol_config && pause ;;
      9) delete_protocol_menu && pause ;;
      10) view_protocols ;;
      11) change_subscription_config && pause ;;
      12) allow_missing_ufw_ports; pause ;;
      0) exit 0 ;;
    esac
  done
}

main_menu
