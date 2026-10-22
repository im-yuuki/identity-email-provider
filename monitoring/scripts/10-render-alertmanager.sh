#!/usr/bin/env bash
# Render the Alertmanager configuration from .env.
#
#   scripts/10-render-alertmanager.sh
#
# The image has no envsubst, so the receivers block is generated here and
# spliced into alertmanager/alertmanager.yml.tmpl. Run it before starting the
# stack and after every change to the delivery settings in .env.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "error: .env is missing; run scripts/00-generate-env.sh first" >&2; exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env; set +a

WEBHOOK="${ALERT_WEBHOOK_URL:-}"
TELEGRAM_TOKEN="${ALERT_TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT="${ALERT_TELEGRAM_CHAT_ID:-}"

if [ -z "$WEBHOOK" ]; then
    echo "warning: ALERT_WEBHOOK_URL is empty — alerts are collected but not delivered" >&2
    WEBHOOK="http://127.0.0.1:9/alerts-unconfigured"
fi

recv=$(mktemp)
trap 'rm -f "$recv"' EXIT

{
    printf '  - name: default\n'
    printf '    webhook_configs:\n'
    printf '      - url: "%s"\n' "$WEBHOOK"
    printf '        send_resolved: true\n'
} > "$recv"

if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT" ]; then
    {
        printf '  - name: telegram\n'
        printf '    telegram_configs:\n'
        printf '      - bot_token: "%s"\n' "$TELEGRAM_TOKEN"
        printf '        chat_id: "%s"\n' "$TELEGRAM_CHAT"
        printf '        send_resolved: true\n'
    } >> "$recv"
    echo "telegram receiver enabled"
else
    echo "telegram receiver disabled (set ALERT_TELEGRAM_BOT_TOKEN and ALERT_TELEGRAM_CHAT_ID)"
fi

out="alertmanager/alertmanager.yml"
awk -v receivers_file="$recv" '
    /^__RECEIVERS__$/ {
        while ((getline line < receivers_file) > 0) print line
        close(receivers_file)
        next
    }
    { print }
' alertmanager/alertmanager.yml.tmpl > "$out"

echo "wrote $out"
