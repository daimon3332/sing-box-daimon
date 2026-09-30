#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/sb.sh"

is_alpine() { return 0; }
for address in '1::2:' ':1::2' '2001:db8::1::2' '1:2:3:4:5:6:7:8::' ':::'; do
  if valid_ip_address "$address" 6; then
    printf 'invalid IPv6 accepted: %s\n' "$address" >&2
    exit 1
  fi
done
for address in '::' '::1' '2001:db8::1' '1:2:3:4:5:6:7:8'; do
  valid_ip_address "$address" 6
done
for address in '1.2.3.4.' '01.2.3.4' '999.2.3.4'; do
  ! endpoint_host_value "$address" >/dev/null || exit 1
done
! endpoint_host_value '[example.com]' >/dev/null || exit 1
valid_port 0080
! valid_port 18446744073709551617 || exit 1
[[ "$(endpoint_host_value '[2001:db8::1]')" == '2001:db8::1' ]]

printf 'ADDRESS_VALIDATION_TEST=PASS\n'
