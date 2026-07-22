# Self-Hosting the JetKVM Cloud Dashboard

This guide deploys a fully self-hosted JetKVM cloud dashboard — API, database,
web dashboard, and Traefik reverse proxy — on any Linux host running Docker,
so a JetKVM device can be accessed securely and remotely without the official
`jetkvm.com` cloud. The reference host used throughout is a Raspberry Pi 5
running Raspberry Pi OS Lite, but any Linux machine with Docker works.

The deployment is driven by [`setup-deployment.sh`](./setup-deployment.sh) in
this folder, which interactively generates every file the stack needs
(`compose.yaml`, `Caddyfile`, `.env`) and then hands off to
`docker compose up -d`.

> [!WARNING]
> **Both repositories must be cloned into the same parent folder.**
> `setup-deployment.sh` builds the dashboard UI directly from a sibling
> checkout of the `kvm` repository that it resolves at `../kvm` relative to
> the `cloud-api` repository root. Run both `git clone` commands below from
> the **same directory**, and do not rename the `kvm` folder. If the sibling
> checkout is missing, the script stops with an error before making any
> changes.

## Contents

1. [Prerequisites](#prerequisites)
2. [Repository sources](#repository-sources)
3. [Cloning the repositories](#cloning-the-repositories)
4. [Information to gather before running the script](#information-to-gather-before-running-the-script)
5. [What setup-deployment.sh does](#what-setup-deploymentsh-does)
6. [OIDC provider configuration](#oidc-provider-configuration)
7. [Traefik reverse proxy design](#traefik-reverse-proxy-design)
8. [Running the setup script and starting the stack](#running-the-setup-script-and-starting-the-stack)
9. [Custom JetKVM device build](#custom-jetkvm-device-build)
10. [Adopting the device and verifying](#adopting-the-device-and-verifying)
11. [Troubleshooting](#troubleshooting)

## Prerequisites

- A Linux host (e.g. Raspberry Pi 5 with Raspberry Pi OS Lite) with:
  - Docker Engine and the Docker Compose v2 plugin (`docker compose version`
    must succeed)
  - `git`
- Two DNS names pointing at the host, one for the dashboard and one for the
  API — for example `app.example.com` and `api.example.com`. For Let's
  Encrypt HTTP-01 certificates, ports 80 and 443 must be reachable from the
  internet; for the Cloudflare DNS-01 or internal-only modes they do not.
- An OIDC identity provider (Google, authentik, or Keycloak). The cloud API
  has **no local accounts** — all sign-ins go through OIDC.
- A JetKVM device on the network, reachable over SSH/IP, for the custom
  device build.
- For the device build: Go and Node.js 22 on the machine that runs the build
  (this can be the same host or a workstation).

## Repository sources

The commands in this guide use the fork variables below so the whole guide
can be switched between the fork (which carries the Cloud OIDC changes) and
upstream by editing **only this section**. Once the OIDC changes are merged
upstream, replace the fork URLs with the upstream URLs and every command in
the guide remains valid.

| Repository | Fork (current, with OIDC changes) | Upstream (after OIDC merge) |
|------------|-----------------------------------|-----------------------------|
| cloud-api  | `https://github.com/JDB321Sailor/cloud-api` | `https://github.com/jetkvm/cloud-api` |
| kvm        | `https://github.com/JDB321Sailor/kvm`       | `https://github.com/jetkvm/kvm`       |

## Cloning the repositories

Run both clones from the same directory (see the warning above):

```sh
mkdir -p ~/jetkvm && cd ~/jetkvm

# Fork (current — includes the Cloud OIDC changes)
git clone https://github.com/JDB321Sailor/cloud-api.git
git clone https://github.com/JDB321Sailor/kvm.git
```

Equivalent upstream commands (use these instead once the OIDC changes are
merged into the upstream JetKVM repositories):

```sh
# Upstream
git clone https://github.com/jetkvm/cloud-api.git
git clone https://github.com/jetkvm/kvm.git
```

The resulting layout must be:

```
~/jetkvm/
├── cloud-api/     ← this repository (contains deploy/)
└── kvm/           ← sibling checkout used to build the dashboard UI
```

## Information to gather before running the script

The script prompts for everything it needs; collect these values first:

| Item | Example | Needed when |
|------|---------|-------------|
| Dashboard DNS name | `app.example.com` | always |
| API DNS name | `api.example.com` | always |
| Certificate mode | `http-01`, `dns-01`, or `internal` | always |
| ACME email address | `admin@example.com` | `http-01` / `dns-01` |
| Cloudflare DNS API token (Zone:DNS:Edit) | — | `dns-01` only |
| OIDC provider choice | `google` / `authentik` / `keycloak` | always |
| OIDC client ID and client secret | — | always (created in the provider first) |
| Authentik base URL + application slug | `https://authentik.example.com`, `jetkvm` | authentik only |
| Keycloak base URL + realm | `https://keycloak.example.com`, `main` | keycloak only |
| Allowed sign-in emails (optional) | `me@example.com` | optional |
| ICE (STUN/TURN) servers (optional) | `stun:stun.l.google.com:19302` | optional |
| Cloudflare TURN key ID + token (optional) | — | optional |

Before choosing the OIDC values, register the redirect URI
`https://<api-domain>/oidc/callback` with the provider — see
[OIDC provider configuration](#oidc-provider-configuration). Note the redirect
URI uses the **API** domain (`api.example.com`), not the dashboard/app domain
(`app.example.com`), even though you sign in via the dashboard.

## What setup-deployment.sh does

The script is an idempotent, rerunnable builder. Section by section:

1. **Prerequisite checks** — verifies `docker`, the Compose v2 plugin, the
   `cloud-api` Dockerfile, and the sibling `../kvm/ui` checkout. It fails
   fast with a clear message if the kvm repository is not cloned next to
   cloud-api.
2. **Answers file** — loads `deploy/setup-deployment.env` (created on first
   successful run, `chmod 600`). Every prompt resolves through three
   precedence tiers: an exported environment variable
   (e.g. `JETKVM_SETUP_OIDC=n ./setup-deployment.sh`) wins outright; a value
   in the answers file becomes the prompt default (or is used as-is when the
   file sets `AUTORUN=true`); otherwise the interactive prompt with its
   built-in default applies. Setting `AUTORUN=true` in the file makes reruns
   fully non-interactive. The script never changes the `AUTORUN` flag itself.
3. **Domains and TLS section** — asks for the dashboard and API DNS names and
   the certificate mode (`http-01`, `dns-01` via Cloudflare, or `internal`
   self-signed for LAN-only deployments), plus the Let's Encrypt email and
   Cloudflare token where applicable.
4. **OIDC section** — asks which provider to use and provider-specific
   questions; see the next chapter for details on where each value ends up.
5. **Extras section** — optional allowed sign-in email list
   (`ALLOWED_IDENTITIES`), custom ICE servers (`ICE_SERVERS`), and Cloudflare
   TURN credentials (`CLOUDFLARE_TURN_ID` / `CLOUDFLARE_TURN_TOKEN`).
6. **File generation** — writes into `deploy/`:
   - `.gitignore` — written first; keeps every generated deployment file
     (itself included) out of git, since they contain secrets and
     host-specific data.
   - `compose.yaml` — the full stack (Traefik, Postgres, API migration job,
     API, dashboard UI). The API is built from this repository's Dockerfile;
     the dashboard image is built from `../../kvm/ui` with
     `VITE_CLOUD_API=https://<api-domain>` baked in (the kvm UI's
     `npm run build:prod` cloud build).
   - `Caddyfile` — static file server config for the built dashboard with a
     single-page-app fallback.
   - `.env` (`chmod 600`) — domains, generated secrets, and all environment
     variables the API reads (`API_HOSTNAME`, `APP_HOSTNAME`, `CORS_ORIGINS`,
     `OIDC_*`, etc. — the same names as `.env.example` in the repo root).
7. **Secret handling** — `COOKIE_SECRET` and `POSTGRES_PASSWORD` are
   generated with `openssl rand` (with python3/urandom fallbacks) on the
   first run and **preserved on every rerun**, so rerunning the script never
   invalidates sessions or breaks the existing database volume. If a
   `jetkvm-cloud_postgres-data` Docker volume already exists but no password
   is known, the script offers to **enter** the existing password, **wipe**
   the volume, or **abort** — it never silently generates a mismatched
   password.
8. **Summary** — prints the `docker compose up -d --build` command, the
   dashboard URL, and the next steps for the device build.

Generated files (`compose.yaml`, `Caddyfile`, `.env`,
`setup-deployment.env`, and — in the Let's Encrypt modes — `letsencrypt/`)
contain deployment-specific data and secrets. The script writes a
`deploy/.gitignore` covering all of them, so git ignores them automatically —
never commit them.

## OIDC provider configuration

The script writes the OIDC settings into `deploy/.env` as the exact
environment variables the cloud API reads (`src/oidc-config.ts` /
`src/oidc.ts`):

| Variable | Meaning |
|----------|---------|
| `OIDC_ISSUER` | Issuer URL; must serve `/.well-known/openid-configuration` |
| `OIDC_CLIENT_ID` | OAuth client ID |
| `OIDC_CLIENT_SECRET` | OAuth client secret |
| `OIDC_SCOPES` | Requested scopes (default `openid email profile`) |

The API performs the authorization-code flow with PKCE and redirects back to
`https://<api-domain>/oidc/callback` — that is the **redirect URI** to
register with every provider. Users must also be permitted by
`ALLOWED_IDENTITIES` when that list is non-empty.

> [!IMPORTANT]
> **The redirect URI must use the API domain, NOT the dashboard (APP) domain.**
> This is an easy mistake to make: you open the dashboard at
> `https://app.example.com` to sign in, so it feels natural to register that
> host with the provider. But the OAuth callback is served by the **API**, so
> the redirect URI you enter in the OIDC client is:
>
> ```
> https://api.example.com/oidc/callback
> ```
>
> **not** `https://app.example.com/oidc/callback`. The value is derived in code
> from the `API_HOSTNAME` environment variable (`src/oidc.ts`:
> `REDIRECT_URI = ${API_HOSTNAME}/oidc/callback`), which the script sets to
> `https://<api-domain>`. Registering the app domain instead produces a
> `redirect_uri` mismatch and every sign-in fails.

### All OIDC-related environment variables set by the script

Beyond the four provider values above, the script writes the supporting
variables the OIDC flow depends on into `deploy/.env`. The example values below
use `app.example.com` (dashboard) and `api.example.com` (API):

| Variable | Consumed by | Example value | Purpose |
|----------|-------------|---------------|---------|
| `OIDC_ISSUER` | `oidc-config.ts` `getOidcIssuerUrl` | `https://auth.example.com/application/o/jetkvm/` | Issuer for discovery; **must exactly match** the `issuer` field returned by `/.well-known/openid-configuration` |
| `OIDC_CLIENT_ID` | `oidc-config.ts` `getOidcClientId` | `<client-id>` | OAuth client ID from the provider |
| `OIDC_CLIENT_SECRET` | `oidc-config.ts` `getOidcClientSecret` | `<client-secret>` | OAuth client secret from the provider |
| `OIDC_SCOPES` | `oidc-config.ts` `getOidcScopes` | `openid email profile` | Requested scopes (default when unset) |
| `API_HOSTNAME` | `oidc.ts` `REDIRECT_URI` | `https://api.example.com` | **Drives the redirect URI** `${API_HOSTNAME}/oidc/callback` — must be the API domain, no trailing slash |
| `APP_HOSTNAME` | `oidc.ts` `normalizeReturnTo` | `https://app.example.com` | Dashboard origin used to validate post-login `returnTo` redirects |
| `CORS_ORIGINS` | CORS middleware | `https://app.example.com` | Allowed browser origins for API calls from the dashboard |
| `COOKIE_SECRET` | session middleware | `<generated hex>` | Signs the session cookie that stores the CSRF token and PKCE `code_verifier` during the login round-trip |

If `API_HOSTNAME` and the registered redirect URI disagree, the provider
rejects the callback; if `OIDC_ISSUER` and the discovery document's `issuer`
disagree, issuer validation fails after the callback. The script keeps both in
sync automatically — the redirect URI it prints during setup is built from the
same `API_DOMAIN` answer that becomes `API_HOSTNAME`.

### Google

1. In [Google Cloud Console](https://console.cloud.google.com/) open
   **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Application type **Web application**; add the authorized redirect URI
   `https://<api-domain>/oidc/callback`.
3. Copy the client ID and client secret into the script prompts. The issuer
   is fixed to `https://accounts.google.com` — the script sets it
   automatically.

### Authentik (preferred provider — expanded guidance)

1. In the authentik admin UI open **Applications → Providers → Create** and
   choose **OAuth2/OpenID Provider**:
   - **Client type:** Confidential
   - **Redirect URIs:** `https://<api-domain>/oidc/callback` (strict)
   - **Signing key:** any RS256 certificate (the default authentik
     self-signed certificate works)
   - **Scopes:** keep the default `openid`, `email`, and `profile` property
     mappings selected — the cloud API identifies users by the `email` claim,
     so the email scope mapping is required. Group claims are **not** needed;
     access control is done per-email with `ALLOWED_IDENTITIES`.
2. Note the generated **Client ID** and **Client Secret** from the provider
   page.
3. Open **Applications → Applications → Create**, bind it to the provider,
   and pick a **slug** (e.g. `jetkvm`). The slug determines the issuer URL:

   ```
   https://<authentik-base-url>/application/o/<slug>/
   ```

   The script asks for the base URL and slug and constructs this issuer
   itself — including the required trailing slash.
4. Assign the authentik users (or a group) that may use JetKVM to the
   application so authentik authorizes them; optionally mirror the same set
   of email addresses into `ALLOWED_IDENTITIES` for enforcement on the
   cloud-api side.
5. Verify discovery works before running the stack:

   ```sh
   curl https://<authentik-base-url>/application/o/<slug>/.well-known/openid-configuration
   ```

### Keycloak

1. In the Keycloak admin console select the realm, then
   **Clients → Create client** (OpenID Connect):
   - **Client authentication:** On (confidential)
   - **Valid redirect URIs:** `https://<api-domain>/oidc/callback`
2. Copy the client ID and the secret from the client's **Credentials** tab.
3. The issuer is `https://<keycloak-base-url>/realms/<realm>`; the script
   asks for the base URL and realm and constructs it.

## Traefik reverse proxy design

Unlike the community nginx-based walkthrough, this stack uses **Traefik v3**
configured entirely through Docker labels — no proxy config files to edit:

- Traefik publishes ports 80 and 443. Port 80 only redirects to HTTPS (and
  answers ACME HTTP-01 challenges).
- The API container carries labels routing
  ``Host(`<api-domain>`)`` to its internal port 3000; the dashboard container
  routes ``Host(`<app-domain>`)`` to its static server on port 8080. Only
  labeled containers are exposed (`exposedbydefault=false`); Postgres is
  never published.
- **WebSockets** (the device ↔ cloud connection on `/webrtc/signaling/*`)
  work through Traefik out of the box — no `Upgrade`/`Connection` header
  configuration is required, which removes the manual WebSocket proxy setup
  the nginx approach needs.
- **TLS**: with `http-01` or `dns-01` mode a `letsencrypt` certificate
  resolver is added and certificates are stored in
  `deploy/letsencrypt/acme.json`; with `internal` mode Traefik serves its
  built-in self-signed certificate (browsers and the device must trust it
  manually — Let's Encrypt is strongly recommended).
- Traefik adds `X-Real-Ip`/`X-Forwarded-For` headers; the generated `.env`
  sets `REAL_IP_HEADER=x-real-ip` so the API logs real client addresses.

## Running the setup script and starting the stack

```sh
cd ~/jetkvm/cloud-api/deploy
./setup-deployment.sh
```

Answer the prompts, then start the stack:

```sh
docker compose up -d --build
```

The first start builds two images on the host (the API from this repository
and the dashboard from `../kvm/ui`); on a Raspberry Pi 5 allow several
minutes. Verify:

```sh
docker compose ps
curl -fsS https://api.example.com/healthz    # → {"ready":true,"time":"..."}
```

Then open `https://app.example.com` and sign in through the OIDC provider.

To rerun after changing answers, run `./setup-deployment.sh` again (previous
answers are the defaults; secrets are preserved) followed by
`docker compose up -d --build`. For unattended reruns set `AUTORUN=true` in
`deploy/setup-deployment.env`.

## Custom JetKVM device build

The stock JetKVM firmware points at `https://api.jetkvm.com`. A development
build from the kvm repository lets the device use the self-hosted cloud (and
carries the matching OIDC device changes). Build on a machine with Go and
Node.js 22 installed, from the sibling `kvm` checkout cloned earlier
(fork: `JDB321Sailor/kvm`; switch to `jetkvm/kvm` after the upstream merge —
see [Repository sources](#repository-sources)).

1. Enable **Developer Mode** on the JetKVM (Settings → Advanced → Developer
   Mode) so the device accepts SSH connections, and note the device's IP
   address.
2. Build and push a dev build in one step with the repo's deploy script,
   which builds the device UI (`ui` → `npm run build:device`), compiles the
   ARM binary, and installs it over SSH:

   ```sh
   cd ~/jetkvm/kvm
   ./dev_deploy.sh -r <device-ip>
   ```

   Alternatively `make build_dev` produces the binary under `bin/` without
   deploying.
3. Point the device at the self-hosted cloud. In the device's local web UI
   open **Settings → Advanced** and set the custom cloud URLs:
   - Cloud API URL: `https://api.example.com`
   - Cloud App URL: `https://app.example.com`

   (This drives the device's `setCloudUrl` RPC, which updates `cloud_url` and
   `cloud_app_url` in the device config and reconnects.)

The dashboard web UI itself is already built with the self-hosted API URL by
the compose stack (`VITE_CLOUD_API` build argument), so no separate frontend
build step is required on the device side.

## Adopting the device and verifying

1. Open `https://app.example.com`, sign in via OIDC.
2. Choose to add/adopt a device and follow the flow — the dashboard redirects
   to the device's local UI, which registers the device with your cloud API
   and exchanges the one-time token for a permanent device token.
3. Back in the dashboard the device appears in the device list; opening it
   establishes a WebRTC session through the self-hosted signaling endpoint.

## Troubleshooting

- **`kvm repository not found`** — both repositories were not cloned into
  the same parent folder; re-read the warning at the top of this guide.
- **No certificate / TLS errors** — check `docker compose logs traefik`. For
  HTTP-01, port 80 must be reachable from the internet and DNS must already
  resolve to the host. `deploy/letsencrypt/acme.json` stores issued
  certificates.
- **Sign-in redirects fail** — the redirect URI registered at the provider
  must be exactly `https://<api-domain>/oidc/callback`, and `OIDC_ISSUER`
  must serve `/.well-known/openid-configuration` (for authentik the trailing
  slash matters). Check `docker compose logs api`.
- **`password authentication failed for user "jetkvm"`** — the Postgres
  volume was initialised with a different password. Rerun
  `./setup-deployment.sh`; it detects this and offers enter/wipe/abort.
- **Device shows disconnected** — confirm the device's cloud URL points at
  `https://<api-domain>` and that the WebSocket connection is allowed
  through any intermediate firewall; watch `docker compose logs -f api`
  while the device reconnects.
- **Dashboard loads but API calls fail (CORS)** — `CORS_ORIGINS` in
  `deploy/.env` must equal `https://<app-domain>`; rerun the script if the
  domain changed.
