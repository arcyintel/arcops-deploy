#!/usr/bin/env bash
#
# ArcOps Android Enterprise Gateway (AEG) — zero-to-production setup script
#
# Bootstraps a DEDICATED machine to run ONLY the AEG stack
# (android-enterprise-gateway + its Postgres + Caddy). This is the third
# deployment split: the MDM platform runs on its own machine (setup.sh), the
# licence server on another (setup-licence.sh), and AEG here. There is exactly
# ONE AEG for the whole fleet — it holds the single Google Cloud service-account
# that talks to the Android Management API, and every customer's emm-mdm
# connects to it over https.
#
# Critical input: the GCP service-account JSON key (AMAPI + Pub/Sub). The
# operator must provide it; this script validates + installs it but never
# generates it. It is mounted read-only into the container and is NEVER baked
# into the image or committed.
#
# SSL certificates are MANUAL — operator obtains them with certbot (DNS-01 or
# HTTP-01) and drops them in /etc/letsencrypt/live/<aeg-domain>/.
#
# Usage:
#   sudo ./setup-aeg.sh --domain aeg.acme.com \
#       --gcp-key /path/to/service-account.json
#   sudo ./setup-aeg.sh --help

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────
AEG_DIR=${AEG_DIR:-/opt/arcops-aeg}
COMMONS_REPO="https://raw.githubusercontent.com/arcyintel/arcops-deploy/main"
INSTALL_CHANNEL=stable   # --channel stable (prod, tracks :stable) | edge (test, tracks :latest)
AEG_DOMAIN=""
GCP_KEY_PATH=""
GHCR_ORG=arcyintel
SKIP_TLS_CHECK=false
SKIP_GHCR=false
NON_INTERACTIVE=false
MIN_RAM_GB=2
MIN_DISK_GB=10

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
ArcOps Android Enterprise Gateway — standalone production setup

Usage:  sudo ./setup-aeg.sh [OPTIONS]

Required:
  --domain HOST            Public domain for the AEG broker
                           (e.g. aeg.acme.com). emm-mdm instances + Google's
                           managed-Play sign-up callback reach AEG here.
  --gcp-key PATH           Path to the Google Cloud service-account JSON key
                           used for all AMAPI + Pub/Sub traffic. Copied to
                           $AEG_DIR/gcp/service-account.json on first run;
                           subsequent runs detect the existing key.

Options:
  --channel CH             Release channel: 'stable' (default; prod — tracks the
                           :stable AEG image, auto-updates via arcops-updater)
                           or 'edge' (test box — tracks :latest). NOTE: stable
                           needs promote.yml to have created :stable first.
  --skip-tls-check         Bootstrap before /etc/letsencrypt/live/<domain>/ has
                           the cert+key files (Caddy will crash-loop until they
                           land).
  --skip-ghcr              Skip GHCR login prompt.
  --aeg-dir PATH           Install directory (default /opt/arcops-aeg).
  -y, --yes                Non-interactive.
  -h, --help               Show this help.

Examples:
  # First run
  sudo ./setup-aeg.sh --domain aeg.acme.com \\
      --gcp-key ~/aeg-service-account.json

  # Bootstrap before certs (Caddy will wait)
  sudo ./setup-aeg.sh --domain aeg.acme.com \\
      --gcp-key ~/aeg-service-account.json --skip-tls-check

After running:
  Edit  $AEG_DIR/.env             — review/rotate generated secrets
  Logs  docker compose -f $AEG_DIR/docker-compose.yaml logs -f
EOF
}

# ── Argument parsing ────────────────────────────────────────
while [ $# -gt 0 ]; do
    case $1 in
        --domain)            AEG_DOMAIN="$2"; shift 2 ;;
        --gcp-key)           GCP_KEY_PATH="$2"; shift 2 ;;
        --channel)           INSTALL_CHANNEL="$2"; shift 2 ;;
        --skip-tls-check)    SKIP_TLS_CHECK=true; shift ;;
        --skip-ghcr)         SKIP_GHCR=true; shift ;;
        --aeg-dir)           AEG_DIR="$2"; shift 2 ;;
        -y|--yes)            NON_INTERACTIVE=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ── Resolve channel → image tags + updater cadence ──────────
case "$INSTALL_CHANNEL" in
    stable) AEG_TAG=stable; UPDATER_TAG=stable; UPDATE_POLL=3600 ;;
    edge)   AEG_TAG=latest; UPDATER_TAG=latest; UPDATE_POLL=120 ;;
    *)      error "Unknown --channel: $INSTALL_CHANNEL (use 'stable' or 'edge')"; exit 1 ;;
esac

# ═══════════════════════════════════════════════════════════════
echo -e "${BOLD}"
cat <<'BANNER'
    _             ___              _    _____ ____
   / \   _ __ ___|  _ \ ___ ___   / \  | ____/ ___|
  / _ \ | '__/ __| | | / _ \ / _ \ / _ \ |  _|| |  _
 / ___ \| | | (__| |_| | (_) | (_) / ___ \| |__| |_| |
/_/   \_\_|  \___|____/ \___/ \___/_/   \_\_____\____|

  Android Enterprise Gateway (AMAPI broker)
BANNER
echo -e "${NC}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════
step "1/8 — System requirements"
# ═══════════════════════════════════════════════════════════════

if [ "$EUID" -ne 0 ]; then
    error "Run as root or with sudo"
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
    error "Insufficient RAM: ${ram_gb}GB (min ${MIN_RAM_GB}GB)"
    exit 1
fi
log "RAM: ${ram_gb}GB"

disk_gb=$(df / --output=avail -BG | tail -1 | tr -d 'G ')
if [ "$disk_gb" -lt "$MIN_DISK_GB" ]; then
    error "Insufficient disk: ${disk_gb}GB (min ${MIN_DISK_GB}GB)"
    exit 1
fi
log "Disk: ${disk_gb}GB available"

# ═══════════════════════════════════════════════════════════════
step "2/8 — Docker"
# ═══════════════════════════════════════════════════════════════

if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi
log "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"

if ! docker compose version >/dev/null 2>&1; then
    info "Installing docker-compose-plugin"
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin
fi
log "Compose: $(docker compose version --short)"

for tool in curl openssl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        info "Installing $tool"
        apt-get install -y -qq "$tool"
    fi
done

# ═══════════════════════════════════════════════════════════════
step "3/8 — Domain + GCP service-account key"
# ═══════════════════════════════════════════════════════════════

if [ -z "$AEG_DOMAIN" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        error "--domain required in non-interactive mode"
        exit 1
    fi
    read -rp "${CYAN}AEG domain (e.g. aeg.acme.com): ${NC}" AEG_DOMAIN
fi
[ -n "$AEG_DOMAIN" ] || { error "Domain is required"; exit 1; }
log "AEG domain: $AEG_DOMAIN"

# Validate + install the GCP service-account key. We never generate it.
mkdir -p "$AEG_DIR/gcp"
key_dest="$AEG_DIR/gcp/service-account.json"

if [ -r "$key_dest" ]; then
    # Readable by the in-container app user (uid is auto-assigned); 0644 on a
    # dedicated single-purpose box is the uid-agnostic safe choice.
    chmod 644 "$key_dest"
    gcp_project=$(jq -r '.project_id // empty' "$key_dest" 2>/dev/null || true)
    [ -n "$gcp_project" ] || { error "Existing $key_dest is not a valid service-account JSON (no project_id)"; exit 1; }
    log "Existing GCP key at $key_dest — kept (project: $gcp_project)"
elif [ -z "$GCP_KEY_PATH" ]; then
    error "No GCP key found at $key_dest and --gcp-key not provided"
    error "Create a service-account in the AMAPI GCP project with the"
    error "androidmanagement.* + pubsub roles, download its JSON key, then re-run:"
    error "  sudo ./setup-aeg.sh --domain $AEG_DOMAIN --gcp-key /path/to/service-account.json"
    exit 1
elif [ ! -r "$GCP_KEY_PATH" ]; then
    error "Cannot read GCP key: $GCP_KEY_PATH"
    exit 1
else
    # Validate it's a real service-account JSON before copying.
    if ! jq -e '.type == "service_account" and .project_id and .private_key and .client_email' \
            "$GCP_KEY_PATH" >/dev/null 2>&1; then
        error "Not a valid GCP service-account JSON (need type=service_account + project_id + private_key + client_email): $GCP_KEY_PATH"
        exit 1
    fi
    gcp_project=$(jq -r '.project_id' "$GCP_KEY_PATH")
    cp "$GCP_KEY_PATH" "$key_dest"
    chmod 644 "$key_dest"
    log "GCP service-account key installed (project: $gcp_project)"
    warn "Store a BACKUP of the service-account key OUTSIDE this server."
fi

# ═══════════════════════════════════════════════════════════════
step "4/8 — SSL certificates"
# ═══════════════════════════════════════════════════════════════

fp=/etc/letsencrypt/live/$AEG_DOMAIN/fullchain.pem
kp=/etc/letsencrypt/live/$AEG_DOMAIN/privkey.pem
if [ -r "$fp" ] && [ -r "$kp" ]; then
    log "Cert + key present at /etc/letsencrypt/live/$AEG_DOMAIN/"
else
    warn "Missing certs for $AEG_DOMAIN"
    info "Get them with certbot, e.g.:"
    info "  sudo apt install -y certbot"
    info "  sudo certbot certonly --standalone -d $AEG_DOMAIN"
    info "(use --manual --preferred-challenges dns when DNS-01 is needed)"
    if [ "$SKIP_TLS_CHECK" = true ]; then
        warn "Continuing anyway (--skip-tls-check). Caddy will crash-loop."
    else
        error "Re-run with --skip-tls-check to bootstrap before certs land,"
        error "or run certbot first and re-run this script."
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════
step "5/8 — Directory layout"
# ═══════════════════════════════════════════════════════════════

mkdir -p "$AEG_DIR"/{gcp,data}
cd "$AEG_DIR"
log "Layout: $AEG_DIR/{gcp,data}"

# ═══════════════════════════════════════════════════════════════
step "6/8 — Secrets + .env"
# ═══════════════════════════════════════════════════════════════

gen_password()  { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }
gen_base64_32() { openssl rand -base64 32; }

if [ -f "$AEG_DIR/.env" ]; then
    warn "$AEG_DIR/.env already exists — preserving (rename to regenerate secrets)"
else
    db_password=$(gen_password)
    app_key=$(gen_base64_32)   # AES-256 key encrypting per-connector webhook secrets at rest

    cat > "$AEG_DIR/.env" <<ENVFILE
# ── ArcOps Android Enterprise Gateway configuration ──────────
# Generated by setup-aeg.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# This file holds secrets — never commit it to git.

# AEG public domain. emm-mdm connectors + Google's sign-up callback reach AEG
# on this single hostname (https).
AEG_DOMAIN=$AEG_DOMAIN

# GHCR org for image pulls.
GHCR_ORG=$GHCR_ORG

# ── PostgreSQL (own instance, schema "aeg") ──────────────────
AEG_DB_USERNAME=postgres
AEG_DB_PASSWORD=$db_password

# ── GCP (AMAPI + Pub/Sub) ────────────────────────────────────
# project-id extracted from the installed service-account key. The key itself
# is at $AEG_DIR/gcp/service-account.json (mounted read-only into the container).
AEG_GCP_PROJECT_ID=$gcp_project

# AES-256-GCM key (base64 32-byte) encrypting per-connector webhook secrets at
# rest. Rotating it does not lock anyone out — connectors re-register.
AEG_APP_KEY=$app_key

# Public URL Google redirects to after managed-Play enterprise sign-up.
AEG_CALLBACK_URL=https://$AEG_DOMAIN/api/v1/aeg/enterprises/callback

# WB3 companion baseline injection — keep OFF until the companion app is on
# managed Google Play.
AEG_COMPANION_ENABLED=false

# ── Image tags ───────────────────────────────────────────────
# Pinned to the channel tag; arcops-updater (track mode) rewrites this on each
# applied update. stable → prod, latest → test box.
AEG_TAG=$AEG_TAG

# ── Release / auto-update (arcops-updater, track mode) ───────
# This box tracks the channel tag + the AEG host files (compose + Caddyfile)
# from commons, auto-applying with backup → health-gate → rollback.
ARCOPS_DIR=$AEG_DIR
ARCOPS_CHANNEL=$INSTALL_CHANNEL
ARCOPS_TRACK_TAG=$AEG_TAG
ARCOPS_UPDATER_TAG=$UPDATER_TAG
ARCOPS_UPDATE_POLL_INTERVAL=$UPDATE_POLL
ARCOPS_AUTO_UPDATE=true

# Optional JVM override — leave commented to use the tuned defaults in
# docker-compose-aeg.yaml.
# AEG_JAVA_OPTS=-Xms128m -Xmx256m
ENVFILE

    chmod 600 "$AEG_DIR/.env"
    log ".env generated (chmod 600)"
fi

# ═══════════════════════════════════════════════════════════════
step "7/8 — Configuration files"
# ═══════════════════════════════════════════════════════════════

info "Fetching Caddyfile"
curl -fsSL "$COMMONS_REPO/Caddyfile.aeg" -o "$AEG_DIR/Caddyfile"
log "Caddyfile"

info "Fetching docker-compose.yaml"
curl -fsSL "$COMMONS_REPO/src/main/resources/docker-compose-aeg.yaml" \
    -o "$AEG_DIR/docker-compose.yaml"
log "docker-compose.yaml"

# ═══════════════════════════════════════════════════════════════
step "8/8 — GHCR + start"
# ═══════════════════════════════════════════════════════════════

if [ "$SKIP_GHCR" = true ]; then
    log "Skipping GHCR login"
elif [ -f "$HOME/.docker/config.json" ] && grep -q "ghcr.io" "$HOME/.docker/config.json" 2>/dev/null; then
    log "GHCR auth already configured"
elif [ "$NON_INTERACTIVE" = true ]; then
    warn "Skipping GHCR prompt — authenticate manually before next pull"
else
    info "GitHub Personal Access Token (read:packages) required"
    read -rp "${CYAN}GitHub username: ${NC}" gh_user
    read -rsp "${CYAN}GitHub PAT: ${NC}" gh_pat
    printf "\n"
    echo "$gh_pat" | docker login ghcr.io -u "$gh_user" --password-stdin
fi

info "Pulling images"
docker compose pull 2>&1 | tail -5 || true

info "Starting postgres"
docker compose up -d postgres-aeg
sleep 10

info "Starting android-enterprise-gateway + caddy"
docker compose up -d

# ═══════════════════════════════════════════════════════════════
step "Health check"
# ═══════════════════════════════════════════════════════════════

max_wait=180
elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
    if docker compose ps android-enterprise-gateway 2>/dev/null | grep -q "healthy"; then
        log "android-enterprise-gateway healthy"
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    printf "  waiting %ss / %ss\r" "$elapsed" "$max_wait"
done
printf "\n"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || docker compose ps
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e "${GREEN}${BOLD}AEG is up.${NC}"
echo ""
echo -e "  ${BOLD}Broker API:${NC}  https://$AEG_DOMAIN/api/v1/aeg/"
echo -e "  ${BOLD}Callback:${NC}    https://$AEG_DOMAIN/api/v1/aeg/enterprises/callback"
echo ""
echo -e "  ${BOLD}Config:${NC}      $AEG_DIR/.env"
echo -e "  ${BOLD}GCP key:${NC}     $AEG_DIR/gcp/service-account.json"
echo -e "  ${BOLD}Logs:${NC}        docker compose -f $AEG_DIR/docker-compose.yaml logs -f"
echo ""
echo -e "${YELLOW}Next: point each customer's emm-mdm at this AEG${NC}"
echo -e "${YELLOW}(set AEG_BASE_URL=https://$AEG_DOMAIN in the MDM stack's .env and${NC}"
echo -e "${YELLOW}register its AEG_API_TOKEN / AEG_WEBHOOK_SECRET as a connector here).${NC}"
echo ""
