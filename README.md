# idp — Identity & Mail stack (docker compose, 1 VPS)

Domains: `idp.`, `mail.`, `mx.`, `vault.june8th.eu.org`. TLS certs attached manually.

## Layout

| Service | Image | Exposed | Notes |
|---|---|---|---|
| nginx | nginx:stable-alpine | 80, 443 | 4 vhosts, TLS from `tls/` |
| authentik + worker | goauthentik/server | - | only via nginx |
| postgres / redis | 17-alpine / 7-alpine | - | authentik deps |
| stalwart | stalwartlabs/stalwart | 25, 465, 587, 993, 995 | HTTP (JMAP/admin) served by nginx on `mx.` |
| bulwark | bulwarkmail/webmail | - | via nginx on `mail.` |
| vaultwarden | vaultwarden/server | - | via nginx on `vault.` |

Secrets live in `.env` (mode 600, auto-generated). Dev cert is a self-signed wildcard; regenerate with `scripts/gen-dev-cert.sh`.

## Boot order (first run)

1. `docker compose up -d`
2. Authentik: bootstrap env creates `akadmin` automatically — no browser initial-setup. Login at `https://idp.june8th.eu.org/if/admin/` with user `akadmin` and `AUTHENTIK_BOOTSTRAP_PASSWORD` from `.env`.
3. Stalwart: open `https://mx.june8th.eu.org/admin` first run, the wizard creates the Stalwart admin. Then Settings -> Directory -> add LDAP directory with the values below.
4. Bulwark: no wizard needed — configured via env (`JMAP_SERVER_URL=http://stalwart:8080`, `ADMIN_PASSWORD`, `SESSION_SECRET` in `.env`). Its admin dashboard password lives in `BULWARK_ADMIN_PASSWORD`. To enable Authentik SSO later, uncomment the `OAUTH_*` block in the bulwark service once the "bulwark" OIDC provider exists in Authentik.
5. Vaultwarden: create your first account; enable OIDC SSO after Authentik is fully set up.

## Authentik - directory & outpost

- Admin UI: `https://idp.june8th.eu.org/if/admin/` (AKAdmin). Multi-level tree: Directory -> Groups (nested groups), assign users per level.
- RBAC: bind groups to policies, attach them to the OIDC providers (Stalwart/Bulwark/Vaultwarden).
- LDAP outpost: Applications -> Outposts -> Create -> LDAP (or use the embedded outpost). It runs inside the authentik container on `:389`. Stalwart binds to `authentik:389` on the docker network.
- Service account for the Stalwart bind: create a normal user `svc-mail` in Authentik with its own password. Stalwart uses DN/password to search.

## Stalwart - external directory (values for the admin UI)

- Directory type: LDAP
- Host: `authentik` / Port: `389` (plain LDAP is fine inside the docker net; for TLS switch to 636 with `LDAPS_REQUIRED=true` on the outpost)
- Bind DN: `cn=svc-mail,ou=users,dc=ldap,dc=goauthentik,dc=io`
- Bind password: the `svc-mail` password
- Base DN: `dc=ldap,dc=goauthentik,dc=io`
- User filter (name): `(&(objectClass=person)(cn={user}))`
- Email filter: `(&(objectClass=person)(mail={email}))`
- Attributes Stalwart reads: name `cn`, email `mail`, type `objectClass`, quota if configured.
- Deploy the Authentik LDAP outpost BEFORE testing the connection in Stalwart.
- Important: keep this directory as an external/fallback source. Stalwart must not be the source of truth; Authentik is. Do not create users directly in Stalwart.

## DNS records (for the real VPS)

```
A     idp.june8th.eu.org    -> <VPS IP>
A     mail.june8th.eu.org   -> <VPS IP>
A     vault.june8th.eu.org  -> <VPS IP>
A     mx.june8th.eu.org     -> <VPS IP>
MX    june8th.eu.org        -> 10 mx.june8th.eu.org
TXT   june8th.eu.org        "v=spf1 mx -all"
TXT   _dmarc.june8th.eu.org "v=DMARC1; p=quarantine; rua=mailto:postmaster@..."
TXT   default._domainkey       (copy from Stalwart DKIM settings after setup)
```

## TLS renewal (manual)

- Replace `tls/server.crt` and `tls/server.key`. nginx: `docker compose exec nginx nginx -s reload`.
- Stalwart reads the same mounted `tls/` at `/etc/stalwart/tls`. Point its config there (`server.certificate.default.cert = "/etc/stalwart/tls/server.crt"`, same for `.key`), then restart the stalwart container.
- Check expiry: `openssl x509 -in tls/server.crt -noout -dates`.

## Ops

```bash
docker compose ps              # health
docker compose logs -f authentik
docker compose down            # data lives in named volumes, not lost
```

Vaultwarden: after OIDC SSO works, set `SIGNUPS_ALLOWED=false` in compose.yaml. `ADMIN_TOKEN` from `.env` unlocks the `/admin` panel.

## Env inventory

Active (set in compose.yaml / .env):
- postgres: `POSTGRES_DB/USER/PASSWORD`, healthcheck via `pg_isready`.
- authentik (server+worker): `AUTHENTIK_SECRET_KEY`, `POSTGRESQL__HOST/NAME/USER/PASSWORD/USE_PGPOOL`, `REDIS__HOST`, `ERROR_REPORTING__ENABLED=false`, `BOOTSTRAP__PASSWORD/USERNAME(akadmin)/EMAIL`.
- stalwart: no env — config lives in `stalwart-data/config.toml` (wizard already ran).
- bulwark: `JMAP_SERVER_URL`, `ADMIN_PASSWORD`, `SESSION_SECRET` (wizard skipped); `OAUTH_*` block prewritten, commented.
- vaultwarden: `DOMAIN`, `ADMIN_TOKEN`, `SIGNUPS_ALLOWED`, `SIGNUPS_DOMAINS_WHITELIST`, `SHOW_PASSWORD_HINT`; `SSO_*` + `SMTP_*` blocks prewritten, commented.
- nginx/redis: no env (nginx = config files; redis = `--save` flag only).

Recommended-but-not-set (decided against or later):
- authentik `AUTHENTIK_WEB__WORKERS` / `AUTHENTIK_WORKER__CONCURRENCY`: tune only if VPS memory is tight.
- vaultwarden `ORG_ATTACHMENT_LIMIT`, push-notification keys: not needed for personal use.
- stalwart relay limits, DKIM keys: configured in its admin UI, not env.

Note: nginx resolves upstream DNS once at startup — after `docker compose up -d` recreates a proxied container, run `docker compose exec nginx nginx -s reload` or the vhost returns empty 404s.
