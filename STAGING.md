# Staging environment

Staging runs as a second, isolated Docker Compose stack on the **same Hetzner VPS** as
production. It exists so iOS can integrate against new backend endpoints (B1+) before they
ship to prod.

| | Production | Staging |
|---|---|---|
| Compose file | `docker-compose.prod.yml` | `docker-compose.staging.yml` |
| Compose project | (default) | `snaglist-staging` |
| App port (localhost) | `8080` | `8081` |
| Postgres volume | `pgdata` | `pgdata_staging` |
| Image tag | `:latest` | `:staging` |
| Deploy trigger | push to `main` | push to `staging` branch (or manual) |
| Public hostname | `api.snaglist.dev` | `staging-api.snaglist.dev` |

## One-time provisioning (human — operational, not in CI)

1. **DNS / Cloudflare:** point `staging-api.snaglist.dev` at the VPS and proxy it to
   `127.0.0.1:8081` (same Cloudflare Tunnel / reverse-proxy mechanism prod already uses on
   `:8080`). Add `staging-api.snaglist.dev` to the backend CORS allow-list if the web app
   will call it (see `configure.swift`).
2. **On the VPS**, create the staging directory and drop in the compose + env files:
   ```bash
   mkdir -p /home/snaglist/staging
   # copy docker-compose.staging.yml into it (e.g. via git or scp)
   cp .env.staging.example /home/snaglist/staging/.env.staging
   # then edit .env.staging — set real POSTGRES_PASSWORD, JWT_SECRET (different from prod!),
   # DATABASE_URL password, and MAGIC_LINK_BASE_URL=https://staging-api.snaglist.dev
   ```
3. **GitHub secrets:** `HETZNER_HOST` and `HETZNER_SSH_KEY` are already used by the prod
   deploy and are reused as-is — no new secrets required.

## Deploying

- Push the branch under test to `staging` (e.g. `git push origin feat/b1-magic-link-auth:staging`),
  or run the **Deploy to Staging** workflow manually from the Actions tab.
- The workflow builds the `:staging` image, SSHes to the VPS, restarts the staging stack, and
  health-checks `http://localhost:8081/health`.

## Notes

- `RESEND_API_KEY` is intentionally left **unset** on staging by default: the magic-link
  request endpoint still returns `204` and stores the token, so iOS can complete the
  request → verify loop by reading the token from the staging DB or app logs without real
  emails going out. Set the key only if you want staging to deliver live email.
- Migrations run automatically on boot (`app.autoMigrate()`), so a fresh staging DB is
  schema-current after first deploy.
