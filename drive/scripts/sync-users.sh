#!/usr/bin/env bash
# Create / refresh the Nextcloud accounts for the active Authentik users of
# the mail domain, and apply per-group quotas.
#
#   scripts/sync-users.sh [--dry-run] [--emails FILE]
#
# Why this script and not a claim:
#   The user_oidc app's `quota` claim is re-applied on EVERY login and would
#   overwrite any quota an admin set manually. So we read groups from
#   Authentik once, pick the highest priority, and write the quota to the
#   oc_preferences table directly. The user_oidc provider is configured
#   without a quota claim in scripts/01-bootstrap-nextcloud.sh.
#
# Quota resolution:
#   - If the user is in N groups listed in DRIVE_QUOTA_GROUPS, pick the
#     first one (priority: left to right).
#   - Otherwise, DRIVE_DEFAULT_QUOTA.
#
# Requirements: curl, jq, docker (and an Authentik API token with read
# access to core/users — same as mail/scripts/sync-users.sh).
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
: "${DRIVE_DEFAULT_QUOTA:?DRIVE_DEFAULT_QUOTA is missing in .env}"
: "${DRIVE_QUOTA_GROUPS:=}"

########## helpers ##########
occ() {
    local cid
    cid=$(docker compose ps -q nextcloud)
    if [ -z "$cid" ]; then
        echo "error: the nextcloud container is not running; start the stack first" >&2
        exit 1
    fi
    docker exec -u www-data "$cid" php occ "$@"
}

# `occ user:list` prints a table; extract the first column (uid).
existing_users() { occ user:list --output=json 2>/dev/null | jq -r '.[].uid'; }

# A non-secret random password; we never log in with it (DRIVE_OIDC_LOGIN_REQUIRED).
random_password() { openssl rand -base64 32 | tr -d '/+=' | head -c 40; }

# Resolve a quota string like "5 GB" to bytes, using Nextcloud's own parser
# (Util::computerFileSize) so that "5 GB", "5GB", "5 gb" all work.
to_bytes() {
    local s="$1"
    occ config:app:set --value="$s" files _quota_probe >/dev/null
    local probe
    probe=$(occ user:setting admin files quota 2>/dev/null)
    echo "$probe"
}

########## 1. wanted addresses (with their groups) ##########
read_wanted() {
    : "${AUTHENTIK_API_TOKEN:?AUTHENTIK_API_TOKEN is missing in .env (see README)}"
    echo "reading users + groups from $AUTHENTIK_URL ..." >&2
    page=1
    while [ "$page" -le 50 ]; do
        response=$(curl -fsS -H "Authorization: Bearer $AUTHENTIK_API_TOKEN" \
            "$AUTHENTIK_URL/api/v3/core/users/?is_active=true&page_size=100&page=$page") || {
            echo "error: Authentik API request failed" >&2
            exit 1
        }
        # emit: "<email>|<comma-joined group names>"
        printf '%s' "$response" | jq -r '
            .results[]
            | select(.is_active == true)
            | "\(.email // empty)|\((.groups // []) | map(.name) | join(","))"
        ' || true
        count=$(printf '%s' "$response" | jq '.results | length')
        [ "$count" -lt 100 ] && break
        page=$((page + 1))
    done
}

if [ -n "$EMAIL_FILE" ]; then
    [ -f "$EMAIL_FILE" ] || { echo "error: $EMAIL_FILE not found" >&2; exit 1; }
    wanted=$(tr ',' '\n' < "$EMAIL_FILE" | sed 's/[[:space:]]//g' | grep -i "^[^@]*@${MAIL_DOMAIN}$" | sort -u | awk -F'@' '{print $0"|"}')
else
    wanted=$(read_wanted | grep -i "^[^|]*@${MAIL_DOMAIN}$|" | sort -u || true)
fi
if [ -z "$wanted" ]; then
    echo "no users found for @$MAIL_DOMAIN — nothing to do"
    exit 0
fi
count=$(printf '%s\n' "$wanted" | grep -c . || true)
echo "$count user(s) in @$MAIL_DOMAIN"

########## 2. existing accounts (uid only) ##########
existing=$(existing_users || true)
existing_set="|$(printf '%s\n' "$existing" | tr '[:upper:]' '[:lower:]' | sort -u | paste -sd'|' -)|"

########## 3. quota map ##########
# parse "staff=50 GB,backup=200 GB" -> ordered associative array
declare -A QUOTA_MAP
priority=()
IFS=',' read -r -a pairs <<< "$DRIVE_QUOTA_GROUPS"
for pair in "${pairs[@]}"; do
    case "$pair" in
        *=*) group=${pair%%=*}; quota=${pair#*=};;
        *)   group=$pair;       quota=$DRIVE_DEFAULT_QUOTA;;
    esac
    QUOTA_MAP["$group"]="$quota"
    priority+=("$group")
done

resolve_quota() {
    local groups_csv="$1"
    IFS=',' read -r -a gs <<< "$groups_csv"
    for g in "${priority[@]}"; do
        for ug in "${gs[@]}"; do
            if [ "$ug" = "$g" ]; then
                echo "${QUOTA_MAP[$g]}"
                return
            fi
        done
    done
    echo "$DRIVE_DEFAULT_QUOTA"
}

########## 4. plan + apply ##########
created=0
quota_set=0
group_added=0
group_removed=0
skipped=0
while IFS='|' read -r email groups_csv; do
    [ -n "$email" ] || continue
    email_lc=$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')
    quota=$(resolve_quota "$groups_csv")
    in_existing=0
    case "$existing_set" in
        *"|$email_lc|"*) in_existing=1 ;;
    esac

    if [ "$in_existing" -eq 0 ]; then
        pw=$(random_password)
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "would create $email quota=$quota groups=${groups_csv:-<none>}"
            created=$((created + 1))
            continue
        fi
        echo "creating $email (quota=$quota)"
        OCC_PASS="$pw" occ user:add --password-from-env --display-name="$email_lc" "$email_lc" >/dev/null
        created=$((created + 1))
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "exists   $email (would set quota=$quota, groups=${groups_csv:-<none>})"
        fi
    fi

    if [ "$DRY_RUN" -ne 1 ]; then
        occ user:setting "$email_lc" files quota "$quota" >/dev/null
        quota_set=$((quota_set + 1))

        # group membership
        wanted_groups=$(printf '%s' "$groups_csv" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' | tr '[:upper:]' '[:lower:]' | sort -u)
        for g in $wanted_groups; do
            occ group:adduser "$g" "$email_lc" >/dev/null 2>&1 && group_added=$((group_added + 1)) || true
        done
        # drop Authentik groups the user no longer has
        current_groups=$(occ group:list-user "$email_lc" --output=json 2>/dev/null | jq -r '.[].gid' || true)
        for g in $current_groups; do
            case "$g" in
                admin) continue ;;  # never strip the built-in admin group from admin users
            esac
            if ! printf '%s\n' "$wanted_groups" | grep -Fxq "$g"; then
                occ group:removeuser "$g" "$email_lc" >/dev/null 2>&1 && group_removed=$((group_removed + 1)) || true
            fi
        done
    fi
done <<EOF
$wanted
EOF

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry run — no changes were made"
    exit 0
fi
echo "done: created=$created quota_set=$quota_set group_added=$group_added group_removed=$group_removed"
