#!/usr/bin/env bash
# Generate per-host Authelia OIDC client-secret digests from an existing .env.
# This is safe to rerun and does NOT rotate any credentials in .env.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="${1:-.env}"
[ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE not found" >&2; exit 1; }

read_env() {
    local key="$1" value
    value=$(sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1)
    [[ "$value" =~ ^[0-9a-fA-F]+$ ]] || {
        echo "error: $key missing or not a hex secret in $ENV_FILE" >&2
        return 1
    }
    printf '%s' "$value"
}

oauth_digest() {
    docker run --rm authelia/authelia:4.39.20 \
        authelia crypto hash generate pbkdf2 --variant sha512 --password "$1" \
        | awk '/^Digest: /{print $2}'
}

mkdir -p authelia/secrets
umask 177
for pair in \
    "bulwark_client_secret:BULWARK_OAUTH_SECRET" \
    "stalwart_client_secret:STALWART_OAUTH_SECRET" \
    "vaultwarden_client_secret:VAULTWARDEN_SSO_SECRET"; do
    file=${pair%%:*}
    key=${pair#*:}
    value=$(read_env "$key")
    digest=$(oauth_digest "$value")
    [[ "$digest" == '$pbkdf2-sha512$'* ]] || {
        echo "error: Authelia did not return a PBKDF2-SHA512 digest for $key" >&2
        exit 1
    }
    printf '%s' "$digest" > "authelia/secrets/$file"
done
chmod 600 authelia/secrets/*_client_secret
echo "Wrote Authelia OIDC client-secret digests under authelia/secrets/ (mode 600)."
