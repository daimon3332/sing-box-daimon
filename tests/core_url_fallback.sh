#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB_PATH="${SB_PATH:-$REPO_ROOT/sb.sh}"
eval "$(sed -n '/^core_download_url() {/,/^}/p' "$SB_PATH")"

# The unauthenticated GitHub API is capped at 60 requests/hour per IP. A shared
# or NAT address can exhaust it, and download_core then had no URL at all and
# aborted the install. Resolving the /releases/latest redirect has no such cap.

API_OK=true
REDIRECT='https://github.com/SagerNet/sing-box/releases/tag/v1.14.0'
curl() {
  if [[ "$*" == *api.github.com* ]]; then
    [[ "$API_OK" == true ]] || return 22
    printf '%s\n' '    "browser_download_url": "https://example.test/sing-box-1.14.0-linux-amd64.tar.gz"'
    printf '%s\n' '    "browser_download_url": "https://example.test/sing-box-1.14.0-linux-amd64.tar.gz.asc"'
    return 0
  fi
  if [[ "$*" == *releases/latest* ]]; then
    [[ -n "$REDIRECT" ]] || return 22
    printf '%s' "$REDIRECT"
    return 0
  fi
  return 22
}

# API reachable: its asset URL is used and the .asc signature is skipped.
API_OK=true
url="$(core_download_url amd64)"
[[ "$url" == "https://example.test/sing-box-1.14.0-linux-amd64.tar.gz" ]]

# API rate-limited: fall back to the redirect and build the asset URL.
API_OK=false
url="$(core_download_url amd64)"
[[ "$url" == "https://github.com/SagerNet/sing-box/releases/download/v1.14.0/sing-box-1.14.0-linux-amd64.tar.gz" ]]
url="$(core_download_url arm64)"
[[ "$url" == "https://github.com/SagerNet/sing-box/releases/download/v1.14.0/sing-box-1.14.0-linux-arm64.tar.gz" ]]
url="$(core_download_url armv7)"
[[ "$url" == *"linux-armv7.tar.gz" ]]

# Both sources unavailable: return empty so download_core reports a clear error
# rather than curling an empty or malformed URL.
REDIRECT=''
[[ -z "$(core_download_url amd64)" ]]

# A redirect that never resolved to a tag must not be parsed into a version.
REDIRECT='https://github.com/SagerNet/sing-box/releases'
[[ -z "$(core_download_url amd64)" ]]

# Nor may a junk redirect produce a URL.
REDIRECT='https://github.com/login?return_to=%2FSagerNet'
[[ -z "$(core_download_url amd64)" ]]

# A pre-release style tag still resolves.
REDIRECT='https://github.com/SagerNet/sing-box/releases/tag/v1.15.0-beta.3'
url="$(core_download_url amd64)"
[[ "$url" == "https://github.com/SagerNet/sing-box/releases/download/v1.15.0-beta.3/sing-box-1.15.0-beta.3-linux-amd64.tar.gz" ]]

printf 'CORE_URL_FALLBACK_TEST=PASS\n'
