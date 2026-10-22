#!/usr/bin/env bash
# Create the Stalwart mailboxes for the Authentik users of the mail domain.
#
#   scripts/sync-users.sh [--dry-run] [--emails FILE]
#
# Why this exists:
#   Stalwart's OIDC directory cannot look accounts up offline — it can only
#   validate a token and map it to an address. A mailbox therefore has to
#   exist before the first login, otherwise the login has nowhere to land and
#   inbound mail to that user is rejected. This script reads the active users
#   from Authentik (API token) and creates the missing Stalwart accounts.
#
# Requirements: curl, jq, docker (and an Authentik API token with read access
# to core/users — see the README).
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
EMAIL_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --emails) EMAIL_FILE="$2"; shift 2 ;;
        --emails=*) EMAIL_FILE="${1#*=}"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }
command -v jq    >/dev/null || { echo "error: jq is required (apt install jq)" >&2; exit 1; }
command -v curl  >/dev/null || { echo "error: curl is required" >&2; exit 1; }
[ -f .env ] || { echo "error: .env is missing; restore/create host secrets first" >&2; exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env; set +a
AUTHENTIK_URL="${AUTHENTIK_URL:-${IDP_URL:-https://idp.june8th.eu.org}}"
MAIL_DOMAIN="${MAIL_DOMAIN:-june8th.eu.org}"
: "${STALWART_ADMIN_PASSWORD:?STALWART_ADMIN_PASSWORD is missing in .env}"

########## 1. wanted addresses ##########
wanted=""
if [ -n "$EMAIL_FILE" ]; then
    [ -f "$EMAIL_FILE" ] || { echo "error: $EMAIL_FILE not found" >&2; exit 1; }
    wanted=$(tr ',' '\n' < "$EMAIL_FILE" | sed 's/[[:space:]]//g' | grep -i "^[^@]*@${MAIL_DOMAIN}$" || true)
else
    : "${AUTHENTIK_API_TOKEN:?AUTHENTIK_API_TOKEN is missing in .env (see README: Authentik API token)}"
    echo "reading users from $AUTHENTIK_URL ..."
    page=1
    while [ "$page" -le 50 ]; do
        response=$(curl -fsS -H "Authorization: Bearer $AUTHENTIK_API_TOKEN" \
            "$AUTHENTIK_URL/api/v3/core/users/?is_active=true&page_size=100&page=$page") || {
            echo "error: Authentik API request failed" >&2
            exit 1
        }
        emails=$(printf '%s' "$response" | jq -r '.results[] | select(.is_active == true) | .email // empty')
        [ -n "$emails" ] || break
        wanted="$wanted$emails"$'\n'
        count=$(printf '%s' "$emails" | grep -c . || true)
        [ "$count" -lt 100 ] && break
        page=$((page + 1))
    done
fi

wanted=$(printf '%s' "$wanted" \
    | tr '[:upper:]' '[:lower:]' \
    | grep -i "^[^@]*@${MAIL_DOMAIN}$" \
    | sort -u || true)
if [ -z "$wanted" ]; then
    echo "no users found for @$MAIL_DOMAIN — nothing to do"
    exit 0
fi
echo "$(printf '%s\n' "$wanted" | grep -c .) user(s) in @$MAIL_DOMAIN"

########## 2. existing accounts ##########
stalwart_cid=$(docker compose ps -q stalwart)
if [ -z "$stalwart_cid" ]; then
    echo "error: the stalwart container is not running; start the stack first" >&2
    exit 1
fi
export STALWART_URL=http://127.0.0.1:8080
export STALWART_USER=admin
export STALWART_PASSWORD="$STALWART_ADMIN_PASSWORD"

cli() {
    docker run --rm --network "container:${stalwart_cid}" \
        -v "$PWD/stalwart:/work:ro" \
        -e STALWART_URL -e STALWART_USER -e STALWART_PASSWORD \
        ghcr.io/stalwartlabs/cli:latest "$@"
}

domain_id=$(cli query Domain --where "name=${MAIL_DOMAIN}" --fields id --json 2>/dev/null \
    | jq -r 'select(.id != null) | .id' | head -n1)
if [ -z "$domain_id" ]; then
    echo "error: domain $MAIL_DOMAIN does not exist in Stalwart; run scripts/01-bootstrap-stalwart.sh first" >&2
    exit 1
fi

existing=$(cli query Account --json 2>/dev/null | jq -r 'select(.emailAddress != null) | .emailAddress' || true)

########## 3. build the plan ##########
plan="stalwart/users.ndjson"
: > "$plan"
index=0
missing=0
while IFS= read -r email; do
    [ -n "$email" ] || continue
    if printf '%s\n' "$existing" | grep -Fxq "$email"; then
        continue
    fi
    missing=$((missing + 1))
    local_part=${email%@*}
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would create $email (domain $domain_id)"
        continue
    fi
    jq -nc --arg id "acct-$index" --arg name "$local_part" --arg domain "$domain_id" --arg desc "$email" '{
        "@type":"create",
        "object":"Account",
        "value":{
            $id:{
                "@type":"User",
                "name":$name,
                "domainId":$domain,
                "description":$desc,
                "credentials":{},
                "memberGroupIds":{},
                "roles":{"@type":"User"},
                "permissions":{"@type":"Inherit"},
                "quotas":{},
                "aliases":{},
                "encryptionAtRest":{"@type":"Disabled"}
            }
        }
    }' >> "$plan"
    index=$((index + 1))
done <<EOF
$wanted
EOF

if [ "$DRY_RUN" -eq 1 ]; then
    echo "$missing account(s) missing — dry run, nothing written"
    exit 0
fi
if [ "$missing" -eq 0 ]; then
    echo "all accounts already exist — nothing to do"
    exit 0
fi

echo "creating $missing account(s)..."
cli apply --file "/work/$(basename "$plan")"

# Stalwart caches the absence of accounts it has never seen; drop that cache
# so the new accounts are usable immediately.
cli create Action --json '{"@type":"InvalidateCaches"}' >/dev/null 2>&1 || \
    echo "warning: could not invalidate the Stalwart account cache; restart the container if logins fail" >&2

echo "done: $missing account(s) created for @$MAIL_DOMAIN"
