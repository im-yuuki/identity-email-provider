#!/usr/bin/env bash
# vaultwarden ADMIN_TOKEN argon2 hasher
# Reads the password/token from stdin and prints an argon2id PHC string
# ($argon2id$v=19$m=65540,t=3,p=4$...) ready to use as ADMIN_TOKEN.
#
#   echo -n 'mypassword' | scripts/vw-hash-token.sh
#
# Vaultwarden detects the $argon2id$ prefix automatically; params travel in
# the string itself, so any argon2id preset works. Plaintext tokens still
# work but log a "[NOTICE] plain-text ADMIN_TOKEN which is insecure" — use this.
set -euo pipefail

PW=$(cat)
if [ -z "$PW" ]; then
    echo "error: stdin was empty — pass a password/token (printf '%s' pw | $0)" >&2
    exit 1
fi

if command -v argon2 >/dev/null 2>&1; then
    printf '%s' "$PW" | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4
else
    # Fallback: hash inside a throwaway container (needs to pull python:3-alpine
    # + pip install argon2-cffi on first run). Password is passed via env.
    docker run --rm -i -e VW_PW="$PW" python:3-alpine sh -c 'pip install -q argon2-cffi >/dev/null 2>&1 && python -c "from argon2 import PasswordHasher; import os; print(PasswordHasher().hash(os.environ[\"VW_PW\"]))"'
fi
