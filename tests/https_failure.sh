#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"
state_value() {
  case "$1" in
    sub_domain) printf old.example.com ;;
    sub_tls) printf true ;;
    sub_port) printf 2096 ;;
  esac
}
set_state_value() { printf 'STATE_CHANGED\n'; }
remove_subscription_nginx_and_cert() { printf 'REMOVED=%s\n' "$1"; }
install_nginx_acme_deps() { :; }
ensure_acme() { :; }
prepare_https_ufw_for_acme() { :; }
rollback_https_ufw_for_acme() { :; }
issue_subscription_cert() { return 1; }
output="$(configure_https_subscription_domain new.example.com || true)"
! grep -Eq 'REMOVED=old.example.com|STATE_CHANGED' <<<"$output" || exit 1
issue_subscription_cert() { :; }
write_nginx_subscription_config() {
  [[ "$1" == old.example.com ]] || return 1
  printf 'OLD_HTTPS_RESTORED\n'
}
output="$(configure_https_subscription_domain new.example.com || true)"
! grep -Eq 'REMOVED=old.example.com|STATE_CHANGED' <<<"$output" || exit 1
grep -Fq OLD_HTTPS_RESTORED <<<"$output"
remove_subscription_nginx_and_cert() { return 1; }
generate_subscription() { printf 'SUBSCRIPTION_CHANGED\n'; }
sync_ufw_ports() { :; }
restart_sub_service() { :; }
if output="$(delete_https_subscription_domain)"; then
  printf 'HTTPS deletion falsely succeeded after cleanup failure\n' >&2
  exit 1
fi
! grep -Eq 'STATE_CHANGED|SUBSCRIPTION_CHANGED|配置已删除' <<<"$output" || exit 1
remove_subscription_nginx_and_cert() { :; }
apply_state_change() { return 1; }
if output="$(delete_https_subscription_domain)"; then
  printf 'HTTPS deletion falsely succeeded after state failure\n' >&2
  exit 1
fi
! grep -Fq '配置已删除' <<<"$output" || exit 1
printf 'HTTPS_FAILURE_TEST=PASS\n'
