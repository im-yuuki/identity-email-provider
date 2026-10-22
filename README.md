# Identity, Mail, Vault, Drive and Monitoring stacks

Self-hosted identity provider, mail server, password manager, file sync &
share, and a small observability stack, split over five VPS and deployed
from this single repository.

| Stack | Host | Services | Public endpoints |
| --- | --- | --- | --- |
| `idp/` | VPS A | Authentik, PostgreSQL | `https://idp.june8th.eu.org` |
| `mail/` | VPS B | Stalwart, Bulwark (webmail) | `https://mail.june8th.eu.org`, `https://mx.june8th.eu.org`, SMTP/IMAP ports |
| `vault/` | VPS C | Vaultwarden | `https://vault.june8th.eu.org` |
| `drive/` | VPS E | Nextcloud, PostgreSQL, Redis | `https://drive.june8th.eu.org`, `https://drive.june8th.eu.org/remote.php/dav/` |
| `monitoring/` | VPS D | Prometheus, Alertmanager, Grafana, node-exporter, cAdvisor | `https://grafana.june8th.eu.org`, `https://metrics.june8th.eu.org/api/v1/write` |

nginx runs **on the host** (systemd), not in Docker: it terminates TLS and
reverse-proxies to the containers, which only publish their ports on
`127.0.0.1`.

Everything talks to everything else over public HTTPS only — no mesh, no
private network between hosts.

* **Authentik** is the single identity provider (OIDC) for Bulwark,
  Vaultwarden and Nextcloud.
* **Stalwart** authenticates mail users against Authentik over OIDC and
  stores the mailboxes itself.
* **Vaultwarden** authenticates against Authentik over OIDC.
* **Nextcloud** authenticates against Authentik over OIDC; per-user quota
  is set from Authentik groups (see `drive/`).
* **Prometheus** collects metrics from every stack and from other projects
  (scrape and/or remote-write) and hands alerts to **Alertmanager**.

## Repository layout

```
idp/          Authentik + PostgreSQL                   (VPS A)
mail/         Stalwart + Bulwark                       (VPS B)
vault/        Vaultwarden                               (VPS C)
drive/        Nextcloud + PostgreSQL + Redis            (VPS E)
monitoring/   Prometheus + Alertmanager + Grafana       (VPS D)
```

Each stack directory is self-contained: its own `compose.yaml`, `.env`,
`nginx/conf.d/` (the vhosts of this host — drop into `/etc/nginx/conf.d/`
on the VPS that runs the stack) and `scripts/`. There is no shared
`nginx.conf` in the repo; the vhosts are self-contained (they set the
`X-Forwarded-*` headers inline), so the host `nginx.conf` only needs the
standard globals.

```
<stack>/
  compose.yaml          # top-level `name:` namespaces the volumes
  .env.example          # template, all secrets empty
  nginx/conf.d/*.conf   # vhosts of this host (drop into /etc/nginx/conf.d)
  scripts/00-generate-env.sh
```

## Requirements

* One VPS per stack, Ubuntu 24.04 or Debian 13, Docker Engine + Compose v2
* `certbot`, `openssl`, `curl`, `jq`, `nginx` on the host (nginx ≥ 1.25.1
  for HTTP/2, older versions fall back to HTTP/1.1)
* A DNS zone for `june8th.eu.org`
* Ports open: 80, 443 everywhere; 25, 465, 587, 993, 995 on the mail host.
  The container ports are bound to `127.0.0.1` and are not reachable from
  outside.

Every host runs the same repository. Clone it wherever you deploy:

```bash
git clone <repo> /opt/identity-email-provider
cd /opt/identity-email-provider/<stack>
```

## Deployment order

The IdP comes first — Bulwark and Vaultwarden need their OIDC applications to
exist before they can start. nginx is set up by hand (see [The host nginx](#the-host-nginx)),
so each step is just `00-generate-env.sh` → `docker compose up -d` → first-boot
script.

### 1. VPS A — identity provider

```bash
cd /opt/identity-email-provider/idp
scripts/00-generate-env.sh          # prints the Authentik admin password ONCE
docker compose up -d
```

The certificate path is always `/etc/letsencrypt/live/june8th.eu.org/` (every
host issues with `--cert-name june8th.eu.org` — see [TLS](#tls)).

Then log in at `https://idp.june8th.eu.org` with `akadmin` and the generated
password and create the users and applications (see below).

### 2. VPS B — mail

```bash
cd /opt/identity-email-provider/mail
scripts/00-generate-env.sh          # prints the Bulwark OIDC secret ONCE
```

Paste the printed `BULWARK_OAUTH_SECRET` into the `bulwark` OAuth2/OIDC
provider in Authentik, then:

```bash
docker compose up -d
scripts/01-bootstrap-stalwart.sh    # domain, TLS cert, OIDC directory, settings
scripts/sync-users.sh               # create the mailboxes of the Authentik users
```

`01-bootstrap-stalwart.sh` is idempotent (upsert/update), so it can be re-run
after editing `mail/stalwart/bootstrap.ndjson`.

### 3. VPS C — vault

```bash
cd /opt/identity-email-provider/vault
scripts/00-generate-env.sh          # prints the Vaultwarden admin token ONCE
```

Paste the printed secret into the `vaultwarden` provider in Authentik, then:

```bash
docker compose up -d
```

### 4. VPS D — monitoring

```bash
cd /opt/identity-email-provider/monitoring
scripts/00-generate-env.sh          # prints the Grafana and metrics passwords ONCE
scripts/10-render-alertmanager.sh   # renders the receivers from .env
docker compose up -d
```

### 5. VPS E — drive (Nextcloud)

```bash
cd /opt/identity-email-provider/drive
scripts/00-generate-env.sh          # prints the Nextcloud admin password ONCE
```

Paste the printed `DRIVE_OIDC_SECRET` into the `nextcloud` OAuth2/OIDC
provider in Authentik (scopes must include `groups`, **no `quota` claim**
— the quota is owned by `sync-users.sh`), then:

```bash
docker compose up -d
scripts/01-bootstrap-nextcloud.sh   # install user_oidc + E2EE apps, configure
scripts/sync-users.sh               # pre-provision users + group→quota
```

`01-bootstrap-nextcloud.sh` is idempotent. `sync-users.sh` is also
idempotent: re-run it whenever a user is added or moved between groups.

## Authentik setup

### Users

Create the users in `Authentik → Directory → Users`. Every user needs an
email address in the mail domain; `mail/scripts/sync-users.sh` turns those
users into Stalwart mailboxes.

### OIDC applications

Both applications are "OpenID Connect" providers in
`Authentik → Applications → Providers → Create → OAuth2/OpenID Connect`.

| Provider | Client id | Client secret | Redirect URI | Authorized scopes |
| --- | --- | --- | --- | --- |
| `bulwark` | `bulwark` | value printed by `mail/scripts/00-generate-env.sh` | `https://mail.june8th.eu.org/auth/callback` and `https://mail\.[a-z0-9.-]+\.june8th\.eu\.org/.*/auth/callback` | `openid`, `profile`, `email`, `offline_access` |
| `vaultwarden` | `vaultwarden` | value printed by `vault/scripts/00-generate-env.sh` | `https://vault.june8th.eu.org/identity/connect/oidc-signin` | `openid`, `profile`, `email` |
| `nextcloud` | `nextcloud` | value printed by `drive/scripts/00-generate-env.sh` | `https://drive.june8th.eu.org/apps/oidc/callback` | `openid`, `profile`, `email`, `groups` |

Notes:

* Use **Authorization Code with PKCE**, client type *confidential*.
* The authorized scopes must cover what the client asks for — a missing scope
  shows up as `invalid_scope` in the Authentik log.
* The Bulwark redirect URI has to match the locale prefix Bulwark adds to the
  callback path (`/en/auth/callback`), hence the regex entry.
* Subject mapping: `email` — Stalwart maps the token to the mailbox address
  with it.
* The Nextcloud provider **must not** have a `quota` claim mapped. The
  `user_oidc` app re-applies the claim on every login and would overwrite
  any quota an admin sets via the UI. Per-user quota is set by
  `drive/scripts/sync-users.sh` based on Authentik group membership.

### API token for the user sync

`mail/scripts/sync-users.sh` reads the user list from the Authentik API. Create
a service account in `Authentik → Directory → Users → Service Accounts`, give it
read access to `core/users` (or use `akadmin`) and put its token in
`mail/.env`:

```
AUTHENTIK_API_TOKEN=...
```

`drive/scripts/sync-users.sh` reuses the same token.

## Drive

Nextcloud on VPS E. Log in is OIDC-only against Authentik — the password
set by `sync-users.sh` is random and never used.

### Apps installed by `01-bootstrap-nextcloud.sh`

| App | Source | Purpose |
| --- | --- | --- |
| `user_oidc` | community (AGPL) | OIDC login against Authentik, auto-provisioning, group mapping |
| `end_to_end_encryption` | community (AGPL) | Client-side E2EE folders (desktop/mobile clients) |
| `files_sharing`, `files_trashbin`, `files_versions` | shipped | baseline file features |

Versions are pinned to the `nextcloud:35.0.2-apache` image; do not switch
to `:latest` — community-maintained image, no auto-update.

### Per-user quota (group-based)

`drive/.env`:

```
DRIVE_DEFAULT_QUOTA=5 GB
DRIVE_QUOTA_GROUPS=staff=50 GB,backup=200 GB
```

`drive/scripts/sync-users.sh` reads the active Authentik users, picks the
highest-priority group from `DRIVE_QUOTA_GROUPS` (left to right), falls
back to `DRIVE_DEFAULT_QUOTA`, and writes the value to the
`oc_preferences` row directly:

```bash
cd /opt/identity-email-provider/drive
scripts/sync-users.sh                # all active Authentik users of the domain
scripts/sync-users.sh --dry-run
scripts/sync-users.sh --emails a@b.c,d@e.f
```

Re-run whenever a user is added or moved between groups. The same token
(`AUTHENTIK_API_TOKEN`) is reused.

The `quota` claim is **not** mapped in Authentik. The `user_oidc` app
re-applies that claim on every login and would silently overwrite the
quota set by this script.

### Native file access (WebDAV)

Nextcloud exposes WebDAV at `https://drive.june8th.eu.org/remote.php/dav/`.
Users authenticate with an **app password** (Settings → Security → App
passwords) — OIDC logins cannot be replayed by macOS Finder or Windows
Explorer.

* **macOS Finder**: ⌘K → `https://<user>@drive.june8th.eu.org/remote.php/dav/`
  (use the app password when prompted; `mount_webdav` requires DAV LOCK,
  writes need the basic-auth app password).
* **Windows Explorer**: `Win+R` → `\\drive.june8th.eu.org@SSL\remote.php\dav\`.
  Windows 11 23H2+ deprecates the WebClient service — known limits: 4 GB
  per file (`FileSizeLimitInBytes` registry tweak), 260-char paths,
  Basic/Digest only.
* **Linux**: `davfs2` or `gvfs` (Files app); or `rclone mount
  :webdav:... /mnt/drive`.
* **Desktop sync client** (Nextcloud desktop ≥ 3.13 / Android ≥ 3.13 /
  iOS ≥ 3.0.5): mounts the full account, including E2EE folders.

### Client-side E2EE folders

The `end_to_end_encryption` app keeps content + filenames + subfolder
names encrypted on the server (AES-256-GCM, master key derived
client-side). Trade-offs:

* Web UI can only **view and download** encrypted files; upload / move
  / delete requires the desktop or mobile client.
* **WebDAV cannot write into E2EE folders** — the `LockPlugin` rejects
  non-E2EE user agents (Finder, Explorer, rclone). For the same reason
  do not use E2EE folders for shared working directories; share normal
  folders instead.
* Known upstream issues: #210 (Finder breaks after enabling), #244
  (deleted files skip trash), #489 (cannot delete non-encrypted files),
  #8379 (client-not-allowed).
* Sharing E2EE folders with another user is long broken; only public
  encrypted shares / file drop are supported (since v2.1).
* Storage accounting: encrypted bytes count against the user's quota.
  The trash bin keeps a default 50% of the remaining quota for
  non-expired deletes.

### Admin tasks

```bash
cd /opt/identity-email-provider/drive
docker compose exec -u www-data nextcloud php occ user:list
docker compose exec -u www-data nextcloud php occ user:info <user>
docker compose exec -u www-data nextcloud php occ user:setting <user> files quota "10 GB"
docker compose exec -u www-data nextcloud php occ app:list
docker compose exec -u www-data nextcloud php occ maintenance:repair
```

Background jobs run via system cron (set by `01-bootstrap-nextcloud.sh`).
If the system cron is not in place, fall back to AJAX mode:

```
occ background:cron
```

reverts to `occ background:ajax` (slower, only fires on page loads).

## Mail

### Bootstrap

`mail/stalwart/bootstrap.ndjson` is the desired state of the Stalwart
configuration:

* `Directory #authentik-oidc` — an OIDC directory pointing at
  `https://idp.june8th.eu.org/application/o/bulwark/`, requiring the audience
  `bulwark` and the scopes `openid` + `email`, taking the address from the
  `email` claim
* `Authentication.directoryId → #authentik-oidc`
* `Domain #mail-domain` (`june8th.eu.org`) and `Certificate #mail-tls`
* `SystemSettings` — default hostname `mx.june8th.eu.org`

The IdP URL and the client id are placeholders in the file; the bootstrap
script renders them from `.env` into `stalwart/bootstrap.rendered.ndjson`.

### User sync

Stalwart's OIDC directory can only validate a token, it cannot look an account
up offline. A mailbox therefore has to exist **before** the first login,
otherwise the login has nowhere to land and inbound mail to that user is
rejected.

```bash
cd /opt/identity-email-provider/mail
scripts/sync-users.sh              # all active Authentik users of the domain
scripts/sync-users.sh --dry-run    # only show what would be created
scripts/sync-users.sh --emails a@b.c,d@e.f
```

Re-run it whenever a new user is added.

### Mail clients

* Thunderbird 102+ supports custom OIDC providers: use
  `https://idp.june8th.eu.org/application/o/bulwark/` as the issuer.
* Outlook and Apple Mail have no OIDC support — use an **app password**
  generated in Bulwark (Stalwart 0.16.6+).

## Monitoring

Prometheus scrapes itself, node-exporter and cAdvisor on the monitoring host
and receives remote-write pushes from other projects. Alert rules live in
`monitoring/prometheus/rules/`, the delivery is configured in
`monitoring/alertmanager/` (rendered from `.env` by
`scripts/10-render-alertmanager.sh`).

### Adding another project — scrape

```yaml
  - job_name: "project-x"
    metrics_path: /metrics
    scrape_interval: 30s
    static_configs:
      - targets: ["project-x.example.com:9090"]
        labels:
          project: project-x
```

### Adding another project — remote-write

The project pushes to `https://metrics.june8th.eu.org/api/v1/write` with the
basic-auth pair from `monitoring/.env`:

```yaml
remote_write:
  - url: "https://metrics.june8th.eu.org/api/v1/write"
    basic_auth:
      username: "metrics"
      password: "<METRICS_BASIC_AUTH_PASSWORD>"
```

Restrict the endpoint to the IPs of the projects that push by uncommenting the
`allow`/`deny` lines in `monitoring/nginx/conf.d/metrics.conf`. The Prometheus
UI itself is not exposed — Grafana is the front door.

### Dashboards

`monitoring/grafana/dashboards/` is provisioned automatically at start-up:
host overview, container overview and Prometheus self-monitoring. The datasource
is provisioned as `prometheus` (uid) pointing at `http://prometheus:9090`.

## The host nginx

Each stack ships its vhost as a single file in `<stack>/nginx/conf.d/`. Drop
the file(s) of the stack you are deploying into `/etc/nginx/conf.d/` on the
VPS that runs that stack. They listen on 80 + 443 and proxy to
`127.0.0.1:<port>` (the ports the compose file publishes on the host).

The vhosts are self-contained: they set `X-Forwarded-*` headers inline, so
the host `nginx.conf` only needs the standard globals (`worker_processes`,
`events { worker_connections }`, `http { include mime.types; include
/etc/nginx/conf.d/*.conf; }`). HTTP/2 is automatic on nginx ≥ 1.25.1.

### One-time setup per host

```bash
sudo apt install -y nginx certbot apache2-utils    # apache2-utils = htpasswd
sudo install -d -m755 /var/www/certbot            # ACME HTTP-01 root
# copy the vhost(s) you need
sudo cp <stack>/nginx/conf.d/*.conf /etc/nginx/conf.d/
sudo nginx -t && sudo systemctl reload nginx
```

Update a vhost later: `sudo cp ...` (or `git pull` + re-copy) and
`sudo systemctl reload nginx`. The container backends are not exposed — only
ports 80 and 443 are open.

### monitoring host — the basic-auth file

`monitoring/nginx/conf.d/metrics.conf` basic-auths the Prometheus
remote-write endpoint. Create the file once:

```bash
sudo install -d -m755 /etc/nginx/auth
METRICS_PASS=$(openssl rand -hex 24)
sudo htpasswd -cB /etc/nginx/auth/metrics.htpasswd metrics   # type $METRICS_PASS
echo "$METRICS_PASS"   # save as METRICS_BASIC_AUTH_PASSWORD in the projects' .env
```

## TLS

Every host runs its own nginx and terminates TLS there. certbot issues the
certificate in **webroot** mode — the host nginx serves
`/.well-known/acme-challenge/` from `/var/www/certbot`, so there is no
downtime and the renewal only has to reload nginx.

```bash
sudo certbot certonly --webroot -w /var/www/certbot \
    --non-interactive --agree-tos --email admin@june8th.eu.org \
    --cert-name june8th.eu.org \
    -d idp.june8th.eu.org
sudo certbot certonly --webroot -w /var/www/certbot \
    --non-interactive --agree-tos --email admin@june8th.eu.org \
    --cert-name june8th.eu.org \
    -d drive.june8th.eu.org
# ...and so on for every domain of the host
```

Every host uses `--cert-name june8th.eu.org`, so the certificate path is
always `/etc/letsencrypt/live/june8th.eu.org/` — that is what the vhosts
hardcode. Wire the renewal hook so nginx picks up new certs without manual
intervention:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null <<'EOF'
#!/bin/sh
systemctl reload nginx
# on the mail host, Stalwart serves 465/587/993/995 with the same cert:
# cd /opt/identity-email-provider/mail && docker compose restart stalwart
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

Test it without touching the live cert:

```bash
sudo certbot renew --dry-run
```

## DNS

| Name | Type | Value |
| --- | --- | --- |
| `idp.june8th.eu.org` | A | IP of VPS A |
| `mail.june8th.eu.org` | A | IP of VPS B |
| `mx.june8th.eu.org` | A | IP of VPS B |
| `vault.june8th.eu.org` | A | IP of VPS C |
| `drive.june8th.eu.org` | A | IP of VPS E |
| `grafana.june8th.eu.org` | A | IP of VPS D |
| `metrics.june8th.eu.org` | A | IP of VPS D |
| `june8th.eu.org` | MX | `mx.june8th.eu.org` |
| `june8th.eu.org` | TXT | `v=spf1 mx -all` |
| `_dmarc.june8th.eu.org` | TXT | `v=DMARC1; p=quarantine` |
| `<selector>._domainkey.june8th.eu.org` | TXT | DKIM public key (Stalwart, `Automatic`) |

The reverse DNS (PTR) of the IP of VPS B must be `mx.june8th.eu.org`.

## Backups

```bash
# per host, stop the stack, dump the volumes, start again
docker run --rm -v <stack>_authentik-db-data:/data -v "$PWD":/backup alpine \
    tar czf /backup/authentik-db-data.tar.gz -C /data .
```

Volumes worth backing up:

| Host | Volume | Content |
| --- | --- | --- |
| A | `idp_authentik-db-data` | users, applications, tokens |
| B | `mail_stalwart-data` | mailboxes, DKIM keys, configuration |
| C | `vault_vaultwarden-data` | encrypted vaults and attachments |
| D | `monitoring_prometheus-data` | metric history |
| E | `drive_nextcloud-data`, `drive_nextcloud-db-data` | user files, Nextcloud code, installed apps, `config.php`, the PostgreSQL cluster |

`vault_vaultwarden-data` holds encrypted vault data — the backup is only as
safe as the user's master password.

For Nextcloud: restore `nextcloud-data` (code + `config/` + `apps/` +
user files) and `nextcloud-db-data` together. `nextcloud-data/config/config.php`
contains the `instanceid` and `secret` referenced from the database; a
mismatch between the two backups puts the installation in maintenance
mode.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Bulwark login loops back to the login page | the browser was blocked by the CORS-less `/.well-known/oauth-authorization-server` answer of Authentik — the `^~ /.well-known/` block in `idp/nginx/conf.d/idp.conf` fixes it |
| `InvalidIssuer` / audience errors in the Stalwart log | `issuerUrl` must equal the `iss` claim of the token (`.../application/o/bulwark/`) and `requireAudience` must equal the client id `bulwark` |
| Mail to a new user is rejected | the mailbox does not exist yet — run `mail/scripts/sync-users.sh` |
| `502 Bad Gateway` on a domain | the container is not running or not published on `127.0.0.1` — check `docker compose ps` and the `proxy_pass` target in the vhost |
| nginx does not start | the vhost or the certificate is broken — `sudo nginx -t` shows the reason; the certificate is issued with `certbot --cert-name june8th.eu.org` (see [TLS](#tls)) |
| nginx does not pick up a vhost change | re-copy the file from the repo and `sudo systemctl reload nginx` |
| remote-write answers 401 | the basic-auth file is missing or stale — see [monitoring host — the basic-auth file](#monitoring-host--the-basic-auth-file) |
| The remote-write endpoint answers 401 | the basic-auth file is missing or stale — recreate it with `htpasswd -cB` (see [monitoring host — the basic-auth file](#monitoring-host--the-basic-auth-file)) |
| Grafana shows no data | check `monitoring/prometheus/prometheus.yml` and the `Targets` page of Prometheus |
| Nextcloud login redirects to the username/password page | the `user_oidc` provider is not installed or the Authentik provider secret was rotated — re-run `drive/scripts/01-bootstrap-nextcloud.sh` and update `DRIVE_OIDC_SECRET` |
| Nextcloud `invalid_scope` in the Authentik log | the Authentik `nextcloud` provider is missing the `groups` scope; re-add it (group-based quotas depend on it) |
| WebDAV returns 401 | OIDC logins cannot be replayed by WebDAV clients — generate an app password in the Nextcloud Security settings and use that for Finder / Explorer / `rclone` |
| WebDAV writes into an E2EE folder fail with `403 Client not allowed` | the `LockPlugin` of `end_to_end_encryption` rejects non-E2EE user agents — mount the E2EE folder through the Nextcloud desktop or mobile client, or use a non-E2EE folder for that share |
| Nextcloud quota is reset on every login | the Authentik `nextcloud` provider has a `quota` claim mapped; remove it — `drive/scripts/sync-users.sh` is the source of truth for quotas |
