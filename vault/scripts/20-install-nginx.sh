#!/usr/bin/env bash
# Install the host nginx for this stack: TLS termination + reverse proxy to
# the containers on 127.0.0.1.
#
#   sudo scripts/20-install-nginx.sh
#
# The vhosts of this stack are symlinked into /etc/nginx/conf.d/, the
# repository stays the source of truth.
set -euo pipefail
STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$STACK_DIR/.." && pwd)"
STACK="$(basename "$STACK_DIR")"

if [ "$(id -u)" -ne 0 ]; then
    echo "run this script as root: sudo scripts/20-install-nginx.sh" >&2
    exit 1
fi
exec bash "$REPO_ROOT/nginx/install.sh" "$STACK"
