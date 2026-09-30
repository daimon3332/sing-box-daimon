#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="/etc/sing-box"
SCRIPT_VERSION="1.11.2"
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
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
ALPINE_PACKAGES="$ROOT/alpine-packages"
APK_REPOSITORIES="${APK_REPOSITORIES:-/etc/apk/repositories}"
NGINX_SUB_NAME="sing-box-daimon-sub"
NGINX_SUB_CONF="/etc/nginx/sites-available/$NGINX_SUB_NAME"
NGINX_SUB_LINK="/etc/nginx/sites-enabled/$NGINX_SUB_NAME"
SNI_OPTIONS=("www.bing.com" "www.amazon.com" "www.apple.com")
PROTOCOLS=(mixed vless_reality vmess_ws hysteria2 tuic anytls trojan shadowsocks vmess_tcp vmess_http)

system_id() {
  local id=""
  [[ ! -r /etc/os-release ]] || id="$(. /etc/os-release; printf '%s' "${ID:-}")"
  printf '%s' "$id"
}

is_alpine() {
  [[ "$(system_id)" == "alpine" ]]
}

if is_alpine; then
  SERVICE="/etc/init.d/sing-box"
  SUB_SERVICE="/etc/init.d/sing-box-sub"
fi

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
    read -r -e -p "$1" "$2" || return 1
  else
    read -r -p "$1" "$2" || return 1
  fi
}

# Leaving a submenu with 0 is not an action; skip the extra "press Enter".
menu_cancel() {
  MENU_CANCELLED=true
  return 1
}

menu_pause() {
  [[ "${MENU_CANCELLED:-false}" == true ]] || pause
  MENU_CANCELLED=false
}

pause() {
  local _
  safe_read "按回车继续..." _ || true
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
  local bytes="${1:-16}"
  if is_alpine || ! has_cmd python3; then
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
    return
  fi
  python3 - "$bytes" <<'PY'
import secrets, sys
print(secrets.token_hex(int(sys.argv[1])))
PY
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
  if is_alpine; then
    local LC_ALL=C value="$1" char i
    for ((i=0; i<${#value}; i++)); do
      char="${value:i:1}"
      case "$char" in
        [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
        *) printf '%%%02X' "'$char" ;;
      esac
    done
    return 0
  fi
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
  safe_read "$prompt [$default]: " value || return 1
  printf '%s' "${value:-$default}"
}

ask_yes_no() {
  local prompt="$1" default="${2:-n}" value
  if [[ "$default" =~ ^[Yy]$ ]]; then
    safe_read "$prompt [Y/n]: " value || return 2
    value="${value:-y}"
  else
    safe_read "$prompt [y/N]: " value || return 2
    value="${value:-n}"
  fi
  [[ "$value" =~ ^[Yy]$ ]]
}

menu_number() {
  local value="$1" max="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  value="${value#"${value%%[!0]*}"}"
  value="${value:-0}"
  ((${#value} <= ${#max})) && ((10#$value <= max)) || return 1
  printf '%s' "$value"
}

valid_port() {
  local port
  port="$(menu_number "$1" 65535)" && ((port > 0))
}

valid_port_range() {
  [[ "$1" =~ ^([0-9]+)[:-]([0-9]+)$ ]] || return 1
  local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
  valid_port "$start" && valid_port "$end" && ((10#$start <= 10#$end))
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_token() {
  [[ "$1" =~ ^[A-Za-z0-9]+$ ]]
}

valid_ip_address() {
  local address="$1" version="$2"
  if is_alpine || ! has_cmd python3; then
    if [[ "$version" == "4" ]]; then
      # Four dot-separated octets, no trailing dot, no leading zeros; matches
      # what Python's ipaddress accepts on the non-Alpine path.
      local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
      [[ "$address" =~ ^$octet\.$octet\.$octet\.$octet$ ]]
      return
    fi
    if [[ "$address" == *.* ]]; then
      valid_ip_address "${address##*:}" 4 || return 1
      address="${address%:*}:0:0"
    fi
    [[ "$address" == *:* && "$address" =~ ^[0-9A-Fa-f:]+$ && "$address" != *:::* ]] || return 1
    [[ "$address" != :* || "$address" == ::* ]] || return 1
    [[ "$address" != *: || "$address" == *:: ]] || return 1
    local rest="$address" part count=0 compressed=false
    local -a parts=()
    if [[ "$address" == *::* ]]; then
      compressed=true
      rest="${address/::/:}"
      [[ "$rest" != *::* ]] || return 1
    else
      [[ "$address" != :* && "$address" != *: ]] || return 1
    fi
    IFS=: read -ra parts <<<"$rest"
    for part in "${parts[@]}"; do
      [[ -z "$part" ]] && continue
      [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      count=$((count + 1))
    done
    if [[ "$compressed" == "true" ]]; then
      ((count < 8))
    else
      ((count == 8))
    fi
    return
  fi
  python3 - "$address" "$version" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try:
  address = ipaddress.ip_address(sys.argv[1])
except ValueError:
  raise SystemExit(1)
raise SystemExit(0 if address.version == int(sys.argv[2]) else 1)
PY
}

endpoint_host_value() {
  local host="$1"
  if [[ "$host" == "["* || "$host" == *"]" ]]; then
    [[ "$host" == "["*"]" ]] || return 1
    host="${host:1:${#host}-2}"
    valid_ip_address "$host" 6 || return 1
  fi
  if [[ "$host" =~ ^[0-9.]+$ ]]; then
    valid_ip_address "$host" 4 || return 1
  fi
  if valid_ip_address "$host" 4 || valid_ip_address "$host" 6 || valid_domain "$host"; then
    printf '%s' "$host"
    return 0
  fi
  return 1
}

ensure_dirs() {
  mkdir -p "$ROOT/bin" "$CONF" "$CERT" "$SUB" "$LOG" "$FIREWALL"
}

ensure_state() {
  ensure_dirs || return 1
  if is_alpine; then
    has_cmd jq || { fail "Alpine NAT 状态管理需要 jq。"; return 1; }
    if [[ ! -s "$STATE" ]]; then
      jq -n --arg token "$(rand_hex 16)" '{token:$token,node_prefix:"",sub_port:2096,sub_endpoint_host:"",sub_domain:"",sub_tls:false,install_mode:"standard",protocols:{}}' >"$STATE"
    fi
    local token tmp
    token="$(jq -r '.token // ""' "$STATE" 2>/dev/null || true)"
    if ! valid_token "$token"; then
      tmp="$(mktemp "$ROOT/.state.XXXXXX")" || return 1
      jq --arg token "$(rand_hex 16)" '.token = $token' "$STATE" >"$tmp" && mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
      invalidate_state_cache
    fi
    jq -e 'type == "object" and (.protocols | type == "object")' "$STATE" >/dev/null 2>&1 || {
      fail "状态文件损坏，已停止操作：$STATE" >&2
      return 1
    }
    return 0
  fi
  if [[ ! -s "$STATE" ]]; then
    python3 - "$STATE" <<'PY' || return 1
import json, os, secrets, sys
state = {
  "token": secrets.token_hex(16),
  "node_prefix": "",
  "sub_port": 2096,
  "sub_endpoint_host": "",
  "sub_domain": "",
  "sub_tls": False,
  "install_mode": "standard",
  "protocols": {}
}
path = sys.argv[1]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
  json.dump(state, f, indent=2, ensure_ascii=False)
  f.write("\n")
  f.flush()
  os.fsync(f.fileno())
os.replace(tmp, path)
PY
  fi
  # Only rewrite when the token is actually invalid. This used to save()
  # unconditionally, so every ensure_state call cost a write plus fsync and
  # invalidated the state cache, and ensure_state runs from rebuild_configs,
  # generate_subscription and most menu actions. Exit 10 signals "rotated".
  local rc=0
  python3 - "$STATE" <<'PY' >/dev/null 2>&1 || rc=$?
import json, os, re, secrets, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
if not isinstance(data, dict) or not isinstance(data.get("protocols"), dict):
  raise SystemExit(1)
if re.fullmatch(r"[A-Za-z0-9]+", str(data.get("token", ""))):
  raise SystemExit(0)
data["token"] = secrets.token_hex(16)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
  f.flush()
  os.fsync(f.fileno())
os.replace(tmp, path)
raise SystemExit(10)
PY
  # A rotated token must drop the cached copy, otherwise callers keep the old
  # token and generate_subscription writes files under a name that no longer
  # matches state.json.
  case "$rc" in
    0) return 0 ;;
    10) invalidate_state_cache ;;
    *) fail "状态文件读取失败，已停止操作：$STATE" >&2; return 1 ;;
  esac
}

has_protocols() {
  [[ -s "$STATE" ]] || return 1
  if is_alpine; then
    jq -e 'any(.protocols[]?; .enabled == true)' "$STATE" >/dev/null 2>&1
    return
  fi
  python3 - "$STATE" <<'PY'
import json, sys
try:
  data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
  raise SystemExit(1)
raise SystemExit(0 if any(v.get("enabled") for v in data.get("protocols", {}).values()) else 1)
PY
}

declare -gA SB_STATE_CACHE=()
SB_STATE_CACHE_STAMP=""
# The filename carries the emitted variable name. An older release wrote
# STATE_CACHE[...] assignments here; sourcing that from this version aborts
# under set -u because the subscript is evaluated arithmetically. Versioning the
# path means a stale file is ignored instead of read, so updates are safe.
SB_STATE_CACHE_FILE_NAME=".state-cache.v2.sh"

state_cache_path() {
  printf '%s/%s' "$ROOT" "$SB_STATE_CACHE_FILE_NAME"
}

# Writers must drop both the file and the in-process copy. The stamp uses
# whole-second mtime, so a write plus rebuild inside one second could otherwise
# match a stale stamp and serve outdated values.
invalidate_state_cache() {
  rm -f "$(state_cache_path)" "$ROOT/.state-cache.sh"
  SB_STATE_CACHE=()
  SB_STATE_CACHE_STAMP=""
  return 0
}

# Regenerate the cache when state.json is newer. Writers delete the cache
# outright, so a missing file also forces a rebuild.
refresh_state_cache_file() {
  local state_cache_file="$1" tmp
  [[ ! -s "$state_cache_file" || "$STATE" -nt "$state_cache_file" ]] || return 0
  # No state yet (fresh host, after uninstall) or no python3 (Alpine): there is
  # nothing to cache, and trying printed a traceback on every menu render.
  [[ -s "$STATE" ]] && has_cmd python3 || return 1
  tmp="$(mktemp "$ROOT/.state-cache.XXXXXX" 2>/dev/null)" || return 1
  if ! python3 - "$STATE" <<'PY' >"$tmp" 2>/dev/null
import json, shlex, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
def emit(value, path=()):
    if isinstance(value, dict):
        for key, item in value.items():
            emit(item, path + (str(key),))
    elif isinstance(value, (str, int, float, bool)) or value is None:
        key = ".".join(path)
        text = "" if value is None else (str(value).lower() if isinstance(value, bool) else str(value))
        print(f"SB_STATE_CACHE[{shlex.quote(key)}]={shlex.quote(text)}")
emit(data)
PY
  then
    rm -f "$tmp"
    return 1
  fi
  if [[ -s "$tmp" ]]; then
    mv -f "$tmp" "$state_cache_file"
  else
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# Source the cache into a process-global array at most once per cache mtime.
# state_value is called ~180x per menu render, almost all inside command
# substitutions; re-sourcing the file each time cost ~2.2 ms per call. A
# subshell inherits the parent's already-populated array, so one load per render
# replaces one load per lookup.
load_state_cache() {
  local state_cache_file="$ROOT/$SB_STATE_CACHE_FILE_NAME" line ok=1
  # Fast path, taken by nearly every lookup: no subprocess at all. -nt and the
  # array-size test are shell builtins. Spawning stat or grep here costs more
  # than the sourcing this cache exists to avoid.
  if [[ "$SB_STATE_CACHE_STAMP" == "$state_cache_file" ]] &&
     ((${#SB_STATE_CACHE[@]})) && [[ ! "$STATE" -nt "$state_cache_file" ]]; then
    return 0
  fi
  refresh_state_cache_file "$state_cache_file" || return 1
  [[ -r "$state_cache_file" ]] || return 1
  # Validate only when actually loading. Anything that is not an
  # SB_STATE_CACHE[...]=... assignment is rebuilt rather than executed, so a
  # truncated or foreign file cannot run code or abort the script under set -u.
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == 'SB_STATE_CACHE['*']='* ]] || { ok=0; break; }
  done <"$state_cache_file"
  if (( ok == 0 )); then
    rm -f "$state_cache_file"
    refresh_state_cache_file "$state_cache_file" || return 1
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == 'SB_STATE_CACHE['*']='* ]] || return 1
    done <"$state_cache_file"
  fi
  SB_STATE_CACHE=()
  source "$state_cache_file" || return 1
  SB_STATE_CACHE_STAMP="$state_cache_file"
  return 0
}

state_value() {
  local key="$1" default="${2:-}"
  [[ -s "$STATE" ]] || { printf '%s' "$default"; return 0; }
  if is_alpine; then
    jq -r --arg key "$key" --arg default "$default" '
      try (getpath($key | split(".")) | if . == null then $default else . end) catch $default |
      if type == "boolean" then tostring else tostring end
    ' "$STATE" 2>/dev/null || printf '%s' "$default"
    return 0
  fi
  load_state_cache || { printf '%s' "$default"; return 0; }
  if [[ ${SB_STATE_CACHE[$key]+_} ]]; then
    printf '%s' "${SB_STATE_CACHE[$key]}"
  else
    printf '%s' "$default"
  fi
  return 0
}

proto_value() {
  local proto="$1" key="$2" default="${3:-}"
  state_value "protocols.$proto.$key" "$default"
}

node_prefix() {
  state_value node_prefix ""
}

node_base_name() {
  case "$1" in
    mixed) printf 'Mixed-SOCKS5' ;;
    vless_reality) printf 'Vless-reality' ;;
    vmess_ws) printf 'Vmess-ws' ;;
    hysteria2) printf 'Hysteria-2' ;;
    tuic) printf 'Tuic-v5' ;;
    anytls) printf 'Anytls' ;;
    trojan) printf 'Trojan' ;;
    shadowsocks) printf 'Shadowsocks' ;;
    vmess_tcp) printf 'Vmess-tcp' ;;
    vmess_http) printf 'Vmess-http' ;;
    *) return 1 ;;
  esac
}

node_name() {
  local prefix base suffix="${2:-}"
  prefix="$(node_prefix)"
  base="$(node_base_name "$1")" || return 1
  if [[ -z "$suffix" && "$(proto_value "$1" ip_version auto)" == "dual" ]]; then
    suffix="${PROTOCOL_VARIANT:-ipv4}"
  fi
  [[ -n "$prefix" ]] && base="$prefix-$base"
  case "$suffix" in
    ipv4) printf '%s-IPv4' "$base" ;;
    ipv6) printf '%s-IPv6' "$base" ;;
    *) printf '%s' "$base" ;;
  esac
}

node_display_name() {
  if [[ "$(proto_value "$1" ip_version auto)" == "dual" ]]; then
    printf '%s / %s' "$(node_name "$1" ipv4)" "$(node_name "$1" ipv6)"
  else
    node_name "$1"
  fi
}

valid_node_prefix() {
  local value="$1"
  [[ -n "$value" && ${#value} -le 32 ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* && "$value" != *"#"* ]]
}

set_node_prefix() {
  local value="$1"
  valid_node_prefix "$value" || return 1
  set_state_value node_prefix "$value"
}

clear_node_prefix() {
  set_state_value node_prefix ""
}

maybe_set_node_prefix() {
  [[ -n "$(node_prefix)" ]] && return 0
  ask_yes_no "是否设置节点名称前缀？" y || return 0
  local value
  while true; do
    # Prefixes are optional, so an unanswerable prompt just leaves it unset
    # rather than aborting the install midway.
    safe_read "请输入节点名称前缀（留空跳过）: " value || return 0
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ -n "$value" ]] || return 0
    if set_node_prefix "$value"; then
      info "节点名称前缀已设置为: $value"
      return 0
    fi
    warn "前缀不能为空、不能超过 32 个字符，且不能包含 # 或换行。"
  done
}

node_prefix_menu() {
  ensure_state || return 1
  title "节点名称前缀"
  local current choice value
  current="$(node_prefix)"
  printf "当前前缀: %s\n" "${current:-未设置}"
  printf "1. 添加/修改前缀\n2. 删除前缀\n0. 返回\n"
  choice="$(ask_menu "请选择: " 2)"
  case "$choice" in
    1)
      while true; do
        safe_read "请输入节点名称前缀: " value || return 1
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if apply_state_change subscription set_node_prefix "$value"; then
          info "节点名称前缀已保存，订阅已更新。"
          return 0
        fi
        warn "前缀不能为空、不能超过 32 个字符，且不能包含 # 或换行。"
      done
      ;;
    2)
      apply_state_change subscription clear_node_prefix || return 1
      info "节点名称前缀已删除，订阅已更新。"
      ;;
    0) menu_cancel ;;
  esac
}

install_mode() {
  state_value install_mode standard
}

lite_mode() {
  [[ "$(install_mode)" == "lite" ]]
}

set_state_value() {
  local key="$1" value="$2"
  ensure_state || return 1
  if is_alpine; then
    local tmp type=string
    [[ "$key" == "sub_port" ]] && [[ "$value" =~ ^[0-9]+$ ]] && type=number
    # Only known boolean keys are coerced; a token or prefix spelled "true"
    # must stay a string or links and names stop matching.
    [[ "$key" == "sub_tls" ]] && [[ "$value" == "true" || "$value" == "false" ]] && type=boolean
    tmp="$(mktemp "$ROOT/.state.XXXXXX")" || return 1
    jq --arg key "$key" --arg value "$value" --arg type "$type" '
      ($key | split(".")) as $path |
      ($value | if $type == "number" then tonumber elif $type == "boolean" then . == "true" else . end) as $typed |
      setpath($path; $typed)
    ' "$STATE" >"$tmp" && mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
    invalidate_state_cache
    return
  fi
  python3 - "$STATE" "$key" "$value" <<'PY' || return 1
import json, os, sys
path, key, value = sys.argv[1], sys.argv[2].split("."), sys.argv[3]
data = json.load(open(path, encoding="utf-8"))
cur = data
for part in key[:-1]:
  cur = cur.setdefault(part, {})
if key[-1] in {"sub_port"} and value.isdigit():
  cur[key[-1]] = int(value)
elif key[-1] in {"sub_tls"} and value in {"true", "false"}:
  cur[key[-1]] = value == "true"
else:
  cur[key[-1]] = value
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
  f.flush()
  os.fsync(f.fileno())
os.replace(tmp, path)
PY
  invalidate_state_cache
}

fetch_latest_script() {
  local url="${1:-$SCRIPT_URL}"
  curl -fsSL --max-time 8 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "${url}?t=$(date +%s)" 2>/dev/null \
    || curl -fsSL --max-time 8 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$url" 2>/dev/null
}

# The version check runs in the background while the menu may be writing
# state.json. It used to read-modify-write state.json through the same
# state.json.tmp path, so the two could lose each other's update or interleave
# into a corrupt file; it also created state.json before anything was
# installed. Keep it in its own cache file instead.
version_cache_file() {
  printf '%s/version' "$(status_cache_dir)"
}

refresh_version_cache() {
  local latest now file tmp old_latest=""
  latest="$(fetch_latest_script | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -n1 || true)"
  [[ "$latest" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || return 1
  now="$(date +%s)"
  file="$(version_cache_file)"
  mkdir -p "${file%/*}" 2>/dev/null || return 0
  [[ -s "$file" ]] && read -r old_latest _ <"$file" || true
  tmp="$(mktemp "$file.XXXXXX" 2>/dev/null)" || return 0
  printf '%s %s\n' "${latest:-${old_latest:--}}" "$now" >"$tmp" && mv -f "$tmp" "$file" || rm -f "$tmp"
  return 0
}

# Take a background-job lock directory. A job killed mid-run leaves its lock
# behind, which used to disable that refresh until the next reboot; treat a
# lock older than two minutes as abandoned.
acquire_async_lock() {
  local lock="$1"
  if [[ -d "$lock" ]] && [[ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]]; then
    rmdir "$lock" 2>/dev/null || true
  fi
  mkdir "$lock" 2>/dev/null
}

refresh_version_cache_async() {
  local dir lock
  dir="$(status_cache_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  lock="$dir/version.lock"
  acquire_async_lock "$lock" || return 0
  ( refresh_version_cache; rmdir "$lock" 2>/dev/null || true ) >/dev/null 2>&1 &
}

version_status() {
  local latest="" checked=0 now age status file
  file="$(version_cache_file)"
  [[ -s "$file" ]] && read -r latest checked <"$file" || true
  [[ "$latest" == "-" ]] && latest=""
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
  ensure_state || return 1
  if is_alpine; then
    local tmp
    tmp="$(mktemp "$ROOT/.state.XXXXXX")" || return 1
    jq --arg proto "$proto" --args '
      .protocols[$proto].enabled = true |
      reduce $ARGS.positional[] as $pair (.;
        ($pair | index("=")) as $split |
        ($pair[0:$split]) as $key |
        ($pair[$split + 1:]) as $raw |
        ($raw | if ($key | test("port$") or $key == "alter_id") then tonumber elif (($key == "enabled" or $key == "tls") and (. == "true" or . == "false")) then . == "true" else . end) as $value |
        .protocols[$proto][$key] = $value
      )
    ' "$@" <"$STATE" >"$tmp" && mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
    return
  fi
  python3 - "$STATE" "$proto" "$@" <<'PY' || return 1
import json, os, sys
path, proto, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
data = json.load(open(path, encoding="utf-8"))
item = data.setdefault("protocols", {}).setdefault(proto, {})
item["enabled"] = True
for pair in pairs:
  key, value = pair.split("=", 1)
  if key.endswith("port") or key in {"alter_id"}:
    item[key] = int(value)
  elif key in {"enabled", "tls"} and value in {"true", "false"}:
    item[key] = value == "true"
  else:
    item[key] = value
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
  f.flush()
  os.fsync(f.fileno())
os.replace(tmp, path)
PY
  invalidate_state_cache
}

delete_protocol_state() {
  local proto="$1"
  [[ -s "$STATE" ]] || return 0
  if is_alpine; then
    local tmp
    tmp="$(mktemp "$ROOT/.state.XXXXXX")" || return 1
    jq --arg proto "$proto" 'del(.protocols[$proto])' "$STATE" >"$tmp" && mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
    return
  fi
  python3 - "$STATE" "$proto" <<'PY' || return 1
import json, os, sys
path, proto = sys.argv[1], sys.argv[2]
data = json.load(open(path, encoding="utf-8"))
data.setdefault("protocols", {}).pop(proto, None)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, ensure_ascii=False)
  f.write("\n")
  f.flush()
  os.fsync(f.fileno())
os.replace(tmp, path)
PY
  invalidate_state_cache
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
  comment="$(hopping_comment "$proto")"
  delete_hopping_rules "$proto"
  if [[ -n "$start" && -n "$end" ]]; then
    iptables -t nat -A PREROUTING -p udp --dport "$start:$end" -m comment --comment "$comment" -j REDIRECT --to-ports "$target" 2>/dev/null ||
      warn "IPv4 跳跃端口规则写入失败，跳跃端口不可用。" >&2
    if host_has_ipv6; then
      ip6tables -t nat -A PREROUTING -p udp --dport "$start:$end" -m comment --comment "$comment" -j REDIRECT --to-ports "$target" 2>/dev/null ||
        warn "IPv6 跳跃端口规则写入失败，IPv6 跳跃端口不可用。" >&2
    fi
  fi
}

# NAT rules live only in the kernel. Unless iptables-persistent happens to be
# installed, a reboot drops the Hysteria2 hopping REDIRECT while the node keeps
# advertising the range. sing-box.service runs this before every start so the
# rules always match state.json.
apply_saved_hopping_rules() {
  if [[ "$(proto_value hysteria2 enabled false)" == "true" ]]; then
    apply_hopping_rules hysteria2 "$(proto_value hysteria2 hop_start "")" "$(proto_value hysteria2 hop_end "")" "$(proto_value hysteria2 port)"
  else
    delete_hopping_rules hysteria2
  fi
  delete_hopping_rules tuic
  return 0
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
  ufw allow "$rule" >/dev/null 2>&1 || { warn "防火墙放行失败: $rule"; return 1; }
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
    mixed|shadowsocks)
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
  if [[ -f "$SUB_SERVICE" || -f "$SUB_SERVER" ]]; then
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
  return 0
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
  ensure_dirs || return 1
  mapfile -t desired < <(required_ufw_rules | awk 'NF && !seen[$0]++')
  mapfile -t managed < <(managed_ufw_rules)
  for rule in "${managed[@]}"; do
    rule_in_list "$rule" "${desired[@]}" || ufw_delete_rule "$rule"
  done
  for rule in "${desired[@]}"; do
    ufw_allow_rule "$rule" || return 1
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
      ufw_allow_rule "$rule" || return 1
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

# The hopping rule REDIRECTs a whole UDP range to one port, so any other
# UDP-carrying protocol whose port falls inside the range stops receiving
# traffic. Report the collisions instead of silently breaking those nodes.
hopping_range_conflicts() {
  local owner="$1" start="$2" end="$3" proto port
  # Callers pass the display label ("Hysteria-2"); without normalising it the
  # protocol's own port was reported as a conflict with itself.
  owner="${owner,,}"
  owner="${owner//-/}"
  [[ "$owner" == tuicv5 ]] && owner=tuic
  for proto in mixed hysteria2 tuic shadowsocks; do
    [[ "$proto" == "$owner" ]] && continue
    [[ "$(proto_value "$proto" enabled false)" == "true" ]] || continue
    port="$(proto_value "$proto" port "")"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    (( port >= start && port <= end )) && printf '%s(%s) ' "$proto" "$port"
  done
  return 0
}

ask_hopping() {
  local proto="$1" current_start="${2:-}" current_end="${3:-}" range start end default_yn=n conflicts
  [[ -n "$current_start" && -n "$current_end" ]] && default_yn=y
  local answer=0
  ask_yes_no "是否开启 ${proto} 跳跃端口？" "$default_yn" || answer=$?
  case "$answer" in
    0) ;;
    1) printf '\t\n'; return 0 ;;
    *) return 1 ;;
  esac
  while true; do
    safe_read "请输入跳跃端口范围，格式 48000:50000${current_start:+ [$current_start:$current_end]}（0 返回）: " range || return 1
    [[ "$range" != 0 ]] || menu_cancel
    range="${range:-${current_start:+$current_start:$current_end}}"
    if valid_port_range "$range"; then
      range="${range/-/:}"
      start="$(menu_number "${range%%:*}" 65535)"
      end="$(menu_number "${range##*:}" 65535)"
      conflicts="$(hopping_range_conflicts "$proto" "$start" "$end")"
      if [[ -n "$conflicts" ]]; then
        warn "该范围包含其他协议的 UDP 端口，会导致这些节点收不到流量: ${conflicts% }" >&2
        continue
      fi
      printf '%s\t%s\n' "$start" "$end"
      return 0
    fi
    # stdout is this function's return channel, read by the caller. A message
    # written here would be consumed as the port values instead of shown.
    warn "端口范围格式错误。" >&2
  done
}

tcp_udp_used() {
  local port="$1"
  if has_cmd ss; then
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && return 0
    ss -H -lun "sport = :$port" 2>/dev/null | grep -q . && return 0
    return 1
  fi
  # Alpine's BusyBox ships netstat but not ss; without this every port looked free.
  has_cmd netstat || return 1
  netstat -lntu 2>/dev/null | awk -v p="$port" '$4 ~ ("[:.]" p "$") { found = 1 } END { exit found ? 0 : 1 }'
}

# The Hysteria2 hopping rule REDIRECTs its whole UDP range, so a port inside it
# never receives its own UDP traffic. The range is checked once when it is set;
# this keeps ports picked or entered later from landing inside it.
hop_range_used() {
  local port="$1" start end
  [[ "$(proto_value hysteria2 enabled false)" == "true" ]] || return 1
  start="$(proto_value hysteria2 hop_start "")"
  end="$(proto_value hysteria2 hop_end "")"
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= start && port <= end ))
}

config_port_used() {
  local port="$1"
  [[ -d "$CONF" ]] || return 1
  if is_alpine; then
    local files=("$CONF"/*.json)
    [[ -e "${files[0]}" ]] || return 1
    jq -se --argjson port "$port" '
      any(.[]; any(.. | objects; (.listen_port? == $port) or (.server_port? == $port) or (.local_port? == $port)))
    ' "${files[@]}" >/dev/null 2>&1
    return
  fi
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
  if is_alpine; then
    jq -e --argjson port "$port" 'any(.protocols[]?; .port == $port)' "$STATE" >/dev/null 2>&1
    return
  fi
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
  hop_range_used "$port" || tcp_udp_used "$port" || config_port_used "$port" || state_port_used "$port"
}

next_free_port() {
  local port="$1" exclude="${2:-}" hop_start hop_end wrapped=0
  port="$(menu_number "$port" 65535)" || return 1
  hop_start="$(proto_value hysteria2 hop_start "")"
  hop_end="$(proto_value hysteria2 hop_end "")"
  while port_used "$port" "$exclude"; do
    # Skip a hop range in one step; probing it port by port costs several
    # python runs each, which is minutes for a range like 20000:50000.
    if [[ "$port" != "$exclude" && "$hop_start" =~ ^[0-9]+$ && "$hop_end" =~ ^[0-9]+$ ]] &&
       (( port >= hop_start && port <= hop_end )) && hop_range_used "$port"; then
      port=$((hop_end + 1))
    else
      port=$((port + 1))
    fi
    if (( port > 65535 )); then
      (( wrapped == 0 )) || { warn "没有可用端口，请选择其他端口范围。" >&2; return 1; }
      wrapped=1
      port=10000
    fi
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
  port="$(next_free_port "$default" "$exclude")" || return 1
  while true; do
    safe_read "$name 端口 [$port]，输入 0 取消: " input || return 1
    input="${input:-$port}"
    [[ "$input" == 0 ]] && return 1
    if ! valid_port "$input"; then
      warn "端口范围必须是 1-65535。" >&2
    elif port_used "$(menu_number "$input" 65535)" "$exclude"; then
      warn "端口 $input 已占用，请重新输入。" >&2
    else
      menu_number "$input" 65535
      return
    fi
  done
}

protocol_exists() {
  [[ "$(proto_value "$1" enabled false)" == "true" ]]
}

protocol_menu_items() {
  local mode="${1:-existing}" proto enabled
  AVAILABLE_PROTOCOLS=()
  for proto in "${PROTOCOLS[@]}"; do
    enabled=false
    protocol_exists "$proto" && enabled=true
    if [[ "$mode" == missing ]]; then
      [[ "$enabled" == false ]] || continue
      if is_alpine || lite_mode; then
        [[ "$proto" == vless_reality ]] || continue
      fi
    else
      [[ "$enabled" == true ]] || continue
    fi
    AVAILABLE_PROTOCOLS+=("$proto")
    printf '%s. %s' "${#AVAILABLE_PROTOCOLS[@]}" "$(node_base_name "$proto")"
    [[ "$mode" == missing ]] || printf '  端口:%s  地址:%s' "$(proto_value "$proto" port)" "$(proto_ip_label "$proto")"
    printf '\n'
  done
}

select_existing_protocol() {
  local all="${1:-false}" choice max
  SELECTED_PROTOCOL=""
  protocol_menu_items
  max=${#AVAILABLE_PROTOCOLS[@]}
  ((max)) || { warn "尚未添加协议。"; return 1; }
  if [[ "$all" == true ]]; then
    max=$((max + 1))
    printf '%s. 全部已添加协议\n' "$max"
  fi
  printf '0. 返回\n'
  choice="$(ask_menu "请选择协议: " "$max")"
  [[ "$choice" != 0 ]] || menu_cancel
  if [[ "$all" == true && "$choice" == "$max" ]]; then
    SELECTED_PROTOCOL=all
  else
    SELECTED_PROTOCOL="${AVAILABLE_PROTOCOLS[choice-1]}"
  fi
}

ask_menu() {
  local prompt="$1" max="$2" default="${3:-}" input
  while true; do
    # On EOF (piped input exhausted, or Ctrl-D) fall back to 0, the "return" /
    # "exit" choice every caller has. Retrying instead spun forever, since a
    # closed stdin never yields a valid number.
    safe_read "$prompt" input || { printf '0'; return; }
    input="${input:-$default}"
    if input="$(menu_number "$input" "$max")"; then
      printf '%s' "$input"
      return 0
    fi
    # stdout is the return channel; a message here becomes the caller's value.
    warn "请输入 0-$max 的数字。" >&2
  done
}

menu_line() {
  printf "${BLUE}%2s.${NC} %s\n" "$1" "$2"
}

pick_sni() {
  local current="${1:-}" choice custom default=4 i
  for i in 0 1 2; do
    [[ "$current" != "${SNI_OPTIONS[i]}" ]] || default=$((i + 1))
  done
  [[ -n "$current" ]] || default=1
  for i in 0 1 2; do
    printf '%s. %s%s\n' "$((i + 1))" "${SNI_OPTIONS[i]}" "$( ((default == i + 1)) && printf '  (默认)')" >&2
  done
  printf '4. 自定义%s\n0. 返回\n' "$( ((default == 4)) && printf '  (默认: %s)' "$current")" >&2
  choice="$(ask_menu "请选择 SNI [回车=$default]: " 4 "$default")"
  case "$choice" in
    1) printf '%s' "${SNI_OPTIONS[0]}" ;;
    2) printf '%s' "${SNI_OPTIONS[1]}" ;;
    3) printf '%s' "${SNI_OPTIONS[2]}" ;;
    4)
      while true; do
        safe_read "请输入 SNI [${current:-www.bing.com}]: " custom || return 1
        custom="${custom:-${current:-www.bing.com}}"
        valid_domain "$custom" && { printf '%s' "$custom"; return; }
        warn "SNI 请输入有效域名。" >&2
      done
      ;;
    *) return 1 ;;
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
  local names san primary ext name missing=0
  ensure_dirs || return 1
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
  ensure_cert || return 1
  openssl x509 -noout -fingerprint -sha256 -in "$CERT/self.crt" |
    awk -F= '{print tolower($2)}' |
    tr -d ':'
}

write_base_configs() {
  ensure_dirs || return 1
  cat >"$CONF/00_log.json" <<EOF || return 1
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true,
    "output": "$LOG/sing-box.log"
  }
}
EOF
  cat >"$CONF/01_outbounds.json" <<'EOF' || return 1
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
  cat >"$CONF/03_route.json" <<'EOF' || return 1
{
  "route": {
    "rules": [],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
}

json_escape() {
  if is_alpine; then
    jq -nr --arg value "$1" '$value | tojson | .[1:-1]'
  else
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False)[1:-1], end="")' "$1"
  fi
}

escape_config_values() {
  local name escaped
  for name in "$@"; do
    escaped="$(json_escape "${!name}")" || return 1
    printf -v "$name" '%s' "$escaped"
  done
}

write_mixed_config() {
  local port="$1" username="$2" password="$3"
  escape_config_values username password || return 1
  cat >"$CONF/10_mixed.json" <<EOF || return 1
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
  escape_config_values uuid sni private_key short_id || return 1
  cat >"$CONF/11_vless_reality.json" <<EOF || return 1
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
  escape_config_values uuid || return 1
  local tls_block=""
  if [[ "$tls_enabled" == "true" ]]; then
    ensure_cert || return 1
    tls_block=',
      "tls": {
        "enabled": true,
        "certificate_path": "'"$CERT"'/self.crt",
        "key_path": "'"$CERT"'/self.key"
      }'
  fi
  cat >"$CONF/12_vmess_ws.json" <<EOF || return 1
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
  escape_config_values password || return 1
  ensure_cert || return 1
  cat >"$CONF/13_hysteria2.json" <<EOF || return 1
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
  escape_config_values uuid password || return 1
  ensure_cert || return 1
  cat >"$CONF/14_tuic.json" <<EOF || return 1
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
      "heartbeat": "10s",
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
  escape_config_values password || return 1
  ensure_cert || return 1
  cat >"$CONF/15_anytls.json" <<EOF || return 1
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
  escape_config_values password || return 1
  ensure_cert || return 1
  cat >"$CONF/16_trojan.json" <<EOF || return 1
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
  escape_config_values password method || return 1
  cat >"$CONF/17_shadowsocks.json" <<EOF || return 1
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
  escape_config_values uuid || return 1
  cat >"$CONF/18_vmess_tcp.json" <<EOF || return 1
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
  escape_config_values uuid path host || return 1
  cat >"$CONF/19_vmess_http.json" <<EOF || return 1
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

apply_state_change() {
  local rc=0
  stage_state_change "$@" || rc=$?
  invalidate_state_cache
  return "$rc"
}

stage_state_change() (
  local mode="$1" live_root="$ROOT" live_state="$STATE" live_conf="$CONF" live_sub="$SUB" live_cert="$CERT" stage file
  shift
  ensure_state || return 1
  stage="$(mktemp -d "$ROOT/.change.XXXXXX")" || return 1
  [[ "$stage" == "$ROOT"/.change.* && -d "$stage" ]] || return 1
  trap 'rm -rf -- "$stage"' EXIT
  local ROOT="$stage" STATE="$stage/state.json" CONF="$stage/conf" SUB="$stage/sub" CERT="$stage/cert"
  local SB_STATE_CACHE_STAMP="" CHANGE_STAGED=true
  local -A SB_STATE_CACHE=()
  ensure_dirs || return 1
  cp "$live_state" "$STATE" || return 1
  [[ ! -d "$live_cert" ]] || cp -a "$live_cert/." "$CERT/" || return 1
  "$@" || return 1
  if [[ "$mode" == config ]]; then
    [[ ! -d "$live_conf" ]] || cp -a "$live_conf/." "$CONF/" || return 1
    render_configs || return 1
    if [[ -x "$BIN" ]]; then
      "$BIN" check -C "$CONF" || { fail "配置校验失败，原配置和节点参数未修改。" >&2; return 1; }
    fi
    for file in "$CONF"/*.json; do
      [[ -f "$file" ]] || continue
      if is_alpine; then
        jq --arg old "$CERT/" --arg new "$live_cert/" 'walk(if type == "string" and startswith($old) then $new + ltrimstr($old) else . end)' "$file" >"$file.tmp" || return 1
      else
        python3 - "$file" "$CERT/" "$live_cert/" <<'PY' >"$file.tmp" || return 1
import json, sys
path, old, new = sys.argv[1:]
def rewrite(value):
    if isinstance(value, dict): return {k: rewrite(v) for k, v in value.items()}
    if isinstance(value, list): return [rewrite(v) for v in value]
    if isinstance(value, str) and value.startswith(old): return new + value[len(old):]
    return value
json.dump(rewrite(json.load(open(path, encoding="utf-8"))), sys.stdout, indent=2, ensure_ascii=False)
PY
      fi
      mv -f "$file.tmp" "$file" || return 1
    done
  else
    generate_subscription || return 1
  fi
  for file in "$CERT"/*; do
    [[ -f "$file" ]] || continue
    cmp -s "$file" "$live_cert/${file##*/}" || mv -f "$file" "$live_cert/${file##*/}" || return 1
  done
  if [[ "$mode" == config ]]; then
    for file in "$live_conf"/{10..29}_*.json; do
      [[ ! -f "$file" || -f "$CONF/${file##*/}" ]] || rm -f -- "$file" || return 1
    done
    for file in "$CONF"/*.json; do
      [[ -f "$file" ]] || continue
      mv -f "$file" "$live_conf/${file##*/}" || return 1
    done
  fi
  for file in "$SUB"/*; do
    [[ -f "$file" ]] || continue
    mv -f "$file" "$live_sub/${file##*/}" || return 1
  done
  mv -f "$STATE" "$live_state" || return 1
  ROOT="$live_root" STATE="$live_state" CONF="$live_conf" SUB="$live_sub" CERT="$live_cert"
  invalidate_state_cache
  if lite_mode; then
    rm -f "$SUB/clash.yaml" "$SUB/v2rayn_raw.txt" "$SUB/v2rayn.txt" "$SUB/sub.txt"
  else
    prune_stale_token_files "$(state_value token)" || return 1
  fi
  if [[ "$mode" == config ]]; then
    apply_protocol_firewall || return 1
  fi
)

rebuild_configs() {
  apply_state_change config :
}

render_configs() {
  ensure_state || return 1
  write_base_configs || return 1
  rm -f "$CONF"/{10..29}_*.json
  if [[ "$(proto_value mixed enabled false)" == "true" ]]; then
    write_mixed_config "$(proto_value mixed port)" "$(proto_value mixed username daimon)" "$(proto_value mixed password daimon)" || return 1
  fi
  if [[ "$(proto_value vless_reality enabled false)" == "true" ]]; then
    write_vless_config "$(proto_value vless_reality port)" "$(proto_value vless_reality uuid)" "$(proto_value vless_reality sni)" "$(proto_value vless_reality private_key)" "$(proto_value vless_reality short_id)" || return 1
  fi
  if [[ "$(proto_value vmess_ws enabled false)" == "true" ]]; then
    write_vmess_config "$(proto_value vmess_ws port)" "$(proto_value vmess_ws uuid)" "$(proto_value vmess_ws tls false)" || return 1
  fi
  if [[ "$(proto_value hysteria2 enabled false)" == "true" ]]; then
    write_hysteria2_config "$(proto_value hysteria2 port)" "$(proto_value hysteria2 password)" || return 1
  fi
  if [[ "$(proto_value tuic enabled false)" == "true" ]]; then
    write_tuic_config "$(proto_value tuic port)" "$(proto_value tuic uuid)" "$(proto_value tuic password)" || return 1
  fi
  if [[ "$(proto_value anytls enabled false)" == "true" ]]; then
    write_anytls_config "$(proto_value anytls port)" "$(proto_value anytls password)" || return 1
  fi
  if [[ "$(proto_value trojan enabled false)" == "true" ]]; then
    write_trojan_config "$(proto_value trojan port)" "$(proto_value trojan password)" || return 1
  fi
  if [[ "$(proto_value shadowsocks enabled false)" == "true" ]]; then
    write_shadowsocks_config "$(proto_value shadowsocks port)" "$(proto_value shadowsocks password)" "$(proto_value shadowsocks method aes-128-gcm)" || return 1
  fi
  if [[ "$(proto_value vmess_tcp enabled false)" == "true" ]]; then
    write_vmess_tcp_config "$(proto_value vmess_tcp port)" "$(proto_value vmess_tcp uuid)" || return 1
  fi
  if [[ "$(proto_value vmess_http enabled false)" == "true" ]]; then
    write_vmess_http_config "$(proto_value vmess_http port)" "$(proto_value vmess_http uuid)" "$(proto_value vmess_http path /vmess-http)" "$(proto_value vmess_http host "${SNI_OPTIONS[0]}")" || return 1
  fi
  generate_subscription
}

apply_protocol_firewall() {
  apply_saved_hopping_rules
  sync_ufw_ports || { fail "配置已保存，但防火墙同步失败，请检查端口放行后重新应用。"; return 1; }
  save_firewall_rules
}


public_ipv4() {
  local ip
  ip="$(curl -4fs --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  valid_ip_address "$ip" 4 && printf '%s' "$ip" || true
}

set_selected_protocol() {
  local proto="$1"
  shift
  set_protocol "$proto" "$@" "ip_version=$SELECTED_IP_VERSION" "endpoint_host=$SELECTED_ENDPOINT_HOST"
}

public_ipv6() {
  local ip
  ip="$(curl -6fs --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  valid_ip_address "$ip" 6 && printf '%s' "$ip" || true
}

status_cache_dir() {
  printf '%s/sing-box-daimon-%s' "${TMPDIR:-/tmp}" "${EUID:-$(id -u)}"
}

status_cache_fresh() {
  local file="$1" ttl="${2:-21600}" now mtime
  [[ -s "$file" ]] || return 1
  now="$(date +%s)"
  mtime="$(stat -c %Y "$file" 2>/dev/null || printf 0)"
  [[ "$mtime" =~ ^[0-9]+$ ]] && (( now - mtime < ttl ))
}

refresh_status_network_async() {
  local dir lock
  dir="$(status_cache_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  lock="$dir/network.lock"
  if status_cache_fresh "$dir/ipv4" && status_cache_fresh "$dir/ipv6"; then
    return 0
  fi
  acquire_async_lock "$lock" || return 0
  (
    local tmp4="$dir/ipv4.tmp" tmp6="$dir/ipv6.tmp"
    local pid4 pid6 value
    ( value="$(public_ipv4)"; printf '%s' "${value:-未知}" >"$tmp4" ) & pid4=$!
    ( value="$(public_ipv6)"; printf '%s' "${value:-未知}" >"$tmp6" ) & pid6=$!
    wait "$pid4" 2>/dev/null || true
    wait "$pid6" 2>/dev/null || true
    mv -f "$tmp4" "$dir/ipv4" 2>/dev/null || true
    mv -f "$tmp6" "$dir/ipv6" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
  ) &
}

status_cached_value() {
  local name="$1" dir
  dir="$(status_cache_dir)"
  [[ -s "$dir/$name" ]] && cat "$dir/$name"
  return 0
}

PUBLIC_IPS_DETECTED=false
PUBLIC_IPS_CHECKED=0
DETECTED_PUBLIC_IPV4=""
DETECTED_PUBLIC_IPV6=""
SELECTED_IP_VERSION=""
SELECTED_ENDPOINT_HOST=""
PROTOCOL_HOST=""
PROTOCOL_URL_HOST=""
PROTOCOL_VARIANT=""
PROTOCOL_ONLY=""

detect_public_ips() {
  local force="${1:-false}" now tmp pid4 pid6
  now="$(date +%s)"
  if [[ "$force" != "true" && "$PUBLIC_IPS_DETECTED" == "true" && "$PUBLIC_IPS_CHECKED" =~ ^[0-9]+$ ]] && (( now - PUBLIC_IPS_CHECKED <= 30 )); then
    [[ -n "$DETECTED_PUBLIC_IPV4" || -n "$DETECTED_PUBLIC_IPV6" ]]
    return
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-daimon-ip.XXXXXX")"
  ( public_ipv4 >"$tmp/ipv4" ) & pid4=$!
  ( public_ipv6 >"$tmp/ipv6" ) & pid6=$!
  wait "$pid4" 2>/dev/null || true
  wait "$pid6" 2>/dev/null || true
  DETECTED_PUBLIC_IPV4="$(<"$tmp/ipv4")"
  DETECTED_PUBLIC_IPV6="$(<"$tmp/ipv6")"
  rm -rf -- "$tmp"
  PUBLIC_IPS_DETECTED=true
  PUBLIC_IPS_CHECKED="$now"
  [[ -n "$DETECTED_PUBLIC_IPV4" || -n "$DETECTED_PUBLIC_IPV6" ]]
}

choose_node_ip_version() {
  local label="$1" choice input detected=false
  SELECTED_IP_VERSION=""
  SELECTED_ENDPOINT_HOST=""
  detect_public_ips true && detected=true
  if [[ -n "$DETECTED_PUBLIC_IPV4" && -n "$DETECTED_PUBLIC_IPV6" ]]; then
    printf "请选择 %s 客户端连接地址：\n1. 仅 IPv4  %s\n2. 仅 IPv6  %s\n3. IPv4 + IPv6\n4. 手动输入 IP 或域名\n0. 返回\n" "$label" "$DETECTED_PUBLIC_IPV4" "$DETECTED_PUBLIC_IPV6" >&2
    while true; do
      safe_read "请选择 [1-4，回车=3]: " choice || return 1
      choice="${choice:-3}"
      case "$choice" in
        0) menu_cancel ;;
        1) SELECTED_IP_VERSION=ipv4; return 0 ;;
        2) SELECTED_IP_VERSION=ipv6; return 0 ;;
        3) SELECTED_IP_VERSION=dual; return 0 ;;
        4) break ;;
        *) warn "请输入 1-4 的数字。" >&2 ;;
      esac
    done
  elif [[ -n "$DETECTED_PUBLIC_IPV4" ]]; then
    printf "请选择 %s 客户端连接地址：\n1. 检测到的 IPv4  %s\n2. 手动输入 IP 或域名\n0. 返回\n" "$label" "$DETECTED_PUBLIC_IPV4" >&2
    while true; do
      safe_read "请选择 [1-2，回车=1]: " choice || return 1
      choice="${choice:-1}"
      case "$choice" in
        0) menu_cancel ;;
        1) SELECTED_IP_VERSION=ipv4; return 0 ;;
        2) break ;;
        *) warn "请输入 1-2 的数字。" >&2 ;;
      esac
    done
  elif [[ -n "$DETECTED_PUBLIC_IPV6" ]]; then
    printf "请选择 %s 客户端连接地址：\n1. 检测到的 IPv6  %s\n2. 手动输入 IP 或域名\n0. 返回\n" "$label" "$DETECTED_PUBLIC_IPV6" >&2
    while true; do
      safe_read "请选择 [1-2，回车=1]: " choice || return 1
      choice="${choice:-1}"
      case "$choice" in
        0) menu_cancel ;;
        1) SELECTED_IP_VERSION=ipv6; return 0 ;;
        2) break ;;
        *) warn "请输入 1-2 的数字。" >&2 ;;
      esac
    done
  elif [[ "$detected" == "false" ]]; then
    warn "未检测到可用的公网 IPv4 或 IPv6，请手动输入客户端连接地址。" >&2
  fi
  while true; do
    safe_read "请输入客户端连接 IPv4、IPv6 或域名（0 返回）: " input || return 1
    [[ "$input" != 0 ]] || menu_cancel
    if SELECTED_ENDPOINT_HOST="$(endpoint_host_value "$input")"; then
      SELECTED_IP_VERSION=custom
      return 0
    fi
    warn "地址格式错误，请输入 IPv4、IPv6 或域名，不要包含协议、端口或路径。" >&2
  done
}

select_protocol_hosts() {
  local proto="$1" version endpoint_host
  endpoint_host="$(proto_value "$proto" endpoint_host "")"
  if [[ -n "$endpoint_host" ]]; then
    PROTOCOL_HOST="$endpoint_host"
  else
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
      dual)
        [[ -n "$DETECTED_PUBLIC_IPV4" && -n "$DETECTED_PUBLIC_IPV6" ]] || {
          fail "$proto 已选择 IPv4 + IPv6，但当前未同时检测到公网 IPv4 和 IPv6。" >&2
          return 1
        }
        if [[ "$PROTOCOL_VARIANT" == "ipv6" ]]; then
          PROTOCOL_HOST="$DETECTED_PUBLIC_IPV6"
        else
          PROTOCOL_HOST="$DETECTED_PUBLIC_IPV4"
        fi
        ;;
      *)
        PROTOCOL_HOST="${DETECTED_PUBLIC_IPV4:-$DETECTED_PUBLIC_IPV6}"
        ;;
    esac
  fi
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
  local endpoint_host
  endpoint_host="$(proto_value "$1" endpoint_host "")"
  [[ -n "$endpoint_host" ]] && { printf '自定义:%s' "$endpoint_host"; return; }
  case "$(proto_value "$1" ip_version auto)" in
    ipv4) printf 'IPv4' ;;
    ipv6) printf 'IPv6' ;;
    dual) printf 'IPv4+IPv6' ;;
    *) printf '自动' ;;
  esac
}

protocols_require_detected_host() {
  local proto
  for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls trojan shadowsocks vmess_tcp vmess_http; do
    if protocol_exists "$proto" && [[ -z "$(proto_value "$proto" endpoint_host "")" ]]; then
      return 0
    fi
  done
  return 1
}

protocols_require_certificate() {
  local proto
  for proto in hysteria2 tuic anytls trojan; do
    if [[ "$(proto_value "$proto" enabled false)" == "true" ]]; then
      return 0
    fi
  done
  [[ "$(proto_value vmess_ws enabled false)" == "true" && "$(proto_value vmess_ws tls false)" == "true" ]]
}

shared_custom_endpoint_host() {
  local proto host shared=""
  for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls trojan shadowsocks vmess_tcp vmess_http; do
    protocol_exists "$proto" || continue
    host="$(proto_value "$proto" endpoint_host "")"
    [[ -n "$host" ]] || return 1
    [[ -z "$shared" || "$shared" == "$host" ]] || return 1
    shared="$host"
  done
  [[ -n "$shared" ]] && printf '%s' "$shared"
}

server_host() {
  local host
  host="$(state_value sub_endpoint_host "")"
  [[ -n "$host" ]] || host="$(shared_custom_endpoint_host || true)"
  [[ -n "$host" ]] || host="$(public_ipv4)"
  [[ -n "$host" ]] || host="$(public_ipv6)"
  printf '%s' "${host:-未知地址}"
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

protocol_link_rows_base() {
  local host url_host
  if [[ "$(proto_value vless_reality enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == vless_reality ) ]]; then
    local port uuid sni public_key short_id
    select_protocol_hosts vless_reality || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    port="$(proto_value vless_reality port)"
    uuid="$(proto_value vless_reality uuid)"
    sni="$(proto_value vless_reality sni)"
    public_key="$(proto_value vless_reality public_key)"
    short_id="$(proto_value vless_reality short_id)"
    printf '%s\tvless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' "$(node_name vless_reality)" "$uuid" "$url_host" "$port" "$sni" "$public_key" "$short_id" "$(url_encode "$(node_name vless_reality)")"
  fi
  if [[ "$(proto_value vmess_ws enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == vmess_ws ) ]]; then
    local port uuid tls vmess
    select_protocol_hosts vmess_ws || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    port="$(proto_value vmess_ws port)"
    uuid="$(proto_value vmess_ws uuid)"
    tls="$(proto_value vmess_ws tls false)"
    vmess="$(python3 - "$host" "$port" "$uuid" "$tls" "$(node_name vmess_ws)" <<'PY'
import base64, json, sys
host, port, uuid, tls, name = sys.argv[1:]
data = {"v":"2","ps":name,"add":host,"port":port,"id":uuid,"aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"/vmess","tls":"tls" if tls == "true" else ""}
print(base64.b64encode(json.dumps(data, separators=(",", ":")).encode()).decode())
PY
)"
    printf '%s\tvmess://%s\n' "$(node_name vmess_ws)" "$vmess"
  fi
  if [[ "$(proto_value hysteria2 enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == hysteria2 ) ]]; then
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
    printf '%s\thysteria2://%s@%s:%s?security=tls&alpn=h3&sni=%s&insecure=1&allowInsecure=1&allow_insecure=1&hop_interval=30s%s#%s\n' "$(node_name hysteria2)" "$hy_password" "$url_host" "$hy_port" "$hy_sni" "$hy_mport" "$(url_encode "$(node_name hysteria2)")"
  fi
  if [[ "$(proto_value tuic enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == tuic ) ]]; then
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
    printf '%s\ttuic://%s@%s:%s?security=tls&sni=%s&alpn=h3&insecure=1&allowInsecure=1&allow_insecure=1&udp_relay_mode=native&congestion_control=bbr#%s\n' "$(node_name tuic)" "$tuic_auth" "$url_host" "$(proto_value tuic port)" "$tuic_sni" "$(url_encode "$(node_name tuic)")"
  fi
  if [[ "$(proto_value anytls enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == anytls ) ]]; then
    local any_sni any_port any_password
    select_protocol_hosts anytls || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    any_sni="$(proto_value anytls sni "${SNI_OPTIONS[0]}")"
    any_port="$(proto_value anytls port)"
    any_password="$(url_encode "$(proto_value anytls password)")"
    printf '%s\tanytls://%s@%s:%s?security=tls&sni=%s&insecure=1&allowInsecure=1&allow_insecure=1&fp=chrome#%s\n' "$(node_name anytls)" "$any_password" "$url_host" "$any_port" "$any_sni" "$(url_encode "$(node_name anytls)")"
  fi
  if [[ "$(proto_value trojan enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == trojan ) ]]; then
    local trojan_password trojan_sni
    select_protocol_hosts trojan || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    trojan_password="$(url_encode "$(proto_value trojan password)")"
    trojan_sni="$(proto_value trojan sni "${SNI_OPTIONS[0]}")"
    printf '%s\ttrojan://%s@%s:%s?security=tls&sni=%s&insecure=1&allowInsecure=1&allow_insecure=1&type=tcp#%s\n' "$(node_name trojan)" "$trojan_password" "$url_host" "$(proto_value trojan port)" "$trojan_sni" "$(url_encode "$(node_name trojan)")"
  fi
  if [[ "$(proto_value shadowsocks enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == shadowsocks ) ]]; then
    local ss_userinfo
    select_protocol_hosts shadowsocks || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    ss_userinfo="$(python3 - "$(proto_value shadowsocks method aes-128-gcm)" "$(proto_value shadowsocks password)" <<'PY'
import base64, sys
print(base64.urlsafe_b64encode(f"{sys.argv[1]}:{sys.argv[2]}".encode()).decode().rstrip("="), end="")
PY
)"
    printf '%s\tss://%s@%s:%s#%s\n' "$(node_name shadowsocks)" "$ss_userinfo" "$url_host" "$(proto_value shadowsocks port)" "$(url_encode "$(node_name shadowsocks)")"
  fi
  if [[ "$(proto_value vmess_tcp enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == vmess_tcp ) ]]; then
    local vmess_tcp
    select_protocol_hosts vmess_tcp || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    vmess_tcp="$(python3 - "$host" "$(proto_value vmess_tcp port)" "$(proto_value vmess_tcp uuid)" "$(node_name vmess_tcp)" <<'PY'
import base64, json, sys
host, port, uuid, name = sys.argv[1:]
data = {"v":"2","ps":name,"add":host,"port":port,"id":uuid,"aid":"0","scy":"auto","net":"tcp","type":"none","host":"","path":"","tls":""}
print(base64.b64encode(json.dumps(data, separators=(",", ":")).encode()).decode())
PY
)"
    printf '%s\tvmess://%s\n' "$(node_name vmess_tcp)" "$vmess_tcp"
  fi
  if [[ "$(proto_value vmess_http enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == vmess_http ) ]]; then
    local vmess_http
    select_protocol_hosts vmess_http || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    vmess_http="$(python3 - "$host" "$(proto_value vmess_http port)" "$(proto_value vmess_http uuid)" "$(proto_value vmess_http host "${SNI_OPTIONS[0]}")" "$(proto_value vmess_http path /vmess-http)" "$(node_name vmess_http)" <<'PY'
import base64, json, sys
host, port, uuid, http_host, path, name = sys.argv[1:]
data = {"v":"2","ps":name,"add":host,"port":port,"id":uuid,"aid":"0","scy":"auto","net":"http","type":"none","host":http_host,"path":path,"tls":""}
print(base64.b64encode(json.dumps(data, separators=(",", ":")).encode()).decode())
PY
)"
    printf '%s\tvmess://%s\n' "$(node_name vmess_http)" "$vmess_http"
  fi
  if [[ "$(proto_value mixed enabled false)" == "true" && ( -z "$PROTOCOL_ONLY" || "$PROTOCOL_ONLY" == mixed ) ]]; then
    local user pass auth
    select_protocol_hosts mixed || return 1
    host="$PROTOCOL_HOST"
    url_host="$PROTOCOL_URL_HOST"
    user="$(url_encode "$(proto_value mixed username daimon)")"
    pass="$(url_encode "$(proto_value mixed password daimon)")"
    auth="${user}:${pass}"
    printf '%s\tsocks5://%s@%s:%s#%s\n' "$(node_name mixed)" "$auth" "$url_host" "$(proto_value mixed port)" "$(url_encode "$(node_name mixed)")"
  fi
}


protocol_link_rows() {
  local only="${1:-}" proto
  PROTOCOL_ONLY="$only" PROTOCOL_VARIANT="" protocol_link_rows_base || return 1
  for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls trojan shadowsocks vmess_tcp vmess_http; do
    [[ -z "$only" || "$proto" == "$only" ]] || continue
    if [[ "$(proto_value "$proto" enabled false)" == "true" && "$(proto_value "$proto" ip_version auto)" == "dual" ]]; then
      PROTOCOL_ONLY="$proto" PROTOCOL_VARIANT=ipv6 protocol_link_rows_base || return 1
    fi
  done
}

generate_subscription() {
  if [[ "${CHANGE_STAGED:-false}" != true ]]; then
    apply_state_change subscription :
    return $?
  fi
  ensure_state || return 1
  ensure_dirs || return 1
  is_alpine || load_state_cache || true
  local token raw v2rayn_raw sub_file ipv4 ipv6 pin prefix
  detect_public_ips || true
  if protocols_require_detected_host && [[ -z "$DETECTED_PUBLIC_IPV4" && -z "$DETECTED_PUBLIC_IPV6" ]]; then
    fail "未检测到可用的公网 IPv4 或 IPv6，无法生成订阅。"
    return 1
  fi
  validate_protocol_hosts || return 1
  if lite_mode; then
    protocol_link_rows | cut -f2- >"$SUB/raw.txt" || return 1
    rm -f "$SUB/clash.yaml" "$SUB/v2rayn_raw.txt" "$SUB/v2rayn.txt" "$SUB/sub.txt"
    return
  fi
  token="$(state_value token)"
  ipv4="$DETECTED_PUBLIC_IPV4"
  ipv6="$DETECTED_PUBLIC_IPV6"
  pin=""
  prefix="$(node_prefix)"
  if protocols_require_certificate; then pin="$(cert_pin_sha256)" || return 1; fi
  raw="$SUB/raw.txt"
  v2rayn_raw="$SUB/v2rayn_raw.txt"
  sub_file="$SUB/sub.txt"
  protocol_link_rows | cut -f2- >"$raw" || return 1
  python3 - "$STATE" "$SUB/clash.yaml" "$v2rayn_raw" "$ipv4" "$ipv6" "$pin" "$CERT/self.crt" "$prefix" <<'PY' || return 1
import base64, json, sys, urllib.parse

state_path, clash_path, v2rayn_path, ipv4, ipv6, pin, cert_path, prefix = sys.argv[1:9]
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

base_protocols = {
    "Vless-reality": "vless_reality", "Vmess-ws": "vmess_ws",
    "Hysteria-2": "hysteria2", "Tuic-v5": "tuic", "Anytls": "anytls",
    "Trojan": "trojan", "Shadowsocks": "shadowsocks",
    "Vmess-tcp": "vmess_tcp", "Vmess-http": "vmess_http",
    "Mixed-SOCKS5": "mixed",
}

def node_name(base):
    name = f"{prefix}-{base}" if prefix else base
    return f"{name}-IPv4" if val(base_protocols[base], "ip_version", "auto") == "dual" else name

def val(name, key, default=""):
    return protos.get(name, {}).get(key, default)

def host_for(name):
    endpoint_host = val(name, "endpoint_host", "")
    if endpoint_host:
        return endpoint_host
    version = val(name, "ip_version", "auto")
    if version in ("ipv4", "dual"):
        if not ipv4:
            raise ValueError(f"{name} selected IPv4 but no public IPv4 was detected")
        if version == "dual" and not ipv6:
            raise ValueError(f"{name} selected dual stack but no public IPv6 was detected")
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
    if name.endswith("-IPv4"):
        base = name[len(prefix) + 1:] if prefix else name
        proto = base_protocols.get(base[:-5])
        if proto and val(proto, "ip_version", "auto") == "dual":
            ipv6_name = name[:-5] + "-IPv6"
            names.append(ipv6_name)
            proxies.append([f"  - name: {q(ipv6_name)}"] + [
                f"    server: {q(ipv6)}" if line.startswith("    server: ") else line
                for line in lines
            ])

if enabled("vless_reality"):
    add(node_name("Vless-reality"), [
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
    add(node_name("Vmess-ws"), [
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
    add(node_name("Hysteria-2"), lines)

if enabled("tuic"):
    add(node_name("Tuic-v5"), [
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
        "    heartbeat-interval: 10000",
        "    congestion-controller: bbr",
        f"    sni: {q(val('tuic', 'sni', 'www.bing.com'))}",
        "    skip-cert-verify: true",
    ])

if enabled("anytls"):
    add(node_name("Anytls"), [
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
    add(node_name("Trojan"), [
        "    type: trojan",
        f"    server: {q(host_for('trojan'))}",
        f"    port: {val('trojan', 'port')}",
        f"    password: {q(val('trojan', 'password'))}",
        f"    sni: {q(val('trojan', 'sni', 'www.bing.com'))}",
        "    skip-cert-verify: true",
        "    udp: true",
    ])

if enabled("shadowsocks"):
    add(node_name("Shadowsocks"), [
        "    type: ss",
        f"    server: {q(host_for('shadowsocks'))}",
        f"    port: {val('shadowsocks', 'port')}",
        f"    cipher: {q(val('shadowsocks', 'method', 'aes-128-gcm'))}",
        f"    password: {q(val('shadowsocks', 'password'))}",
        "    udp: true",
    ])

if enabled("vmess_tcp"):
    add(node_name("Vmess-tcp"), [
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
    add(node_name("Vmess-http"), [
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
    add(node_name("Mixed-SOCKS5"), [
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

def append_v2(proto, link):
    v2.append(link)
    if val(proto, "ip_version", "auto") != "dual":
        return
    if link.startswith("vmess://"):
        item = json.loads(base64.b64decode(link[8:]))
        item["add"] = ipv6
        item["ps"] = item["ps"][:-5] + "-IPv6"
        v2.append("vmess://" + b64(json.dumps(item, separators=(",", ":"), ensure_ascii=False)))
    elif link.startswith("v2rayn://"):
        scheme, encoded = link.rsplit("/", 1)
        item = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        item["Address"] = ipv6
        item["Remarks"] = item["Remarks"][:-5] + "-IPv6"
        v2.append(scheme + "/" + b64url_json(item))
    else:
        parts = urllib.parse.urlsplit(link)
        userinfo = parts.netloc.rsplit("@", 1)[0]
        name = urllib.parse.unquote(parts.fragment)[:-5] + "-IPv6"
        v2.append(parts._replace(
            netloc=f"{userinfo}@{uri_host(ipv6)}:{val(proto, 'port')}",
            fragment=u(name),
        ).geturl())

if enabled("vless_reality"):
    append_v2("vless_reality", "vless://{}@{}:{}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={}&fp=chrome&pbk={}&sid={}&type=tcp#{}".format(
        u(val("vless_reality", "uuid")), uri_host(host_for("vless_reality")), val("vless_reality", "port"), u(val("vless_reality", "sni")),
        u(val("vless_reality", "public_key")), u(val("vless_reality", "short_id")), u(node_name("Vless-reality"))))
if enabled("vmess_ws"):
    vm = {"v":"2","ps":node_name("Vmess-ws"),"add":host_for("vmess_ws"),"port":str(val("vmess_ws", "port")),"id":val("vmess_ws", "uuid"),"aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"/vmess","tls":"tls" if val("vmess_ws", "tls", False) is True else ""}
    append_v2("vmess_ws", "vmess://" + b64(json.dumps(vm, separators=(",", ":"), ensure_ascii=False)))
if enabled("hysteria2"):
    extra = {"UpMbps": 200, "DownMbps": 1000}
    hs, he = val("hysteria2", "hop_start"), val("hysteria2", "hop_end")
    if hs and he:
        extra["Ports"] = f"{hs}-{he}"
        extra["HopInterval"] = "30"
    item = {"ConfigType":7,"CoreType":24,"ConfigVersion":4,"Remarks":node_name("Hysteria-2"),"Address":host_for("hysteria2"),"Port":val("hysteria2", "port"),"Password":val("hysteria2", "password"),"StreamSecurity":"tls","AllowInsecure":"false","Sni":val("hysteria2", "sni", "www.bing.com"),"Alpn":"h3","Cert":cert,"ProtoExtraObj":extra}
    append_v2("hysteria2", "v2rayn://hysteria2/" + b64url_json(item))
if enabled("tuic"):
    item = {"ConfigType":8,"CoreType":24,"ConfigVersion":4,"Remarks":node_name("Tuic-v5"),"Address":host_for("tuic"),"Port":val("tuic", "port"),"Username":val("tuic", "uuid"),"Password":val("tuic", "password"),"StreamSecurity":"tls","AllowInsecure":"false","Sni":val("tuic", "sni", "www.bing.com"),"Alpn":"h3","Cert":cert,"ProtoExtraObj":{"CongestionControl":"bbr"}}
    append_v2("tuic", "v2rayn://tuic/" + b64url_json(item))
if enabled("anytls"):
    item = {"ConfigType":11,"CoreType":24,"ConfigVersion":4,"Remarks":node_name("Anytls"),"Address":host_for("anytls"),"Port":val("anytls", "port"),"Password":val("anytls", "password"),"StreamSecurity":"tls","AllowInsecure":"false","Sni":val("anytls", "sni", "www.bing.com"),"Fingerprint":"chrome","Cert":cert}
    append_v2("anytls", "v2rayn://anytls/" + b64url_json(item))
if enabled("trojan"):
    append_v2("trojan", "trojan://{}@{}:{}?security=tls&sni={}&insecure=1&allowInsecure=1&allow_insecure=1&type=tcp#{}".format(
        u(val("trojan", "password")), uri_host(host_for("trojan")), val("trojan", "port"), u(val("trojan", "sni", "www.bing.com")), u(node_name("Trojan"))))
if enabled("shadowsocks"):
    userinfo = base64.urlsafe_b64encode(f"{val('shadowsocks', 'method', 'aes-128-gcm')}:{val('shadowsocks', 'password')}".encode()).decode().rstrip("=")
    append_v2("shadowsocks", "ss://{}@{}:{}#{}".format(userinfo, uri_host(host_for("shadowsocks")), val("shadowsocks", "port"), u(node_name("Shadowsocks"))))
if enabled("vmess_tcp"):
    vm = {"v":"2","ps":node_name("Vmess-tcp"),"add":host_for("vmess_tcp"),"port":str(val("vmess_tcp", "port")),"id":val("vmess_tcp", "uuid"),"aid":"0","scy":"auto","net":"tcp","type":"none","host":"","path":"","tls":""}
    append_v2("vmess_tcp", "vmess://" + b64(json.dumps(vm, separators=(",", ":"), ensure_ascii=False)))
if enabled("vmess_http"):
    vm = {"v":"2","ps":node_name("Vmess-http"),"add":host_for("vmess_http"),"port":str(val("vmess_http", "port")),"id":val("vmess_http", "uuid"),"aid":"0","scy":"auto","net":"http","type":"none","host":val("vmess_http", "host", "www.bing.com"),"path":val("vmess_http", "path", "/vmess-http"),"tls":""}
    append_v2("vmess_http", "vmess://" + b64(json.dumps(vm, separators=(",", ":"), ensure_ascii=False)))
if enabled("mixed"):
    credentials = base64.b64encode(f"{val('mixed', 'username', 'daimon')}:{val('mixed', 'password', 'daimon')}".encode()).decode()
    append_v2("mixed", "socks://{}@{}:{}#{}".format(credentials, uri_host(host_for("mixed")), val("mixed", "port"), u(node_name("Mixed-SOCKS5"))))
open(v2rayn_path, "w", encoding="utf-8").write("\n".join(v2) + ("\n" if v2 else ""))
PY
  b64 <"$v2rayn_raw" >"$SUB/v2rayn.txt" || return 1
  cp "$SUB/v2rayn.txt" "$sub_file" || return 1
  cp "$sub_file" "$SUB/$token" || return 1
  cp "$SUB/v2rayn.txt" "$SUB/$token.v2rayn" || return 1
  cp "$SUB/clash.yaml" "$SUB/$token.clash" || return 1
  cp "$raw" "$SUB/$token.raw" || return 1
  prune_stale_token_files "$token"
}

# Token-named copies persist until explicitly deleted. The menu removes the
# previous set when the user changes the token, but ensure_state also rotates an
# invalid token, which would leave the old subscription readable on disk. Prune
# on every generation so only the active token's files remain.
prune_stale_token_files() {
  local token="$1" path base
  [[ -d "$SUB" ]] || return 0
  for path in "$SUB"/*; do
    [[ -f "$path" ]] || continue
    base="${path##*/}"
    case "$base" in
      raw.txt|sub.txt|clash.yaml|v2rayn.txt|v2rayn_raw.txt) continue ;;
      "$token"|"$token".v2rayn|"$token".clash|"$token".raw) continue ;;
    esac
    rm -f -- "$path"
  done
  return 0
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
  local show_qr_codes="${1:-true}" only="${2:-}" label link found=0
  while IFS=$'\t' read -r label link; do
    [[ -n "${link:-}" ]] || continue
    found=1
    title "【 $label 】"
    printf "${MAGENTA}%s${NC}\n" "$link"
    [[ "$show_qr_codes" == "true" ]] && show_qr "$link"
    printf "\n"
  done < <(protocol_link_rows "$only")
  (( found == 1 )) || printf "暂无协议链接。\n\n"
}

write_sub_server() {
  ensure_state || return 1
  cat >"$SUB_SERVER" <<EOF || return 1
#!/usr/bin/env python3
import http.server
import json
import pathlib
import socket
import socketserver
from urllib.parse import urlparse

ROOT = pathlib.Path("$ROOT")
STATE = ROOT / "state.json"
SUB = ROOT / "sub"

def read_state():
    try:
        with open(STATE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}

class Handler(http.server.BaseHTTPRequestHandler):
    def send_subscription(self, send_body=True):
        token = read_state().get("token", "")
        if not token:
            self.send_response(503)
            self.end_headers()
            return
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
        try:
            data = (SUB / file_name).read_bytes()
        except OSError:
            self.send_response(404)
            self.end_headers()
            return
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
    daemon_threads = True

# Dual-stack: bind :: with V6ONLY off so one socket serves IPv4 and IPv6.
# IPv6-only VPS links are generated as http://[addr]:port/..., which a
# 0.0.0.0-only socket can never answer. Fall back to IPv4 if IPv6 is absent.
class DualStackTCPServer(ReuseTCPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except (AttributeError, OSError):
            pass
        ReuseTCPServer.server_bind(self)

try:
    port = int(read_state().get("sub_port", 2096))
except (TypeError, ValueError):
    port = 2096
if not 1 <= port <= 65535:
    port = 2096

try:
    httpd = DualStackTCPServer(("::", port), Handler)
except OSError:
    httpd = ReuseTCPServer(("0.0.0.0", port), Handler)
with httpd:
    httpd.serve_forever()
EOF
  chmod +x "$SUB_SERVER"
}

# A downloaded script is installed only when it is complete and parses: a
# truncated download or an HTML error page must never replace the manager.
valid_script_file() {
  local file="$1"
  [[ -s "$file" ]] && bash -n "$file" 2>/dev/null &&
    grep -q '^SCRIPT_VERSION="[^"]\+"' "$file"
}

write_managed_script() {
  local src tmp
  src="$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$SCRIPT_SOURCE")"
  # Running from the installed copy (sb / sing-box shortcuts): it is already in
  # place. This used to fall through to a download, silently replacing the
  # running version with whatever was on GitHub.
  if [[ "$src" == "$SCRIPT" && -s "$SCRIPT" ]]; then
    chmod 0755 "$SCRIPT"
    return 0
  fi
  if [[ -r "$src" ]] && valid_script_file "$src"; then
    install -m 0755 "$src" "$SCRIPT"
    return
  fi
  tmp="$(mktemp "$ROOT/.sb.sh.XXXXXX")" || return 1
  if curl -fsSL --max-time 60 "$SCRIPT_URL" -o "$tmp" && valid_script_file "$tmp"; then
    install -m 0755 "$tmp" "$SCRIPT"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  fail "管理脚本下载失败或内容不完整，未覆盖现有脚本。"
  return 1
}

# Point a shortcut at the managed script only when it is free or already ours.
# Something else at /usr/local/bin/sing-box may be a real sing-box binary.
link_shortcut_if_managed() {
  local link="$1"
  if [[ -e "$link" || -L "$link" ]] && [[ "$(readlink -f "$link" 2>/dev/null || true)" != "$SCRIPT" ]]; then
    return 0
  fi
  ln -sf "$SCRIPT" "$link"
}

managed_service_exists() {
  local name="$1"
  if is_alpine; then
    [[ -x "/etc/init.d/$name" ]]
  else
    [[ "$(systemctl show -p LoadState --value "$name.service" 2>/dev/null)" == loaded ]]
  fi
}

managed_service_enable() {
  if is_alpine; then
    rc-update add "$1" default >/dev/null 2>&1
  else
    systemctl enable "$1" >/dev/null 2>&1
  fi
}

managed_service_disable_now() {
  if is_alpine; then
    rc-service "$1" stop >/dev/null 2>&1 || true
    rc-update del "$1" default >/dev/null 2>&1 || true
  else
    systemctl disable --now "$1" >/dev/null 2>&1 || true
  fi
}

managed_service_start() {
  if is_alpine; then rc-service "$1" start; else systemctl start "$1"; fi
}

managed_service_stop() {
  if is_alpine; then rc-service "$1" stop; else systemctl stop "$1"; fi
}

managed_service_restart() {
  if is_alpine; then rc-service "$1" restart; else systemctl restart "$1"; fi
}

managed_service_active() {
  if is_alpine; then
    rc-service "$1" status >/dev/null 2>&1
  else
    systemctl is-active --quiet "$1"
  fi
}

managed_service_status() {
  if is_alpine; then rc-service "$1" status; else systemctl status "$1" --no-pager; fi
}

managed_service_enable_only() {
  if is_alpine; then rc-update add "$1" default; else systemctl enable "$1"; fi
}

managed_service_disable_only() {
  if is_alpine; then rc-update del "$1" default; else systemctl disable "$1"; fi
}

write_services() {
  local mode="${1:-standard}"
  if is_alpine; then
    [[ "$mode" == "lite" ]] || { fail "Alpine 仅支持 NAT 轻量 VLESS Reality 安装。"; return 1; }
    cat >"$SERVICE" <<EOF || return 1
#!/sbin/openrc-run
name="sing-box"
description="sing-box NAT lite service"
command="$BIN"
command_args="run -C $CONF"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
output_log="$LOG/sing-box.log"
error_log="$LOG/sing-box.log"

depend() {
  need net
  after firewall
}
EOF
    chmod 0755 "$SERVICE"
    managed_service_disable_now sing-box-sub
    rm -f "$SUB_SERVICE" "$SUB_SERVER"
    return
  fi
  cat >"$SERVICE" <<EOF || return 1
[Unit]
Description=sing-box service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
ExecStartPre=-/bin/bash $SCRIPT --apply-hopping
ExecStart=$BIN run -C $CONF
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  if [[ "$mode" == "standard" ]]; then
    cat >"$SUB_SERVICE" <<EOF || return 1
[Unit]
Description=sing-box daimon subscription service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 $SUB_SERVER
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  else
    systemctl disable --now sing-box-sub >/dev/null 2>&1 || true
    rm -f "$SUB_SERVICE" "$SUB_SERVER"
  fi
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

ca_certificates_ready() {
  [[ -s /etc/ssl/certs/ca-certificates.crt ]]
}

lite_dependencies_ready() {
  local cmd
  if is_alpine; then
    for cmd in bash curl jq apk rc-service rc-update; do
      has_cmd "$cmd" || return 1
    done
    ca_certificates_ready
    return
  fi
  for cmd in curl tar gzip python3 ss; do
    has_cmd "$cmd" || return 1
  done
  ! dpkg_python_broken || return 1
  ca_certificates_ready
}

# An older NAT installer could leave python3 unpacked but unconfigured. The
# binary still runs, yet every later apt-get stops on unmet dependencies.
dpkg_python_broken() {
  local status
  has_cmd dpkg-query || return 1
  status="$(dpkg-query -W -f='${db:Status-Abbrev}' python3 2>/dev/null || true)"
  [[ -n "$status" && "$status" != ii* ]]
}

standard_dependencies_ready() {
  local cmd
  for cmd in curl tar gzip python3 ss openssl; do
    has_cmd "$cmd" || return 1
  done
  ! dpkg_python_broken || return 1
  ca_certificates_ready
}

standard_missing_apt_packages() {
  has_cmd curl || printf '%s\n' curl
  has_cmd tar || printf '%s\n' tar
  has_cmd gzip || printf '%s\n' gzip
  has_cmd python3 && ! dpkg_python_broken || printf '%s\n' python3
  has_cmd ss || printf '%s\n' iproute2
  has_cmd openssl || printf '%s\n' openssl
  ca_certificates_ready || printf '%s\n' ca-certificates
}

# Hopping is a NAT REDIRECT; minimal Debian 12 images ship nftables without the
# iptables front end, and the rules used to fail silently.
ensure_hopping_tools() {
  has_cmd iptables && return 0
  info "跳跃端口需要 iptables，正在安装..." >&2
  if has_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables >&2 ||
      { apt-get update >&2 && DEBIAN_FRONTEND=noninteractive apt-get install -y iptables >&2; } || true
  elif has_cmd dnf; then
    dnf install -y iptables >&2 || true
  elif has_cmd yum; then
    yum install -y iptables >&2 || true
  fi
  has_cmd iptables && return 0
  fail "iptables 安装失败，无法开启跳跃端口。" >&2
  return 1
}

install_optional_qrencode() {
  has_cmd qrencode && return 0
  if has_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode || true
  elif has_cmd dnf; then
    dnf install -y qrencode || true
  elif has_cmd yum; then
    yum install -y qrencode || true
  fi
  if has_cmd qrencode; then
    info "二维码工具 qrencode 已安装。"
  else
    warn "qrencode 安装失败，仅无法在终端显示二维码，不影响节点使用。"
  fi
}

install_alpine_lite_dependencies() {
  local package tmp
  local required=(bash curl ca-certificates jq)
  local missing=()
  local installed=()
  ensure_dirs || return 1
  for package in "${required[@]}"; do
    apk info -e "$package" >/dev/null 2>&1 || missing+=("$package")
  done
  if ((${#missing[@]})); then
    info "正在安装 Alpine NAT 最小依赖：${missing[*]}"
    apk add --no-cache "${missing[@]}" || {
      fail "Alpine NAT 最小依赖安装失败。"
      return 1
    }
    sync
    sleep 1
    installed=("${missing[@]}")
  fi
  if ((${#installed[@]})); then
    tmp="$(mktemp "$ROOT/.alpine-packages.XXXXXX")"
    { [[ ! -s "$ALPINE_PACKAGES" ]] || cat "$ALPINE_PACKAGES"; printf '%s\n' "${installed[@]}"; } |
      awk 'NF && !seen[$0]++' >"$tmp"
    mv -f "$tmp" "$ALPINE_PACKAGES"
  fi
  lite_dependencies_ready || {
    fail "Alpine NAT 必需依赖仍不完整。"
    return 1
  }
}

debian_dep_satisfied() {
  local name="$1" op="${2:-}" want="${3:-}" status version
  status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$name" 2>/dev/null || true)"
  [[ "$status" == ii* ]] || return 1
  [[ -n "$op" ]] || return 0
  version="$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null)" || return 1
  dpkg --compare-versions "$version" "$op" "$want"
}

# Candidates for one dependency name: the package itself, else its providers.
debian_dep_candidates() {
  awk -F'\t' -v n="$2" '
    $1 == n { print $1; found = 1; exit }
    { k = split($5, p, /, */); for (i = 1; i <= k; i++) { sub(/ .*/, "", p[i]); if (p[i] == n) prov[++c] = $1 } }
    END { if (!found) for (i = 1; i <= c; i++) print prov[i] }
  ' "$1"
}

# A fixed package list broke whenever the base image lacked one dependency
# (Debian 12 minimal has no libnsl2/libtirpc3), leaving python3 unconfigured.
# Resolve the python3 closure from the streamed index instead; apt-get update
# is what NAT machines with 64 MB cannot afford.
download_debian_lite_packages() {
  local cache="$1" arch codename base index pkg line filename checksum deps group alt name op want cand target resolved
  local queue=(python3) seen=" " groups alts candidates
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
  [[ -n "$arch" && -n "$codename" ]] || return 1
  base="https://deb.debian.org/debian"
  index="$cache/Packages.index"
  curl -fLsS --limit-rate 2M "$base/dists/$codename/main/binary-$arch/Packages.gz" | gzip -dc |
    awk 'BEGIN { RS = ""; FS = "\n"; OFS = "\t" }
      {
        p = f = s = d = v = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^Package: /) p = substr($i, 10)
          else if ($i ~ /^Filename: /) f = substr($i, 11)
          else if ($i ~ /^SHA256: /) s = substr($i, 9)
          else if ($i ~ /^(Pre-)?Depends: /) { x = $i; sub(/^[^:]*: /, "", x); d = d == "" ? x : d ", " x }
          else if ($i ~ /^Provides: /) v = substr($i, 11)
        }
        if (p != "" && f != "" && s != "") print p, f, s, d, v
      }' >"$index" || return 1
  while ((${#queue[@]})); do
    pkg="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ "$seen" != *" $pkg "* ]] || continue
    seen+="$pkg "
    line="$(awk -F'\t' -v p="$pkg" '$1 == p { print; exit }' "$index")"
    [[ -n "$line" ]] || { warn "软件源中找不到依赖包: $pkg" >&2; return 1; }
    IFS=$'\t' read -r _ filename checksum deps _ <<<"$line"
    target="$cache/${filename##*/}"
    curl -fLsS --limit-rate 1M "$base/$filename" -o "$target" || return 1
    printf '%s  %s\n' "$checksum" "$target" | sha256sum -c - >/dev/null 2>&1 || return 1
    sync
    IFS=',' read -ra groups <<<"$deps"
    for group in "${groups[@]}"; do
      resolved=""
      candidates=()
      IFS='|' read -ra alts <<<"$group"
      for alt in "${alts[@]}"; do
        read -r name op want <<<"${alt//[()]/ }"
        name="${name%%:*}"
        [[ -n "$name" ]] || continue
        if debian_dep_satisfied "$name" "$op" "$want"; then resolved=1; break; fi
        while IFS= read -r cand; do
          [[ -n "$cand" ]] || continue
          [[ "$cand" == "$name" ]] || ! debian_dep_satisfied "$cand" || { resolved=1; break 2; }
          candidates+=("$cand")
        done < <(debian_dep_candidates "$index" "$name")
      done
      [[ -z "$resolved" ]] || continue
      ((${#candidates[@]})) || { warn "无法解析依赖: $group" >&2; return 1; }
      queue+=("${candidates[0]}")
    done
  done
  rm -f "$index"
}

download_apt_lite_packages() {
  local cache="$1"
  shift
  DEBIAN_FRONTEND=noninteractive apt-get \
    -o "Dir::Cache::archives=$cache/" \
    -o APT::Install-Recommends=false \
    -o APT::Install-Suggests=false \
    install -y --download-only "$@"
}

install_apt_lite_dependencies() {
  local cache stale deb package status attempt audit os_id
  local packages=(curl tar gzip python3 iproute2 ca-certificates)
  local debs=()
  mkdir -p "$ROOT"
  audit="$(dpkg --audit 2>/dev/null || true)"
  if [[ -n "$audit" ]]; then
    dpkg --configure -a >/dev/null 2>&1 || true
    audit="$(dpkg --audit 2>/dev/null || true)"
  fi
  # On Debian the resolver below refetches unconfigured packages together with
  # whatever they lack, which is how an interrupted earlier install is repaired.
  [[ -z "$audit" || "$(system_id)" == debian ]] || {
    fail "dpkg 存在未完成事务，请先执行 dpkg --configure -a。"
    return 1
  }
  while IFS= read -r stale; do
    [[ "$stale" == "$ROOT"/.packages.* ]] && rm -rf -- "$stale"
  done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name '.packages.*' -print 2>/dev/null)
  cache="$(mktemp -d "$ROOT/.packages.XXXXXX")" || {
    fail "无法创建依赖下载目录。"
    return 1
  }
  mkdir -p "$cache/partial"
  info "正在以低内存方式下载 NAT 必需依赖..."
  os_id="$(system_id)"
  if [[ "$os_id" == "debian" ]]; then
    download_debian_lite_packages "$cache" || {
      rm -rf -- "$cache"
      fail "Debian 轻量依赖下载或校验失败。"
      return 1
    }
  elif ! download_apt_lite_packages "$cache" "${packages[@]}"; then
    rm -rf -- "$cache"
    fail "低内存依赖下载失败。请确认系统已有可用的软件包索引。"
    return 1
  fi
  mapfile -t debs < <(find "$cache" -maxdepth 1 -type f -name '*.deb' -print | sort)
  for ((attempt = 0; attempt <= ${#debs[@]}; attempt++)); do
    for deb in "${debs[@]}"; do
      package="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
      [[ -n "$package" ]] || continue
      status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
      [[ "$status" == ii* ]] && continue
      dpkg -i "$deb" >/dev/null 2>&1 || true
    done
    dpkg --configure -a >/dev/null 2>&1 || true
    if lite_dependencies_ready && [[ -z "$(dpkg --audit 2>/dev/null || true)" ]]; then
      rm -rf -- "$cache"
      info "NAT 轻量依赖已安装。"
      return 0
    fi
  done
  rm -rf -- "$cache"
  fail "NAT 轻量依赖安装不完整。"
  return 1
}

install_dependencies() {
  local mode="${1:-standard}"
  local packages=()
  local rpm_packages=(curl tar gzip python3 iproute ca-certificates openssl)
  if [[ "$mode" == "lite" ]]; then
    if lite_dependencies_ready; then
      info "NAT 必需依赖已齐全，跳过包管理器。"
      return 0
    fi
    if is_alpine; then
      install_alpine_lite_dependencies || return 1
    elif has_cmd apt-get; then
      install_apt_lite_dependencies || return 1
    elif has_cmd dnf; then
      dnf install -y --setopt=install_weak_deps=False "${rpm_packages[@]:0:6}"
    elif has_cmd yum; then
      yum install -y "${rpm_packages[@]:0:6}"
    else
      fail "缺少 NAT 必需依赖，且未识别可用的包管理器。"
      return 1
    fi
    lite_dependencies_ready || {
      fail "NAT 必需依赖仍不完整。"
      return 1
    }
    return 0
  fi
  if standard_dependencies_ready; then
    info "Sing-box 必需依赖已齐全，跳过包管理器。"
    install_optional_qrencode
    return 0
  fi
  if has_cmd apt-get; then
    mapfile -t packages < <(standard_missing_apt_packages)
    if dpkg_python_broken; then
      dpkg --configure -a || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y -f || true
    fi
    if ! apt-get update; then
      warn "APT 索引更新失败，将使用已成功更新或现有的可信索引继续安装，不会降低签名验证。"
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"; then
      fail "Sing-box 必需依赖安装失败。请修复上方报错的 APT 软件源后重试。"
      return 1
    fi
  elif has_cmd dnf; then
    dnf install -y "${rpm_packages[@]}"
  elif has_cmd yum; then
    yum install -y "${rpm_packages[@]}"
  else
    fail "未识别包管理器，且 Sing-box 必需依赖不完整。"
    return 1
  fi
  standard_dependencies_ready || {
    fail "Sing-box 必需依赖仍不完整，请检查 curl、tar、gzip、openssl、python3、ss 和 CA 证书。"
    return 1
  }
  install_optional_qrencode
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
  # acme.sh standalone listens on IPv4 only unless told otherwise, so an
  # IPv6-only host (AAAA record only) could never pass the HTTP-01 challenge.
  local listen_opts=()
  if host_has_ipv6 && [[ -z "$(public_ipv4)" ]]; then
    listen_opts=(--listen-v6)
  fi
  if ! "$acme" --issue -d "$domain" --standalone "${listen_opts[@]}" --server letsencrypt --force; then
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

host_has_ipv6() {
  # procfs reports size 0, so -s is always false here; look for an entry.
  grep -q . /proc/net/if_inet6 2>/dev/null
}

write_nginx_subscription_config() {
  local domain="$1" port="$2" dir listen80_v6="" listen443_v6=""
  dir="$(subscription_cert_dir "$domain")"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  # IPv4-only listeners left https://domain/sub/... unreachable over IPv6.
  # Only add [::] when the kernel has IPv6, or nginx fails to bind.
  if host_has_ipv6; then
    listen80_v6="
    listen [::]:80;"
    listen443_v6="
    listen [::]:443 ssl http2;"
  fi
  cat >"$NGINX_SUB_CONF" <<EOF || return 1
server {
    listen 80;$listen80_v6
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;$listen443_v6
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

remove_subscription_cert() {
  local domain="$1" acme dir
  valid_domain "$domain" || return 1
  acme="$(acme_bin)"
  [[ ! -x "$acme" ]] || "$acme" --remove -d "$domain" >/dev/null 2>&1 || return 1
  dir="$(subscription_cert_dir "$domain")"
  if [[ -d "$dir" ]]; then
    [[ "$(readlink -f "$dir")" == "/root/domain/$domain" ]] || return 1
    rm -rf -- "$dir"
  fi
}

remove_subscription_nginx_and_cert() {
  local domain="${1:-}"
  rm -f "$NGINX_SUB_CONF" "$NGINX_SUB_LINK" || return 1
  [[ -z "$domain" ]] || remove_subscription_cert "$domain" || return 1
  if has_cmd nginx; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
}

set_https_state() {
  set_state_value sub_domain "$1" && set_state_value sub_tls "$2"
}

configure_https_subscription_domain() {
  local domain="$1" port email old_domain
  valid_domain "$domain" || { fail "域名格式不正确。"; return 1; }
  port="$(state_value sub_port 2096)"
  email="admin@$domain"
  old_domain="$(state_value sub_domain "")"
  install_nginx_acme_deps || return 1
  ensure_acme "$email" || return 1
  prepare_https_ufw_for_acme || return 1
  if ! issue_subscription_cert "$domain"; then
    fail "证书申请失败，原 HTTPS 订阅配置未修改。"
    rollback_https_ufw_for_acme
    return 1
  fi
  if ! write_nginx_subscription_config "$domain" "$port" ||
     ! apply_state_change subscription set_https_state "$domain" true; then
    fail "HTTPS 订阅配置失败，正在恢复原域名配置。"
    if [[ -n "$old_domain" ]]; then
      write_nginx_subscription_config "$old_domain" "$port" || warn "原 nginx 配置恢复失败，请检查日志。"
    fi
    rollback_https_ufw_for_acme
    return 1
  fi
  if [[ -n "$old_domain" && "$old_domain" != "$domain" ]]; then
    remove_subscription_cert "$old_domain" || warn "旧域名证书清理失败，新订阅已配置。"
  fi
  sync_ufw_ports || return 1
  HTTPS_UFW_BOOTSTRAP=()
  info "HTTPS 订阅域名已配置: https://$domain/sub/$(state_value token)"
}

delete_https_subscription_domain() {
  local domain
  domain="$(state_value sub_domain "")"
  [[ -n "$domain" ]] || { warn "当前未设置 HTTPS 订阅域名。"; return 0; }
  remove_subscription_nginx_and_cert "$domain" || { fail "HTTPS 配置清理失败，请检查 nginx 和证书状态。"; return 1; }
  apply_state_change subscription set_https_state "" false || { fail "HTTPS 配置已清理，但订阅状态更新失败，请重试。"; return 1; }
  sync_ufw_ports || { fail "HTTPS 配置已删除，但防火墙同步失败。"; return 1; }
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

# The unauthenticated GitHub API allows 60 requests/hour per IP, which a shared
# or NAT address can exhaust, making installs fail with no usable error. Fall
# back to resolving the /releases/latest redirect, which has no such limit.
core_download_url() {
  local arch="$1" url version redirect
  url="$(curl -fsSL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
    python3 -c '
import json, sys
try:
    release = json.load(sys.stdin)
    suffix = "-linux-" + sys.argv[1] + ".tar.gz"
    for asset in release.get("assets", []):
        url = asset.get("browser_download_url", "")
        if url.startswith("https://") and url.endswith(suffix):
            print(url)
            break
except (ValueError, TypeError, AttributeError):
    pass
' "$arch" || true)"
  if [[ -n "$url" ]]; then
    printf '%s' "$url"
    return 0
  fi
  redirect="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 15 \
    https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)"
  version="${redirect##*/tag/v}"
  [[ -n "$version" && "$version" != "$redirect" && "$version" =~ ^[0-9][0-9A-Za-z.\-]*$ ]] || return 0
  printf 'https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-linux-%s.tar.gz' \
    "$version" "$version" "$arch"
  return 0
}

alpine_upstream_core() {
  local dir="$1" arch redirect version
  arch="$(arch_name)" || return 1
  redirect="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 15     https://github.com/SagerNet/sing-box/releases/latest)" || return 1
  version="${redirect##*/tag/v}"
  [[ "$version" != "$redirect" && "$version" =~ ^[0-9][0-9A-Za-z.-]*$ ]] || return 1
  curl -fLsS --limit-rate 1M     "https://github.com/SagerNet/sing-box/releases/download/v$version/sing-box-$version-linux-$arch-musl.tar.gz" |
    tar -xzf - -C "$dir" || return 1
  mv -f "$dir/sing-box-$version-linux-$arch-musl/sing-box" "$dir/sing-box"
}

download_core() {
  local mode="${1:-standard}" arch url tmp file lib stale
  if is_alpine; then
    [[ "$mode" == "lite" ]] || {
      fail "Alpine 仅支持 NAT 轻量内核安装。"
      return 1
    }
    while IFS= read -r stale; do
      [[ "$stale" == "$ROOT"/.download.* ]] && rm -rf -- "$stale"
    done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name '.download.*' -print 2>/dev/null)
    tmp="$(mktemp -d "$ROOT/.download.XXXXXX")" || {
      fail "无法创建 Alpine sing-box 下载目录。"
      return 1
    }
    local repository version marker sync_pid
    repository="$(awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      /\/community[[:space:]]*$/ { print $NF; exit }
    ' "$APK_REPOSITORIES")"
    arch="$(apk --print-arch)"
    [[ -n "$repository" && -n "$arch" ]] || {
      rm -rf -- "$tmp"
      fail "未找到 Alpine community 仓库或系统架构。"
      return 1
    }
    version="$(curl -fLsS --limit-rate 2M "$repository/$arch/APKINDEX.tar.gz" |
      tar -xzO APKINDEX |
      awk 'BEGIN { RS=""; FS="\n" }
        !found && $0 ~ /(^|\n)P:sing-box(\n|$)/ {
          for (i=1; i<=NF; i++) if ($i ~ /^V:/) { print substr($i, 3); found=1; break }
        }
      ')"
    if [[ -z "$version" ]]; then
      # Alpine packages sing-box only from 3.23 on; older releases take the
      # upstream musl build over HTTPS, as the Debian path does.
      info "Alpine community 仓库中没有 sing-box，改用官方 musl 构建..."
      alpine_upstream_core "$tmp" || {
        rm -rf -- "$tmp"
        fail "sing-box 官方 musl 内核下载或解压失败。"
        return 1
      }
      file="$tmp/sing-box"
    else
      url="$repository/$arch/sing-box-$version.apk"
      info "正在以最低内存方式安装 Alpine sing-box $version..."
      if ! curl -fLsS --limit-rate 1M "$url" -o "$tmp/sing-box.apk"; then
        rm -rf -- "$tmp"
        fail "Alpine sing-box 包下载失败。"
        return 1
    fi
    sync
    if ! apk verify "$tmp/sing-box.apk" >/dev/null 2>&1; then
      rm -rf -- "$tmp"
      fail "Alpine sing-box 包签名校验失败。"
      return 1
    fi
    marker="$tmp/.sync"
    : >"$marker"
    ( while [[ -e "$marker" ]]; do sync; sleep 1; done ) &
    sync_pid=$!
    if ! curl -fLsS --limit-rate 512K "file://$tmp/sing-box.apk" |
      tar -xzf - -C "$tmp" usr/bin/sing-box; then
      rm -f "$marker"
      wait "$sync_pid" 2>/dev/null || true
      rm -rf -- "$tmp"
      fail "Alpine sing-box 内核提取失败。"
      return 1
    fi
    rm -f "$marker"
    wait "$sync_pid" 2>/dev/null || true
    file="$tmp/usr/bin/sing-box"
    rm -f "$tmp/sing-box.apk"
    fi
    sync
    chmod 0755 "$file" || {
      rm -rf -- "$tmp"
      fail "无法设置 Alpine sing-box 内核权限。"
      return 1
    }
    "$file" version >/dev/null 2>&1 || {
      rm -rf -- "$tmp"
      fail "Alpine sing-box 原生内核无法执行。"
      return 1
    }
    mv -f "$file" "$BIN" || {
      rm -rf -- "$tmp"
      fail "无法原子安装 Alpine sing-box 内核。"
      return 1
    }
    chmod 0755 "$BIN"
    rm -rf -- "$tmp"
    return
  fi
  arch="$(arch_name)"
  while IFS= read -r stale; do
    [[ "$stale" == "$ROOT"/.download.* ]] && rm -rf -- "$stale"
  done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name '.download.*' -print 2>/dev/null)
  tmp="$(mktemp -d "$ROOT/.download.XXXXXX")" || {
    fail "无法创建 sing-box 下载目录。"
    return 1
  }
  url="$(core_download_url "$arch")"
  if [[ -z "$url" ]]; then
    rm -rf "$tmp"
    fail "未找到 sing-box 下载地址。请确认网络可访问 GitHub 后重试。"
    return 1
  fi
  if [[ "$mode" == "lite" ]]; then
    info "正在以最低内存方式流式安装 sing-box 内核..."
    if ! curl -fLsS --limit-rate 1M "$url" |
      tar --checkpoint=100 --checkpoint-action=exec='sync' -xzf - -C "$tmp" --wildcards '*/sing-box'; then
      rm -rf -- "$tmp"
      fail "sing-box 内核流式下载或解压失败。"
      return 1
    fi
  else
    if ! curl -fL "$url" -o "$tmp/sing-box.tar.gz"; then
      rm -rf -- "$tmp"
      fail "sing-box 内核下载失败。"
      return 1
    fi
    if ! tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"; then
      rm -rf -- "$tmp"
      fail "sing-box 内核解压失败。"
      return 1
    fi
  fi
  file="$(find "$tmp" -type f -name sing-box | head -n1)"
  if [[ -z "$file" ]]; then
    rm -rf "$tmp"
    fail "压缩包内未找到 sing-box。"
    return 1
  fi
  lib="$(find "$tmp" -type f -name libcronet.so | head -n1)"
  [[ "$mode" == "lite" ]] || rm -f "$tmp/sing-box.tar.gz"
  sync
  [[ "$mode" == "lite" ]] && sleep 1
  if ! chmod 0755 "$file"; then
    rm -rf "$tmp"
    fail "无法设置 sing-box 内核执行权限。"
    return 1
  fi
  if ! "$file" version >/dev/null 2>&1; then
    rm -rf "$tmp"
    fail "sing-box 内核无法执行，请检查文件权限或文件系统挂载选项。"
    return 1
  fi
  if [[ -n "$lib" ]] && ! mv -f "$lib" "$ROOT/bin/libcronet.so"; then
    rm -rf "$tmp"
    fail "无法安装 sing-box 运行库。"
    return 1
  fi
  if ! mv -f "$file" "$BIN"; then
    rm -rf "$tmp"
    fail "无法原子安装 sing-box 内核。"
    return 1
  fi
  chmod 0755 "$BIN" || {
    rm -rf "$tmp"
    fail "无法设置 sing-box 内核执行权限。"
    return 1
  }
  rm -rf "$tmp"
}

install_shortcuts() {
  write_managed_script || return 1
  ln -sf "$SCRIPT" /usr/local/bin/sb
  if [[ -e /usr/local/bin/sing-box && ! "$(readlink -f /usr/local/bin/sing-box 2>/dev/null || true)" == "$SCRIPT" ]]; then
    local yn
    warn "/usr/local/bin/sing-box 已存在，可能不是本脚本管理。"
    # EOF must never read as consent: leave the existing symlink alone.
    safe_read "是否覆盖为管理脚本快捷命令？[y/N]: " yn || return 0
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
  if is_alpine; then
    warn "尚未安装 sing-box 内核，请先执行菜单 13：NAT 轻量安装。"
  else
    warn "尚未安装 sing-box 内核，请先执行菜单 3：标准安装，或菜单 13：NAT 轻量安装。"
  fi
  return 1
}

add_mixed() {
  local port username password
  choose_node_ip_version "Mixed" || return 1
  port="$(ask_port "Mixed" 30000)" || return 1
  username="$(ask_text "Mixed 用户名" "daimon")" || return 1
  password="$(ask_text "Mixed 密码" "daimon")" || return 1
  apply_state_change config set_selected_protocol mixed "port=$port" "username=$username" "password=$password" || return 1
}

add_vless_reality() {
  local port uuid sni short_id keys private_key public_key
  require_core_installed || return 1
  choose_node_ip_version "Vless-reality" || return 1
  port="$(ask_port "Vless-reality" "$(random_free_port)")" || return 1
  uuid="$(ask_text "Vless-reality UUID" "$(rand_uuid)")" || return 1
  sni="$(pick_sni "$(random_sni)")" || return 1
  short_id="$(rand_hex 8)"
  keys="$(reality_keypair || true)"
  private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
  public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  if [[ -z "$private_key" || -z "$public_key" ]]; then
    fail "Reality 密钥生成失败，请确认 sing-box 内核可用。"
    return 1
  fi
  apply_state_change config set_selected_protocol vless_reality "port=$port" "uuid=$uuid" "sni=$sni" "short_id=$short_id" "private_key=$private_key" "public_key=$public_key" || return 1
}

add_vmess_ws() {
  local port uuid yn tls answer
  choose_node_ip_version "Vmess-ws" || return 1
  port="$(ask_port "Vmess-ws" "$(random_free_port)")" || return 1
  uuid="$(ask_text "Vmess-ws UUID" "$(rand_uuid)")" || return 1
  if ask_yes_no "是否开启 VMess-WS TLS？" n; then
    tls=true
  else
    answer=$?
    ((answer == 1)) || return 1
    tls=false
  fi
  apply_state_change config set_selected_protocol vmess_ws "port=$port" "uuid=$uuid" "tls=$tls" || return 1
}

add_hysteria2() {
  local port password sni hop_start hop_end hopping
  choose_node_ip_version "Hysteria-2" || return 1
  port="$(ask_port "Hysteria-2" "$(random_free_port)")" || return 1
  password="$(ask_text "Hysteria-2 密码" "$(rand_uuid)")" || return 1
  sni="$(pick_sni "$(random_sni)")" || return 1
  hopping="$(ask_hopping "Hysteria-2")" || return 1
  IFS=$'\t' read -r hop_start hop_end <<<"$hopping"
  [[ -z "$hop_start" ]] || ensure_hopping_tools || return 1
  apply_state_change config set_selected_protocol hysteria2 "port=$port" "password=$password" "sni=$sni" "hop_start=$hop_start" "hop_end=$hop_end" || return 1
}

add_tuic() {
  local port uuid password sni
  choose_node_ip_version "Tuic-v5" || return 1
  port="$(ask_port "Tuic-v5" "$(random_free_port)")" || return 1
  uuid="$(ask_text "Tuic-v5 UUID" "$(rand_uuid)")" || return 1
  password="$(ask_text "Tuic-v5 密码" "$uuid")" || return 1
  sni="$(pick_sni "$(random_sni)")" || return 1
  apply_state_change config set_selected_protocol tuic "port=$port" "uuid=$uuid" "password=$password" "sni=$sni" "hop_start=" "hop_end=" || return 1
}

add_anytls() {
  local port password sni
  choose_node_ip_version "Anytls" || return 1
  port="$(ask_port "Anytls" "$(random_free_port)")" || return 1
  password="$(ask_text "Anytls 密码" "$(rand_uuid)")" || return 1
  sni="$(pick_sni "$(random_sni)")" || return 1
  apply_state_change config set_selected_protocol anytls "port=$port" "password=$password" "sni=$sni" || return 1
}

add_trojan() {
  local port password sni
  choose_node_ip_version "Trojan" || return 1
  port="$(ask_port "Trojan" "$(random_free_port)")" || return 1
  password="$(ask_text "Trojan 密码" "$(rand_uuid)")" || return 1
  sni="$(pick_sni "$(random_sni)")" || return 1
  apply_state_change config set_selected_protocol trojan "port=$port" "password=$password" "sni=$sni" || return 1
}

add_shadowsocks() {
  local port password method
  choose_node_ip_version "Shadowsocks" || return 1
  port="$(ask_port "Shadowsocks" "$(random_free_port)")" || return 1
  password="$(ask_text "Shadowsocks 密码" "$(rand_uuid)")" || return 1
  method="$(ask_text "Shadowsocks 加密方式" "aes-128-gcm")" || return 1
  apply_state_change config set_selected_protocol shadowsocks "port=$port" "password=$password" "method=$method" || return 1
}

add_vmess_tcp() {
  local port uuid
  choose_node_ip_version "Vmess-tcp" || return 1
  port="$(ask_port "Vmess-tcp" "$(random_free_port)")" || return 1
  uuid="$(ask_text "Vmess-tcp UUID" "$(rand_uuid)")" || return 1
  apply_state_change config set_selected_protocol vmess_tcp "port=$port" "uuid=$uuid" || return 1
}

add_vmess_http() {
  local port uuid host path
  choose_node_ip_version "Vmess-http" || return 1
  port="$(ask_port "Vmess-http" "$(random_free_port)")" || return 1
  uuid="$(ask_text "Vmess-http UUID" "$(rand_uuid)")" || return 1
  host="$(pick_sni "$(random_sni)")" || return 1
  path="$(ask_text "Vmess-http 路径" "/vmess-http")" || return 1
  [[ "$path" == /* ]] || path="/$path"
  apply_state_change config set_selected_protocol vmess_http "port=$port" "uuid=$uuid" "host=$host" "path=$path" || return 1
}

add_all_protocols() {
  local proto needs_ip=false
  ensure_state || return 1
  if is_alpine || lite_mode; then
    fail "NAT 轻量模式只支持 VLESS Reality；如需其他协议，请先执行标准安装升级。"
    return 1
  fi
  require_core_installed || return 1
  maybe_set_node_prefix
  for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls; do
    if ! protocol_exists "$proto"; then
      needs_ip=true
      break
    fi
  done
  [[ "$needs_ip" == "false" ]] || choose_node_ip_version "一键添加协议" || return 1
  apply_state_change config add_missing_protocols || return 1
  info "一键协议已生成。"
  show_protocol_details
}

add_missing_protocols() {
  [[ "$(proto_value mixed enabled false)" == "true" ]] || set_selected_protocol mixed "port=$(next_free_port 30000)" "username=daimon" "password=daimon" || return 1
  [[ "$(proto_value vless_reality enabled false)" == "true" ]] || {
    local keys private_key public_key
    keys="$(reality_keypair || true)"
    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
    [[ -n "$private_key" && -n "$public_key" ]] || { fail "Reality 密钥生成失败，请确认 sing-box 内核可用。"; return 1; }
    set_selected_protocol vless_reality "port=$(random_free_port)" "uuid=$(rand_uuid)" "sni=$(random_sni)" "short_id=$(rand_hex 8)" "private_key=$private_key" "public_key=$public_key" || return 1
  }
  [[ "$(proto_value vmess_ws enabled false)" == "true" ]] || set_selected_protocol vmess_ws "port=$(random_free_port)" "uuid=$(rand_uuid)" "tls=false" || return 1
  [[ "$(proto_value hysteria2 enabled false)" == "true" ]] || set_selected_protocol hysteria2 "port=$(random_free_port)" "password=$(rand_uuid)" "sni=$(random_sni)" "hop_start=" "hop_end=" || return 1
  if [[ "$(proto_value tuic enabled false)" != "true" ]]; then
    local tuic_uuid
    tuic_uuid="$(rand_uuid)"
    set_selected_protocol tuic "port=$(random_free_port)" "uuid=$tuic_uuid" "password=$tuic_uuid" "sni=$(random_sni)" "hop_start=" "hop_end=" || return 1
  fi
  [[ "$(proto_value anytls enabled false)" == "true" ]] || set_selected_protocol anytls "port=$(random_free_port)" "password=$(rand_uuid)" "sni=$(random_sni)" || return 1
  return 0
}

install_sing_box() {
  need_root
  if is_alpine; then
    fail "Alpine 仅支持菜单 13 的 NAT 轻量 VLESS Reality 安装。"
    return 1
  fi
  install_dependencies standard || return 1
  ensure_dirs || return 1
  ensure_state || return 1
  set_state_value install_mode standard || return 1
  download_core standard || return 1
  ensure_cert || { fail "自签证书生成失败。"; return 1; }
  # Also regenerates the subscription files NAT lite deleted, so an upgrade
  # from lite no longer answers 404, and resyncs UFW and hopping rules.
  rebuild_configs || return 1
  write_sub_server || return 1
  write_services standard || return 1
  install_shortcuts || warn "快捷命令安装失败，可继续使用 $SCRIPT。"
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

lite_state_is_fresh() {
  ! has_protocols
}

install_nat_lite() {
  need_root
  install_dependencies lite || return 1
  ensure_state || return 1
  lite_state_is_fresh || {
    fail "NAT 轻量安装只接受尚未添加协议的状态，请先使用标准模式或清理现有协议。"
    return 1
  }
  ensure_dirs || return 1
  maybe_set_node_prefix || return 1
  choose_node_ip_version "NAT 轻量 VLESS" || return 1
  download_core lite || return 1
  set_state_value install_mode lite || return 1
  write_base_configs || return 1
  write_services lite || return 1
  install_shortcuts || warn "快捷命令安装失败，可继续使用 $SCRIPT。"
  sync_ufw_ports
  managed_service_enable sing-box || return 1
  local keys private_key public_key
  keys="$(reality_keypair || true)"
  private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
  public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  [[ -n "$private_key" && -n "$public_key" ]] || {
    fail "Reality 密钥生成失败，请确认 sing-box 内核可用。"
    return 1
  }
  apply_state_change config set_selected_protocol vless_reality \
    "port=$(random_free_port)" \
    "uuid=$(rand_uuid)" \
    "sni=$(random_sni)" \
    "short_id=$(rand_hex 8)" \
    "private_key=$private_key" \
    "public_key=$public_key" || return 1
  if managed_service_restart sing-box >/dev/null 2>&1 && managed_service_active sing-box; then
    info "NAT 轻量 VLESS Reality 已安装并运行。外部端口请在 NAT 页面映射为同一端口。"
    show_protocol_details
    return 0
  fi
  fail "NAT 轻量 VLESS Reality 已写入，但 Sing-box 启动失败。"
  managed_service_status sing-box 2>/dev/null || true
  return 1
}

remove_alpine_managed_packages() {
  local remove_all="${1:-false}" package tmp
  local remove=()
  local keep=()
  is_alpine && [[ -s "$ALPINE_PACKAGES" ]] || return 0
  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    if [[ "$remove_all" == "true" || "$package" == "sing-box" || "$package" == "jq" ]]; then
      remove+=("$package")
    else
      keep+=("$package")
    fi
  done <"$ALPINE_PACKAGES"
  ((${#remove[@]})) && apk del "${remove[@]}" >/dev/null 2>&1 || true
  if [[ "$remove_all" == "true" || ${#keep[@]} -eq 0 ]]; then
    rm -f "$ALPINE_PACKAGES"
  else
    tmp="$(mktemp "$ROOT/.alpine-packages.XXXXXX")"
    printf '%s\n' "${keep[@]}" >"$tmp"
    mv -f "$tmp" "$ALPINE_PACKAGES"
  fi
}

uninstall_sing_box() {
  need_root
  local yn
  # An unanswerable prompt must not be treated as confirmation to uninstall.
  safe_read "确认删除所有协议并卸载 Sing-box？管理脚本会保留。[y/N]: " yn || return 0
  [[ "$yn" =~ ^[Yy]$ ]] || return 0
  managed_service_disable_now sing-box
  managed_service_disable_now sing-box-sub
  remove_subscription_nginx_and_cert "$(state_value sub_domain "")"
  delete_all_ufw_rules
  delete_hopping_rules hysteria2
  delete_hopping_rules tuic
  save_firewall_rules
  rm -f "$SERVICE" "$SUB_SERVICE"
  is_alpine || systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$ROOT/bin" "$CONF" "$CERT" "$SUB" "$LOG"
  rm -f "$STATE" "$STATE.tmp" "$SUB_SERVER" "$UFW_RULES"
  invalidate_state_cache
  remove_alpine_managed_packages false
  ensure_dirs || return 1
  info "Sing-box 和所有协议已卸载，管理脚本已保留。"
}

delete_script() {
  need_root
  local yn
  safe_read "确认删除脚本、所有协议和 Sing-box？此操作不可恢复。[y/N]: " yn || return 0
  [[ "$yn" =~ ^[Yy]$ ]] || return 0
  managed_service_disable_now sing-box
  managed_service_disable_now sing-box-sub
  remove_subscription_nginx_and_cert "$(state_value sub_domain "")"
  delete_all_ufw_rules
  delete_hopping_rules hysteria2
  delete_hopping_rules tuic
  save_firewall_rules
  rm -f "$SERVICE" "$SUB_SERVICE"
  is_alpine || systemctl daemon-reload >/dev/null 2>&1 || true
  [[ "$(readlink -f /usr/local/bin/sb 2>/dev/null || true)" == "$SCRIPT" ]] && rm -f /usr/local/bin/sb
  [[ "$(readlink -f /usr/local/bin/sing-box 2>/dev/null || true)" == "$SCRIPT" ]] && rm -f /usr/local/bin/sing-box
  remove_alpine_managed_packages true
  [[ "$ROOT" == "/etc/sing-box" ]] && rm -rf "$ROOT"
  info "脚本、Sing-box 和所有协议已删除。"
  exit 0
}

update_script() {
  need_root
  local tmp latest
  ensure_dirs || return 1
  tmp="$ROOT/sb.sh.update"
  info "正在下载最新脚本..."
  if ! fetch_latest_script >"$tmp"; then
    rm -f "$tmp"
    fail "脚本更新失败：下载失败。"
    return 1
  fi
  if ! valid_script_file "$tmp"; then
    rm -f "$tmp"
    fail "脚本更新失败：新脚本为空、不完整或语法检查未通过。"
    return 1
  fi
  if cmp -s "$tmp" "$SCRIPT"; then
    rm -f "$tmp"
    info "已是最新版本 ${SCRIPT_VERSION}，无需更新。"
    return 0
  fi
  latest="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n1)"
  if [[ -z "$latest" || "$(printf '%s\n%s\n' "$latest" "$SCRIPT_VERSION" | sort -V | tail -n1)" != "$latest" ]]; then
    rm -f "$tmp"
    warn "下载版本低于当前版本或缺少版本信息，未更新。"
    return 1
  fi
  chmod 0755 "$tmp" && mv -f "$tmp" "$SCRIPT" || return 1
  rm -f "$tmp"
  ln -sf "$SCRIPT" /usr/local/bin/sb
  link_shortcut_if_managed /usr/local/bin/sing-box
  if ! "$SCRIPT" --refresh-installed; then
    fail "脚本已更新，但已有安装状态刷新失败，请重新执行更新或检查服务日志。"
    return 1
  fi
  refresh_version_cache >/dev/null 2>&1 || true
  info "脚本已更新：${SCRIPT_VERSION} -> ${latest:-未知}。正在重新载入新版脚本..."
  sleep 1
  exec "$SCRIPT"
}

refresh_installed() {
  need_root
  local sing_box_active=false
  ensure_state || return 1
  ensure_dirs || return 1
  if lite_mode; then
    rebuild_configs || return 1
    write_services lite || return 1
    if managed_service_active sing-box; then
      managed_service_restart sing-box && managed_service_active sing-box || return 1
    fi
    return 0
  fi
  install_optional_qrencode
  managed_service_active sing-box 2>/dev/null && sing_box_active=true
  rebuild_configs || return 1
  write_sub_server || return 1
  write_services standard || return 1
  if [[ "$sing_box_active" == "true" ]]; then
    if ! "$BIN" check -C "$CONF" >/dev/null 2>&1; then
      fail "sing-box 配置检查失败，未应用更新。"
      "$BIN" check -C "$CONF" || true
      return 1
    fi
    managed_service_restart sing-box >/dev/null 2>&1 || return 1
    managed_service_active sing-box || return 1
  fi
  restart_sub_service || { fail "订阅服务重启失败，请在运行管理中查看状态。"; return 1; }
  return 0
}

legacy_subscription_needs_refresh() {
  lite_mode && return 1
  has_protocols || return 1
  [[ -s "$SUB/v2rayn_raw.txt" ]] || return 0
  grep -Eq 'AllowInsecure":"true"|v2rayn://socks/' "$SUB/v2rayn_raw.txt"
}

systemd_unit_exists() {
  managed_service_exists "${1%.service}"
}

restart_if_running() {
  local rc=0
  if ! systemd_unit_exists sing-box.service; then
    warn "Sing-box 服务未安装，请先安装。"
    return 1
  fi
  if has_protocols; then
    [[ -x "$BIN" ]] || { fail "sing-box 内核不存在。"; return 1; }
    "$BIN" check -C "$CONF" || { fail "配置检查失败，未重启服务。"; return 1; }
    if managed_service_restart sing-box && managed_service_active sing-box; then
      info "Sing-box 已应用新配置并运行。"
    else
      fail "Sing-box 重启失败，请查看运行管理日志。"
      rc=1
    fi
  else
    managed_service_stop sing-box || { fail "Sing-box 停止失败。"; return 1; }
    info "未启用协议，Sing-box 已停止。"
  fi
  if ! lite_mode && ! is_alpine && systemd_unit_exists sing-box-sub.service; then
    restart_sub_service || { fail "订阅服务重启失败。"; rc=1; }
  fi
  return "$rc"
}

add_protocol_menu() {
  require_core_installed || return 1
  title "添加协议"
  protocol_menu_items missing
  ((${#AVAILABLE_PROTOCOLS[@]})) || { info "当前模式支持的协议均已添加，请使用修改协议。"; return 1; }
  printf '0. 返回\n'
  local choice proto
  choice="$(ask_menu "请选择: " "${#AVAILABLE_PROTOCOLS[@]}")"
  [[ "$choice" != 0 ]] || menu_cancel
  proto="${AVAILABLE_PROTOCOLS[choice-1]}"
  maybe_set_node_prefix || return 1
  case "$proto" in
    mixed) add_mixed || { fail "协议添加失败。"; return 1; } ;;
    vless_reality) add_vless_reality || { fail "协议添加失败。"; return 1; } ;;
    vmess_ws) add_vmess_ws || { fail "协议添加失败。"; return 1; } ;;
    hysteria2) add_hysteria2 || { fail "协议添加失败。"; return 1; } ;;
    tuic) add_tuic || { fail "协议添加失败。"; return 1; } ;;
    anytls) add_anytls || { fail "协议添加失败。"; return 1; } ;;
    trojan) add_trojan || { fail "协议添加失败。"; return 1; } ;;
    shadowsocks) add_shadowsocks || { fail "协议添加失败。"; return 1; } ;;
    vmess_tcp) add_vmess_tcp || { fail "协议添加失败。"; return 1; } ;;
    vmess_http) add_vmess_http || { fail "协议添加失败。"; return 1; } ;;
  esac
  restart_if_running || return 1
  info "协议已添加。"
  show_protocol_details "$proto"
}

change_protocol_ip_version() {
  local proto="$1" label="$2"
  choose_node_ip_version "$label" || return 1
  apply_state_change subscription set_protocol "$proto" "ip_version=$SELECTED_IP_VERSION" "endpoint_host=$SELECTED_ENDPOINT_HOST" || return 1
  ADDRESS_ONLY_CHANGE=true
}

set_all_protocol_ip_version() {
  local mode="$1" host="$2" tmp
  ensure_state || return 1
  if is_alpine; then
    tmp="$(mktemp "$ROOT/.state.XXXXXX")" || return 1
    jq --arg mode "$mode" --arg host "$host" '
      .protocols |= with_entries(
        if .value.enabled == true then
          .value.ip_version = $mode | .value.endpoint_host = $host
        else . end
      )
    ' "$STATE" >"$tmp" && mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
  else
    python3 - "$STATE" "$mode" "$host" <<'PY' || return 1
import json, os, sys
path, mode, host = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
for item in data.get("protocols", {}).values():
    if item.get("enabled") is True:
        item["ip_version"] = mode
        item["endpoint_host"] = host
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, path)
PY
  fi
  invalidate_state_cache
}

change_all_protocol_ip_version() {
  local proto found=false
  for proto in mixed vless_reality vmess_ws hysteria2 tuic anytls trojan shadowsocks vmess_tcp vmess_http; do
    if protocol_exists "$proto"; then found=true; break; fi
  done
  [[ "$found" == "true" ]] || { warn "尚未添加协议。"; return 1; }
  choose_node_ip_version "全部已添加协议" || return 1
  apply_state_change subscription set_all_protocol_ip_version "$SELECTED_IP_VERSION" "$SELECTED_ENDPOINT_HOST" || return 1
  info "全部已添加协议的客户端连接地址已更新。"
  show_protocol_details
}

change_protocol_port() {
  local proto="$1" label="$2" old_port port
  old_port="$(proto_value "$proto" port)"
  port="$(ask_port "$label" "$old_port" "$old_port")" || return 1
  [[ "$port" != "$old_port" ]] || { info "端口未变化。"; return 1; }
  apply_state_change config set_protocol "$proto" "port=$port"
}

change_protocol_config() {
  require_core_installed || return 1
  ADDRESS_ONLY_CHANGE=false
  title "更改协议配置"
  select_existing_protocol || return 1
  local proto="$SELECTED_PROTOCOL" label field port value hop_start hop_end hopping
  label="$(node_base_name "$proto")"
  case "$proto" in
    mixed)
      printf "1. 修改端口\n2. 修改用户名\n3. 修改密码\n4. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Mixed 用户名" "$(proto_value mixed username daimon)")" || return 1; apply_state_change config set_protocol mixed "username=$value" || return 1 ;;
        3) value="$(ask_text "Mixed 密码" "$(proto_value mixed password daimon)")" || return 1; apply_state_change config set_protocol mixed "password=$value" || return 1 ;;
        4) change_protocol_ip_version mixed "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    vless_reality)
      printf "1. 修改端口\n2. 修改 UUID\n3. 修改 SNI\n4. 重新生成 Reality 密钥\n5. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 5)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Vless-reality UUID" "$(proto_value vless_reality uuid)")" || return 1; apply_state_change config set_protocol vless_reality "uuid=$value" || return 1 ;;
        3) value="$(pick_sni "$(proto_value vless_reality sni)")" || return 1; apply_state_change config set_protocol vless_reality "sni=$value" || return 1 ;;
        4)
          local keys private_key public_key
          keys="$(reality_keypair || true)"
          private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
          public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
          [[ -n "$private_key" && -n "$public_key" ]] || { fail "Reality 密钥生成失败。"; return 0; }
          apply_state_change config set_protocol vless_reality "private_key=$private_key" "public_key=$public_key" "short_id=$(rand_hex 8)" || return 1
          ;;
        5) change_protocol_ip_version vless_reality "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    vmess_ws)
      printf "1. 修改端口\n2. 修改 UUID\n3. 开关 TLS\n4. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Vmess-ws UUID" "$(proto_value vmess_ws uuid)")" || return 1; apply_state_change config set_protocol vmess_ws "uuid=$value" || return 1 ;;
        3)
          printf '1. 开启 TLS\n2. 关闭 TLS\n0. 返回\n'
          value="$(ask_menu "请选择: " 2)"
          [[ "$value" != 0 ]] || menu_cancel
          [[ "$value" == 1 ]] && value=true || value=false
          apply_state_change config set_protocol vmess_ws "tls=$value" || return 1
          ;;
        4) change_protocol_ip_version vmess_ws "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    hysteria2)
      printf "1. 修改端口\n2. 修改密码\n3. 修改 SNI\n4. 设置跳跃端口\n5. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 5)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Hysteria-2 密码" "$(proto_value hysteria2 password)")" || return 1; apply_state_change config set_protocol hysteria2 "password=$value" || return 1 ;;
        3) value="$(pick_sni "$(proto_value hysteria2 sni "${SNI_OPTIONS[0]}")")" || return 1; apply_state_change config set_protocol hysteria2 "sni=$value" || return 1 ;;
        4) hopping="$(ask_hopping "$label" "$(proto_value hysteria2 hop_start "")" "$(proto_value hysteria2 hop_end "")")" || return 1; IFS=$'\t' read -r hop_start hop_end <<<"$hopping"; [[ -z "$hop_start" ]] || ensure_hopping_tools || return 1; apply_state_change config set_protocol hysteria2 "hop_start=$hop_start" "hop_end=$hop_end" || return 1 ;;
        5) change_protocol_ip_version hysteria2 "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    tuic)
      printf "1. 修改端口\n2. 修改 UUID\n3. 修改密码\n4. 修改 SNI\n5. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 5)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Tuic-v5 UUID" "$(proto_value tuic uuid)")" || return 1; apply_state_change config set_protocol tuic "uuid=$value" || return 1 ;;
        3) value="$(ask_text "Tuic-v5 密码" "$(proto_value tuic password)")" || return 1; apply_state_change config set_protocol tuic "password=$value" || return 1 ;;
        4) value="$(pick_sni "$(proto_value tuic sni "${SNI_OPTIONS[0]}")")" || return 1; apply_state_change config set_protocol tuic "sni=$value" || return 1 ;;
        5) change_protocol_ip_version tuic "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    anytls)
      printf "1. 修改端口\n2. 修改密码\n3. 修改 SNI\n4. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Anytls 密码" "$(proto_value anytls password)")" || return 1; apply_state_change config set_protocol anytls "password=$value" || return 1 ;;
        3) value="$(pick_sni "$(proto_value anytls sni "${SNI_OPTIONS[0]}")")" || return 1; apply_state_change config set_protocol anytls "sni=$value" || return 1 ;;
        4) change_protocol_ip_version anytls "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    trojan)
      printf "1. 修改端口\n2. 修改密码\n3. 修改 SNI\n4. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Trojan 密码" "$(proto_value trojan password)")" || return 1; apply_state_change config set_protocol trojan "password=$value" || return 1 ;;
        3) value="$(pick_sni "$(proto_value trojan sni "${SNI_OPTIONS[0]}")")" || return 1; apply_state_change config set_protocol trojan "sni=$value" || return 1 ;;
        4) change_protocol_ip_version trojan "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    shadowsocks)
      printf "1. 修改端口\n2. 修改密码\n3. 修改加密方式\n4. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 4)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Shadowsocks 密码" "$(proto_value shadowsocks password)")" || return 1; apply_state_change config set_protocol shadowsocks "password=$value" || return 1 ;;
        3) value="$(ask_text "Shadowsocks 加密方式" "$(proto_value shadowsocks method aes-128-gcm)")" || return 1; apply_state_change config set_protocol shadowsocks "method=$value" || return 1 ;;
        4) change_protocol_ip_version shadowsocks "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    vmess_tcp)
      printf "1. 修改端口\n2. 修改 UUID\n3. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 3)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Vmess-tcp UUID" "$(proto_value vmess_tcp uuid)")" || return 1; apply_state_change config set_protocol vmess_tcp "uuid=$value" || return 1 ;;
        3) change_protocol_ip_version vmess_tcp "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
    vmess_http)
      printf "1. 修改端口\n2. 修改 UUID\n3. 修改 Host\n4. 修改路径\n5. 修改客户端连接地址\n0. 返回\n"
      field="$(ask_menu "请选择: " 5)" || return 1
      case "$field" in
        1) change_protocol_port "$proto" "$label" || return 1 ;;
        2) value="$(ask_text "Vmess-http UUID" "$(proto_value vmess_http uuid)")" || return 1; apply_state_change config set_protocol vmess_http "uuid=$value" || return 1 ;;
        3) value="$(pick_sni "$(proto_value vmess_http host "${SNI_OPTIONS[0]}")")" || return 1; apply_state_change config set_protocol vmess_http "host=$value" || return 1 ;;
        4) value="$(ask_text "Vmess-http 路径" "$(proto_value vmess_http path /vmess-http)")" || return 1; [[ "$value" == /* ]] || value="/$value"; apply_state_change config set_protocol vmess_http "path=$value" || return 1 ;;
        5) change_protocol_ip_version vmess_http "$label" || return 1 ;;
        0) menu_cancel ;;
      esac
      ;;
  esac
  if [[ "$ADDRESS_ONLY_CHANGE" != "true" ]]; then
    restart_if_running || return 1
  fi
  info "配置已更新。"
  show_protocol_details "$proto"
  return 0
}



change_subscription_config() {
  require_core_installed || return 1
  local choice old_port new_port new_token input domain endpoint_host http_enabled=true
  if is_alpine || lite_mode; then http_enabled=false; fi
  title "更改综合订阅配置"
  printf '节点连接地址决定客户端连接哪个 IPv4/IPv6；订阅下载地址不改变节点或出站。\n'
  if [[ "$http_enabled" == true ]]; then
    endpoint_host="$(state_value sub_endpoint_host "")"
    domain="$(state_value sub_domain "")"
    printf '当前订阅端口:%s\nHTTP/IP订阅地址:%s\n当前HTTPS域名:%s\n\n' \
      "$(state_value sub_port 2096)" "${endpoint_host:-自动}" "${domain:-未设置}"
    show_subscription_links
    printf '\n1. 修改综合订阅端口\n2. 指定或重新生成 token（旧链接将失效）\n3. 设置/更改 HTTPS 订阅域名\n'
    [[ -z "$domain" ]] || printf '4. 删除 HTTPS 订阅域名配置\n'
    printf '5. 修改 HTTP/IP 订阅下载地址\n'
  else
    printf 'NAT 轻量模式不提供 HTTP/HTTPS 订阅，以下操作仅更新节点链接。\n'
  fi
  printf '6. 切换节点连接地址：IPv4 / IPv6 / 双栈 / 手动地址（单协议或全部）\n0. 返回\n'
  while true; do
    choice="$(ask_menu "请选择: " 6)"
    [[ "$choice" != 0 ]] || menu_cancel
    if [[ "$http_enabled" == false && "$choice" != 6 ]] || [[ "$choice" == 4 && -z "${domain:-}" ]]; then
      warn "请选择当前菜单显示的编号。"
      continue
    fi
    break
  done
  case "$choice" in
    1)
      old_port="$(state_value sub_port 2096)"
      new_port="$(ask_port "综合订阅" "$old_port" "$old_port")" || return 1
      [[ "$new_port" != "$old_port" ]] || { info "订阅端口未变化。"; return 0; }
      apply_state_change subscription set_state_value sub_port "$new_port" || return 1
      write_sub_server || return 1
      restart_sub_service || { fail "订阅服务启动失败，请检查端口和日志。"; return 1; }
      sync_ufw_ports || return 1
      if [[ -n "$domain" && "$(state_value sub_tls false)" == true ]]; then
        write_nginx_subscription_config "$domain" "$new_port" || return 1
      fi
      info "综合订阅端口已更新为 $new_port。"
      ;;
    2)
      while true; do
        safe_read "请输入新 token，回车随机生成（0 返回）: " input || return 1
        [[ "$input" != 0 ]] || menu_cancel
        new_token="${input:-$(rand_token)}"
        valid_token "$new_token" && break
        warn "token 只能包含字母和数字。"
      done
      apply_state_change subscription set_state_value token "$new_token" || return 1
      info "综合订阅 token 已更新，旧链接已失效。"
      ;;
    3)
      while true; do
        safe_read "请输入 HTTPS 订阅域名（0 返回）: " domain || return 1
        [[ "$domain" != 0 ]] || menu_cancel
        valid_domain "$domain" && break
        warn "请输入有效域名。"
      done
      configure_https_subscription_domain "$domain" || return 1
      ;;
    4)
      ask_yes_no "确认删除 HTTPS 域名配置、nginx 反代和该域名证书？" n || return 1
      delete_https_subscription_domain || return 1
      ;;
    5)
      while true; do
        safe_read "请输入订阅下载 IPv4、IPv6 或域名，回车恢复自动（0 返回）: " input || return 1
        [[ "$input" != 0 ]] || menu_cancel
        if [[ -z "$input" ]]; then endpoint_host=""; break; fi
        if endpoint_host="$(endpoint_host_value "$input")"; then break; fi
        warn "地址格式错误，不要包含协议、端口或路径。"
      done
      set_state_value sub_endpoint_host "$endpoint_host" || return 1
      info "订阅下载地址已更新，节点连接地址不变。"
      ;;
    6)
      title "选择需要切换地址的协议"
      select_existing_protocol true || return 1
      if [[ "$SELECTED_PROTOCOL" == all ]]; then
        change_all_protocol_ip_version || return 1
      else
        change_protocol_ip_version "$SELECTED_PROTOCOL" "$(node_base_name "$SELECTED_PROTOCOL")" || return 1
        info "节点连接地址已更新，端口和认证信息未改变。"
        show_protocol_details "$SELECTED_PROTOCOL"
      fi
      return 0
      ;;
  esac
  printf '\n当前订阅链接如下：\n'
  show_subscription_links
}

delete_protocol_menu() {
  require_core_installed || return 1
  local input item proto choice max invalid protocols=()
  title "删除协议"
  protocol_menu_items
  max=${#AVAILABLE_PROTOCOLS[@]}
  ((max)) || { warn "尚未添加协议。"; return 1; }
  printf '%s. 删除所有已添加协议\n0. 返回\n' "$((max+1))"
  while true; do
    safe_read "请选择，可多选，如 1 3 或 1,3（0 返回）: " input || return 1
    input="${input//,/ }"
    protocols=()
    invalid=false
    for item in $input; do
      if ! choice="$(menu_number "$item" "$((max+1))")"; then
        invalid=true
        break
      fi
      [[ "$choice" != 0 ]] || menu_cancel
      if ((choice == max+1)); then
        protocols=("${AVAILABLE_PROTOCOLS[@]}")
      else
        proto="${AVAILABLE_PROTOCOLS[choice-1]}"
        [[ " ${protocols[*]} " == *" $proto "* ]] || protocols+=("$proto")
      fi
    done
    if [[ "$invalid" == false ]] && ((${#protocols[@]})); then break; fi
    warn "无效选择，请输入上方显示的编号。"
  done
  printf '将删除以下 %s 个协议：\n' "${#protocols[@]}"
  for proto in "${protocols[@]}"; do printf '  %s\n' "$(node_base_name "$proto")"; done
  ask_yes_no "确认删除？" n || return 1
  apply_state_change config delete_selected_protocols "${protocols[@]}" || return 1
  restart_if_running || return 1
  info "协议已删除 ${#protocols[@]} 个。"
}

delete_selected_protocols() {
  local proto
  for proto in "$@"; do delete_protocol_state "$proto" || return 1; done
}

os_name() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    printf '%s' "${PRETTY_NAME:-未知}"
  else
    printf '未知'
  fi
}

fetch_region() {
  local text
  text="$(curl -fs --max-time 5 https://myip.ipip.net 2>/dev/null || true)"
  [[ -n "$text" ]] && printf '%s' "$text" | sed 's/^[^：:]*[：:] *//;s/[[:space:]]*$//' || printf '未知'
}

refresh_region_async() {
  local dir lock cache
  dir="$(status_cache_dir)"
  cache="$dir/region"
  mkdir -p "$dir" 2>/dev/null || return 0
  status_cache_fresh "$cache" && return 0
  lock="$dir/region.lock"
  acquire_async_lock "$lock" || return 0
  (
    local tmp="$cache.tmp"
    fetch_region >"$tmp" 2>/dev/null || true
    mv -f "$tmp" "$cache" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
  ) &
}

region_name() {
  local dir cache
  dir="$(status_cache_dir)"
  cache="$dir/region"
  if status_cache_fresh "$cache"; then
    cat "$cache"
  else
    fetch_region
  fi
}

sing_box_status() {
  if [[ ! -x "$BIN" && ! -f "$SERVICE" ]]; then
    printf '未安装'
  elif managed_service_active sing-box 2>/dev/null; then
    printf '已运行'
  else
    printf '未运行'
  fi
}

show_status_header() {
  local os kernel arch virt bbr qdisc ipv4 ipv6 region active prefix
  os="$(os_name)"
  kernel="$(uname -r)"
  arch="$(uname -m)"
  virt="$(systemd-detect-virt 2>/dev/null || printf '未知')"
  bbr="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知')"
  refresh_status_network_async
  refresh_region_async
  ipv4="$(status_cached_value ipv4)"
  ipv6="$(status_cached_value ipv6)"
  region="$(status_cached_value region)"
  active="$(sing_box_status)"
  prefix="$(node_prefix)"
  printf "${CYAN}系统:${NC}%s  ${CYAN}内核:${NC}%s  ${CYAN}处理器:${NC}%s  ${CYAN}虚拟化:${NC}%s  ${CYAN}BBR算法:${NC}%s ${CYAN}队列算法:${NC}%s\n" "$os" "$kernel" "$arch" "$virt" "$bbr" "$qdisc"
  printf "%s\n" "$(version_status)"
  if [[ -n "$prefix" ]]; then
    printf "${CYAN}节点名称前缀:${NC}${MAGENTA}%s${NC}\n" "$prefix"
  else
    printf "${CYAN}节点名称前缀:${NC}%b\n" "$(color_status 未设置)"
  fi
  printf "${CYAN}出口IPV4地址:${NC}${MAGENTA}%s${NC}   ${CYAN}出口IPV6地址:${NC}%b\n" "${ipv4:-检测中}" "$(color_status "${ipv6:-检测中}")"
  printf "${CYAN}服务器地区:${NC}${MAGENTA}%s${NC}\n" "${region:-检测中}"
  printf "%s\n" "$(ufw_status_text)"
  printf "${CYAN}Sing-box状态:${NC}%b\n\n" "$(color_status "$active")"
}

show_protocols() {
  title "Sing-box节点关键信息、已分流域名情况如下："
  if ! has_protocols; then
    if [[ -s "$STATE" ]]; then
      printf "暂无协议。\n\n"
      if lite_mode; then
        printf "NAT 轻量模式未启用 HTTP/HTTPS 订阅服务。\n\n"
      else
        show_subscription_links
        printf "\n"
      fi
    else
      printf "暂无协议。\n\n综合订阅链接:\n未生成\n\n"
    fi
    return
  fi
  [[ "$(proto_value vless_reality enabled false)" == "true" ]] &&
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}Reality域名证书伪装地址:${NC}${MAGENTA}%s${NC}\n" "$(node_display_name vless_reality)" "$(proto_value vless_reality port)" "$(proto_ip_label vless_reality)" "$(proto_value vless_reality sni)"
  [[ "$(proto_value vmess_ws enabled false)" == "true" ]] &&
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}%b\n" "$(node_display_name vmess_ws)" "$(proto_value vmess_ws port)" "$(proto_ip_label vmess_ws)" "$(color_status "$([[ "$(proto_value vmess_ws tls false)" == "true" ]] && printf '自签证书' || printf 'TLS关闭')")"
  if [[ "$(proto_value hysteria2 enabled false)" == "true" ]]; then
    local hy_hop="未添加"
    [[ -n "$(proto_value hysteria2 hop_start "")" && -n "$(proto_value hysteria2 hop_end "")" ]] && hy_hop="$(proto_value hysteria2 hop_start)-$(proto_value hysteria2 hop_end)"
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}自签证书  ${CYAN}转发多端口:${NC}%b\n" "$(node_display_name hysteria2)" "$(proto_value hysteria2 port)" "$(proto_ip_label hysteria2)" "$(color_status "$hy_hop")"
  fi
  if [[ "$(proto_value tuic enabled false)" == "true" ]]; then
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}自签证书\n" "$(node_display_name tuic)" "$(proto_value tuic port)" "$(proto_ip_label tuic)"
  fi
  [[ "$(proto_value anytls enabled false)" == "true" ]] &&
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}自签证书\n" "$(node_display_name anytls)" "$(proto_value anytls port)" "$(proto_ip_label anytls)"
  [[ "$(proto_value trojan enabled false)" == "true" ]] &&
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}自签证书\n" "$(node_display_name trojan)" "$(proto_value trojan port)" "$(proto_ip_label trojan)"
  [[ "$(proto_value shadowsocks enabled false)" == "true" ]] &&
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}加密方式:${NC}%s\n" "$(node_display_name shadowsocks)" "$(proto_value shadowsocks port)" "$(proto_ip_label shadowsocks)" "$(proto_value shadowsocks method aes-128-gcm)"
  [[ "$(proto_value vmess_tcp enabled false)" == "true" ]] &&
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}证书形式:${NC}%b\n" "$(node_display_name vmess_tcp)" "$(proto_value vmess_tcp port)" "$(proto_ip_label vmess_tcp)" "$(color_status TLS关闭)"
  [[ "$(proto_value vmess_http enabled false)" == "true" ]] &&
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}Host:${NC}${MAGENTA}%s${NC}  ${CYAN}路径:${NC}%s\n" "$(node_display_name vmess_http)" "$(proto_value vmess_http port)" "$(proto_ip_label vmess_http)" "$(proto_value vmess_http host "${SNI_OPTIONS[0]}")" "$(proto_value vmess_http path /vmess-http)"
  [[ "$(proto_value mixed enabled false)" == "true" ]] &&
    printf "${YELLOW}【 %s 】${NC} ${CYAN}端口:${NC}${GREEN}%s${NC}  ${CYAN}节点IP:${NC}%s  ${CYAN}包含:${NC}HTTP/SOCKS5\n" "$(node_display_name mixed)" "$(proto_value mixed port)" "$(proto_ip_label mixed)"
  printf "\n"
  if lite_mode; then
    printf "${CYAN}安装模式:${NC}${GREEN}NAT 轻量 VLESS Reality${NC}  ${CYAN}HTTP订阅:${NC}未启用\n"
  else
    show_subscription_links
  fi
  printf "\n"
}

# With a protocol, show only its nodes and the subscription URLs, so the
# result of a change is not scrolled away by every other node's QR code.
show_protocol_details() {
  local only="${1:-}"
  is_alpine || load_state_cache || true
  if lite_mode; then
    title "NAT 轻量 VLESS Reality 节点链接如下："
  else
    title "单个协议链接和二维码如下："
  fi
  if ! has_protocols; then
    printf "暂无协议。\n\n"
    return
  fi
  if lite_mode; then
    show_protocol_links false
    printf "${CYAN}HTTP/HTTPS订阅服务:${NC}未安装\n\n"
    return
  fi
  if [[ -n "$only" && "$only" != all ]]; then
    show_protocol_links true "$only"
    printf "${CYAN}HTTP/IP订阅链接(v2rayN默认):${NC}\n${MAGENTA}%s${NC}\n" "$(sub_http_link)"
    printf "${CYAN}HTTP/IP Clash/Mihomo订阅链接:${NC}\n${MAGENTA}%s${NC}\n" "$(sub_http_link clash)"
    if sub_https_link >/dev/null 2>&1; then
      printf "${CYAN}HTTPS域名订阅链接(v2rayN默认):${NC}\n${MAGENTA}%s${NC}\n" "$(sub_https_link)"
      printf "${CYAN}HTTPS域名 Clash/Mihomo订阅链接:${NC}\n${MAGENTA}%s${NC}\n" "$(sub_https_link clash)"
    fi
    printf "\n全部节点和订阅二维码：主菜单 10。\n"
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
  require_core_installed || { pause; return 0; }
  local choice action label service failed
  local services=(sing-box)
  lite_mode || services+=(sing-box-sub)
  while true; do
    title "Sing-box运行管理"
    printf "1. 启动 Sing-box\n2. 停止 Sing-box\n3. 重启 Sing-box\n4. 查看状态\n5. 查看日志\n6. 开机自启\n7. 关闭开机自启\n8. 检查配置\n0. 返回上一界面\n"
    choice="$(ask_menu "请选择: " 8)"
    case "$choice" in
      1|2|3|6|7)
        case "$choice" in
          1) action=start; label=启动 ;;
          2) action=stop; label=停止 ;;
          3) action=restart; label=重启 ;;
          6) action=enable_only; label=开启开机自启 ;;
          7) action=disable_only; label=关闭开机自启 ;;
        esac
        failed=false
        if [[ "$choice" == 1 || "$choice" == 3 ]]; then
          "$BIN" check -C "$CONF" || { fail "配置检查失败，未启动或重启服务。"; pause; continue; }
        fi
        for service in "${services[@]}"; do
          if ! "managed_service_$action" "$service"; then
            fail "$service $label失败。"
            failed=true
          elif [[ "$choice" == 1 || "$choice" == 3 ]] && ! managed_service_active "$service"; then
            fail "$service 未运行，请检查日志。"
            failed=true
          fi
        done
        [[ "$failed" == true ]] || info "服务$label成功。"
        pause
        ;;
      4) for service in "${services[@]}"; do managed_service_status "$service" || true; done; pause ;;
      5) if is_alpine; then tail -n 80 "$LOG/sing-box.log" 2>/dev/null || true; else journalctl -u sing-box -n 80 --no-pager || true; fi; pause ;;
      8) "$BIN" check -C "$CONF" || true; pause ;;
      0) return 0 ;;
    esac
  done
}

main_menu_item_hidden() {
  case "$1" in
    3) is_alpine ;;
    6) is_alpine || lite_mode ;;
    12) ! has_cmd ufw ;;
    *) return 1 ;;
  esac
}

main_menu() {
  while true; do
    clear_screen
    # Load once in this shell so the ~180 lookups below, which all run inside
    # command substitutions, inherit a populated array instead of each
    # re-sourcing the cache file.
    is_alpine || load_state_cache || true
    show_status_header
    show_protocols
    printf "\n"
    menu_line 0 "退出脚本"
    menu_line 1 "更新脚本"
    menu_line 2 "删除脚本"
    printf "${DIM}%s${NC}\n" '----------------------------------------'
    is_alpine || menu_line 3 "标准安装 Sing-box"
    menu_line 13 "NAT 轻量安装：仅 Vless-reality"
    menu_line 4 "删除卸载 Sing-box"
    menu_line 5 "Sing-box运行管理"
    printf "${DIM}%s${NC}\n" '----------------------------------------'
    if ! is_alpine && ! lite_mode; then
      menu_line 6 "一键添加协议：Mixed / Vless-reality / Vmess-ws / Hysteria-2 / Tuic-v5 / Anytls"
    fi
    menu_line 7 "添加协议"
    menu_line 8 "修改协议"
    menu_line 9 "删除协议"
    printf "${DIM}%s${NC}\n" '----------------------------------------'
    if is_alpine || lite_mode; then
      menu_line 10 "查看 NAT 节点链接"
      menu_line 11 "更改节点连接地址（IPv4/IPv6）"
    else
      menu_line 10 "查看协议和综合订阅链接"
      menu_line 11 "更改综合订阅配置（含节点 IPv4/IPv6）"
    fi
    has_cmd ufw && menu_line 12 "一键放行所有缺失端口"
    menu_line 14 "设置节点名称前缀"
    local choice
    while true; do
      choice="$(ask_menu "请选择: " 14)"
      main_menu_item_hidden "$choice" || break
      warn "请选择当前菜单显示的编号。"
    done
    MENU_CANCELLED=false
    case "$choice" in
      1) update_script || true; menu_pause ;;
      2) delete_script || true ;;
      3) install_sing_box || true; menu_pause ;;
      4) uninstall_sing_box || true; menu_pause ;;
      5) run_manage ;;
      6) add_all_protocols && restart_if_running; menu_pause ;;
      7) add_protocol_menu || true; menu_pause ;;
      8) change_protocol_config || true; menu_pause ;;
      9) delete_protocol_menu || true; menu_pause ;;
      10) view_protocols ;;
      11) change_subscription_config || true; menu_pause ;;
      12) allow_missing_ufw_ports || true; menu_pause ;;
      13) install_nat_lite || true; menu_pause ;;
      14) node_prefix_menu || true; menu_pause ;;
      0) exit 0 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # A cache file left by an older release holds STATE_CACHE[...] assignments.
  # This version never reads that name, but removing it means a downgrade or a
  # re-run of the intermediate release cannot abort on it under set -u.
  rm -f "$ROOT/.state-cache.sh" 2>/dev/null || true
  case "${1:-}" in
    --refresh-installed) refresh_installed ;;
    --apply-hopping) apply_saved_hopping_rules ;;
    *)
      if legacy_subscription_needs_refresh; then
        refresh_installed || warn "检测到旧版订阅格式，但自动刷新失败，请在菜单中重新执行更新。"
      fi
      main_menu
      ;;
  esac
fi
