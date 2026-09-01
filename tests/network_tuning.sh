#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT

MEM_MB=4096
memory_total_mb() { printf '%s' "$MEM_MB"; }

MEM_MB=256;  [[ "$(tune_buffer_max)" == 16777216 ]]
MEM_MB=768;  [[ "$(tune_buffer_max)" == 33554432 ]]
MEM_MB=1536; [[ "$(tune_buffer_max)" == 67108864 ]]
MEM_MB=4096; [[ "$(tune_buffer_max)" == 134217728 ]]

MEM_MB=256;  [[ "$(tune_backlog)" == 2048 ]]
MEM_MB=1536; [[ "$(tune_backlog)" == 8192 ]]
MEM_MB=4096; [[ "$(tune_backlog)" == 16384 ]]

CC_LIST="reno cubic bbr"
sysctl_read() {
  case "$1" in
    net.ipv4.tcp_available_congestion_control) printf '%s' "$CC_LIST" ;;
    *) printf '' ;;
  esac
}
cc_available bbr
CC_LIST="reno cubic"
modprobe() { return 1; }
! cc_available bbr
CC_LIST="reno cubic bbr"

TC_MODE=mq
# Real `tc qdisc show dev X` output omits the "dev X" field, so "root"/"parent"
# land on $4, not $6. `tc qdisc show` (no dev) keeps it. Both must parse.
tc() {
  case "$TC_MODE" in
    mq)
      cat <<'EOF'
qdisc mq 0: root
qdisc fq_codel 0: parent :2 limit 10240p flows 1024 quantum 1514
qdisc fq_codel 0: parent :1 limit 10240p flows 1024 quantum 1514
EOF
      ;;
    fq_root) printf 'qdisc fq 0: root refcnt 2 limit 10000p flow_limit 100p\n' ;;
    fq_child)
      cat <<'EOF'
qdisc mq 0: root
qdisc fq 0: parent :2 limit 10000p flow_limit 100p
qdisc fq 0: parent :1 limit 10000p flow_limit 100p
EOF
      ;;
    withdev)
      cat <<'EOF'
qdisc mq 0: dev eth0 root
qdisc fq_codel 0: dev eth0 parent :2 limit 10240p flows 1024
qdisc fq_codel 0: dev eth0 parent :1 limit 10240p flows 1024
EOF
      ;;
  esac
  return 0
}
has_cmd() { [[ "$1" == tc ]]; }
tunable_interfaces() { printf 'eth0\n'; }

TC_MODE=mq
[[ "$(interface_root_qdisc eth0)" == mq ]]
[[ "$(interface_leaf_qdisc eth0)" == fq_codel ]]
[[ "$(interface_parent_handles eth0 | tr '\n' ' ')" == ":2 :1 " ]]
TC_MODE=withdev
[[ "$(interface_root_qdisc eth0)" == mq ]]
[[ "$(interface_leaf_qdisc eth0)" == fq_codel ]]
[[ "$(interface_parent_handles eth0 | tr '\n' ' ')" == ":2 :1 " ]]
TC_MODE=fq_root
[[ "$(interface_root_qdisc eth0)" == fq ]]
[[ -z "$(interface_leaf_qdisc eth0)" ]]

sysctl_read() { [[ "$1" == net.core.default_qdisc ]] && printf 'fq' || printf ''; }
TC_MODE=mq
[[ "$(effective_qdisc_label)" == "fq(未生效)" ]]
TC_MODE=fq_root
[[ "$(effective_qdisc_label)" == "fq" ]]
TC_MODE=fq_child
[[ "$(effective_qdisc_label)" == "fq" ]]

TC_MODE=fq_root
[[ "$(apply_interface_qdisc eth0 fq)" == "ok" ]]
TC_MODE=fq_child
[[ "$(apply_interface_qdisc eth0 fq)" == "ok" ]]

# mq path: assign handle 1:, then set fq on each tx queue. Record the commands
# so the "handle 1:" step and per-queue children are both asserted.
interface_tx_queues() { printf '2'; }
TC_CALLS="$CASE_ROOT/tc_calls"
: >"$TC_CALLS"
TC_MODE=mq
tc() {
  if [[ "$1" == qdisc && "$2" == show ]]; then
    case "$TC_MODE" in
      mq)
        printf 'qdisc mq 0: root\n'
        printf 'qdisc fq_codel 0: parent :2 limit 10240p\n'
        printf 'qdisc fq_codel 0: parent :1 limit 10240p\n'
        ;;
      mq_fq)
        printf 'qdisc mq 1: root\n'
        printf 'qdisc fq 800b: parent 1:2 limit 10000p\n'
        printf 'qdisc fq 800a: parent 1:1 limit 10000p\n'
        ;;
      rootfail) printf 'qdisc pfifo_fast 0: root\n' ;;
    esac
    return 0
  fi
  printf '%s\n' "$*" >>"$TC_CALLS"
  # Emulate the kernel rebuilding children once a real handle is assigned.
  [[ "$*" == *"root handle 1: mq"* ]] && TC_MODE=mq_fq
  [[ "$TC_MODE" == rootfail && "$*" == *"root fq"* ]] && return 1
  return 0
}
[[ "$(apply_interface_qdisc eth0 fq)" == "child" ]]
grep -Fq 'qdisc replace dev eth0 root handle 1: mq' "$TC_CALLS"
grep -Fq 'qdisc replace dev eth0 parent 1:1 fq' "$TC_CALLS"
grep -Fq 'qdisc replace dev eth0 parent 1:2 fq' "$TC_CALLS"
# It must never try the unaddressable ":1" form or delete a zero-handle root.
! grep -q 'parent :1' "$TC_CALLS"
! grep -q 'qdisc del' "$TC_CALLS"

# Non-mq root that rejects the replace must report failure, not silent success.
TC_MODE=rootfail
[[ "$(apply_interface_qdisc eth0 fq)" == "fail" ]]

# qdisc_available must not mutate any interface; it only inspects module state.
MODPROBE_RC=0
modprobe() { return "$MODPROBE_RC"; }
MODPROBE_RC=0
qdisc_available fq
MODPROBE_RC=1
sysctl_read() { [[ "$1" == net.core.default_qdisc ]] && printf 'fq' || printf ''; }
qdisc_available fq          # already the active default qdisc
! qdisc_available nosuchqd
MODPROBE_RC=0

# sysctl_writable must fail when the key cannot be read at all.
sysctl_read() { printf ''; }
sysctl() { return 0; }
! sysctl_writable
sysctl_read() { printf '1'; }
sysctl() { return 1; }
! sysctl_writable
sysctl() { return 0; }
sysctl_writable
sysctl_read() { [[ "$1" == net.core.default_qdisc ]] && printf 'fq' || printf ''; }

SYSCTL_TUNE_FILE="$CASE_ROOT/tune.conf"
write_sysctl_tune_file bbr fq 134217728 16384
grep -Fxq 'net.ipv4.tcp_congestion_control = bbr' "$SYSCTL_TUNE_FILE"
grep -Fxq 'net.core.default_qdisc = fq' "$SYSCTL_TUNE_FILE"
grep -Fxq 'net.core.rmem_max = 134217728' "$SYSCTL_TUNE_FILE"
grep -Fxq 'net.core.netdev_max_backlog = 16384' "$SYSCTL_TUNE_FILE"
grep -Fxq 'net.ipv4.udp_rmem_min = 8192' "$SYSCTL_TUNE_FILE"

status_cache_dir() { printf '%s' "$CASE_ROOT/missing-cache"; }
value="$(status_cached_value ipv4)"
[[ -z "$value" ]]

UFW_RULES="$CASE_ROOT/missing-ufw.rules"
rules="$(managed_ufw_rules)"
[[ -z "$rules" ]]

ufw_active() { return 0; }
required_ufw_rules() { printf '80/tcp\n'; }
ufw_delete_rule() { printf 'del:%s\n' "$1"; }
deleted="$(delete_all_ufw_rules)"
[[ "$deleted" == "del:80/tcp" ]]

printf 'NETWORK_TUNING_TEST=PASS\n'
