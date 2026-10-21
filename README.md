# Identity & Mail — `june8th.eu.org`

## Layout

```text
Internet
  ├─ nginx :80/:443 ── idp.june8th.eu.org   → Authelia (SSO/OIDC)
  │                 ├─ mail.june8th.eu.org  → Bulwark (webmail)
  │                 └─ mx.june8th.eu.org    → Stalwart (admin/JMAP)
  ├─ SMTP/IMAP ports ──────────────────────→ Stalwart
  └─ vault.june8th.eu.org                  → Vaultwarden (currently disabled)

Docker network: Authelia + Stalwart ── OpenLDAP (users and mail accounts)
Persistent named volumes: LDAP, Authelia, Stalwart, Bulwark
```

| Public ports | Service |
|---|---|
| 80, 443 | nginx / HTTPS sites |
| 25, 465, 587 | SMTP / submission |
| 993, 995 | IMAPS / POP3S |

## Quickstart (fresh VPS)

1. Point DNS records below at the VPS. Install a TLS certificate covering `june8th.eu.org` and `*.june8th.eu.org`; nginx and Stalwart use `/etc/letsencrypt` by default.
2. Clone the repo, then run each bootstrap script **once**:

   ```bash
   ./scripts/generate-env.sh             # creates private .env + OIDC secret digests
   ./scripts/generate-authelia-keys.sh   # creates the per-host OIDC signing key
   ```

   Keep `.env`, `authelia/keys/` and `authelia/secrets/` private. Do not run `generate-env.sh --force` on an initialized host: it rotates credentials.
3. Start the stack and check status:

   ```bash
   docker compose config --quiet
   docker compose up -d
   docker compose ps
   ```

4. Open `https://mx.june8th.eu.org/admin` and complete Stalwart's first-run setup. Use OpenLDAP for accounts; Authelia SSO is at `https://idp.june8th.eu.org`.

## DNS records

Replace `<VPS_IP>` with the server's public IPv4. Add AAAA records only if IPv6 is configured.

| Type | Name | Value |
|---|---|---|
| A | `idp` | `<VPS_IP>` |
| A | `mail` | `<VPS_IP>` |
| A | `mx` | `<VPS_IP>` |
| A | `vault` | `<VPS_IP>` (optional; Vaultwarden is disabled) |
| MX | `@` | `10 mx.june8th.eu.org.` |
| TXT | `@` | `v=spf1 mx -all` |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:admin@june8th.eu.org` |
| TXT | `v1-rsa-20261021._domainkey` | DKIM public key from Stalwart |
| TXT | `v1-ed25519-20261021._domainkey` | DKIM public key from Stalwart |

Publish each DKIM value exactly as shown by Stalwart, including its `v=DKIM1; k=...; p=...` fields. Set the VPS reverse DNS/PTR to `mx.june8th.eu.org` at the hosting provider.

Vaultwarden is intentionally disabled. Its Compose block remains commented out.
