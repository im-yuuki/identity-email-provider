#!/usr/bin/env bash
# First-boot configuration of the Nextcloud container.
#
#   scripts/01-bootstrap-nextcloud.sh
#
# Idempotent: safe to re-run after editing .env. Operates only through
# `occ` inside the nextcloud container, so it needs docker + the stack
# already running.
#
# Steps:
#   1. install the OIDC + E2EE community apps
#   2. set trusted_domains, overwrite.cli.url, overwriteprotocol,
#      trusted_proxies
#   3. set the user_oidc provider (claims, group claim, login restriction)
#   4. set a sensible default quota
#   5. configure a redis lock + memcache (use the `redis` container)
#   6. register the system cron
#
# Authentik provider (in Authentik):
#   client id     : $DRIVE_OIDC_CLIENT_ID
#   client secret : $DRIVE_OIDC_SECRET
#   redirect URI  : https://$DRIVE_HOSTNAME/apps/oidc/callback
#   scopes        : openid profile email groups
#   subject mode  : based on the user identifier, claim email
#   (do NOT add a `quota` claim — sync-users.sh owns the quota)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }
command -v jq    >/dev/null || { echo "error: jq is required (apt install jq)" >&2; exit 1; }

[ -f .env ] || { echo "error: .env is missing; run scripts/00-generate-env.sh first" >&2; exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${IDP_URL:?IDP_URL is missing in .env}"
: "${DRIVE_OIDC_CLIENT_ID:?DRIVE_OIDC_CLIENT_ID is missing in .env}"
: "${DRIVE_OIDC_SECRET:?DRIVE_OIDC_SECRET is missing in .env}"
: "${DRIVE_HOSTNAME:?DRIVE_HOSTNAME is missing in .env}"

occ() {
    local cid
    cid=$(docker compose ps -q nextcloud)
    if [ -z "$cid" ]; then
        echo "error: the nextcloud container is not running; start the stack first" >&2
        exit 1
    fi
    docker exec -u www-data "$cid" php occ "$@"
}

echo "==> waiting for the Nextcloud container to be ready"
for _ in $(seq 1 60); do
    if occ status >/dev/null 2>&1; then break; fi
    sleep 2
done
occ status >/dev/null || { echo "error: Nextcloud did not become ready" >&2; exit 1; }

########## 1. trusted domains + URL ##########
echo "==> trusted_domains / overwrite.cli.url"
# index 0 is "localhost" by default; the public hostname goes at index 1.
# Re-set every entry to make the script idempotent.
occ config:system:delete trusted_domains >/dev/null 2>&1 || true
occ config:system:set trusted_domains 0 --value="$DRIVE_HOSTNAME" >/dev/null
i=1
for d in $(printf '%s' "${DRIVE_TRUSTED_DOMAINS:-$DRIVE_HOSTNAME}" | tr ',' ' '); do
    [ -n "$d" ] || continue
    occ config:system:set trusted_domains "$i" --value="$d" >/dev/null
    i=$((i + 1))
done
occ config:system:set overwrite.cli.url     --value="https://$DRIVE_HOSTNAME" >/dev/null
occ config:system:set overwriteprotocol     --value="https" >/dev/null
occ config:system:set forward_for_headers   --value="1" --type=boolean >/dev/null
# host nginx adds X-Forwarded-For — trust only the loopback it traverses
occ config:system:set trusted_proxies 0     --value="127.0.0.1" >/dev/null

########## 2. apps ##########
echo "==> installing apps"
needed=(
    user_oidc
    end_to_end_encryption
    files_sharing
    files_trashbin
    files_versions
)
for app in "${needed[@]}"; do
    if occ app:list --shipped=false --output=json 2>/dev/null | jq -e --arg a "$app" '.enabled[$a] != null or .disabled[$a] != null' >/dev/null 2>&1; then
        echo "    $app already present"
        continue
    fi
    if ! occ app:install "$app" >/dev/null 2>&1; then
        echo "    $app: install failed (continuing; re-run after checking the marketplace URL)"
    fi
done
for app in "${needed[@]}"; do
    occ app:enable "$app" >/dev/null 2>&1 || true
done

########## 3. memcache + file locking (redis) ##########
echo "==> memcache + file locking via redis"
occ config:system:set memcache.local   --value='\OC\Memcache\Redis' >/dev/null
occ config:system:set memcache.distributed --value='\OC\Memcache\Redis' >/dev/null
occ config:system:set memcache.locking --value='\OC\Memcache\Redis' >/dev/null
occ config:system:set redis host     --value='redis' >/dev/null
occ config:system:set redis port     --value=6379      --type=integer >/dev/null
occ config:system:set redis password --value="$DRIVE_REDIS_PASSWORD" >/dev/null
occ config:system:set redis dbindex  --value=0         --type=integer >/dev/null
occ config:system:set redis timeout  --value=1.5       --type=double  >/dev/null

########## 4. user_oidc provider ##########
echo "==> user_oidc provider (nextcloud)"
ISSUER="${IDP_URL%/}/application/o/${DRIVE_OIDC_CLIENT_ID}/"
PROVIDER_UID=1
# idempotent: delete the old provider, recreate it; user_oidc stores its
# providers in the oc_oidc_providers table, deleting the row removes the
# old config cleanly.
existing=$(occ user_oidc:provider --output=json 2>/dev/null | jq -r --arg c "$DRIVE_OIDC_CLIENT_ID" '.[] | select(.clientId == $c) | .id' | head -n1)
if [ -n "$existing" ]; then
    echo "    removing existing provider id=$existing"
    occ user_oidc:provider "$existing" --delete >/dev/null 2>&1 || true
fi
occ user_oidc:provider "$PROVIDER_UID" \
    --clientid="$DRIVE_OIDC_CLIENT_ID" \
    --clientsecret="$DRIVE_OIDC_SECRET" \
    --issuer="$ISSUER" \
    --authorization-endpoint="$ISSUER/authorize/" \
    --token-endpoint="$ISSUER/token/" \
    --userinfo-endpoint="$ISSUER/userinfo/" \
    --jwks-uri="$ISSUER/jwks/" \
    --end-session-endpoint="$ISSUER/end-session/" \
    --scope="openid profile email groups" \
    --mapping-uid=sub \
    --mapping-display-name=name \
    --mapping-email=email \
    --mapping-groups=groups \
    --use-email-as-uid=0 \
    --unique-uid=1 \
    --check-redirect-uri=1 \
    --redirect-uri="https://$DRIVE_HOSTNAME/apps/oidc/callback" \
    --logout-uri="https://$DRIVE_HOSTNAME" \
    --group-provisioning=1 \
    --groups-claim=groups >/dev/null
if [ "${DRIVE_OIDC_LOGIN_REQUIRED:-true}" = "true" ]; then
    # app:disable is the right way to enforce OIDC-only login (user_oidc >= 8.6)
    occ app:disable password >/dev/null 2>&1 || true
    # hide the username/password form so the OIDC button is the only path
    occ config:app:set --value=1 user_oidc force_login_button >/dev/null 2>&1 || true
fi

########## 5. default quota + E2EE app settings ##########
echo "==> default quota + E2EE app settings"
# `occ user:setting` only sets on a specific user; the default quota is a
# config value on the `files` app. The string is stored verbatim and
# parsed by Util::computerFileSize on use.
occ config:app:set --value="$DRIVE_DEFAULT_QUOTA" files default_quota >/dev/null
# admin does not need a quota
occ user:setting admin files quota none >/dev/null

# E2EE: nothing server-side to tweak for v2.5 — the keys live in oc_e2e_*
# tables and the master key is derived client-side.
occ config:app:set --value=1 end_to_end_encryption enable_encryption >/dev/null 2>&1 || true

########## 6. background jobs (system cron) ##########
echo "==> switching background jobs to system cron"
occ background:cron >/dev/null

echo
echo "nextcloud bootstrap complete"
echo
echo "remaining manual step: run scripts/sync-users.sh to pre-provision the"
echo "existing Authentik users and apply per-group quotas."
echo
echo "verifying:"
occ status | head -n 30
echo
occ app:list | grep -E "user_oidc|end_to_end_encryption" || true
