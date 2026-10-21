# Identity & Mail stack (docker compose, 1 VPS)

Domains: `idp.`, `mail.`, `mx.`, `vault.june8th.eu.org`. TLS certs attached manually.

## Layout

| Service | Image | Exposed | Notes |
|---|---|---|---|
| nginx | nginx:stable-alpine | 80, 443 | 4 vhosts, TLS from `${LETSENCRYPT_DIR:-./tls}` |
| openldap | osixia/openldap:2.6.15-alpha | - | `:389` docker net only; users/groups seed qua `openldap/ldif/custom/`; legacy tag `2.6-stable` broken (#605) |
| authelia | authelia/authelia:4.39.20 | - | SSO portal + OIDC provider; chỉ qua nginx trên `idp.` (không có OIDC nếu thiếu `authelia/keys/primary.key` — xem Boot order step 0) |
| stalwart | ghcr.io/stalwartlabs/stalwart:v0.16.27-alpine | 25, 465, 587, 993, 995 | HTTP listener :8080 behind nginx on `mx.`; `STALWART_PUBLIC_URL` points discovery at the public URL |
| bulwark | ghcr.io/bulwarkmail/webmail:latest | - | via nginx on `mail.` |
| vaultwarden | vaultwarden/server:latest | - | DISABLED (service block commented out) |

Secrets live in `.env` (mode 600, auto-generated). Dev cert is a self-signed wildcard; regenerate with `scripts/gen-dev-cert.sh`.

## Boot order (first run)

0. Sau khi clone repo lần đầu: `sh scripts/generate-authelia-keys.sh` — sinh `authelia/keys/primary.key` (RSA2048, chmod 600). File này **gitignore có chủ ý**: là private key OIDC, mỗi host phải sinh key riêng. Thiếu nó Authelia **crash-loop**: template `{{ secret "/config/keys/primary.key" }}` fail → toàn bộ rendered config bị discard → chuỗi lỗi "x is required" (ldap/session/storage/oidc...) — không phải lỗi config thật. Chỉ chạy `--force` khi nghi ngờ key bị lộ (xoay key làm mọi token/session đang phát hành vô giá trị).
1. `docker compose up -d`
2. Authelia + OpenLDAP: login SSO portal tại `https://idp.june8th.eu.org` với `uid=admin,ou=people` (mail `admin@june8th.eu.org`) + `LDAP_ADMIN_PASSWORD` từ `.env`. Cây thư mục đã được seed bằng ldif (`openldap/ldif/custom/`): `ou=people` (uid=admin, uid=user1), `ou=services` (uid=svc-mail, uid=svc-stalwart-auth), `ou=groups` (memberOf overlay bật sẵn). Đổi mật khẩu dev mặc định bằng `ldappasswd`.
3. Stalwart: open `https://mx.june8th.eu.org/admin` first run — 0.16 bootstrap mode. Login `admin` + `STALWART_ADMIN_PASSWORD` from `.env` (pinned via `STALWART_RECOVERY_ADMIN`; no password fishing in logs). Complete the 5-screen wizard (hostname `mx.june8th.eu.org`, default domain, RocksDB defaults, internal directory, console logging, manual DNS), then Settings -> Directory -> add LDAP directory with the values below. (Có thể chạy headless bằng `stalwart-cli` + file plan NDJSON — xem `.private/context.md`.)
4. Bulwark: SSO enabled via Authelia — `OAUTH_ENABLED/OAUTH_ONLY/OAUTH_CLIENT_ID=bulwark/OAUTH_CLIENT_SECRET/OAUTH_ISSUER_URL=https://idp.june8th.eu.org` + `AUTO_SSO_ENABLED` (login page auto-redirects). Admin dashboard password = `BULWARK_ADMIN_PASSWORD` (regular login at /en/auth? removed — read the admin docs). NOTE bulwark needs `extra_hosts: idp...:host-gateway` and a real TLS cert on the VPS to reach the issuer from inside the container (dev: `NODE_TLS_REJECT_UNAUTHORIZED=0`, remove on VPS).
5. Vaultwarden: **commented out for now.** Uncomment the `vaultwarden` service block in compose.yaml and `docker compose up -d` — volume and `.env` secrets are kept, so nothing is lost. Enable the OIDC SSO block after Authelia is fully set up (client `vaultwarden` đã có sẵn trong `authelia/configuration.yml`; `SMTP_PASSWORD` must also be set for outbound mail).

## OpenLDAP - directory layout

- Suffix `dc=june8th,dc=eu,dc=org`, account admin `cn=admin,dc=june8th,dc=eu,dc=org` (password = `LDAP_ADMIN_PASSWORD`; argon2 hash cho cả config/data root set qua `OPENLDAP_BOOTSTRAP_*_ROOT_PW_HASHED`).
- Users: `ou=people` (inetOrgPerson, `mail` = địa chỉ email đầy đủ); service binds: `ou=services` (uid=svc-mail cho Stalwart); groups: `ou=groups` (groupOfNames, member = DN) + memberOf overlay (propagation user entry ← group member).
- ACLs đã set trong `cn=config`: svc-mail được read toàn bộ (trừ userPassword), user được self-write password. **Lưu ý**: ACL nằm ở `ldap-config` volume — nếu volume bị xóa, phải set lại bộ ACL này (lưu trong `.private/context.md`).
- Stalwart bind bằng `uid=svc-mail,ou=services,...` + `STALWART_LDAP_BIND_PASSWORD` (Registry giữ bản copy riêng — rotation của `.env` không tự áp, xem mục Scripts).

## Stalwart - directory (values hiển thị trong admin UI / registry)

- Directory type: LDAP, URL `ldap://openldap` (không TLS trong docker net)
- Bind: `uid=svc-mail,ou=services,dc=june8th,dc=eu,dc=org` + `STALWART_LDAP_BIND_PASSWORD`
- Base DN: `dc=june8th,dc=eu,dc=org`
- Login/mail filter: `(&(objectClass=inetOrgPerson)(mail={email}))` — accounts phải email-shaped trong 0.16
- Authelia backend LDAP đọc cùng cây này (uid=admin...) — một nguồn sự thật duy nhất là OpenLDAP, đừng tạo user trực tiếp trong Stalwart.

## DNS records (for the real VPS)

```
A     idp.june8th.eu.org    -> <VPS IP>
A     mail.june8th.eu.org   -> <VPS IP>
A     vault.june8th.eu.org  -> <VPS IP>
A     mx.june8th.eu.org     -> <VPS IP>
MX    june8th.eu.org        -> 10 mx.june8th.eu.org
TXT   june8th.eu.org        "v=spf1 mx -all"
TXT   _dmarc.june8th.eu.org "v=DMARC1; p=quarantine; rua=mailto:postmaster@..."
TXT   v1-rsa-20261021._domainkey.june8th.eu.org      (publicKey của DkimSignature v1-rsa — copy từ Stalwart registry/admin UI)
TXT   v1-ed25519-20261021._domainkey.june8th.eu.org  (publicKey của DkimSignature v1-ed25519)
```

## TLS (letsencrypt layout)

Cả nginx và stalwart mount cùng 1 cây cert r/o (`target = /etc/letsencrypt`, nguồn = `LETSENCRYPT_DIR` trong `.env`):

- Local: `LETSENCRYPT_DIR` unset → mount `./tls`, tạo bằng `sh scripts/gen-dev-cert.sh` (biết cấu trúc `tls/live/<domain>/fullchain.pem|privkey.pem` giống certbot).
- VPS: thêm `LETSENCRYPT_DIR=/etc/letsencrypt` vào `.env` rồi `docker compose up -d nginx stalwart` — mount toàn bộ `/etc/letsencrypt` (live + archive, r/o) nên symlink renewal đọc được ngay.
- Vhost trỏ `ssl_certificate /etc/letsencrypt/live/june8th.eu.org/fullchain.pem` + `privkey.pem` (wildcard `*.june8th.eu.org` → dùng DNS-01: `certbot certonly --cert-name june8th.eu.org --dns-...` với plugin DNS nhà cung cấp).
- Stalwart (SMTP/IMAP chấm dứt TLS trực tiếp): lần đầu import trong WebUI **Settings → TLS → Certificates → from file**, đường dẫn `/etc/letsencrypt/live/june8th.eu.org/fullchain.pem` + `privkey.pem` (hoặc tạo Certificate object dạng File qua `stalwart-cli` — đã làm sẵn trong registry dev); sau renewal `docker compose restart stalwart` (hoặc kích hoạt qua JMAP API như discussion #3199 của stalwartlabs).
- Sau renewal: `docker compose exec nginx nginx -s reload` (đặt vào deploy hook của certbot); kiểm tra: `openssl x509 -in /etc/letsencrypt/live/june8th.eu.org/fullchain.pem -noout -dates`.

## JMAP (desktop clients)

JMAP đã expose qua nginx trên vhost `mx.` (TLS chấm dứt ở nginx, upstream `stalwart:8080`):

- Discovery URL cho client desktop: `https://mx.june8th.eu.org/.well-known/jmap` (redirect → `/jmap/session`)
- Session endpoint: `https://mx.june8th.eu.org/jmap/session` — `apiUrl` `/jmap/`, upload/download/eventSource đều là path-relative nên client tự ghép với origin `https://mx.june8th.eu.org`
- WebSocket push: `wss://mx.june8th.eu.org/jmap/ws` (đã bật trong capabilities `urn:ietf:params:jmap:websocket`)
- Long-poll `eventsource` đã có `proxy_read_timeout 300s` trong vhost; nếu client giữ kết nối lâu hơn, tăng ở `mx.conf`
- Xác thực: Basic auth (username/password) — qua OpenLDAP directory (accounts email-shaped, password = password LDAP)
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
docker compose logs -f authelia
docker compose down            # data lives in named volumes, not lost
```

Vaultwarden: service is commented out in compose.yaml (volume `vaultwarden-data` + `.env` keys retained). After OIDC SSO works, keep `SIGNUPS_ALLOWED=false`. `ADMIN_TOKEN` from `.env` unlocks the `/admin` panel.

## Scripts

```bash
scripts/generate-env.sh [-o FILE] [--force]       # fresh .env with all stack secrets (OpenLDAP+Authelia era)
scripts/generate-authelia-keys.sh [--force]       # sinh authelia/keys/primary.key (OIDC signing key) — CHẠY TRƯỚC up -d sau fresh clone
scripts/vaultwarden-hash-token.sh                 # stdin -> vaultwarden ADMIN_TOKEN argon2id PHC (docker fallback)
scripts/generate-dev-cert.sh                      # self-signed wildcard -> tls/live/june8th.eu.org/{fullchain,privkey}.pem
```

**`authelia/keys/primary.key` (phần trong Scripts ở trên được nhắc lại vì quan trọng):**
- Là khóa ký RS256 cho mọi `id_token` của Authelia; nửa công khai tự publish tại `https://idp.june8th.eu.org/jwks.json` — Bulwark/Stalwart/Vaultwarden verify chữ ký bằng đó, không cần chia sẻ secret thêm.
- PEM đa dòng nên phải là file (referenced qua template `{{ secret "/config/keys/primary.key" }}`), không đặt được vào `.env`.
- Gitignored: mỗi host sinh key riêng. Fresh clone cần chạy lại script trước `docker compose up -d`, nếu không Authelia crash-loop (template fail → cả config render bị discard).
- Chỉ rotate (`--force`) khi nghi lộ key — mọi token/session đang phát hành vô giá trị (user bị văng hết).

- `generate-env.sh` generates: LDAP_ADMIN_PASSWORD (+ both OpenLDAP argon2 bootstrap root hashes via `slappasswd`, `$$`-doubled), Authelia JWT/session/storage secrets, Stalwart admin + LDAP bind passwords, Bulwark/SSO secrets, and the Vaultwarden argon2id PHC token.
- It ALSO re-syncs the three pbkdf2 client digests in `authelia/configuration.yml` (bulwark/stalwart/vaultwarden) to match the new `*_OAUTH_SECRET` values — restart authelia after regenerating. Sync only runs when writing the real `.env`.
- Rotation does NOT auto-apply to: stalwart's stored `Directory.bindSecret` (registry copy of `STALWART_LDAP_BIND_PASSWORD`), and dev LDAP user passwords (`ldappasswd` needed).
- `VAULTWARDEN_ADMIN_TOKEN` must be an argon2id PHC string (`$argon2id$...`); plaintext still works but logs `[NOTICE] plain-text ADMIN_TOKEN which is insecure`. The token stored in `.env` is written with `$$` because docker compose interpolates `.env` values (single `$` gets swallowed as a variable name and the hash is corrupted). The `/admin` password = the plaintext input — printed once, not stored.
- `generate-env.sh` refuses to overwrite an existing `.env` unless `--force` (a backup is kept).

## Env inventory

Active (set in compose.yaml / .env):
- openldap: `LDAP_ADMIN_PASSWORD`, `OPENLDAP_BOOTSTRAP_CONFIG_ROOT_PASSWORD_HASHED`/`..._DATA_ROOT_PASSWORD_HASHED` (argon2 PHC, `$$`-doubled), `OPENLDAP_BOOTSTRAP_MEMBEROF=true`, `OPENLDAP_URLS=ldap://:389/`; legacy `LDAP_*` vars are inert labels for this image.
- authelia: `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `AUTHELIA_STORAGE_KEY` (maps to `AUTHELIA_STORAGE_ENCRYPTION_KEY`), LDAP bind password = `LDAP_ADMIN_PASSWORD`.
- stalwart: `STALWART_RECOVERY_ADMIN=admin:<pw>` (pinned first-boot admin; remove after a permanent admin exists), `STALWART_PUBLIC_URL=https://mx.june8th.eu.org`, `STALWART_LDAP_BIND_PASSWORD` (bind used at bootstrap; registry holds its own copy). Everything else lives in the 0.16 config/datastore (`/etc/stalwart` + `/var/lib/stalwart` volumes).
- bulwark: `JMAP_SERVER_URL`, `ADMIN_PASSWORD`, `SESSION_SECRET`, SSO ACTIVE: `OAUTH_ENABLED/OAUTH_ONLY/OAUTH_CLIENT_ID=bulwark/OAUTH_CLIENT_SECRET=${BULWARK_OAUTH_SECRET}/OAUTH_ISSUER_URL=https://idp.june8th.eu.org/AUTO_SSO_ENABLED=true`, `extra_hosts idp→host-gateway`.
- vaultwarden: not running (service commented out). `SSO_*` + `SMTP_*` blocks prewritten, commented; `ADMIN_TOKEN` in `.env` is an argon2id PHC (`$$`-doubled for compose).
- nginx: no env (config files only).

nginx resilience: all vhosts use Docker's `resolver 127.0.0.11` + variable `proxy_pass`, so nginx starts even when a backend container is missing (e.g. vaultwarden disabled → `vault.` answers 502 instead of crash-looping).

Recommended-but-not-set (decided against or later):
- vaultwarden `ORG_ATTACHMENT_LIMIT`, push-notification keys: not needed for personal use.
- stalwart relay limits, DKIM keys: configured in the 0.16 datastore (DkimSignature objects), not env.
