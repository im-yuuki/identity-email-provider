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

recovery_started=0
restore_normal_mode() {
    if [ "$recovery_started" -eq 1 ]; then
        echo "Returning Stalwart to normal mode..."
        docker compose up -d stalwart
    fi
}
trap restore_normal_mode EXIT

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
    echo "error: LDAP admin password in .env does not match persisted LDAP data" >&2
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
recovery_started=1
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

read -r -s -p "Stalwart recovery admin password (STALWART_ADMIN_PASSWORD): " STALWART_PASSWORD
echo
export STALWART_PASSWORD

cli=(docker run --rm --network container:stalwart
    -v "$PWD/stalwart:/work:ro"
    -e STALWART_URL=http://127.0.0.1:8080
    -e STALWART_USER=admin
    -e STALWART_PASSWORD
    ghcr.io/stalwartlabs/cli:latest)
"${cli[@]}" apply --file /work/bootstrap.ndjson --dry-run
"${cli[@]}" apply --file /work/bootstrap.ndjson

restore_normal_mode
recovery_started=0
trap - EXIT
echo "Stalwart configuration applied; it is back in normal mode."
