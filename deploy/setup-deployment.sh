#!/usr/bin/env bash
# Interactive builder for a Docker-based self-hosted JetKVM cloud dashboard.
#
# Produces every file needed to run the stack in this folder:
#   .gitignore            keeps all generated deployment files out of git
#   compose.yaml          full stack: Traefik, cloud API, Postgres, dashboard UI
#   Caddyfile             static file server config for the built dashboard UI
#   .env                  secrets, domains, and OIDC settings (chmod 600)
#
# Requires the kvm repository cloned next to this cloud-api repository
# (both clones in the same parent folder) — the dashboard UI is built
# directly from that sibling checkout.
#
# After a successful run:  cd into this folder and `docker compose up -d`.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
KVM_DIR="$REPO_DIR/../kvm"

SRC_DOCKERFILE="$REPO_DIR/Dockerfile"
SRC_UI_DIR="$KVM_DIR/ui"

OUT_GITIGNORE="$SCRIPT_DIR/.gitignore"
OUT_COMPOSE="$SCRIPT_DIR/compose.yaml"
OUT_CADDYFILE="$SCRIPT_DIR/Caddyfile"
OUT_ENV="$SCRIPT_DIR/.env"
OUT_ANSWERS="$SCRIPT_DIR/setup-deployment.env"

# Persistent answers file state. load_answers_file() sets AUTORUN from the
# file; write_answers_file() preserves it unchanged after a run.
AUTORUN="false"
declare -A _ANSWERS        # populated by each prompt helper during the run
declare -A _FILE_DEFAULTS  # answers-file values, used as prompt defaults

if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
info() { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# Returns true when the script must not attempt interactive prompts.
# A permission test on /dev/tty is not enough: without a controlling
# terminal (cron, CI, setsid) the node is readable but opening it fails,
# so probe with a real open.
_no_tty() { [ "$AUTORUN" = "true" ] || ! { : </dev/tty; } 2>/dev/null; }

on_error() {
    local rc=$?
    printf '\n%serror:%s setup-deployment.sh stopped unexpectedly (exit %s). Review the output above and re-run.\n' \
        "$RED" "$RESET" "$rc" >&2
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Prompt helpers. Every value is resolved through three precedence tiers
# (highest to lowest):
#   1. Environment variable exported by the user before invocation
#      (e.g. JETKVM_SETUP_OIDC=n ./setup-deployment.sh) — used as-is,
#      the prompt is skipped.
#   2. Value from the answers file (_FILE_DEFAULTS). With AUTORUN=true (or
#      no readable TTY) it is used as-is and the prompt is skipped; with
#      AUTORUN=false it only becomes the displayed default of the prompt.
#   3. Interactive prompt / built-in default.
# ---------------------------------------------------------------------------
ask() {
    local prompt="$1" envvar="$2" default="${3:-y}" ans hint
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        case "${!envvar}" in
            [Yy]*|1|true|TRUE) _ANSWERS["$envvar"]="y"; return 0 ;;
            *)                  _ANSWERS["$envvar"]="n"; return 1 ;;
        esac
    fi
    # Answers-file value becomes the default answer (tier 2/3).
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        case "${_FILE_DEFAULTS[$envvar]}" in
            [Yy]*|1|true|TRUE) default="y" ;;
            *)                 default="n" ;;
        esac
    fi
    [ "$default" = y ] && hint="Y/n" || hint="y/N"
    if _no_tty; then
        warn "non-interactive shell; assuming '$default' for: $prompt"
        if [ "$default" = y ]; then
            [ -n "$envvar" ] && _ANSWERS["$envvar"]="y"; return 0
        else
            [ -n "$envvar" ] && _ANSWERS["$envvar"]="n"; return 1
        fi
    fi
    printf '%s%s%s [%s] ' "$BOLD" "$prompt" "$RESET" "$hint" >/dev/tty
    read -r ans </dev/tty || ans=""
    ans="${ans:-$default}"
    case "$ans" in
        [Yy]*) [ -n "$envvar" ] && _ANSWERS["$envvar"]="y"; return 0 ;;
        *)     [ -n "$envvar" ] && _ANSWERS["$envvar"]="n"; return 1 ;;
    esac
}

prompt_value() {
    local outvar="$1" envvar="$2" prompt="$3" default="${4:-}" value=""
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        printf -v "$outvar" '%s' "${!envvar}"
        [ -n "$envvar" ] && _ANSWERS["$envvar"]="${!envvar}"
        return
    fi
    # Answers-file value becomes the bracketed default (tier 2/3).
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        default="${_FILE_DEFAULTS[$envvar]}"
    fi
    if _no_tty; then
        if [ -n "$default" ]; then
            warn "non-interactive shell; using default for: $prompt"
            printf -v "$outvar" '%s' "$default"
            [ -n "$envvar" ] && _ANSWERS["$envvar"]="$default"
            return
        fi
        die "missing required input for: $prompt. Set ${envvar}."
    fi
    while :; do
        if [ -n "$default" ]; then
            printf '%s%s%s [%s]: ' "$BOLD" "$prompt" "$RESET" "$default" >/dev/tty
        else
            printf '%s%s%s: ' "$BOLD" "$prompt" "$RESET" >/dev/tty
        fi
        read -r value </dev/tty || value=""
        value="${value:-$default}"
        if [ -n "$value" ]; then
            printf -v "$outvar" '%s' "$value"
            [ -n "$envvar" ] && _ANSWERS["$envvar"]="$value"
            return
        fi
        printf 'A value is required.\n' >/dev/tty
    done
}

prompt_optional() {
    local outvar="$1" envvar="$2" prompt="$3" default="" value=""
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        printf -v "$outvar" '%s' "${!envvar}"
        [ -n "$envvar" ] && _ANSWERS["$envvar"]="${!envvar}"
        return
    fi
    # Answers-file value becomes the bracketed default (tier 2/3).
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        default="${_FILE_DEFAULTS[$envvar]}"
    fi
    if _no_tty; then
        printf -v "$outvar" '%s' "$default"
        [ -n "$envvar" ] && _ANSWERS["$envvar"]="$default"
        return
    fi
    if [ -n "$default" ]; then
        printf '%s%s%s [%s]: ' "$BOLD" "$prompt" "$RESET" "$default" >/dev/tty
    else
        printf '%s%s%s [leave blank to skip]: ' "$BOLD" "$prompt" "$RESET" >/dev/tty
    fi
    read -r value </dev/tty || value=""
    value="${value:-$default}"
    printf -v "$outvar" '%s' "$value"
    [ -n "$envvar" ] && _ANSWERS["$envvar"]="$value"
}

prompt_choice() {
    # prompt_choice OUTVAR ENVVAR PROMPT DEFAULT CHOICE...
    local outvar="$1" envvar="$2" prompt="$3" default="$4" value choice
    shift 4
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        for choice in "$@"; do
            if [ "${!envvar}" = "$choice" ]; then
                printf -v "$outvar" '%s' "$choice"
                [ -n "$envvar" ] && _ANSWERS["$envvar"]="$choice"
                return
            fi
        done
        die "invalid value '${!envvar}' for ${envvar} (expected one of: $*)"
    fi
    # Answers-file value becomes the default choice (tier 2/3), validated
    # against the choice list so a stale/invalid file value cannot leak in.
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        local _fd_valid=0
        for choice in "$@"; do
            if [ "${_FILE_DEFAULTS[$envvar]}" = "$choice" ]; then
                _fd_valid=1
                break
            fi
        done
        if [ "$_fd_valid" = 1 ]; then
            default="${_FILE_DEFAULTS[$envvar]}"
        else
            warn "ignoring invalid answers-file value '${_FILE_DEFAULTS[$envvar]}' for ${envvar} (expected one of: $*)"
        fi
    fi
    if _no_tty; then
        warn "non-interactive shell; using default '$default' for: $prompt"
        printf -v "$outvar" '%s' "$default"
        [ -n "$envvar" ] && _ANSWERS["$envvar"]="$default"
        return
    fi
    while :; do
        printf '%s%s%s (%s) [%s]: ' "$BOLD" "$prompt" "$RESET" "$(IFS='/'; echo "$*")" "$default" >/dev/tty
        read -r value </dev/tty || value=""
        value="${value:-$default}"
        for choice in "$@"; do
            if [ "$value" = "$choice" ]; then
                printf -v "$outvar" '%s' "$choice"
                [ -n "$envvar" ] && _ANSWERS["$envvar"]="$choice"
                return
            fi
        done
        printf 'Choose one of: %s\n' "$*" >/dev/tty
    done
}

gen_hex() {
    if have openssl; then
        openssl rand -hex 32
    elif have python3; then
        python3 -c "import secrets; print(secrets.token_hex(32))"
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# ---------------------------------------------------------------------------
# Answers file: load prior answers so reruns keep earlier choices, and write
# current answers back after a successful run.
# ---------------------------------------------------------------------------
load_answers_file() {
    if [ ! -f "$OUT_ANSWERS" ]; then
        return
    fi
    local _line _key _value
    while IFS= read -r _line; do
        # Skip comments and blank lines.
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${_line//[[:space:]]/}" ]]  && continue
        [[ "$_line" == *=* ]] || continue
        _key="${_line%%=*}"
        _value="${_line#*=}"
        if [ "$_key" = "AUTORUN" ]; then
            AUTORUN="$_value"
            continue
        fi
        # Only load non-empty values. File values are kept separate from
        # the environment so they act as prompt defaults (precedence 2),
        # never masquerading as user-exported variables (precedence 1).
        if [ -n "$_value" ] && [ -n "$_key" ]; then
            _FILE_DEFAULTS["$_key"]="$_value"
        fi
    done <"$OUT_ANSWERS"
    if [ "$AUTORUN" = "true" ]; then
        info "AUTORUN=true: running non-interactively using $OUT_ANSWERS"
    fi
}

write_answers_file() {
    # Preserve the AUTORUN flag exactly as set by the user — never modify it.
    local _autorun="false"
    if [ -f "$OUT_ANSWERS" ]; then
        local _al
        while IFS= read -r _al; do
            if [[ "$_al" =~ ^AUTORUN=(.*)$ ]]; then
                _autorun="${BASH_REMATCH[1]}"
                break
            fi
        done <"$OUT_ANSWERS"
    fi
    info "Saving answers to $OUT_ANSWERS"
    local _a  # shorthand: print one answer line safely
    _a() { printf '%s=%s\n' "$1" "${_ANSWERS[$1]:-}"; }
    (
        umask 177
        {
        cat <<'HDR'
# JetKVM cloud dashboard deployment answers file.
# Generated and updated by setup-deployment.sh after each successful run.
# Secrets are stored here — keep this file private (chmod 600, never commit).
#
# AUTORUN flag
#   false (default): script prompts interactively; values below are pre-filled defaults.
#   true: fully non-interactive — all required values for enabled sections must be filled
#         in below; a missing required value causes an immediate error naming the variable.
#   Only YOU should change this flag; setup-deployment.sh never modifies it.
#
# Precedence (highest to lowest):
#   1. Exported shell environment variable  (e.g. JETKVM_SETUP_OIDC=n ./setup-deployment.sh)
#   2. Value in this file
#   3. Interactive prompt / built-in default
HDR
        printf 'AUTORUN=%s\n' "$_autorun"
        cat <<'S1'

# ---------------------------------------------------------------------------
# Domains and TLS
# ---------------------------------------------------------------------------
# Public DNS name of the dashboard (e.g. app.example.com)
S1
        _a JETKVM_SETUP_APP_DOMAIN
        printf '%s\n' "# Public DNS name of the cloud API (e.g. api.example.com)"
        _a JETKVM_SETUP_API_DOMAIN
        printf '%s\n' "# Certificate mode.  Values: http-01 | dns-01 | internal  (default: http-01)"
        _a JETKVM_SETUP_TLS_MODE
        printf '%s\n' "# Email address for Let's Encrypt registration  (http-01 / dns-01 only)"
        _a JETKVM_SETUP_ACME_EMAIL
        printf '%s\n' "# Cloudflare DNS API token with Zone:DNS:Edit permission  (dns-01 only)"
        _a CF_DNS_API_TOKEN
        printf '%s\n' "# DNS-01 propagation-check resolvers, comma-separated host:port  (dns-01 only; default 1.1.1.1:53,8.8.8.8:53)"
        _a JETKVM_SETUP_ACME_RESOLVERS
        cat <<'S2'

# ---------------------------------------------------------------------------
# OIDC login provider
# ---------------------------------------------------------------------------
# Configure the OIDC provider now?  Values: y | n  (default: y)
# The cloud API has no local accounts; without OIDC nobody can sign in.
S2
        _a JETKVM_SETUP_OIDC
        printf '%s\n' "# Identity provider.  Values: google | authentik | keycloak  (default: authentik)"
        _a JETKVM_SETUP_OIDC_PROVIDER
        cat <<'S2A'
# --- Authentik path (only when OIDC_PROVIDER=authentik) ---
# Authentik base URL (e.g. https://authentik.example.com)
S2A
        _a JETKVM_SETUP_AUTHENTIK_URL
        printf '%s\n' "# Authentik application slug"
        _a JETKVM_SETUP_AUTHENTIK_SLUG
        cat <<'S2B'
# --- Keycloak path (only when OIDC_PROVIDER=keycloak) ---
# Keycloak base URL (e.g. https://keycloak.example.com)
S2B
        _a JETKVM_SETUP_KEYCLOAK_URL
        printf '%s\n' "# Keycloak realm name"
        _a JETKVM_SETUP_KEYCLOAK_REALM
        cat <<'S2C'
# --- All provider paths ---
# OIDC client ID
S2C
        _a JETKVM_OIDC_CLIENT_ID
        printf '%s\n' "# OIDC client secret (sensitive — file is kept 600)"
        _a JETKVM_OIDC_CLIENT_SECRET
        printf '%s\n' "# OAuth scopes  (default: openid email profile)"
        _a JETKVM_OIDC_SCOPES
        cat <<'S3'

# ---------------------------------------------------------------------------
# Access control and WebRTC (optional)
# ---------------------------------------------------------------------------
# Comma-separated email addresses allowed to sign in (blank allows all)
S3
        _a JETKVM_SETUP_ALLOWED_IDENTITIES
        printf '%s\n' "# Comma-separated STUN/TURN ICE server URIs (blank uses the built-in default)"
        _a JETKVM_SETUP_ICE_SERVERS
        printf '%s\n' "# Configure the Cloudflare TURN service?  Values: y | n  (default: n)"
        _a JETKVM_SETUP_TURN
        printf '%s\n' "# Cloudflare TURN key ID  (TURN only)"
        _a CLOUDFLARE_TURN_ID
        printf '%s\n' "# Cloudflare TURN API token  (TURN only)"
        _a CLOUDFLARE_TURN_TOKEN
        cat <<'S4'

# ---------------------------------------------------------------------------
# Secrets (normally generated automatically — only set these to pre-supply
# an existing value, e.g. to pair with an already-initialised data volume)
# ---------------------------------------------------------------------------
# Postgres password.
# Required in non-interactive (AUTORUN=true) mode when the Docker named
# volume jetkvm-cloud_postgres-data already exists and no .env is present.
# Leave blank to have the script generate a fresh value (or detect it).
S4
        _a POSTGRES_PASSWORD
        } >"$OUT_ANSWERS"
    )
    chmod 600 "$OUT_ANSWERS"
}

check_prereqs() {
    have docker || die "docker is required. Install Docker Engine first: https://docs.docker.com/engine/install/"
    docker compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is required (docker compose version failed)."
    [ -f "$SRC_DOCKERFILE" ] || die "missing $SRC_DOCKERFILE — run this script from a full cloud-api repository clone."
    [ -f "$SRC_UI_DIR/package.json" ] || die "kvm repository not found at $KVM_DIR — clone the kvm repository into the same parent folder as cloud-api (see deployment.md) and re-run."
}

# ---------------------------------------------------------------------------
# The kvm/ui checkout ships some public/ assets as symlinks pointing outside
# ui/, which is the dashboard image's Docker build context, so they arrive
# dangling and the Vite build fails with ENOENT. Replace each with a real
# copy of its target so the context is self-contained. Idempotent.
# ---------------------------------------------------------------------------
materialize_ui_symlinks() {
    local ui_dir="$SRC_UI_DIR" link target
    [ -d "$ui_dir" ] || return 0
    while IFS= read -r -d '' link; do
        if target="$(readlink -f "$link" 2>/dev/null)" && [ -f "$target" ]; then
            info "Materializing symlinked UI asset for the build context: ${link#"$KVM_DIR"/}"
            rm -f "$link"
            cp "$target" "$link"
        else
            warn "Unresolved symlink in UI checkout left as-is (build may fail): $link"
        fi
    done < <(find "$ui_dir" \( -name node_modules -o -name .git \) -prune -o -type l -print0)
}

# ---------------------------------------------------------------------------
# Domains and TLS. Traefik terminates HTTPS for both hostnames; certificates
# come from Let's Encrypt (HTTP-01 or Cloudflare DNS-01) or from Traefik's
# built-in self-signed certificate for internal-only deployments.
# ---------------------------------------------------------------------------
section_domains() {
    prompt_value APP_DOMAIN JETKVM_SETUP_APP_DOMAIN "Dashboard DNS name (e.g. app.example.com)"
    prompt_value API_DOMAIN JETKVM_SETUP_API_DOMAIN "Cloud API DNS name (e.g. api.example.com)"
    [ "$APP_DOMAIN" != "$API_DOMAIN" ] || die "the dashboard and API need two different DNS names."

    ACME_EMAIL=""
    CF_TOKEN=""
    prompt_choice TLS_MODE JETKVM_SETUP_TLS_MODE \
        "Certificate mode: Let's Encrypt HTTP-01, Let's Encrypt Cloudflare DNS-01, or internal self-signed" \
        http-01 http-01 dns-01 internal
    case "$TLS_MODE" in
        http-01)
            info "HTTP-01 requires ports 80 and 443 reachable from the internet and public DNS records for both hostnames."
            prompt_value ACME_EMAIL JETKVM_SETUP_ACME_EMAIL "Email address for Let's Encrypt registration"
            ;;
        dns-01)
            info "DNS-01 issues certificates without inbound port 80; both hostnames must be Cloudflare-managed DNS records."
            prompt_value ACME_EMAIL JETKVM_SETUP_ACME_EMAIL "Email address for Let's Encrypt registration"
            prompt_value CF_TOKEN CF_DNS_API_TOKEN "Cloudflare DNS API token (Zone:DNS:Edit for the domain)"
            info "Traefik checks _acme-challenge TXT propagation before validation; a container's default resolver"
            info "(Docker's 127.0.0.11) cannot see public records, so public resolvers must perform that check."
            prompt_value ACME_RESOLVERS JETKVM_SETUP_ACME_RESOLVERS \
                "DNS propagation-check resolvers (comma-separated host:port)" "1.1.1.1:53,8.8.8.8:53"
            ;;
        internal)
            warn "internal mode serves a self-signed certificate; browsers and the JetKVM device must be told to trust it."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# OIDC login provider. The cloud API authenticates users exclusively through
# OIDC (env vars OIDC_ISSUER / OIDC_CLIENT_ID / OIDC_CLIENT_SECRET /
# OIDC_SCOPES read by src/oidc-config.ts). Each provider path asks only for
# what that provider needs and derives the issuer URL from it.
# ---------------------------------------------------------------------------
section_oidc() {
    OIDC_ISSUER=""
    OIDC_CLIENT_ID=""
    OIDC_CLIENT_SECRET=""
    OIDC_SCOPES="openid email profile"
    if ! ask "Configure the OIDC login provider now?" JETKVM_SETUP_OIDC y; then
        warn "OIDC skipped — the API will start but every sign-in attempt will fail until OIDC_ISSUER, OIDC_CLIENT_ID and OIDC_CLIENT_SECRET are filled in $OUT_ENV."
        return 0
    fi

    local provider
    prompt_choice provider JETKVM_SETUP_OIDC_PROVIDER \
        "Identity provider" authentik google authentik keycloak
    info "Redirect URI to register with the provider: https://$API_DOMAIN/oidc/callback"

    case "$provider" in
        google)
            info "Create an OAuth 2.0 Client ID (type: Web application) in Google Cloud Console → APIs & Services → Credentials,"
            info "add the redirect URI above, then copy the client ID and secret here."
            OIDC_ISSUER="https://accounts.google.com"
            prompt_value OIDC_CLIENT_ID JETKVM_OIDC_CLIENT_ID "Google OAuth client ID"
            prompt_value OIDC_CLIENT_SECRET JETKVM_OIDC_CLIENT_SECRET "Google OAuth client secret"
            ;;
        authentik)
            local ak_base ak_slug
            info "In the authentik admin UI create a confidential OAuth2/OpenID provider with the redirect URI above,"
            info "then create an application bound to it. The application slug forms the issuer URL:"
            info "  <base-url>/application/o/<slug>/"
            prompt_value ak_base JETKVM_SETUP_AUTHENTIK_URL "Authentik base URL (e.g. https://authentik.example.com)"
            ak_base="${ak_base%/}"
            prompt_value ak_slug JETKVM_SETUP_AUTHENTIK_SLUG "Authentik application slug"
            OIDC_ISSUER="$ak_base/application/o/$ak_slug/"
            prompt_value OIDC_CLIENT_ID JETKVM_OIDC_CLIENT_ID "Authentik client ID"
            prompt_value OIDC_CLIENT_SECRET JETKVM_OIDC_CLIENT_SECRET "Authentik client secret"
            info "Authentik's default 'email' and 'profile' scope mappings cover everything the cloud API reads;"
            info "group claims are not required."
            ;;
        keycloak)
            local kc_base kc_realm
            info "In the Keycloak admin console create a confidential OpenID Connect client with the redirect URI above."
            info "The realm forms the issuer URL:  <base-url>/realms/<realm>"
            prompt_value kc_base JETKVM_SETUP_KEYCLOAK_URL "Keycloak base URL (e.g. https://keycloak.example.com)"
            kc_base="${kc_base%/}"
            prompt_value kc_realm JETKVM_SETUP_KEYCLOAK_REALM "Keycloak realm name"
            OIDC_ISSUER="$kc_base/realms/$kc_realm"
            prompt_value OIDC_CLIENT_ID JETKVM_OIDC_CLIENT_ID "Keycloak client ID"
            prompt_value OIDC_CLIENT_SECRET JETKVM_OIDC_CLIENT_SECRET "Keycloak client secret"
            ;;
    esac
    prompt_value OIDC_SCOPES JETKVM_OIDC_SCOPES "OAuth scopes" "openid email profile"
}

# ---------------------------------------------------------------------------
# Access control and WebRTC extras, all optional.
# ---------------------------------------------------------------------------
section_extras() {
    prompt_optional ALLOWED_IDENTITIES JETKVM_SETUP_ALLOWED_IDENTITIES \
        "Email addresses allowed to sign in, comma-separated (blank allows all)"
    prompt_optional ICE_SERVERS JETKVM_SETUP_ICE_SERVERS \
        "ICE (STUN/TURN) server URIs, comma-separated (blank uses the built-in default)"
    TURN_ID=""
    TURN_TOKEN=""
    if ask "Configure the Cloudflare TURN service for WebRTC relay?" JETKVM_SETUP_TURN n; then
        prompt_value TURN_ID CLOUDFLARE_TURN_ID "Cloudflare TURN key ID"
        prompt_value TURN_TOKEN CLOUDFLARE_TURN_TOKEN "Cloudflare TURN API token"
    fi
}

# ---------------------------------------------------------------------------
# File generation. The compose file builds the API image from the repository
# Dockerfile and the dashboard image from the sibling kvm/ui checkout with
# VITE_CLOUD_API pointed at the self-hosted API. Traefik routes both
# hostnames via Docker labels; WebSockets pass through without extra config.
# ---------------------------------------------------------------------------
write_compose() {
    info "Writing $OUT_COMPOSE"

    local resolver_labels="" acme_config="" traefik_env="" acme_mount=""
    # Compose-style ${VAR} placeholders below are expanded by docker compose
    # from the generated .env at runtime, not by this script.
    # shellcheck disable=SC2016
    case "$TLS_MODE" in
        http-01)
            resolver_labels=$'\n      - "traefik.http.routers.__NAME__.tls.certresolver=letsencrypt"'
            acme_mount=$'\n      - ./letsencrypt:/letsencrypt'
            acme_config='      - "--certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"'
            ;;
        dns-01)
            resolver_labels=$'\n      - "traefik.http.routers.__NAME__.tls.certresolver=letsencrypt"'
            acme_mount=$'\n      - ./letsencrypt:/letsencrypt'
            # resolvers=: the propagation pre-check must query public DNS; a
            # container's default resolver (Docker's 127.0.0.11) cannot see the
            # public _acme-challenge record and issuance stalls forever.
            acme_config='      - "--certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare"'
            acme_config+=$'\n'"      - \"--certificatesresolvers.letsencrypt.acme.dnschallenge.resolvers=${ACME_RESOLVERS}\""
            traefik_env='    environment:
      CF_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}'
            ;;
        internal)
            ;;
    esac

    local api_resolver="${resolver_labels//__NAME__/api}"
    local app_resolver="${resolver_labels//__NAME__/app}"

    {
        cat <<EOF
name: jetkvm-cloud

networks:
  jetkvm:
    driver: bridge

services:
  # Traefik must be v3.6+; earlier v3.x images bundle a Docker API client that
  # defaults to API version 1.24 and only negotiates downward, so it cannot
  # talk to modern Docker daemons (Engine 25+, minimum API 1.40) and fails with
  # "client version 1.24 is too old. Minimum supported API version is 1.40".
  traefik:
    image: traefik:v3.7
    restart: unless-stopped
    command:
      - "--log.level=INFO"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
EOF
        if [ -n "$acme_config" ]; then printf '%s\n' "$acme_config"; fi
        if [ -n "$traefik_env" ]; then printf '%s\n' "$traefik_env"; fi
        cat <<EOF
    ports:
      - "80:80"
      - "443:443"
    networks:
      - jetkvm
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro$acme_mount

  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_USER: jetkvm
      POSTGRES_DB: jetkvm
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U jetkvm -d jetkvm"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 5s
    networks:
      - jetkvm
    volumes:
      - postgres-data:/var/lib/postgresql/data

  # Runs database migrations to completion before the API starts.
  api-migrate:
    build: ..
    env_file:
      - .env
    environment:
      DATABASE_URL: postgresql://jetkvm:\${POSTGRES_PASSWORD}@db:5432/jetkvm
    depends_on:
      db:
        condition: service_healthy
    command: ["sh", "-c", "npx prisma migrate deploy"]
    networks:
      - jetkvm
    restart: no

  api:
    build: ..
    restart: unless-stopped
    env_file:
      - .env
    environment:
      PORT: 3000
      DATABASE_URL: postgresql://jetkvm:\${POSTGRES_PASSWORD}@db:5432/jetkvm
    depends_on:
      db:
        condition: service_healthy
      api-migrate:
        condition: service_completed_successfully
    networks:
      - jetkvm
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(\`\${API_DOMAIN}\`)"
      - "traefik.http.routers.api.entrypoints=websecure"
      - "traefik.http.routers.api.tls=true"$api_resolver
      - "traefik.http.services.api.loadbalancer.server.port=3000"

  # Dashboard UI, built from the sibling kvm repository checkout and served
  # as static files with a single-page-application fallback.
  app:
    build:
      context: ../../kvm/ui
      dockerfile_inline: |
        FROM node:22-alpine AS build
        WORKDIR /ui
        COPY package.json package-lock.json ./
        RUN npm ci
        COPY . .
        ARG CLOUD_API
        ENV VITE_CLOUD_API=\$\$CLOUD_API
        RUN npm run build:prod
        FROM caddy:2-alpine
        COPY --from=build /ui/dist /srv
      args:
        CLOUD_API: https://\${API_DOMAIN}
    pull_policy: build
    restart: unless-stopped
    networks:
      - jetkvm
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(\`\${APP_DOMAIN}\`)"
      - "traefik.http.routers.app.entrypoints=websecure"
      - "traefik.http.routers.app.tls=true"$app_resolver
      - "traefik.http.services.app.loadbalancer.server.port=8080"

volumes:
  postgres-data:
    driver: local
EOF
    } >"$OUT_COMPOSE"
}

# ---------------------------------------------------------------------------
# The generated deployment files contain secrets and host-specific data; a
# local .gitignore keeps every one of them (itself included) out of git.
# ---------------------------------------------------------------------------
write_gitignore() {
    info "Writing $OUT_GITIGNORE"
    cat >"$OUT_GITIGNORE" <<'EOF'
# Generated by setup-deployment.sh. These deployment files contain secrets
# and host-specific data — never commit them.
.gitignore
compose.yaml
Caddyfile
.env
setup-deployment.env
letsencrypt/
EOF
}

write_caddyfile() {
    # SPA fallback: unknown paths return index.html so client routing works.
    cat >"$OUT_CADDYFILE" <<'EOF'
:8080 {
	root * /srv
	encode gzip
	try_files {path} /index.html
	file_server
}
EOF
}

write_env_file() {
    info "Generating secrets and writing $OUT_ENV"
    local cookie_secret pg_password existing_cookie="" existing_pg=""

    # Preserve existing secrets from a prior .env so a rerun does not
    # regenerate them and break sessions or an existing Postgres volume.
    if [ -f "$OUT_ENV" ]; then
        existing_cookie="$(grep -m1 '^COOKIE_SECRET=' "$OUT_ENV" | cut -d= -f2-)" || true
        existing_pg="$(grep -m1 '^POSTGRES_PASSWORD=' "$OUT_ENV" | cut -d= -f2-)" || true
    fi

    cookie_secret="${COOKIE_SECRET:-${existing_cookie:-$(gen_hex)}}"

    # Resolve POSTGRES_PASSWORD. When a fresh random value would be generated
    # (no exported variable and no existing .env value), check for a stale
    # Docker named volume that was initialised with a different password —
    # Postgres only applies POSTGRES_PASSWORD on first data-directory init.
    local _pg_source=""
    if [ -n "${POSTGRES_PASSWORD:-}" ]; then
        pg_password="$POSTGRES_PASSWORD"
        _pg_source="env"
    elif [ -n "${_FILE_DEFAULTS[POSTGRES_PASSWORD]:-}" ]; then
        pg_password="${_FILE_DEFAULTS[POSTGRES_PASSWORD]}"
        _ANSWERS[POSTGRES_PASSWORD]="$pg_password"
        _pg_source="file"
    elif [ -n "$existing_pg" ]; then
        pg_password="$existing_pg"
        _pg_source="existing"
    else
        local _pg_vol="${COMPOSE_PROJECT_NAME:-jetkvm-cloud}_postgres-data"
        local _vol_inspect_out
        if _vol_inspect_out="$(docker volume inspect "$_pg_vol" 2>&1)"; then
            # Volume exists — a freshly generated password would not match the
            # one used when the volume was initialised, breaking auth.
            if _no_tty; then
                die "Postgres data volume '$_pg_vol' already exists but no POSTGRES_PASSWORD is \
available. A newly-generated password will not match the one used when the volume \
was initialised, causing 'FATAL: password authentication failed for user \"jetkvm\"'. \
Remedies — choose one and rerun: \
(1) export POSTGRES_PASSWORD=<existing-password> before running the script, \
(2) add POSTGRES_PASSWORD=<existing-password> to $OUT_ANSWERS, or \
(3) remove the stale volume first (destroys all data): docker volume rm $_pg_vol"
            else
                warn "Postgres data volume '$_pg_vol' already exists."
                {
                    printf '\n'
                    printf '  Generating a fresh random POSTGRES_PASSWORD would not match the\n'
                    printf '  password used to initialise the existing data directory, causing:\n'
                    printf '    FATAL: password authentication failed for user "jetkvm"\n'
                    printf '\n'
                    printf '  How to proceed:\n'
                    printf '    enter  — supply the existing POSTGRES_PASSWORD to reuse this volume\n'
                    printf '    wipe   — remove the volume and all its data, generate a new password\n'
                    printf '    abort  — exit; handle this manually\n'
                    printf '\n'
                } >/dev/tty
                local _pg_action
                prompt_choice _pg_action POSTGRES_VOLUME_ACTION \
                    "Action for existing volume '$_pg_vol'" enter \
                    enter wipe abort
                case "$_pg_action" in
                    enter)
                        prompt_value pg_password POSTGRES_PASSWORD \
                            "Existing POSTGRES_PASSWORD (will be stored in $OUT_ENV)"
                        _pg_source="entered"
                        ;;
                    wipe)
                        warn "Volume '$_pg_vol' and ALL its data will be permanently deleted."
                        if ! ask "Confirm deletion of volume '$_pg_vol'?" "" n; then
                            die "Deletion not confirmed. Aborting."
                        fi
                        docker volume rm "$_pg_vol" \
                            || die "Could not remove '$_pg_vol'. Steps to resolve: (1) run 'docker compose down' to stop any containers using the volume, (2) verify Docker daemon permissions, (3) rerun this script."
                        info "Volume '$_pg_vol' removed. A fresh password will be generated."
                        pg_password="$(gen_hex)"
                        _pg_source="generated"
                        ;;
                    abort)
                        die "Aborting. To proceed manually: (1) export POSTGRES_PASSWORD=<existing-password> and rerun, or (2) docker volume rm $_pg_vol to start fresh."
                        ;;
                esac
            fi
        else
            # Distinguish "volume not found" from a real Docker error.
            if echo "$_vol_inspect_out" | grep -qi "no such volume\|not found"; then
                pg_password="$(gen_hex)"
                _pg_source="generated"
            else
                # Unexpected Docker error; warn and proceed with a fresh
                # password. If a stale volume exists this may still cause an
                # auth failure, but the user will see the docker error output.
                warn "Could not query Docker volume '$_pg_vol': $_vol_inspect_out"
                warn "Proceeding with a fresh random password. If '$_pg_vol' exists with a different password, 'docker compose up -d' may fail with an auth error — rerun this script and supply POSTGRES_PASSWORD."
                pg_password="$(gen_hex)"
                _pg_source="generated"
            fi
        fi
    fi

    if [ -n "${COOKIE_SECRET:-}" ]; then
        info "COOKIE_SECRET: using exported environment variable"
    elif [ -n "$existing_cookie" ]; then
        warn "COOKIE_SECRET: preserving existing value from $OUT_ENV (not regenerated)"
    else
        info "COOKIE_SECRET: generated new random value"
    fi
    case "$_pg_source" in
        env)      info "POSTGRES_PASSWORD: using exported environment variable" ;;
        file)     info "POSTGRES_PASSWORD: using value from $OUT_ANSWERS" ;;
        existing) warn "POSTGRES_PASSWORD: preserving existing value from $OUT_ENV (not regenerated)" ;;
        entered)  info "POSTGRES_PASSWORD: using entered existing password (volume reused)" ;;
        *)        info "POSTGRES_PASSWORD: generated new random value" ;;
    esac

    {
        echo "# Generated deployment settings. Keep this file private (contains secrets)."
        echo "APP_DOMAIN=$APP_DOMAIN"
        echo "API_DOMAIN=$API_DOMAIN"
        if [ "$TLS_MODE" != internal ]; then
            echo "ACME_EMAIL=$ACME_EMAIL"
        fi
        if [ "$TLS_MODE" = dns-01 ]; then
            echo "CF_DNS_API_TOKEN=$CF_TOKEN"
        fi
        echo "POSTGRES_PASSWORD=$pg_password"
        echo "COOKIE_SECRET=$cookie_secret"
        echo
        echo "# Values read by the cloud API service (see .env.example in the repo root)."
        echo "API_HOSTNAME=https://$API_DOMAIN"
        echo "APP_HOSTNAME=https://$APP_DOMAIN"
        echo "CORS_ORIGINS=https://$APP_DOMAIN"
        echo "REAL_IP_HEADER=x-real-ip"
        echo "OIDC_ISSUER=$OIDC_ISSUER"
        echo "OIDC_CLIENT_ID=$OIDC_CLIENT_ID"
        echo "OIDC_CLIENT_SECRET=$OIDC_CLIENT_SECRET"
        echo "OIDC_SCOPES=$OIDC_SCOPES"
        echo "ALLOWED_IDENTITIES=$ALLOWED_IDENTITIES"
        echo "ICE_SERVERS=$ICE_SERVERS"
        echo "CLOUDFLARE_TURN_ID=$TURN_ID"
        echo "CLOUDFLARE_TURN_TOKEN=$TURN_TOKEN"
    } >"$OUT_ENV"
    chmod 600 "$OUT_ENV"
}

print_done() {
    info "Setup complete. Deployment files are in: $SCRIPT_DIR"
    echo
    echo "Start the stack:"
    echo "  cd $SCRIPT_DIR"
    echo "  docker compose up -d --build"
    echo
    echo "Dashboard: https://$APP_DOMAIN"
    echo "Cloud API: https://$API_DOMAIN  (health check: https://$API_DOMAIN/healthz)"
    if [ "$TLS_MODE" = internal ]; then
        echo "Certificates are self-signed in internal mode; expect browser trust warnings."
    else
        echo "Ensure DNS records for both hostnames point at this host before starting."
    fi
    echo
    echo "Next: build the JetKVM device software with the cloud URL pointed at"
    echo "https://$API_DOMAIN and deploy it to the device — see deployment.md,"
    echo "section 'Custom JetKVM device build'."
}

main() {
    info "JetKVM cloud dashboard deployment setup"
    echo

    check_prereqs

    # Ensure the sibling kvm/ui checkout is a self-contained Docker build
    # context before generating compose (see materialize_ui_symlinks).
    materialize_ui_symlinks

    # Load the persistent answers file before any prompts so that prior
    # answers serve as defaults and AUTORUN=true skips all interactive input.
    load_answers_file

    # Prompt sections, then file generation. Secrets are generated
    # automatically, so only domains and OIDC details require input.
    section_domains
    section_oidc
    section_extras

    write_gitignore
    write_compose
    write_caddyfile
    write_env_file
    write_answers_file
    print_done
}

main "$@"
