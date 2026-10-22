# Identity, Mail, Vault and Monitoring stacks

Self-hosted identity provider, mail server, password manager and a small
observability stack, split over four VPS and deployed from this single
repository.

| Stack | Host | Services | Public endpoints |
| --- | --- | --- | --- |
| `idp/` | VPS A | Authentik, PostgreSQL, nginx | `https://idp.june8th.eu.org` |
| `mail/` | VPS B | Stalwart, Bulwark (webmail), nginx | `https://mail.june8th.eu.org`, `https://mx.june8th.eu.org`, SMTP/IMAP ports |
| `vault/` | VPS C | Vaultwarden, nginx | `https://vault.june8th.eu.org` |
| `monitoring/` | VPS D | Prometheus, Alertmanager, Grafana, node-exporter, cAdvisor, nginx | `https://grafana.june8th.eu.org`, `https://metrics.june8th.eu.org/api/v1/write` |

Everything talks to everything else over public HTTPS only — no mesh, no
private network between hosts.

* **Authentik** is the single identity provider (OIDC) for Bulwark and
  Vaultwarden.
* **Stalwart** authenticates mail users against Authentik over OIDC and
  stores the mailboxes itself.
* **Vaultwarden** authenticates against Authentik over OIDC.
* **Prometheus** collects metrics from every stack and from other projects
  (scrape and/or remote-write) and hands alerts to **Alertmanager**.

## Repository layout

```
idp/          Authentik + PostgreSQL + nginx          (VPS A)
mail/         Stalwart + Bulwark + nginx              (VPS B)
vault/        Vaultwarden + nginx                     (VPS C)
monitoring/   Prometheus + Alertmanager + Grafana      (VPS D)
nginx/        shared nginx.conf (globals, ACME, default server)
```

Each stack directory is self-contained: its own `compose.yaml`, `.env`,
`nginx/conf.d/` and `scripts/`. Only `nginx/nginx.conf` is shared, so the
proxy defaults stay identical on all hosts.

```
<stack>/
  compose.yaml          # top-level `name:` namespaces the volumes
  .env.example          # template, all secrets empty
  nginx/conf.d/*.conf   # vhosts of this host
  scripts/00-generate-env.sh
  scripts/10-tls.sh
```

## Requirements

* One VPS per stack, Ubuntu 24.04 or Debian 13, Docker Engine + Compose v2
* `certbot`, `openssl`, `curl`, `jq` on the host
* A DNS zone for `june8th.eu.org`
* Ports open: 80, 443 everywhere; 25, 465, 587, 993, 995 on the mail host

Every host runs the same repository. Clone it wherever you deploy:

```bash
git clone <repo> /opt/identity-email-provider
cd /opt/identity-email-provider/<stack>
```

## Deployment order

The IdP comes first — Bulwark and Vaultwarden need their OIDC applications to
exist before they can start.

### 1. VPS A — identity provider

```bash
cd /opt/identity-email-provider/idp
scripts/00-generate-env.sh          # prints the Authentik admin password ONCE
scripts/10-tls.sh                   # issues the certificate (nginx is stopped for it)
docker compose up -d
```

The certificate is issued as `--cert-name june8th.eu.org` on **every** host, so
the path inside the containers is always
`/etc/letsencrypt/live/june8th.eu.org/` — that is what nginx and Stalwart
hardcode.

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
scripts/10-tls.sh                   # mail. + mx.
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
scripts/10-tls.sh                   # vault.
docker compose up -d
```

### 4. VPS D — monitoring

```bash
cd /opt/identity-email-provider/monitoring
scripts/00-generate-env.sh          # prints the Grafana and metrics passwords ONCE
scripts/10-render-alertmanager.sh   # renders the receivers from .env
scripts/10-tls.sh                   # grafana. + metrics.
docker compose up -d
```

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

Notes:

* Use **Authorization Code with PKCE**, client type *confidential*.
* The authorized scopes must cover what the client asks for — a missing scope
  shows up as `invalid_scope` in the Authentik log.
* The Bulwark redirect URI has to match the locale prefix Bulwark adds to the
  callback path (`/en/auth/callback`), hence the regex entry.
* Subject mapping: `email` — Stalwart maps the token to the mailbox address
  with it.

### API token for the user sync

`mail/scripts/sync-users.sh` reads the user list from the Authentik API. Create
a service account in `Authentik → Directory → Users → Service Accounts`, give it
read access to `core/users` (or use `akadmin`) and put its token in
`mail/.env`:

```
AUTHENTIK_API_TOKEN=...
```

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

## TLS

`scripts/10-tls.sh` issues the certificate with certbot in standalone mode
(nginx is stopped for the request) and installs renewal hooks that stop and
start nginx again around the renewal:

```bash
cd /opt/identity-email-provider/<stack>
scripts/10-tls.sh                                  # default domains of the stack
scripts/10-tls.sh mail.june8th.eu.org mx.june8th.eu.org   # explicit domains
certbot renew --dry-run
```

Every host uses `--cert-name june8th.eu.org`, so the renewal hooks and the
container paths stay the same everywhere.

## DNS

| Name | Type | Value |
| --- | --- | --- |
| `idp.june8th.eu.org` | A | IP of VPS A |
| `mail.june8th.eu.org` | A | IP of VPS B |
| `mx.june8th.eu.org` | A | IP of VPS B |
| `vault.june8th.eu.org` | A | IP of VPS C |
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

`vault_vaultwarden-data` holds encrypted vault data — the backup is only as
safe as the user's master password.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Bulwark login loops back to the login page | the browser was blocked by the CORS-less `/.well-known/oauth-authorization-server` answer of Authentik — the `^~ /.well-known/` block in `idp/nginx/conf.d/idp.conf` fixes it |
| `InvalidIssuer` / audience errors in the Stalwart log | `issuerUrl` must equal the `iss` claim of the token (`.../application/o/bulwark/`) and `requireAudience` must equal the client id `bulwark` |
| Mail to a new user is rejected | the mailbox does not exist yet — run `mail/scripts/sync-users.sh` |
| nginx will not start | the certificate is missing — run `scripts/10-tls.sh` first |
| `nginx -t` fails after a renewal | the renewal hooks stopped nginx; start it again with `docker compose up -d nginx` |
| Grafana shows no data | check `monitoring/prometheus/prometheus.yml` and the `Targets` page of Prometheus |
