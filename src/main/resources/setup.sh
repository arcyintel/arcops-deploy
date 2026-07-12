#!/usr/bin/env bash
#
# ArcOps MDM Platform — zero-to-production setup script
#
# Bootstraps a clean Ubuntu/Debian host with the current ArcOps stack
# (identity, gateway, back-core, apple-mdm, android-mdm, windows-mdm
# + their Postgres + Caddy + RabbitMQ + Redis + Consul + Mosquitto).
# Does NOT install the licence project — that lives
# separately on its own machine and is gated behind compose profile
# `licence`.
#
# SSL certificates are MANUAL — operators are expected to obtain
# Let's Encrypt (or any) certs beforehand and drop them in the
# expected /etc/letsencrypt/live/<host>/{fullchain,privkey}.pem
# layout. Three hosts need certs:
#   1. $DOMAIN                       — main app
#   2. mdm.$DOMAIN                   — Windows MDM OMA-DM
#   3. enterpriseenrollment.$DOMAIN  — Windows MDM enrollment
#
# Usage:
#   sudo ./setup.sh --domain mdm.acme.com
#   sudo ./setup.sh --domain mdm.acme.com --skip-tls-check  # bootstrap before certs
#   sudo ./setup.sh --help

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────
ARCOPS_DIR=${ARCOPS_DIR:-/opt/arcops}
COMMONS_REPO="https://raw.githubusercontent.com/arcyintel/arcops-deploy/main"
DOMAIN=""
GHCR_ORG=arcyintel
LICENSE_SERVER_URL=""
MANIFEST_URL_OVERRIDE=""   # --manifest-url: read the release manifest straight from here (e.g. the git-committed manifest-stable.json) instead of <license-server>/api/v1/release/manifest
RELEASE_VERSION=""   # --version X.Y.Z pins host files + image tags to that release; empty = resolve from manifest, else bootstrap from 'main'
INSTALL_CHANNEL=stable   # --channel stable (customers, versioned) | edge (test server, tracks :latest + main)
SKIP_TLS_CHECK=false
SKIP_GHCR=false
NON_INTERACTIVE=false
ARCOPS_USER=${ARCOPS_USER:-uconos}
APPLE_REPLICAS=1
ANDROID_REPLICAS=1
WINDOWS_REPLICAS=1
EMM_REPLICAS=1
MIN_RAM_GB=4
MIN_DISK_GB=20

# ── Colors ───────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""
fi
log()   { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*" >&2; }
error() { printf "${RED}[✗]${NC} %s\n" "$*" >&2; }
info()  { printf "${BLUE}[i]${NC} %s\n" "$*"; }
step()  { printf "\n${CYAN}${BOLD}── %s ──${NC}\n" "$*"; }

usage() {
    cat <<EOF
ArcOps MDM Platform — production setup

Usage:  sudo ./setup.sh [OPTIONS]

Required (one of):
  --domain HOST            Primary domain (e.g. mdm.acme.com)
  Interactive prompt       If --domain is not provided

Options:
  --license-server-url URL Origin of the ArcOps licence server this deployment
                           phones home to (e.g. https://licence.acme.com). Enables
                           revocation/upgrade pickup + the offline-grace heartbeat.
                           Leave unset ONLY for air-gapped installs.
  --manifest-url URL       Read the release manifest from this exact URL instead
                           of deriving <license-server>/api/v1/release/manifest.
                           Point it at the git-committed manifest-stable.json to
                           skip the licence-server publish path entirely.
  --version X.Y.Z          Pin the install to a specific ArcOps release (host
                           files + image tags). Omit to resolve the latest
                           stable from the licence-server manifest, falling back
                           to 'main' + :stable if none is reachable. The
                           arcops-updater keeps the box current after install.
  --channel CH             Release channel: 'stable' (default; customers — pinned,
                           manifest-driven) or 'edge' (test/staging server —
                           tracks the moving :latest tag + 'main' host files so
                           you validate a build before promoting it to stable).
  --skip-tls-check         Don't fail if /etc/letsencrypt/live/<host>/ is
                           empty. Use to bootstrap the stack before certs
                           land; Caddy will keep restarting until they do.
  --skip-ghcr              Skip GHCR login prompt (assume already authed).
  --apple-replicas N       active-active count for apple-mdm (default 1).
  --android-replicas N     active-active count for android-mdm (default 1).
  --windows-replicas N     active-active count for windows-mdm (default 1).
  --emm-replicas N         active-active count for emm-mdm / Android Enterprise (default 1).
  --arcops-dir PATH        Install directory (default /opt/arcops).
  -y, --yes                Non-interactive (no confirmation prompts).
  -h, --help               Show this help and exit.

Examples:
  sudo ./setup.sh --domain mdm.acme.com
  sudo ./setup.sh --domain mdm.acme.com --skip-tls-check --yes
  sudo ./setup.sh --domain mdm.acme.com --apple-replicas 2

After running:
  Edit  $ARCOPS_DIR/.env        — review/rotate generated secrets
  Watch $ARCOPS_DIR             — compose lives here
  Logs  docker compose -f $ARCOPS_DIR/docker-compose.yaml logs -f
EOF
}

# ── Argument parsing ────────────────────────────────────────
while [ $# -gt 0 ]; do
    case $1 in
        --domain)            DOMAIN="$2"; shift 2 ;;
        --license-server-url) LICENSE_SERVER_URL="$2"; shift 2 ;;
        --manifest-url)      MANIFEST_URL_OVERRIDE="$2"; shift 2 ;;
        --version)           RELEASE_VERSION="$2"; shift 2 ;;
        --channel)           INSTALL_CHANNEL="$2"; shift 2 ;;
        --skip-tls-check)    SKIP_TLS_CHECK=true; shift ;;
        --skip-ghcr)         SKIP_GHCR=true; shift ;;
        --apple-replicas)    APPLE_REPLICAS="$2"; shift 2 ;;
        --android-replicas)  ANDROID_REPLICAS="$2"; shift 2 ;;
        --windows-replicas)  WINDOWS_REPLICAS="$2"; shift 2 ;;
        --emm-replicas)      EMM_REPLICAS="$2"; shift 2 ;;
        --arcops-dir)        ARCOPS_DIR="$2"; shift 2 ;;
        -y|--yes)            NON_INTERACTIVE=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ── Resolve the release to install ──────────────────────────
# Host files (compose, Caddyfile) AND image tags are pinned to one ArcOps
# release so a fresh box matches the fleet — not whatever happens to be on
# 'main' at install time. Resolution order:
#   1. --version X.Y.Z              (explicit pin)
#   2. licence-server manifest      (.version, if reachable and not 0.0.0)
#   3. fallback: 'main' + :stable   (bootstrap; the updater converges the box)
# ARCOPS_MANIFEST_URL is also where the updater reads the manifest + phones
# home; derived from --license-server-url (no manifest source ⇒ updater idles).
case "$INSTALL_CHANNEL" in
    stable|edge) ;;
    *) error "Unknown --channel: $INSTALL_CHANNEL (use 'stable' or 'edge')"; exit 1 ;;
esac
ARCOPS_MANIFEST_URL=""
if [ -n "$LICENSE_SERVER_URL" ]; then
    ARCOPS_MANIFEST_URL="${LICENSE_SERVER_URL%/}/api/v1/release/manifest"
fi
# --manifest-url overrides the derived endpoint. Use it to read the manifest
# directly from the git-committed manifest-stable.json (no licence-server POST /
# publish-token wiring + no GH→box reachability needed; the manifest's own
# composeUrl/caddyfileUrl point at the version-pinned git raw, and fleet version
# intake still flows via the gateway's X-Installed-Version on /license/check).
if [ -n "$MANIFEST_URL_OVERRIDE" ]; then
    ARCOPS_MANIFEST_URL="$MANIFEST_URL_OVERRIDE"
fi
if [ "$INSTALL_CHANNEL" = edge ]; then
    # Test/staging box: track the moving :latest tag + 'main' host files. No
    # version pinning; the updater (edge mode) converges it on every push.
    # COMMONS_REPO stays at the 'main' default set above.
    IMAGE_TAG="latest"
    INSTALLED_VERSION="edge"
    UPDATE_POLL=120
    UPDATER_TAG="latest"
else
    # Stable (customers): pin to a concrete release. Resolution order:
    #   1. --version X.Y.Z   2. manifest .version (if reachable, not 0.0.0)
    #   3. fallback 'main' + :stable (bootstrap; the updater converges the box)
    if [ -z "$RELEASE_VERSION" ] && [ -n "$ARCOPS_MANIFEST_URL" ]; then
        # Parse .version without a jq dependency (jq may be absent this early).
        mver=$(curl -fsSL --max-time 10 "${ARCOPS_MANIFEST_URL}?channel=stable" 2>/dev/null \
                | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
                | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
        if [ -n "$mver" ] && [ "$mver" != "0.0.0" ]; then RELEASE_VERSION="$mver"; fi
    fi
    if [ -n "$RELEASE_VERSION" ]; then
        COMMONS_REPO="https://raw.githubusercontent.com/arcyintel/arcops-deploy/v${RELEASE_VERSION}"
        IMAGE_TAG="$RELEASE_VERSION"
        INSTALLED_VERSION="$RELEASE_VERSION"
    else
        # COMMONS_REPO stays at the 'main' default set above.
        IMAGE_TAG="stable"
        INSTALLED_VERSION="0.0.0"
    fi
    UPDATE_POLL=3600
    UPDATER_TAG="stable"
fi

# ═══════════════════════════════════════════════════════════════
echo -e "${BOLD}"
cat <<'BANNER'
    _             ___
   / \   _ __ ___|  _ \ _ __  ___
  / _ \ | '__/ __| | | | '_ \/ __|
 / ___ \| | | (__| |_| | |_) \__ \
/_/   \_\_|  \___|____/| .__/|___/
                       |_|

  Mobile Device Management Platform
BANNER
echo -e "${NC}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════
step "1/9 — System Requirements"
# ═══════════════════════════════════════════════════════════════

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root or with sudo"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    error "Unsupported OS — requires Linux"
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
log "OS: $PRETTY_NAME"

ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
ram_gb=$((ram_kb / 1024 / 1024))
if [ "$ram_gb" -lt "$MIN_RAM_GB" ]; then
    error "Insufficient RAM: ${ram_gb}GB (minimum ${MIN_RAM_GB}GB)"
    exit 1
fi
log "RAM: ${ram_gb}GB"

disk_gb=$(df / --output=avail -BG | tail -1 | tr -d 'G ')
if [ "$disk_gb" -lt "$MIN_DISK_GB" ]; then
    error "Insufficient disk: ${disk_gb}GB available (minimum ${MIN_DISK_GB}GB)"
    exit 1
fi
log "Disk: ${disk_gb}GB available on /"

# ═══════════════════════════════════════════════════════════════
step "2/9 — Docker"
# ═══════════════════════════════════════════════════════════════

if ! command -v docker >/dev/null 2>&1; then
    info "Docker not found — installing via get.docker.com"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    log "Docker installed"
else
    log "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
fi

if ! docker compose version >/dev/null 2>&1; then
    info "Installing docker-compose-plugin"
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin
fi
log "Compose: $(docker compose version --short)"

# Pre-flight: ensure curl + openssl present for secret generation +
# file fetches.
for tool in curl openssl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        info "Installing $tool"
        apt-get install -y -qq "$tool"
    fi
done

# ═══════════════════════════════════════════════════════════════
step "3/9 — Domain"
# ═══════════════════════════════════════════════════════════════

if [ -z "$DOMAIN" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        error "--domain required in non-interactive mode"
        exit 1
    fi
    read -rp "${CYAN}Primary domain (e.g. mdm.acme.com): ${NC}" DOMAIN
fi
if [ -z "$DOMAIN" ]; then
    error "Domain is required"
    exit 1
fi
log "Primary domain: $DOMAIN"
log "Windows MDM hosts (DNS A → this server):"
log "  mdm.$DOMAIN"
log "  enterpriseenrollment.$DOMAIN"

# ═══════════════════════════════════════════════════════════════
step "4/9 — SSL Certificates (manual)"
# ═══════════════════════════════════════════════════════════════

cert_root=/etc/letsencrypt/live
required_hosts=("$DOMAIN" "mdm.$DOMAIN")
# enterpriseenrollment shares the mdm cert as a SAN (single-cert
# multi-host issuance), so we only validate the two distinct cert
# directories.

missing_certs=()
for h in "${required_hosts[@]}"; do
    fp="$cert_root/$h/fullchain.pem"
    kp="$cert_root/$h/privkey.pem"
    if [ -r "$fp" ] && [ -r "$kp" ]; then
        log "$h — cert + key present"
    else
        missing_certs+=("$h")
    fi
done

if [ ${#missing_certs[@]} -gt 0 ]; then
    warn "Missing certificates for: ${missing_certs[*]}"
    info "Obtain them manually before Caddy can start, e.g.:"
    info "  sudo apt install -y certbot"
    info "  sudo certbot certonly --manual --preferred-challenges dns \\"
    info "    -d $DOMAIN -d mdm.$DOMAIN -d enterpriseenrollment.$DOMAIN"
    info "Files must land at:"
    for h in "${missing_certs[@]}"; do
        info "  $cert_root/$h/fullchain.pem"
        info "  $cert_root/$h/privkey.pem"
    done
    if [ "$SKIP_TLS_CHECK" = true ]; then
        warn "Continuing anyway (--skip-tls-check). Caddy will crash-loop until certs land."
    else
        error "Re-run with --skip-tls-check to bootstrap the stack before certs land,"
        error "or run certbot first and then re-run this script."
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════
step "5/9 — Directory layout"
# ═══════════════════════════════════════════════════════════════

mkdir -p "$ARCOPS_DIR"/{config,certs,data,mosquitto,mosquitto/secrets,keys,scripts}
cd "$ARCOPS_DIR"
log "Layout: $ARCOPS_DIR/{config,certs,data,mosquitto,mosquitto/secrets,keys,scripts}"

# ═══════════════════════════════════════════════════════════════
step "6/9 — Secrets + .env"
# ═══════════════════════════════════════════════════════════════

gen_password()  { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }
gen_hex()       { openssl rand -hex 32; }
gen_base64_32() { openssl rand -base64 32; }
# The Super Admin bootstrap password ALSO has to pass identity's PasswordPolicy
# (PasswordValidationService: upper + lower + digit + special when
# password_require_special is on). gen_password is alphanumeric only, so it can
# lack a symbol (always) and a digit (~1.5% of draws) → the initial-admin seed
# would be rejected. Append "@1" to guarantee a symbol + digit for any draw.
gen_admin_password() { printf '%s@1' "$(gen_password)"; }

# Detect the docker group on the host so the identity container can
# read /var/run/docker.sock through group_add (mode 660 + group docker).
docker_gid=$(getent group docker 2>/dev/null | cut -d: -f3 || true)
if [ -z "$docker_gid" ]; then
    warn "No 'docker' group on host — DockerStatsService will not see per-container stats"
    docker_gid=999  # safe fallback; container will log "Permission denied" until fixed
fi

if [ -f "$ARCOPS_DIR/.env" ]; then
    warn "$ARCOPS_DIR/.env already exists — preserving (rename it if you want secrets re-generated)"
else
    db_password=$(gen_password)
    rabbitmq_password=$(gen_password)
    server_secret=$(gen_password)
    mdm_ca_master_key=$(gen_base64_32)
    mdm_gateway_secret=$(gen_hex)
    # Per-install HMAC secret for the signed managed-file download token
    # (FILE_DISTRIBUTION). back_core mints + verifies; never leaves back_core.
    # Random per install so no two deployments share a forgeable signing key.
    files_download_token_secret=$(gen_base64_32)
    # Shared MQTT broker principal password for the mosquitto go-auth `files`
    # backend. Hashed (PBKDF2) into mosquitto/secrets/passwords.txt at startup
    # (step 9) as the `arcops-backend` principal — the shared identity every
    # backend service uses AND that /auth hands to the apple/android agents.
    # The auth-enabled broker rejects anonymous CONNECT, so this must be
    # generated + hashed or the whole fleet fails to connect.
    mqtt_password=$(gen_password)
    # Android Enterprise connector creds are NO LONGER generated here. emm-mdm
    # SELF-BOOTSTRAPS them from its licence (POST /api/v1/aeg/bootstrap → AEG mints
    # the token + webhook secret, persisted to config/aeg-connector.properties). A
    # random token written here would actually DEADLOCK the bootstrap: the connector
    # would see a non-empty AEG_API_TOKEN env, assume it is provisioned, and never
    # mint — yet AEG would reject it (it never minted that value). So leave both blank.
    # (Set them in .env only to pre-provision a token out of band — that overrides.)
    # Unique per-install Super Admin bootstrap password — replaces the baked-in
    # init.json default so no two deployments share admin credentials. The
    # operator is forced to change it on first login.
    initial_admin_password=$(gen_admin_password)
    initial_admin_email="${ARCOPS_INITIAL_ADMIN_EMAIL:-admin@${DOMAIN}}"

    cat > "$ARCOPS_DIR/.env" <<ENVFILE
# ── ArcOps configuration ─────────────────────────────────────
# Generated by setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# This file holds secrets — never commit it to git.

# Primary domain. Used by Caddy as the main vhost and by
# back-end services for absolute URL composition (CORS, link
# generation, etc.).
DOMAIN=$DOMAIN

# Windows MDM public hostname (used in OMA-DM provisioning XML
# and the MDM DiscoveryService SOAP response).
MDM_PUBLIC_HOST=https://mdm.$DOMAIN

# GHCR org we pull images from.
GHCR_ORG=$GHCR_ORG

# ── Licence server phone-home ────────────────────────────────
# Origin of the ArcOps licence server this deployment validates against.
# The gateway calls it hourly to pick up revocation/upgrades and to refresh
# the offline-grace heartbeat. EMPTY = no phone-home (air-gapped only) —
# online deployments MUST set this or revocation won't reach them and an
# online licence will self-degrade once its offline-grace window elapses.
ARCOPS_LICENSE_SERVER_URL=$LICENSE_SERVER_URL

# ── Database ─────────────────────────────────────────────────
DB_NAME=molsec_uconos
DB_USERNAME=postgres
DB_PASSWORD=$db_password

# ── RabbitMQ ─────────────────────────────────────────────────
RABBITMQ_USER=admin
RABBITMQ_PASSWORD=$rabbitmq_password

# ── MQTT broker auth (mosquitto go-auth \`files\` backend) ─────
# Shared principal every backend service uses (their MqttConfig only sends
# creds when the username is non-blank) AND that /auth hands to the
# apple/android agents. The matching PBKDF2 hash is provisioned into
# mosquitto/secrets/passwords.txt on first start. The auth-enabled broker
# rejects anonymous CONNECT, so BOTH must be present or the fleet drops off.
MQTT_USERNAME=arcops-backend
MQTT_PASSWORD=$mqtt_password

# ── Identity (OAuth2 + JWT) ──────────────────────────────────
SERVER_SECRET=$server_secret
JWK_SET_URI=http://identity:8080/oauth2/jwks

# First-boot Super Admin. Seeded once on first start; you MUST change this
# password at first login (the login flow forces it). Log in with username
# "SuperAdmin" OR this email. Changing the password later does NOT update this
# file — it's only the bootstrap secret.
ARCOPS_INITIAL_ADMIN_EMAIL=$initial_admin_email
ARCOPS_INITIAL_ADMIN_PASSWORD=$initial_admin_password

# ── Windows MDM (required by windows-mdm service) ────────────
# MDM_CA_MASTER_KEY encrypts the root CA private key at rest.
# Rotating it invalidates every device's enrolment cert —
# never rotate without rolling the whole fleet.
MDM_CA_MASTER_KEY=$mdm_ca_master_key
# Shared secret Caddy sends on /dm/** so windows-mdm trusts
# the X-Client-Cert-Thumbprint header. Caddy reads this from
# the same .env, so the two stay in sync.
MDM_GATEWAY_SECRET=$mdm_gateway_secret

# ── File distribution (FILE_DISTRIBUTION) ────────────────────
# HMAC secret back_core uses to sign the short-lived, device-bound
# managed-file download token verified on the NON_JWT /agent-binary
# path. back_core both mints and verifies — the secret never leaves it.
# Empty ⇒ token signing disabled (legacy unguessable-UUID capability).
ARCOPS_FILES_DOWNLOAD_TOKEN_SECRET=$files_download_token_secret

# ── Android Enterprise (emm-mdm → central AEG broker) ────────
# emm-mdm runs here like the other MDM services. The AMAPI broker (AEG) is the
# vendor's central instance; the compose defaults AEG_BASE_URL to its domain, so
# leaving it blank here uses that default (override only for a non-default AEG).
# AEG_API_TOKEN/AEG_WEBHOOK_SECRET are intentionally BLANK: emm-mdm self-bootstraps
# them from its licence (a random value here would deadlock the bootstrap — see the
# secret-gen section). Set them only to pre-provision a token out of band.
AEG_BASE_URL=
AEG_API_TOKEN=
AEG_WEBHOOK_SECRET=

# ── Docker socket access for admin Resources page ────────────
# Identity reads /var/run/docker.sock through its docker group
# membership. group_add in compose injects this gid as a
# supplementary group on the in-container appuser.
DOCKER_GID=$docker_gid

# ── Replica counts (active-active) ───────────────────────────
APPLE_MDM_REPLICAS=$APPLE_REPLICAS
ANDROID_MDM_REPLICAS=$ANDROID_REPLICAS
WINDOWS_MDM_REPLICAS=$WINDOWS_REPLICAS
EMM_MDM_REPLICAS=$EMM_REPLICAS

# ── Image tags ───────────────────────────────────────────────
# Pinned to the installed ArcOps release. arcops-updater rewrites these (and
# INSTALLED_VERSION) on every applied update — do not hand-edit unless pinning.
GATEWAY_TAG=$IMAGE_TAG
BACK_CORE_TAG=$IMAGE_TAG
IDENTITY_TAG=$IMAGE_TAG
APPLE_MDM_TAG=$IMAGE_TAG
ANDROID_MDM_TAG=$IMAGE_TAG
WINDOWS_MDM_TAG=$IMAGE_TAG
EMM_MDM_TAG=$IMAGE_TAG
FRONTEND_TAG=$IMAGE_TAG

# ── Release / auto-update (arcops-updater) ───────────────────
# What this box is running. The updater compares it to the release manifest and
# only acts when the manifest is newer; it rewrites this on every applied
# update. Single source of truth for "what version is this box on".
INSTALLED_VERSION=$INSTALLED_VERSION
# Channel: "stable" (customers, versioned/manifest) or "edge" (test server,
# tracks :latest + main). How it reaches the manifest (and phones home) below.
# Empty MANIFEST_URL ⇒ updater idles (air-gapped: run arcops-update.sh --bundle).
ARCOPS_CHANNEL=$INSTALL_CHANNEL
ARCOPS_MANIFEST_URL=$ARCOPS_MANIFEST_URL
# Updater image tag, poll cadence (seconds), and master switch. AUTO=false makes
# the updater idle so an operator drives arcops-update.sh by hand.
ARCOPS_UPDATER_TAG=$UPDATER_TAG
ARCOPS_UPDATE_POLL_INTERVAL=$UPDATE_POLL
ARCOPS_AUTO_UPDATE=true
# Edge-channel knobs (used only when ARCOPS_CHANNEL=edge). Empty CADDYFILE_URL
# ⇒ edge won't overwrite this box's Caddyfile (may be a licence variant).
ARCOPS_EDGE_TAG=latest
ARCOPS_EDGE_BASE_URL=https://raw.githubusercontent.com/arcyintel/arcops-deploy/main
ARCOPS_EDGE_CADDYFILE_URL=
ENVFILE

    chmod 600 "$ARCOPS_DIR/.env"
    log ".env generated (chmod 600)"
fi

# ═══════════════════════════════════════════════════════════════
step "7/9 — Configuration files"
# ═══════════════════════════════════════════════════════════════

# Mosquitto — minimal anonymous-allowed broker for MQTT-over-TCP +
# WebSocket. iegomez/mosquitto-go-auth plugin is baked into the
# custom image we pull but stays unloaded until allow_anonymous is
# flipped to false in this conf (a separate sprint).
cat > "$ARCOPS_DIR/mosquitto/mosquitto.conf" <<'MQTT'
listener 1883
listener 9001
protocol websockets

allow_anonymous true

persistence true
persistence_location /mosquitto/data/
log_dest stdout

max_keepalive 120
MQTT
log "mosquitto.conf"

# Host files are fetched from the resolved release ref (a vX.Y.Z tag when
# pinned, else 'main'); image tags + INSTALLED_VERSION in .env match it.
info "Release source: ${COMMONS_REPO##*/commons/}  (images :$IMAGE_TAG, INSTALLED_VERSION=$INSTALLED_VERSION)"

# Caddyfile — fetch the licence-free variant from commons.
info "Fetching Caddyfile (no-licence variant)"
curl -fsSL "$COMMONS_REPO/Caddyfile.no-licence" -o "$ARCOPS_DIR/Caddyfile"
log "Caddyfile"

# docker-compose.yaml — fetch from commons. The file uses compose
# profile `licence` to gate licence-server + postgres-licence; we
# don't activate that profile so they don't get pulled or started.
info "Fetching docker-compose.yaml"
curl -fsSL "$COMMONS_REPO/src/main/resources/docker-compose-production.yaml" \
    -o "$ARCOPS_DIR/docker-compose.yaml"
log "docker-compose.yaml"

# ═══════════════════════════════════════════════════════════════
step "8/9 — GHCR authentication"
# ═══════════════════════════════════════════════════════════════

if [ "$SKIP_GHCR" = true ]; then
    log "Skipping GHCR login (--skip-ghcr)"
elif [ -f "$HOME/.docker/config.json" ] && grep -q "ghcr.io" "$HOME/.docker/config.json" 2>/dev/null; then
    log "GHCR auth already configured"
elif [ "$NON_INTERACTIVE" = true ]; then
    warn "Skipping GHCR prompt (non-interactive). Authenticate manually before next pull:"
    warn "  echo \$PAT | docker login ghcr.io -u <user> --password-stdin"
else
    info "Need GitHub Personal Access Token with read:packages scope"
    read -rp "${CYAN}GitHub username: ${NC}" gh_user
    read -rsp "${CYAN}GitHub PAT: ${NC}" gh_pat
    printf "\n"
    echo "$gh_pat" | docker login ghcr.io -u "$gh_user" --password-stdin
    log "GHCR authenticated"
fi

# ═══════════════════════════════════════════════════════════════
step "9/9 — Start ArcOps"
# ═══════════════════════════════════════════════════════════════

cd "$ARCOPS_DIR"

info "Pulling images (without licence profile)"
docker compose pull 2>&1 | tail -5 || true

# ── Provision mosquitto go-auth passwords.txt (files backend) ─
# The auth-enabled broker (allow_anonymous false) authenticates the shared
# `arcops-backend` principal via the `files` backend reading this PBKDF2 hash.
# Generated from MQTT_PASSWORD (.env) with the `pw` tool baked into the broker
# image. WITHOUT it, once the auth config is active mosquitto fatals on boot
# ("couldn't open passwords file") and every service + agent drops off. The
# broker ships anonymous by default and flips to auth via the updater/runbook,
# so a pw failure here degrades to an anonymous broker (still works) with a
# warning rather than a hard install failure. Idempotent: kept if present.
mqtt_secrets_dir="$ARCOPS_DIR/mosquitto/secrets"
mqtt_pw_file="$mqtt_secrets_dir/passwords.txt"
if [ -f "$mqtt_pw_file" ]; then
    log "mosquitto passwords.txt already present — kept"
else
    mqtt_pw=$(grep '^MQTT_PASSWORD=' "$ARCOPS_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "$mqtt_pw" ]; then
        mkdir -p "$mqtt_secrets_dir"
        mqtt_img="ghcr.io/${GHCR_ORG}/mosquitto-with-go-auth:2"
        mqtt_hash=$(docker run --rm --entrypoint /mosquitto/pw "$mqtt_img" -p "$mqtt_pw" 2>/dev/null | tail -n1 || true)
        if printf '%s' "$mqtt_hash" | grep -q '^PBKDF2\$'; then
            printf 'arcops-backend:%s\n' "$mqtt_hash" > "$mqtt_pw_file"
            chown -R 1000:1000 "$mqtt_secrets_dir" 2>/dev/null || true
            chmod 600 "$mqtt_pw_file"
            log "mosquitto passwords.txt provisioned (arcops-backend)"
        else
            warn "Could not hash MQTT password via the broker image's pw tool —"
            warn "broker stays anonymous until you provision $mqtt_pw_file"
            warn "(see DEPLOYMENT.md) and restart mosquitto."
        fi
    fi
fi

info "Starting infrastructure (postgres, rabbitmq, redis, consul, mosquitto)"
docker compose up -d \
    postgres-back-core postgres-apple-mdm postgres-identity \
    postgres-android-mdm postgres-windows-mdm \
    rabbitmq consul redis mosquitto

info "Waiting for infrastructure to settle (~15s)"
sleep 15

info "Starting application services"
docker compose up -d

info "Fixing volume permissions on first boot"
sleep 5
# Apple/Android/Windows MDM volumes need write access for appuser
# (uid 999) — Docker named volumes start as root-owned. /app/signed-scripts is
# the windows-mdm HOST bind (./scripts) for UI-authored .ps1 bodies; chowning the
# bind target inside the container also chowns the host source (shared inode) so
# appuser can persist scripts. Harmlessly no-ops on apple/android (dir absent).
for svc in $(docker compose ps --format '{{.Name}}' | grep -E 'apple-mdm|android-mdm|windows-mdm'); do
    docker exec -u 0 "$svc" sh -c 'chown -R 999:999 /app/apps /app/certs /app/releases /app/signed-scripts 2>/dev/null || true' 2>/dev/null || true
done
# config/ is a HOST bind-mount (./config) shared by the gateway + every MDM
# service: the gateway (appuser uid 999) writes config/license.dat there on
# license apply, and each service writes the .lastvalidated heartbeat. The host
# dir starts root-owned → the non-root containers (999) can't write → license
# apply fails with "config/license.dat" and the licence never propagates. chown
# it to 999 so all services can read+write. (apps/certs/releases above are
# per-service named volumes, handled in-container; config is a shared bind-mount.)
chown -R 999:999 "$ARCOPS_DIR/config" 2>/dev/null || true
log "Volume permissions normalised"

# ═══════════════════════════════════════════════════════════════
# Health check + summary
# ═══════════════════════════════════════════════════════════════

step "Health check"
services=("gateway:8084" "back-core:8086" "identity:8080" "apple-mdm:8085" "android-mdm:8088" "windows-mdm:8089" "emm-mdm:8087")
max_wait=240
elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
    all_healthy=true
    for svc in "${services[@]}"; do
        name="${svc%%:*}"
        if ! docker compose ps "$name" 2>/dev/null | grep -q "healthy"; then
            all_healthy=false
            break
        fi
    done
    if $all_healthy; then break; fi
    sleep 10
    elapsed=$((elapsed + 10))
    printf "  waiting %ss / %ss\r" "$elapsed" "$max_wait"
done
printf "\n"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || docker compose ps
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e "${GREEN}${BOLD}ArcOps is up.${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC}  https://$DOMAIN"
echo -e "  ${BOLD}Admin:${NC}      https://$DOMAIN/admin"
echo -e "  ${BOLD}Win MDM:${NC}    https://mdm.$DOMAIN  /  https://enterpriseenrollment.$DOMAIN"
echo ""
echo -e "  ${BOLD}Config:${NC}     $ARCOPS_DIR/.env"
echo -e "  ${BOLD}Logs:${NC}       docker compose -f $ARCOPS_DIR/docker-compose.yaml logs -f"
echo ""
if [ ${#missing_certs[@]} -gt 0 ]; then
    warn "Caddy is restart-looping until you drop certs at:"
    for h in "${missing_certs[@]}"; do
        echo "    $cert_root/$h/{fullchain,privkey}.pem"
    done
fi
arcops_admin_email=$(grep '^ARCOPS_INITIAL_ADMIN_EMAIL=' "$ARCOPS_DIR/.env" | cut -d= -f2-)
arcops_admin_password=$(grep '^ARCOPS_INITIAL_ADMIN_PASSWORD=' "$ARCOPS_DIR/.env" | cut -d= -f2-)
echo -e "  ${BOLD}Super Admin (first login — password change is forced):${NC}"
echo -e "    Username: SuperAdmin   (or email: $arcops_admin_email)"
echo -e "    Password: $arcops_admin_password"
echo -e "    ${YELLOW}Stored in $ARCOPS_DIR/.env — change it at first login.${NC}"
echo ""
