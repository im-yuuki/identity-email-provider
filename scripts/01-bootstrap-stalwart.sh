#!/usr/bin/env bash
# One-time Stalwart bootstrap/config reconciliation.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
    echo "error: .env is missing; restore/create host secrets first" >&2
    exit 1
fi
if ! grep -Eq '^AUTHENTIK_LDAP_TOKEN=.+$' .env; then
    echo "error: AUTHENTIK_LDAP_TOKEN is empty; create the LDAP outpost in Authentik and add its token to .env" >&2
    exit 1
fi
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }
for file in stalwart/config.json stalwart/bootstrap.ndjson compose.stalwart-recovery.yaml; do
    [ -f "$file" ] || { echo "error: missing $file" >&2; exit 1; }
done
docker compose config --quiet

cleanup_needed=0
cleanup() {
    status=$?
    trap - EXIT
    if [ "$cleanup_needed" -eq 1 ]; then
        echo "Stopping and removing all Compose containers (named volumes are kept)..."
        if ! docker compose --profile ldap down --remove-orphans; then
            echo "warning: Compose cleanup failed; check for remaining containers" >&2
            [ "$status" -ne 0 ] || status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

cleanup_needed=1
echo "Starting Authentik LDAP outpost and Stalwart in recovery mode..."
docker compose --profile ldap -f compose.yaml -f compose.stalwart-recovery.yaml up -d authentik-ldap stalwart
ready=0
for _ in $(seq 1 60); do
    if docker compose exec -T stalwart sh -c 'nc -z 127.0.0.1 8080 && nc -z authentik-ldap 3389' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    echo "error: Stalwart or Authentik LDAP outpost did not become ready" >&2
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

cli=(docker run --rm --network container:stalwart
    -v "$PWD/stalwart:/work:ro"
    -e STALWART_URL=http://127.0.0.1:8080
    -e STALWART_USER=admin
    -e STALWART_PASSWORD
    ghcr.io/stalwartlabs/cli:latest)
"${cli[@]}" apply --file /work/bootstrap.ndjson --dry-run
"${cli[@]}" apply --file /work/bootstrap.ndjson

echo "Stalwart configuration applied."
