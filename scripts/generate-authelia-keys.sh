#!/usr/bin/env bash
# Generate the Authelia OIDC JWKS key: authelia/keys/primary.key (RSA 2048).
#
#   scripts/generate-authelia-keys.sh [--force]
#
# authelia/configuration.yml references this file via the template
# {{ secret "/config/keys/primary.key" }} — without it the config template
# render fails and authelia crash-loops. The file is gitignored, so run this
# once on every machine (incl. the VPS) after a fresh clone.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="authelia/keys/primary.key"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ -e "$KEY" ] && [ "$FORCE" -ne 1 ]; then
    echo "OK: $KEY already exists (use --force to regenerate — invalidates existing OIDC tokens)"
    exit 0
fi

mkdir -p "$(dirname "$KEY")"
[ -e "$KEY" ] && cp "$KEY" "$KEY.bak.$(date +%s)"
openssl genrsa -out "$KEY" 2048
chmod 600 "$KEY"
echo "wrote $KEY (600)"
echo "apply with: docker compose restart authelia"
