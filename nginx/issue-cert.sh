#!/usr/bin/env bash
# Issue (or renew) the TLS certificate of the stack in the current directory.
#
#   bash <repo>/nginx/issue-cert.sh domain [domain ...]
#
# The certificate is always issued as --cert-name june8th.eu.org so every host
# ends up with the same path (/etc/letsencrypt/live/june8th.eu.org/), which
# the Stalwart certificate object inside the container refers to.
#
# certbot runs in webroot mode: the host nginx serves /.well-known/acme-challenge/
# from /var/www/certbot, so there is no downtime and the renewal only has to
# reload nginx.
set -euo pipefail

CERT_NAME=june8th.eu.org

if [ $# -lt 1 ]; then
    echo "usage: $0 <domain> [domain ...]" >&2
    exit 1
fi
DOMAINS=("$@")

command -v certbot >/dev/null || { echo "error: certbot is required (apt install certbot)" >&2; exit 1; }
command -v nginx    >/dev/null || { echo "error: nginx is not installed; run scripts/20-install-nginx.sh first" >&2; exit 1; }
[ -f .env ] || { echo "error: .env is missing; run scripts/00-generate-env.sh first" >&2; exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env; set +a
ACME_EMAIL="${ACME_EMAIL:-admin@june8th.eu.org}"
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
CERTBOT_WEBROOT="${CERTBOT_WEBROOT:-/var/www/certbot}"
export LETSENCRYPT_DIR   # certbot honours LETSENCRYPT_DIR

install -d -m 755 "$CERTBOT_WEBROOT"

if ! systemctl is-active --quiet nginx 2>/dev/null; then
    echo "error: nginx is not running — it has to serve the ACME challenge" >&2
    echo "       systemctl start nginx" >&2
    exit 1
fi

args=(certonly --webroot -w "$CERTBOT_WEBROOT" --non-interactive --agree-tos
    --email "$ACME_EMAIL" --cert-name "$CERT_NAME")
for d in "${DOMAINS[@]}"; do args+=(-d "$d"); done

# after a renewal nginx has to pick up the new certificate ...
args+=(--deploy-hook "systemctl reload nginx || nginx -s reload")
# ... and on the mail host Stalwart serves 465/587/993/995 with it
if [ -f compose.yaml ] && grep -q "^  stalwart:" compose.yaml; then
    args+=(--deploy-hook "docker compose restart stalwart")
fi

certbot "${args[@]}"

echo "certificate ready: $LETSENCRYPT_DIR/live/$CERT_NAME/"
