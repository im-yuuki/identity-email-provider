# Identity & Mail stack (docker compose, 1 VPS)

Domains: `idp.`, `mail.`, `mx.`, `vault.june8th.eu.org`. TLS certs attached manually.

## Layout

| Service | Image | Exposed | Notes |
|---|---|---|---|
| nginx | nginx:stable-alpine | 80, 443 | 4 vhosts, TLS from `tls/` |
| authentik + worker | ghcr.io/goauthentik/server:2026.8.4 | - | only via nginx (no `latest` tag exists on ghcr) |
| postgres / redis | postgres:18-alpine / redis:8-alpine | - | authentik deps; 18 mounts `/var/lib/postgresql` (not `/data`) |
| stalwart | ghcr.io/stalwartlabs/stalwart:v0.16.27-alpine | 25, 465, 587, 993, 995 | HTTP listener :8080 behind nginx on `mx.`; `STALWART_PUBLIC_URL` points discovery at the public URL |
| bulwark | ghcr.io/bulwarkmail/webmail:latest | - | via nginx on `mail.` |
| vaultwarden | vaultwarden/server:latest | - | DISABLED (service block commented out) |

Secrets live in `.env` (mode 600, auto-generated). Dev cert is a self-signed wildcard; regenerate with `scripts/gen-dev-cert.sh`.

## Boot order (first run)

1. `docker compose up -d`
2. Authentik: bootstrap env creates `akadmin` automatically — no browser initial-setup. Login at `https://idp.june8th.eu.org/if/admin/` with user `akadmin` and `AUTHENTIK_BOOTSTRAP_PASSWORD` from `.env`.
3. Stalwart: open `https://mx.june8th.eu.org/admin` first run — 0.16 bootstrap mode. Login `admin` + `STALWART_ADMIN_PASSWORD` from `.env` (pinned via `STALWART_RECOVERY_ADMIN`; no password fishing in logs). Complete the 5-screen wizard (hostname `mx.june8th.eu.org`, default domain, RocksDB defaults, internal directory, console logging, manual DNS), then Settings -> Directory -> add LDAP directory with the values below.
4. Bulwark: SSO enabled via Authelia — `OAUTH_ENABLED/OAUTH_ONLY/OAUTH_CLIENT_ID=bulwark/OAUTH_CLIENT_SECRET/OAUTH_ISSUER_URL=https://idp.june8th.eu.org` + `AUTO_SSO_ENABLED` (login page auto-redirects). Admin dashboard password = `BULWARK_ADMIN_PASSWORD` (regular login at /en/auth? removed — read the admin docs). NOTE bulwark needs `extra_hosts: idp...:host-gateway` and a real TLS cert on the VPS to reach the issuer from inside the container (dev: `NODE_TLS_REJECT_UNAUTHORIZED=0`, remove on VPS).
5. Vaultwarden: **commented out for now.** Uncomment the `vaultwarden` service block in compose.yaml and `docker compose up -d` — volume and `.env` secrets are kept, so nothing is lost. Enable the OIDC SSO block after Authentik is fully set up (`SMTP_PASSWORD` must also be set for outbound mail).

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

## TLS (letsencrypt layout)

Cả nginx và stalwart mount cùng 1 cây cert r/o (`target = /etc/letsencrypt`, nguồn = `LETSENCRYPT_DIR` trong `.env`):

- Local: `LETSENCRYPT_DIR` unset → mount `./tls`, tạo bằng `sh scripts/gen-dev-cert.sh` (biết cấu trúc `tls/live/<domain>/fullchain.pem|privkey.pem` giống certbot).
- VPS: thêm `LETSENCRYPT_DIR=/etc/letsencrypt` vào `.env` rồi `docker compose up -d nginx stalwart` — mount toàn bộ `/etc/letsencrypt` (live + archive, r/o) nên symlink renewal đọc được ngay.
- Vhost trỏ `ssl_certificate /etc/letsencrypt/live/mx.june8th.eu.org/fullchain.pem` + `privkey.pem` (wildcard `*.june8th.eu.org` → dùng DNS-01: `certbot certonly --cert-name june8th.eu.org --dns-route53...` hoặc plugin DNS nhà cung cấp).
- Stalwart (SMTP/IMAP chấm dứt TLS trực tiếp): lần đầu import trong WebUI **Settings → TLS → Certificates → from file**, đường dẫn `/etc/letsencrypt/live/mx.june8th.eu.org/fullchain.pem` + `privkey.pem`; sau renewal `docker compose restart stalwart` (hoặc kích hoạt qua JMAP API như discussion #3199 của stalwartlabs).
- Sau renewal: `docker compose exec nginx nginx -s reload` (đặt vào deploy hook của certbot); kiểm tra: `openssl x509 -in /etc/letsencrypt/live/mx.june8th.eu.org/fullchain.pem -noout -dates`.

## JMAP (desktop clients)

JMAP đã expose qua nginx trên vhost `mx.` (TLS chấm dứt ở nginx, upstream `stalwart:8080`):

- Discovery URL cho client desktop: `https://mx.june8th.eu.org/.well-known/jmap` (redirect → `/jmap/session`)
- Session endpoint: `https://mx.june8th.eu.org/jmap/session` — `apiUrl` `/jmap/`, upload/download/eventSource đều là path-relative nên client tự ghép với origin `https://mx.june8th.eu.org`
- WebSocket push: `wss://mx.june8th.eu.org/jmap/ws` (đã bật trong capabilities `urn:ietf:params:jmap:websocket`)
- Long-poll `eventsource` đã có `proxy_read_timeout 300s` trong vhost; nếu client giữ kết nối lâu hơn, tăng ở `mx.conf`
- Xác thực: Basic auth (username/password) — lấy từ Stalwart internal directory hoặc LDAP (Authentik) sau khi cấu hình Directory trong wizard/admin
- STALWART_PUBLIC_URL=https://mx.june8th.eu.org (compose.yaml) đảm bảo các URL trong discovery là domain đúng chứ không phải tên container

Client của bạn chỉ cần đặt JMAP URL = `https://mx.june8th.eu.org/.well-known/jmap` (hoặc trực tiếp session endpoint) + account = địa chỉ email đầy đủ.

## Logs (RAM on the real VPS)

Docker has no native in-RAM logging driver. To keep container logs in RAM and protect the VPS disk:

1. `/etc/docker/daemon.json` — let containers inherit the daemon driver, no per-service overrides in compose (this repo already has none):
   ```json
   { "log-driver": "journald" }
   ```
2. `/etc/systemd/journald.conf` — keep the journal itself in tmpfs/RAM, lost on reboot by design:
   ```
   Storage=volatile
   RuntimeMaxUse=200M
   ```
3. `systemctl restart systemd-journald docker && docker compose up -d`
   `docker logs <container>` and `journalctl -u docker CONTAINER_NAME=<name>` keep working; total RAM cost ≤ 200M.

On the dev Mac (OrbStack) journald is unavailable; OrbStack already caps each container's json-file logs at 20m × 5 files at the daemon level, so nothing is needed here.

## Ops

```bash
docker compose ps              # health
docker compose logs -f authentik
docker compose down            # data lives in named volumes, not lost
```

Vaultwarden: service is commented out in compose.yaml (volume `vaultwarden-data` + `.env` keys retained). After OIDC SSO works, keep `SIGNUPS_ALLOWED=false`. `ADMIN_TOKEN` from `.env` unlocks the `/admin` panel.

## Scripts

```bash
scripts/gen-env.sh [--force]      # generate a fresh .env with random secrets (argon2 token included)
scripts/vw-hash-token.sh          # stdin -> vaultwarden ADMIN_TOKEN argon2id PHC (uses argon2 CLI or docker fallback)
```

- `VAULTWARDEN_ADMIN_TOKEN` must be an argon2id PHC string (`$argon2id$...`); plaintext still works but logs `[NOTICE] plain-text ADMIN_TOKEN which is insecure`. The token stored in `.env` is written with `$$` because docker compose interpolates `.env` values (single `$` gets swallowed as a variable name and the hash is corrupted). The `/admin` password = the plaintext input of `vw-hash-token.sh` — print once, don't store.
- `scripts/gen-env.sh` refuses to overwrite an existing `.env` unless `--force` (a backup is kept) and prints the Vaultwarden plaintext token exactly once.

## Env inventory

Active (set in compose.yaml / .env):
- postgres: `POSTGRES_DB/USER/PASSWORD`, healthcheck via `pg_isready`.
- authentik (server+worker): `AUTHENTIK_SECRET_KEY`, `POSTGRESQL__HOST/NAME/USER/PASSWORD/USE_PGPOOL`, `REDIS__HOST`, `ERROR_REPORTING__ENABLED=false`, `BOOTSTRAP__PASSWORD/USERNAME(akadmin)/EMAIL`.
  - caveat: `BOOTSTRAP__EMAIL` is not honored on akadmin creation in 2026.8.4 — akadmin gets `root@example.com`; fix in admin UI or SQL after first boot.
- stalwart: `STALWART_RECOVERY_ADMIN=admin:<pw>` (pinned first-boot admin; remove after a permanent admin exists), `STALWART_PUBLIC_URL=https://mx.june8th.eu.org`. Everything else lives in the 0.16 config/datastore (`/etc/stalwart` + `/var/lib/stalwart` volumes).
- bulwark: `JMAP_SERVER_URL`, `ADMIN_PASSWORD`, `SESSION_SECRET` (wizard skipped); `OAUTH_*` block prewritten, commented.
- vaultwarden: not running (service commented out). `SSO_*` + `SMTP_*` blocks prewritten, commented; `ADMIN_TOKEN` in `.env` is an argon2id PHC (`$$`-doubled for compose).
- nginx/redis: no env (nginx = config files; redis = flags only).

nginx resilience: all vhosts use Docker's `resolver 127.0.0.11` + variable `proxy_pass`, so nginx starts even when a backend container is missing (e.g. vaultwarden disabled → `vault.` answers 502 instead of crash-looping).

Recommended-but-not-set (decided against or later):
- authentik `AUTHENTIK_WEB__WORKERS` / `AUTHENTIK_WORKER__CONCURRENCY`: tune only if VPS memory is tight.
- vaultwarden `ORG_ATTACHMENT_LIMIT`, push-notification keys: not needed for personal use.
- stalwart relay limits, DKIM keys: configured in its admin UI, not env.
