#!/usr/bin/env zsh
# Self-signed wildcard cert for LOCAL TESTING ONLY (no inbound traffic expected here)
set -e
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout tls/server.key -out tls/server.crt \
  -subj "/CN=*.june8th.eu.org" \
  -addext "subjectAltName=DNS:june8th.eu.org,DNS:*.june8th.eu.org" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
chmod 600 tls/server.key
echo "dev wildcard cert -> tls/server.crt + tls/server.key"
