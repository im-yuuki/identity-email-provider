#!/usr/bin/env bash
# Install the host nginx for one stack: main config + the vhosts of the stack.
#
#   sudo bash nginx/install.sh <idp|mail|vault|monitoring>
#
# The stack directories keep their vhosts in <stack>/nginx/conf.d/ — this
# script symlinks them into /etc/nginx/conf.d/, so the repository stays the
# single source of truth and `git pull` is enough to update a vhost.
#
# TLS is terminated by this nginx: the containers only publish their ports on
# 127.0.0.1.
set -euo pipefail

STACK="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$STACK" ]; then
    echo "usage: sudo bash nginx/install.sh <idp|mail|vault|monitoring>" >&2
    exit 1
fi

CONF_D="$REPO_ROOT/$STACK/nginx/conf.d"
if [ ! -d "$CONF_D" ]; then
    echo "error: $CONF_D not found (unknown stack '$STACK')" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "error: run this script as root (sudo)" >&2
    exit 1
fi

########## nginx package ##########
if ! command -v nginx >/dev/null 2>&1; then
    echo "installing nginx ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nginx
fi

########## directories ##########
install -d -m 755 /etc/nginx/conf.d
install -d -m 755 /var/www/certbot        # ACME HTTP-01 challenge root
install -d -m 700 /etc/nginx/ssl
install -d -m 755 /etc/nginx/auth         # basic-auth files (remote-write)

# HTTP/2: the `http2` directive needs nginx >= 1.25.1, older versions stay on
# HTTP/1.1 (the file stays empty, the include in nginx.conf is harmless).
nginx_version="$(nginx -v 2>&1 | sed -n 's|.*nginx version: \([0-9][0-9.]*\).*|\1|p')"
if [ -n "$nginx_version" ] && awk -v v="$nginx_version" 'BEGIN{
    split(v, a, ".");
    exit !((a[1]+0) > 1 || ((a[1]+0) == 1 && (a[2]+0) > 25) || ((a[1]+0) == 1 && (a[2]+0) == 25 && (a[3]+0) >= 1))
}'; then
    echo "http2 on;" > /etc/nginx/http2.conf
else
    echo "# HTTP/2 disabled: nginx ${nginx_version:-unknown} is older than 1.25.1" > /etc/nginx/http2.conf
    echo "warning: nginx ${nginx_version:-unknown} does not support 'http2 on;' — HTTP/1.1 only" >&2
fi

# Placeholder certificate for the catch-all server: it is never trusted, it
# only keeps nginx startable before the real certificates exist.
if [ ! -f /etc/nginx/ssl/default.crt ]; then
    echo "generating the placeholder certificate ..."
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/CN=placeholder.invalid" \
        -keyout /etc/nginx/ssl/default.key -out /etc/nginx/ssl/default.crt \
        >/dev/null 2>&1
    chmod 600 /etc/nginx/ssl/default.key
fi

########## main config ##########
if [ -f /etc/nginx/nginx.conf ] && ! grep -q "Managed by the identity-email-provider" /etc/nginx/nginx.conf 2>/dev/null; then
    cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%s)"
fi
install -m 644 "$REPO_ROOT/nginx/nginx.conf" /etc/nginx/nginx.conf

########## vhosts of this stack ##########
# remove vhosts of other stacks (they would point at containers that are not
# running on this host)
for link in /etc/nginx/conf.d/*.conf; do
    [ -e "$link" ] || [ -L "$link" ] || continue
    target="$(readlink -f "$link" 2>/dev/null || echo "$link")"
    case "$target" in
        "$REPO_ROOT/$STACK"/*) ;;
        *) rm -f "$link" ;;
    esac
done
for conf in "$CONF_D"/*.conf; do
    [ -e "$conf" ] || continue
    ln -sfn "$conf" "/etc/nginx/conf.d/$(basename "$conf")"
    echo "linked $(basename "$conf")"
done

# basic-auth files of the stack (remote-write endpoint)
if [ -d "$REPO_ROOT/$STACK/nginx/auth" ]; then
    for htpasswd in "$REPO_ROOT/$STACK"/nginx/auth/*; do
        [ -f "$htpasswd" ] || continue
        install -m 644 "$htpasswd" "/etc/nginx/auth/$(basename "$htpasswd")"
        echo "installed /etc/nginx/auth/$(basename "$htpasswd")"
    done
fi

# the packaged default site is not included by our nginx.conf, but remove it
rm -f /etc/nginx/sites-enabled/default

########## reload ##########
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx

echo
echo "nginx is installed for the stack '$STACK'."
echo "Next: scripts/10-tls.sh (certificate), then docker compose up -d."
