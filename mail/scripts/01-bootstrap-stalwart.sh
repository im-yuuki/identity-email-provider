#!/usr/bin/env bash
# One-time Stalwart bootstrap/config reconciliation.
#
#   scripts/01-bootstrap-stalwart.sh
#
# Applies stalwart/bootstrap.ndjson (domain, TLS certificate, OIDC directory
# pointing at Authentik, system settings) to a freshly started Stalwart in
# recovery mode, then restarts the stack without recovery mode.
#
# The plan is idempotent (upsert/update), so it can be re-run safely.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
    echo "error: .env is missing; restore/create host secrets first" >&2
    exit 1
fi
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }
for file in stalwart/config.json stalwart/bootstrap.ndjson compose.stalwart-recovery.yaml; do
    [ -f "$file" ] || { echo "error: missing $file" >&2; exit 1; }
done

# shellcheck disable=SC1091
set -a; . ./.env; set +a
IDP_URL="${IDP_URL:-https://idp.june8th.eu.org}"
BULWARK_OAUTH_CLIENT_ID="${BULWARK_OAUTH_CLIENT_ID:-bulwark}"

docker compose config --quiet

# Render the plan: the IdP URL and client id come from .env.
rendered="stalwart/bootstrap.rendered.ndjson"
sed -e "s|\${IDP_URL}|${IDP_URL}|g" \
    -e "s|\${BULWARK_OAUTH_CLIENT_ID}|${BULWARK_OAUTH_CLIENT_ID}|g" \
    stalwart/bootstrap.ndjson > "$rendered"

cleanup_needed=0
cleanup() {
    status=$?
    trap - EXIT
    if [ "$cleanup_needed" -eq 1 ]; then
        echo "Stopping and removing all Compose containers (named volumes are kept)..."
        if ! docker compose -f compose.yaml -f compose.stalwart-recovery.yaml down --remove-orphans; then
            echo "warning: Compose cleanup failed; check for remaining containers" >&2
            [ "$status" -ne 0 ] || status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

cleanup_needed=1
echo "Starting Stalwart in recovery mode..."
docker compose -f compose.yaml -f compose.stalwart-recovery.yaml up -d stalwart
ready=0
for _ in $(seq 1 60); do
    if docker compose exec -T stalwart sh -c 'nc -z 127.0.0.1 8080' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    echo "error: Stalwart did not become ready" >&2
    exit 1
fi

recovery_admin=$(docker compose exec -T stalwart sh -c 'printf "%s" "$STALWART_RECOVERY_ADMIN"')
case "$recovery_admin" in
    admin:*) STALWART_PASSWORD=${recovery_admin#admin:} ;;
    *)
        unset recovery_admin
        echo "error: STALWART_RECOVERY_ADMIN is missing or does not use the admin account" >&2
        exit 1
        ;;
esac
unset recovery_admin
if [ -z "$STALWART_PASSWORD" ]; then
    echo "error: recovery admin password is empty; check STALWART_ADMIN_PASSWORD in .env" >&2
    exit 1
fi
export STALWART_PASSWORD

stalwart_cid=$(docker compose ps -q stalwart)
if [ -z "$stalwart_cid" ]; then
    echo "error: could not resolve the Stalwart container id" >&2
    exit 1
fi

cli=(docker run --rm --network "container:${stalwart_cid}"
    -v "$PWD/stalwart:/work:ro"
    -e STALWART_URL=http://127.0.0.1:8080
    -e STALWART_USER=admin
    -e STALWART_PASSWORD
    ghcr.io/stalwartlabs/cli:latest)
"${cli[@]}" apply --file "/work/$(basename "$rendered")" --dry-run
"${cli[@]}" apply --file "/work/$(basename "$rendered")"

echo "Stalwart configuration applied."

cleanup_needed=0
docker compose -f compose.yaml -f compose.stalwart-recovery.yaml down --remove-orphans
echo "Starting the mail stack without recovery mode..."
docker compose up -d
echo "Done. Next: scripts/sync-users.sh to create the mailboxes."
