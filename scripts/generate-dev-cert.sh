#!/usr/bin/env zsh
# Self-signed wildcard cert for LOCAL TESTING ONLY (no inbound traffic expected here).
# Layout mirrors /etc/letsencrypt (live/<domain>/{fullchain,privkey}.pem) so the same
# nginx + stalwart mount works on the VPS with the real certbot tree.
DOMAIN=june8th.eu.org
set -e
mkdir -p "tls/live/$DOMAIN"
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout "tls/live/$DOMAIN/privkey.pem" -out "tls/live/$DOMAIN/fullchain.pem" \
  -subj "/CN=*$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
chmod 600 "tls/live/$DOMAIN/privkey.pem"
echo "dev wildcard cert -> tls/live/$DOMAIN/fullchain.pem + privkey.pem"
