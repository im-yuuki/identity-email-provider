#!/usr/bin/env bash
# Issue (or renew) the TLS certificate for this stack with certbot.
#
#   scripts/10-tls.sh [domain ...]
#
# The certificate is always issued as --cert-name june8th.eu.org so every host
# exposes the same in-container path (/etc/letsencrypt/live/june8th.eu.org/),
# which nginx and Stalwart hardcode.
#
# certbot runs in standalone mode, so the stack's nginx container is stopped
# for the duration of the request. The renewal hooks installed below do the
# same automatically, so `certbot renew` works unattended.
set -euo pipefail
cd "$(dirname "$0")/.."

CERT_NAME=june8th.eu.org
DEFAULT_DOMAINS=(idp.june8th.eu.org)

if [ $# -gt 0 ]; then
    DOMAINS=("$@")
else
    DOMAINS=("${DEFAULT_DOMAINS[@]}")
fi

command -v certbot >/dev/null || { echo "error: certbot is required (apt install certbot)" >&2; exit 1; }
[ -f .env ] || { echo "error: .env is missing; run scripts/00-generate-env.sh first" >&2; exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env; set +a
ACME_EMAIL="${ACME_EMAIL:-admin@june8th.eu.org}"
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
export LETSENCRYPT_DIR   # certbot honours LETSENCRYPT_DIR

STACK_DIR="$PWD"
nginx_was_running=0
if docker compose ps --status running nginx 2>/dev/null | grep -q nginx; then
    nginx_was_running=1
    echo "stopping nginx for the certbot run..."
    docker compose stop nginx
fi

restore_nginx() {
    if [ "$nginx_was_running" -eq 1 ]; then
        echo "starting nginx again..."
        docker compose start nginx || true
    fi
}
trap restore_nginx EXIT

args=(certonly --standalone --non-interactive --agree-tos
    --email "$ACME_EMAIL" --cert-name "$CERT_NAME")
for d in "${DOMAINS[@]}"; do args+=(-d "$d"); done
certbot "${args[@]}"

# Renewal hooks: nginx has to release port 80 while certbot renews standalone.
hook_dir="${LETSENCRYPT_DIR}/renewal-hooks"
mkdir -p "$hook_dir/pre" "$hook_dir/post"
cat > "$hook_dir/pre/stop-nginx" <<EOF
#!/bin/sh
docker compose -f "$STACK_DIR/compose.yaml" stop nginx || true
EOF
cat > "$hook_dir/post/start-nginx" <<EOF
#!/bin/sh
docker compose -f "$STACK_DIR/compose.yaml" start nginx || true
EOF
chmod +x "$hook_dir/pre/stop-nginx" "$hook_dir/post/start-nginx"

echo "certificate ready: $LETSENCRYPT_DIR/live/$CERT_NAME/"
