#!/usr/bin/env bash
#
# ArcOps Licence Server — zero-to-production setup script
#
# Bootstraps a dedicated machine to run ONLY the licence-server +
# licence-portal stack (postgres + redis + caddy + mailhog). This
# is the second half of the ArcOps deployment split: the main MDM
# platform runs on its own machine via setup.sh; this script runs
# on a separate machine that issues + verifies customer licences.
#
# Critical input: the RSA-4096 PKCS#8 PRIVATE KEY used to sign
# every customer licence. The operator must provide it before
# starting the stack — this script never generates the key, it
# only validates that one is present at the expected path. Losing
# this key invalidates every customer licence forever.
#
# SSL certificates are MANUAL — operator obtains them with certbot
# (DNS-01 or HTTP-01) and drops them in
# /etc/letsencrypt/live/<licence-domain>/.
#
# Usage:
#   sudo ./setup-licence.sh --domain licence.acme.com \
#       --key /path/to/arcops-license-private.pem
#   sudo ./setup-licence.sh --help

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────
LICENCE_DIR=${LICENCE_DIR:-/opt/arcops-licence}
COMMONS_REPO="https://raw.githubusercontent.com/arcyintel/arcops-deploy/main"
INSTALL_CHANNEL=stable   # --channel stable (prod, tracks :stable) | edge (test, tracks :latest)
LICENCE_DOMAIN=""
PRIVATE_KEY_PATH=""
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
ArcOps Licence Server — standalone production setup

Usage:  sudo ./setup-licence.sh [OPTIONS]

Required:
  --domain HOST            Public domain for licence portal + API
                           (e.g. licence.acme.com).
  --key PATH               Path to the RSA-4096 PKCS#8 PRIVATE KEY
                           used to sign every customer licence. Will
                           be copied to $LICENCE_DIR/keys/ on first
                           run; subsequent runs detect the existing
                           key and skip the copy.

Options:
  --channel CH             Release channel: 'stable' (default; prod — tracks the
                           :stable licence images, auto-updates via arcops-updater)
                           or 'edge' (test box — tracks :latest). NOTE: stable
                           needs promote.yml to have created :stable first.
  --skip-tls-check         Bootstrap before /etc/letsencrypt/live/
                           <domain>/ has the cert+key files (Caddy
                           will crash-loop until they land).
  --skip-ghcr              Skip GHCR login prompt.
  --smtp-host HOST         External SMTP host (default: mailhog).
  --smtp-port PORT         External SMTP port (default: 1025).
  --licence-dir PATH       Install directory (default /opt/arcops-licence).
  -y, --yes                Non-interactive.
  -h, --help               Show this help.

Examples:
  # First run with all defaults (mailhog SMTP, single instance)
  sudo ./setup-licence.sh --domain licence.acme.com \\
      --key ~/arcops-license-private.pem

  # Bootstrap before certs (Caddy will wait)
  sudo ./setup-licence.sh --domain licence.acme.com \\
      --key ~/arcops-license-private.pem --skip-tls-check

  # Real SMTP for outbound notifications
  sudo ./setup-licence.sh --domain licence.acme.com \\
      --key ~/arcops-license-private.pem \\
      --smtp-host smtp.sendgrid.net --smtp-port 587

After running:
  Edit  $LICENCE_DIR/.env             — review/rotate generated secrets
  Logs  docker compose -f $LICENCE_DIR/docker-compose.yaml logs -f
EOF
}

# ── Argument parsing ────────────────────────────────────────
SMTP_HOST=""
SMTP_PORT=""
while [ $# -gt 0 ]; do
    case $1 in
        --domain)            LICENCE_DOMAIN="$2"; shift 2 ;;
        --key)               PRIVATE_KEY_PATH="$2"; shift 2 ;;
        --channel)           INSTALL_CHANNEL="$2"; shift 2 ;;
        --skip-tls-check)    SKIP_TLS_CHECK=true; shift ;;
        --skip-ghcr)         SKIP_GHCR=true; shift ;;
        --smtp-host)         SMTP_HOST="$2"; shift 2 ;;
        --smtp-port)         SMTP_PORT="$2"; shift 2 ;;
        --licence-dir)       LICENCE_DIR="$2"; shift 2 ;;
        -y|--yes)            NON_INTERACTIVE=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ── Resolve channel → image tags + updater cadence ──────────
# The licence stack follows the same channel model as the fleet. arcops-updater
# (track mode) keeps this box on the channel tag. NOTE: --channel stable
# requires the licence images to already carry :stable — run promote.yml once
# (which also creates :stable for licence + licence-portal) BEFORE installing a
# prod box, else `docker compose up` can't pull :stable.
case "$INSTALL_CHANNEL" in
    stable) LIC_TAG=stable; UI_TAG=stable; UPDATER_TAG=stable; UPDATE_POLL=3600 ;;
    edge)   LIC_TAG=latest; UI_TAG=latest; UPDATER_TAG=latest; UPDATE_POLL=120 ;;
    *)      error "Unknown --channel: $INSTALL_CHANNEL (use 'stable' or 'edge')"; exit 1 ;;
esac

# ═══════════════════════════════════════════════════════════════
echo -e "${BOLD}"
cat <<'BANNER'
    _             ___        _   _
   / \   _ __ ___|  _ \ ___ | | (_) ___ ___ _ __  ___ ___
  / _ \ | '__/ __| | | / _ \| | | |/ __/ _ \ '_ \/ __/ _ \
 / ___ \| | | (__| |_| (_) | |_| | (_|  __/ | | \__ \  __/
/_/   \_\_|  \___|____/\___/ \___/_|\___\___|_| |_|___/\___|

  Standalone Licence Server
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
step "3/8 — Domain + signing key"
# ═══════════════════════════════════════════════════════════════

if [ -z "$LICENCE_DOMAIN" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        error "--domain required in non-interactive mode"
        exit 1
    fi
    read -rp "${CYAN}Licence domain (e.g. licence.acme.com): ${NC}" LICENCE_DOMAIN
fi
[ -n "$LICENCE_DOMAIN" ] || { error "Domain is required"; exit 1; }
log "Licence domain: $LICENCE_DOMAIN"

# Validate the signing key. We never generate it for the operator —
# losing the key invalidates every customer licence, so it must be
# explicitly provided.
mkdir -p "$LICENCE_DIR/keys"
key_dest="$LICENCE_DIR/keys/arcops-license-private.pem"

if [ -r "$key_dest" ]; then
    # Normalise ownership/perms: the licence-server container runs as appuser
    # (uid 999), and our boot-time check rejects any group/other access — so the
    # ONLY combination that's both readable by the container and accepted is
    # 0600 owned by 999. A manually-dropped key is often 0644/root, which crash-
    # loops the server, so fix it here every run.
    chown 999:999 "$key_dest" 2>/dev/null || true
    chmod 600 "$key_dest"
    log "Existing signing key at $key_dest — kept (perms normalised: owner 999, 0600)"
elif [ -z "$PRIVATE_KEY_PATH" ]; then
    error "No signing key found at $key_dest and --key not provided"
    error "Generate one with:"
    error "  openssl genpkey -algorithm RSA -out arcops-license-private.pem \\"
    error "    -pkeyopt rsa_keygen_bits:4096"
    error "Then re-run this script with --key /path/to/arcops-license-private.pem"
    error "WARNING: store the key backup OUTSIDE this server — losing it"
    error "invalidates every issued customer licence permanently."
    exit 1
elif [ ! -r "$PRIVATE_KEY_PATH" ]; then
    error "Cannot read signing key: $PRIVATE_KEY_PATH"
    exit 1
else
    # Validate it's a real RSA key + 4096-bit before copying.
    if ! openssl pkey -in "$PRIVATE_KEY_PATH" -noout 2>/dev/null; then
        error "Not a valid PEM-encoded private key: $PRIVATE_KEY_PATH"
        exit 1
    fi
    bits=$(openssl pkey -in "$PRIVATE_KEY_PATH" -text -noout 2>/dev/null \
        | grep -oE 'Private-Key: \(([0-9]+) bit' | grep -oE '[0-9]+' || echo 0)
    if [ "$bits" -lt 4096 ]; then
        error "Signing key is only ${bits}-bit — the licence-server enforces RSA-4096 and"
        error "will refuse to boot with a weaker key. Generate a 4096-bit key:"
        error "  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out arcops-license-private.pem"
        exit 1
    fi
    cp "$PRIVATE_KEY_PATH" "$key_dest"
    # The licence-server container runs as appuser (uid 999); the key must be
    # owned by 999 + 0600 so it's readable by the container yet not group/other-
    # accessible (the boot-time security check rejects the latter).
    chown 999:999 "$key_dest"
    chmod 600 "$key_dest"
    log "Signing key installed (${bits}-bit RSA, owner 999, chmod 600)"
    warn "Store a BACKUP of the private key OUTSIDE this server before continuing."
    if [ "$NON_INTERACTIVE" != true ]; then
        read -rp "${CYAN}Press Enter once you've backed it up...${NC}"
    fi
fi

# ═══════════════════════════════════════════════════════════════
step "4/8 — SSL certificates"
# ═══════════════════════════════════════════════════════════════

fp=/etc/letsencrypt/live/$LICENCE_DOMAIN/fullchain.pem
kp=/etc/letsencrypt/live/$LICENCE_DOMAIN/privkey.pem
if [ -r "$fp" ] && [ -r "$kp" ]; then
    log "Cert + key present at /etc/letsencrypt/live/$LICENCE_DOMAIN/"
else
    warn "Missing certs for $LICENCE_DOMAIN"
    info "Get them with certbot, e.g.:"
    info "  sudo apt install -y certbot"
    info "  sudo certbot certonly --standalone -d $LICENCE_DOMAIN"
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

mkdir -p "$LICENCE_DIR"/{keys,data}
cd "$LICENCE_DIR"
log "Layout: $LICENCE_DIR/{keys,data}"

# ═══════════════════════════════════════════════════════════════
step "6/8 — Secrets + .env"
# ═══════════════════════════════════════════════════════════════

gen_password()  { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }
gen_hex()       { openssl rand -hex 32; }

if [ -f "$LICENCE_DIR/.env" ]; then
    warn "$LICENCE_DIR/.env already exists — preserving (rename to regenerate secrets)"
else
    db_password=$(gen_password)
    redis_password=$(gen_password)
    portal_password=$(gen_password)
    portal_secret=$(gen_hex)
    portal_jwt_secret=$(openssl rand -base64 48 | tr -d '\n')   # 384-bit, well above HS256 min
    admin_password=$(gen_password)
    # The portal only accepts users whose email is on the allowed portal domain
    # (PortalUserService rejects anything else at creation), so the seed admin's
    # email MUST be @<portal-domain> — otherwise the seeder fails and you're
    # locked out with zero portal users. Default the seed email to that domain.
    portal_login_domain="${LICENCE_PORTAL_DOMAIN:-arcyintel.com}"
    admin_email="${LICENCE_ADMIN_EMAIL:-admin@${portal_login_domain}}"

    cat > "$LICENCE_DIR/.env" <<ENVFILE
# ── ArcOps Licence Server configuration ──────────────────────
# Generated by setup-licence.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# This file holds secrets — never commit it to git.

# Licence public domain. Both the portal SPA and the REST API are
# served from this single hostname; the portal calls /api/* on the
# same origin (no CORS).
LICENCE_DOMAIN=$LICENCE_DOMAIN

# GHCR org for image pulls.
GHCR_ORG=$GHCR_ORG

# ── PostgreSQL ───────────────────────────────────────────────
LICENCE_DB_USERNAME=postgres
LICENCE_DB_PASSWORD=$db_password

# ── Redis (refresh tokens + rate-limit counters) ─────────────
LICENCE_REDIS_PASSWORD=$redis_password

# ── Portal auth ──────────────────────────────────────────────
# The licence-server signs/validates portal JWTs and seeds the first
# admin from these. SPRING_PROFILES_ACTIVE=prod (set in compose) makes
# SecretSanityCheck hard-fail boot if any are left at a dev default.
#   LICENCE_PORTAL_JWT_SECRET  — HS256 signing key (>=256-bit)
#   LICENCE_PORTAL_SECRET      — HMAC secret for opaque tokens
#   LICENCE_PORTAL_PASSWORD    — legacy portal password slot
#   LICENCE_PORTAL_ADMIN_*     — first portal admin seeded on boot
LICENCE_PORTAL_JWT_SECRET=$portal_jwt_secret
LICENCE_PORTAL_SECRET=$portal_secret
LICENCE_PORTAL_PASSWORD=$portal_password
LICENCE_PORTAL_ADMIN_EMAIL=$admin_email
LICENCE_PORTAL_ADMIN_PASSWORD=$admin_password
# Portal login is restricted to this email domain. The seed admin email above
# MUST be on this domain (set both consistently via LICENCE_ADMIN_EMAIL +
# LICENCE_PORTAL_DOMAIN if you change it).
LICENCE_PORTAL_DOMAIN=$portal_login_domain

# ── SMTP — used for licence renewal / expiry notifications.
# MailHog (compose-internal) is the default; override with real
# SMTP for production.
SMTP_HOST=${SMTP_HOST:-mailhog}
SMTP_PORT=${SMTP_PORT:-1025}

# ── Image tags ───────────────────────────────────────────────
# Pinned to the channel tag; arcops-updater (track mode) rewrites these on each
# applied update. stable → prod, latest → test box.
LICENCE_TAG=$LIC_TAG
LICENCE_UI_TAG=$UI_TAG

# ── Release / auto-update (arcops-updater, track mode) ───────
# This box tracks the channel tag + the licence host files (compose + Caddyfile)
# from commons, auto-applying with backup → health-gate → rollback. AUTO=false
# makes the updater idle so an operator drives arcops-update.sh by hand.
ARCOPS_DIR=$LICENCE_DIR
ARCOPS_CHANNEL=$INSTALL_CHANNEL
ARCOPS_TRACK_TAG=$LIC_TAG
ARCOPS_UPDATER_TAG=$UPDATER_TAG
ARCOPS_UPDATE_POLL_INTERVAL=$UPDATE_POLL
ARCOPS_AUTO_UPDATE=true

# Optional JVM override — leave commented to use the tuned
# defaults in docker-compose-licence.yaml.
# LICENCE_JAVA_OPTS=-Xms128m -Xmx256m
ENVFILE

    chmod 600 "$LICENCE_DIR/.env"
    log ".env generated (chmod 600)"
fi

# ═══════════════════════════════════════════════════════════════
step "7/8 — Configuration files"
# ═══════════════════════════════════════════════════════════════

info "Fetching Caddyfile"
curl -fsSL "$COMMONS_REPO/Caddyfile.licence" -o "$LICENCE_DIR/Caddyfile"
log "Caddyfile"

info "Fetching docker-compose.yaml"
curl -fsSL "$COMMONS_REPO/src/main/resources/docker-compose-licence.yaml" \
    -o "$LICENCE_DIR/docker-compose.yaml"
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

info "Starting infra (postgres + redis + mailhog)"
docker compose up -d postgres-licence redis mailhog
sleep 10

info "Starting licence-server + portal + caddy"
docker compose up -d

# ═══════════════════════════════════════════════════════════════
step "Health check"
# ═══════════════════════════════════════════════════════════════

max_wait=180
elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
    if docker compose ps licence-server 2>/dev/null | grep -q "healthy"; then
        log "licence-server healthy"
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

admin_login_email=$(grep '^LICENCE_PORTAL_ADMIN_EMAIL=' "$LICENCE_DIR/.env" | cut -d= -f2-)
admin_login_password=$(grep '^LICENCE_PORTAL_ADMIN_PASSWORD=' "$LICENCE_DIR/.env" | cut -d= -f2-)

echo ""
echo -e "${GREEN}${BOLD}Licence server is up.${NC}"
echo ""
echo -e "  ${BOLD}Portal:${NC}      https://$LICENCE_DOMAIN"
echo -e "  ${BOLD}API:${NC}         https://$LICENCE_DOMAIN/api/"
echo -e "  ${BOLD}MailHog:${NC}     https://$LICENCE_DOMAIN/mail/"
echo ""
echo -e "  ${BOLD}Portal admin login (first boot, 2FA enrolled on first sign-in):${NC}"
echo -e "    Email:    $admin_login_email"
echo -e "    Password: $admin_login_password"
echo ""
echo -e "  ${BOLD}Config:${NC}      $LICENCE_DIR/.env"
echo -e "  ${BOLD}Signing key:${NC} $LICENCE_DIR/keys/arcops-license-private.pem"
echo -e "  ${BOLD}Logs:${NC}        docker compose -f $LICENCE_DIR/docker-compose.yaml logs -f"
echo ""
echo -e "${YELLOW}Reminder: the signing key at $LICENCE_DIR/keys/${NC}"
echo -e "${YELLOW}arcops-license-private.pem is the ONLY copy on this server.${NC}"
echo -e "${YELLOW}Losing it invalidates every customer licence forever — back it up.${NC}"
echo ""
