#!/usr/bin/env bash
# Issue (or renew) the TLS certificate of this stack.
#
#   scripts/10-tls.sh [domain ...]
#
# The certificate is always issued as --cert-name june8th.eu.org, so the path
# is /etc/letsencrypt/live/june8th.eu.org/ on every host.
#
# certbot runs in webroot mode against the host nginx (which terminates TLS),
# so there is no downtime and the renewal only reloads nginx.
set -euo pipefail
STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$STACK_DIR/.." && pwd)"
cd "$STACK_DIR"

if [ $# -gt 0 ]; then
    DOMAINS=("$@")
else
    DOMAINS=(idp.june8th.eu.org)
fi
exec bash "$REPO_ROOT/nginx/issue-cert.sh" "${DOMAINS[@]}"
