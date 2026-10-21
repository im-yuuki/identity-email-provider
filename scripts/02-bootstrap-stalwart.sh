#!/usr/bin/env bash
# One-time Stalwart bootstrap/config reconciliation.
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
docker compose config --quiet

cleanup_needed=0
cleanup() {
    status=$?
    trap - EXIT
    if [ "$cleanup_needed" -eq 1 ]; then
        echo "Stopping and removing all Compose containers (named volumes are kept)..."
        if ! docker compose down --remove-orphans; then
            echo "warning: Compose cleanup failed; check for remaining containers" >&2
            [ "$status" -ne 0 ] || status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

cleanup_needed=1
echo "Starting LDAP and verifying existing credentials..."
docker compose up -d openldap
ready=0
for _ in $(seq 1 60); do
    if docker compose exec -T openldap sh -c 'nc -z 127.0.0.1 389' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    echo "error: OpenLDAP did not become ready" >&2
    exit 1
fi

# Match the existing credential when possible. If a password is already set but
# the current .env value does not authenticate, stop instead of rotating it.
docker compose exec -T openldap sh -ec '
  uri=ldap://127.0.0.1:389
  admin="cn=admin,dc=june8th,dc=eu,dc=org"
  svc="uid=svc-mail,ou=services,dc=june8th,dc=eu,dc=org"
  if ! ldapwhoami -x -H "$uri" -D "$admin" -w "$LDAP_ADMIN_PASSWORD" >/dev/null 2>&1; then
    echo "error: LDAP_ADMIN_PASSWORD in .env does not match the existing ldap-data volume" >&2
    echo "A newly generated .env cannot authenticate against the old LDAP database." >&2
    echo "Restore the matching .env backup; do not prune or reinitialize volumes unless the data is disposable." >&2
    exit 1
  fi
  if ldapwhoami -x -H "$uri" -D "$svc" -w "$STALWART_LDAP_BIND_PASSWORD" >/dev/null 2>&1; then
    echo "LDAP svc-mail password already matches .env"
  else
    entry=$(ldapsearch -x -LLL -H "$uri" -D "$admin" -w "$LDAP_ADMIN_PASSWORD" -b "$svc" -s base userPassword)
    if printf "%s\n" "$entry" | grep -q "^userPassword:"; then
      echo "error: svc-mail password differs from .env; refusing to change a persisted credential" >&2
      exit 1
    fi
    ldapmodify -x -H "$uri" -D "$admin" -w "$LDAP_ADMIN_PASSWORD" <<EOF
dn: $svc
changetype: modify
replace: userPassword
userPassword: $STALWART_LDAP_BIND_PASSWORD
EOF
  fi'

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
    echo "error: Stalwart recovery listener did not become ready" >&2
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
