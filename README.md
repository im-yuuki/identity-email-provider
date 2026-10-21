# Identity & Mail — `june8th.eu.org`

Self-hosted identity, mail, webmail, and password vault services. **Authentik is the source of truth for users and groups.** Stalwart reads mail users from Authentik through its LDAP outpost; Bulwark and Vaultwarden use Authentik for OIDC sign-in.

## Services

| URL | Service | Purpose |
|---|---|---|
| `https://idp.june8th.eu.org` | Authentik | User and admin portal, identity provider, OIDC |
| `https://mail.june8th.eu.org` | Bulwark | Webmail |
| `https://mx.june8th.eu.org` | Stalwart | Mail server and admin/JMAP interface |
| `https://vault.june8th.eu.org` | Vaultwarden | Password vault with Authentik SSO |

Nginx publishes the web services on ports 80 and 443. Stalwart also requires inbound TCP ports 25, 465, 587, 993, and 995. The Authentik LDAP outpost is internal to the Compose network; it is not published to the Internet.

## Requirements

- Docker Engine and the Docker Compose plugin on the VPS.
- DNS records pointing to the VPS (see [DNS](#dns-records)).
- A readable Let's Encrypt certificate tree at `/etc/letsencrypt` by default. The certificate must cover `june8th.eu.org` and `*.june8th.eu.org`. Set `LETSENCRYPT_DIR` in `.env` if the tree is elsewhere.
- Firewall rules allowing the public ports listed above. Some VPS providers restrict outbound SMTP on port 25.

Run the commands below **on the VPS**, from the repository directory. In particular, the environment generator checks Docker volumes on the machine where it runs. Do not run Docker runtime commands against a development Mac engine.

## Fresh install or switch from the old stack

### 1. Stop the old stack, if present

Before replacing the old OpenLDAP/Authelia Compose files, stop their containers while keeping all volumes:

```bash
docker compose down --remove-orphans
```

This switch does not migrate OpenLDAP users or reuse Authelia data. Existing LDAP, Authelia, previous Authentik, Stalwart, Bulwark, and Vaultwarden volumes are **not deleted**. The new Authentik installation uses separate volumes; legacy volumes remain unused. Never add `-v` unless you deliberately intend to destroy stored data.

### 2. Generate fresh secrets

On a fresh installation:

```bash
./scripts/00-generate-env.sh
```

If old volumes exist, the generator refuses by default. Since this deployment intentionally starts a new identity store and leaves the old volumes unused, explicitly allow that:

```bash
./scripts/00-generate-env.sh --force --allow-existing-volumes
```

The latter backs up an existing `.env` and writes a new one; it does not reuse old secrets or delete volumes. Treat both `.env` and any backup as credentials. The generator prints the Vaultwarden admin password once—store it securely. **Do not rerun the generator to add later values:** it rotates the generated secrets. Add the LDAP outpost token to the existing `.env` as described below.

### 3. Start Authentik

```bash
docker compose up -d nginx postgres authentik authentik-worker
```

Open `https://idp.june8th.eu.org/if/admin/` and sign in as `akadmin` using `AUTHENTIK_BOOTSTRAP_PASSWORD` from `.env`. The bootstrap password is only applied when Authentik initializes a new database; changing the variable later does not reset an existing account. Create the users and groups here—this is the identity source of truth.

### 4. Configure Authentik's LDAP provider and outpost

In the Authentik Admin interface, create an LDAP application/provider with base DN:

```text
dc=ldap,dc=goauthentik,dc=io
```

Then configure a service account for Stalwart:

1. Create a **service account** named `svc-mail` in **Directory → Users**. Create an **app password** for it and copy the generated value. Do not use an API token for LDAP bind authentication.
2. Replace `STALWART_LDAP_BIND_PASSWORD` in `.env` with that app password. Configure the LDAP provider's bind flow to accept app passwords.
3. Give the service account access to the LDAP application. To allow directory searches, create a role, add `svc-mail` to it, then assign that role the provider's **Search full LDAP directory** permission.
4. Create a **manual LDAP outpost** in **Applications → Outposts**, assign the LDAP application, and copy the outpost token into `AUTHENTIK_LDAP_TOKEN` in `.env`.

Edit the existing `.env`; do not rerun the generator. The bootstrap script checks that `AUTHENTIK_LDAP_TOKEN` is non-empty before it starts. The LDAP outpost listens on the internal Compose network at `authentik-ldap:3389` and is not Internet-facing.

### 5. Configure OIDC applications

Create OAuth2/OpenID Connect providers and applications in Authentik for Bulwark and Vaultwarden. Use the matching client IDs and secrets from `.env`, and set the application slugs to `bulwark` and `vaultwarden` so the issuer URLs match Compose:

| Application | Client ID | Secret variable | Strict redirect URI |
|---|---|---|---|
| Bulwark | `bulwark` | `BULWARK_OAUTH_SECRET` | `https://mail.june8th.eu.org/auth/callback` |
| Vaultwarden | `vaultwarden` | `VAULTWARDEN_SSO_SECRET` | `https://vault.june8th.eu.org/identity/connect/oidc-signin` |

Allow the intended users or groups to access each application. For a new provider, enter the corresponding value from `.env` as its client secret so both sides match.

### 6. Apply Stalwart's directory and TLS configuration

After the Authentik LDAP provider, service account, application binding, and outpost token are ready, run:

```bash
./scripts/01-bootstrap-stalwart.sh
```

The script starts the LDAP outpost and Stalwart in recovery mode, validates and applies `stalwart/bootstrap.ndjson`, then stops and removes the project's containers. **Named volumes are preserved**; the script never uses `down -v`. It exits with an error before starting containers if the outpost token is missing.

### 7. Start the full stack

```bash
docker compose --profile ldap up -d
docker compose ps
```

The `ldap` profile is required to start the Authentik LDAP outpost. Visit the service URLs in the table above.

## TLS certificate renewals

Stalwart runs as root in its container and reads the host's Let's Encrypt files through a read-only mount. No certificate copy or host renewal hook is used. After Certbot rotates the files, reload the certificates in Stalwart using its **Reload TLS Certificates** action in the admin interface or CLI. While the stack is running, reload Nginx as well:

```bash
docker compose exec nginx nginx -s reload
```

If the stack is stopped during renewal, start it again to load the renewed files.

## DNS records

Replace `<VPS_IP>` with the VPS public IPv4 address. Add AAAA records only if IPv6 is configured and reachable.

| Type | Name | Value |
|---|---|---|
| A | `idp` | `<VPS_IP>` |
| A | `mail` | `<VPS_IP>` |
| A | `mx` | `<VPS_IP>` |
| A | `vault` | `<VPS_IP>` |
| MX | `@` | `10 mx.june8th.eu.org.` |
| TXT | `@` | `v=spf1 mx -all` |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:admin@june8th.eu.org` |
| TXT | `<selector>._domainkey` | DKIM record generated by Stalwart |

Publish the complete DKIM record shown by Stalwart, including its `v=DKIM1; k=...; p=...` fields. Set the VPS reverse DNS/PTR record to `mx.june8th.eu.org` at the hosting provider.
