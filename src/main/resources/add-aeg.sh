#!/usr/bin/env bash
#
# add-aeg.sh — Bolt the Android Enterprise Gateway (AEG) onto an ALREADY-RUNNING
# licence box. NO from-scratch reinstall.
#
# Adds postgres-aeg + android-enterprise-gateway to the existing licence stack,
# fronted by the SAME Caddy, host-routed:
#   <licence-domain>  → licence-server / licence-portal   (unchanged)
#   <aeg-domain>      → android-enterprise-gateway:8090    (new)
#
# It does NOT re-bootstrap the licence server. The running licence-server, its
# database, secrets, and signing key are LEFT UNTOUCHED — verified: the licence
# service definitions in the combined compose are byte-identical to the
# standalone one, so `docker compose up -d` creates only the two AEG services and
# recreates Caddy + the updater; it does not restart licence-server / its DB.
#
# What this script does, in order:
#   1. installs the GCP service-account key under <licence-dir>/gcp/
#   2. appends AEG_* keys to the EXISTING .env (licence secrets preserved)
#   3. swaps docker-compose.yaml + Caddyfile to the combined licence+AEG ones
#      (timestamped backups kept), so the track-mode updater follows both going
#      forward
#   4. pulls the AEG image + `docker compose up -d`
#
# Idempotent: safe to re-run. An existing AEG block in .env is preserved; the
# compose/Caddyfile are re-fetched and re-applied.
#
# SSL is MANUAL: get a cert for the AEG domain with certbot and drop it in
# /etc/letsencrypt/live/<aeg-domain>/ (the licence cert is already there).
#
# Usage:
#   sudo ./add-aeg.sh --aeg-domain aeg.acme.com --gcp-key /path/to/service-account.json
#   sudo ./add-aeg.sh --help
#
# To run AEG on its OWN separate machine instead, use setup-aeg.sh (standalone).
# For a brand-new licence box that should include AEG from day one, use
# setup-licence.sh --with-aeg.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────
LICENCE_DIR=${LICENCE_DIR:-/opt/arcops-licence}
COMMONS_REPO="https://raw.githubusercontent.com/arcyintel/arcops-deploy/main"
AEG_DOMAIN=""
GCP_KEY_PATH=""
SKIP_TLS_CHECK=false
NON_INTERACTIVE=false

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
ArcOps — add the Android Enterprise Gateway to a running licence box

Usage:  sudo ./add-aeg.sh --aeg-domain HOST --gcp-key PATH [OPTIONS]

Required:
  --aeg-domain HOST    Public domain for AEG (e.g. aeg.acme.com). Point its DNS
                       at THIS machine (same IP as the licence domain) and get a
                       TLS cert for it (certbot).
  --gcp-key PATH       GCP service-account JSON (AMAPI + Pub/Sub). Copied to
                       $LICENCE_DIR/gcp/service-account.json. Not needed on a
                       re-run if the key is already installed.

Options:
  --licence-dir PATH   Existing licence install dir (default $LICENCE_DIR).
  --skip-tls-check     Proceed before the AEG cert is in /etc/letsencrypt/live/
                       (Caddy will crash-loop until it lands).
  -y, --yes            Non-interactive.
  -h, --help           Show this help.

After running, point each ArcOps customer (and test.uconos.com) at AEG:
  set  AEG_BASE_URL=https://<aeg-domain>  in their .env and restart emm-mdm.
Then provision an emm-connector credential in the AEG portal/API.
EOF
}

# ── Argument parsing ────────────────────────────────────────
while [ $# -gt 0 ]; do
    case $1 in
        --aeg-domain)      AEG_DOMAIN="$2"; shift 2 ;;
        --gcp-key)         GCP_KEY_PATH="$2"; shift 2 ;;
        --licence-dir)     LICENCE_DIR="$2"; shift 2 ;;
        --skip-tls-check)  SKIP_TLS_CHECK=true; shift ;;
        -y|--yes)          NON_INTERACTIVE=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

echo -e "${BOLD}"
cat <<'BANNER'
  Add Android Enterprise Gateway → existing licence box
BANNER
echo -e "${NC}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════
step "1/5 — Preflight: this must be a running licence box"
# ═══════════════════════════════════════════════════════════════

if [ "$EUID" -ne 0 ]; then
    error "Run as root or with sudo"
    exit 1
fi
for tool in docker curl openssl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        error "Required tool missing: $tool"
        exit 1
    fi
done
if ! docker compose version >/dev/null 2>&1; then
    error "docker compose plugin not available"
    exit 1
fi
if [ ! -f "$LICENCE_DIR/.env" ] || [ ! -f "$LICENCE_DIR/docker-compose.yaml" ]; then
    error "No licence install found at $LICENCE_DIR (.env / docker-compose.yaml missing)."
    error "Run setup-licence.sh there first, then re-run this script."
    exit 1
fi
cd "$LICENCE_DIR"
# Confirm the running stack really is the licence stack (so we don't clobber the
# wrong dir). The compose project name = this dir's basename → named volumes
# (pg_licence_data, …) are reused, never recreated.
if ! docker compose config --services 2>/dev/null | grep -qx "licence-server"; then
    error "$LICENCE_DIR/docker-compose.yaml has no 'licence-server' service — wrong directory?"
    exit 1
fi
if [ -z "$AEG_DOMAIN" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        error "--aeg-domain required in non-interactive mode"
        exit 1
    fi
    read -rp "${CYAN}AEG domain (e.g. aeg.acme.com): ${NC}" AEG_DOMAIN
fi
[ -n "$AEG_DOMAIN" ] || { error "AEG domain is required"; exit 1; }
log "Licence install: $LICENCE_DIR (licence-server present)"
log "AEG domain: $AEG_DOMAIN (co-located behind the existing Caddy)"

# ═══════════════════════════════════════════════════════════════
step "2/5 — GCP service-account key"
# ═══════════════════════════════════════════════════════════════

# NOTE on perms: the GCP key is chmod 644 (matching the standalone setup-aeg.sh).
# The android-enterprise-gateway container runs as a non-root app user with an
# auto-assigned uid; the key is bind-mounted read-only into it. A root-owned 0600
# file would be UNREADABLE by that uid and break AEG boot. 0644 is the uid-agnostic
# safe choice on this single-tenant vendor box (which already holds the master RSA
# signing key). Pub/Sub + AMAPI scope on the SA limits blast radius.
mkdir -p "$LICENCE_DIR/gcp"
gcp_dest="$LICENCE_DIR/gcp/service-account.json"
gcp_project=""
if [ -r "$gcp_dest" ]; then
    chmod 644 "$gcp_dest"
    gcp_project=$(jq -r '.project_id // empty' "$gcp_dest" 2>/dev/null || true)
    [ -n "$gcp_project" ] || { error "Existing $gcp_dest is not a valid service-account JSON (no project_id)"; exit 1; }
    log "Existing GCP key at $gcp_dest — kept (project: $gcp_project)"
elif [ -z "$GCP_KEY_PATH" ]; then
    error "No GCP key at $gcp_dest and --gcp-key not provided."
    error "Create a service-account in the AMAPI GCP project (androidmanagement.* + pubsub),"
    error "download its JSON key, then re-run with --gcp-key /path/to/service-account.json"
    exit 1
elif [ ! -r "$GCP_KEY_PATH" ]; then
    error "Cannot read GCP key: $GCP_KEY_PATH"
    exit 1
else
    if ! jq -e '.type == "service_account" and .project_id and .private_key and .client_email' \
            "$GCP_KEY_PATH" >/dev/null 2>&1; then
        error "Not a valid GCP service-account JSON (need type=service_account + project_id + private_key + client_email): $GCP_KEY_PATH"
        exit 1
    fi
    gcp_project=$(jq -r '.project_id' "$GCP_KEY_PATH")
    cp "$GCP_KEY_PATH" "$gcp_dest"
    chmod 644 "$gcp_dest"
    log "GCP service-account key installed (project: $gcp_project)"
    warn "Store a BACKUP of the service-account key OUTSIDE this server."
fi

# ═══════════════════════════════════════════════════════════════
step "3/5 — SSL certificate for the AEG domain"
# ═══════════════════════════════════════════════════════════════

afp=/etc/letsencrypt/live/$AEG_DOMAIN/fullchain.pem
akp=/etc/letsencrypt/live/$AEG_DOMAIN/privkey.pem
if [ -r "$afp" ] && [ -r "$akp" ]; then
    log "Cert + key present at /etc/letsencrypt/live/$AEG_DOMAIN/"
else
    warn "Missing certs for $AEG_DOMAIN"
    info "Get them with certbot, e.g.:"
    info "  sudo certbot certonly --standalone -d $AEG_DOMAIN"
    info "(use --manual --preferred-challenges dns when DNS-01 is needed)"
    if [ "$SKIP_TLS_CHECK" = true ]; then
        warn "Continuing anyway (--skip-tls-check). Caddy will crash-loop until the cert lands."
    else
        error "Re-run with --skip-tls-check to proceed before the cert lands, or run certbot first."
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════
step "4/5 — AEG config (.env) + combined compose/Caddyfile"
# ═══════════════════════════════════════════════════════════════

# 4a) Backup + rollback machinery FIRST, so any failure below (bad download,
# invalid compose, pull failure, AEG never healthy) restores the box to exactly
# its pre-AEG state — compose, Caddyfile AND the .env append.
ts=$(date +%Y%m%d-%H%M%S)
bak_compose="$LICENCE_DIR/docker-compose.yaml.bak-$ts"
bak_caddy="$LICENCE_DIR/Caddyfile.bak-$ts"
# Collision guard: a rapid re-run in the same wall-clock second must not overwrite
# a prior run's backup (which after the first run is the only snapshot of the
# pre-AEG compose). Bump a suffix until the names are free.
n=1
while [ -e "$bak_compose" ] || [ -e "$bak_caddy" ]; do
    bak_compose="$LICENCE_DIR/docker-compose.yaml.bak-$ts-$n"
    bak_caddy="$LICENCE_DIR/Caddyfile.bak-$ts-$n"
    n=$((n + 1))
done
cp "$LICENCE_DIR/docker-compose.yaml" "$bak_compose"
cp "$LICENCE_DIR/Caddyfile"           "$bak_caddy"
# .env byte size BEFORE any AEG append, so rollback can truncate it back exactly
# (undoes a first-run append; a no-op when a re-run appends nothing).
env_bytes_before=$(wc -c < "$LICENCE_DIR/.env" | tr -d ' ')
log "Backed up compose + Caddyfile ($bak_compose)"

_rolled_back=false
rollback() {
    [ "$_rolled_back" = true ] && return 0
    _rolled_back=true
    warn "Rolling back to the pre-AEG state…"
    [ -f "$bak_compose" ] && mv -f "$bak_compose" "$LICENCE_DIR/docker-compose.yaml"
    [ -f "$bak_caddy" ]   && mv -f "$bak_caddy"   "$LICENCE_DIR/Caddyfile"
    truncate -s "$env_bytes_before" "$LICENCE_DIR/.env" 2>/dev/null || true
    # Bring Caddy + updater back on the restored (licence-only) compose and drop
    # the half-started AEG containers so nothing dangles. Best-effort.
    docker compose up -d --remove-orphans 2>&1 | tail -3 || true
    error "Rolled back. Licence stack restored to its pre-AEG state."
}
# Backstop for any unguarded failure below (curl/mv/up-d). Guarded failures
# (config/pull/health) call rollback explicitly with a clearer message.
trap 'rollback' ERR

# 4b) Append AEG_* to the EXISTING .env — licence secrets are preserved verbatim.
if grep -qE '^AEG_DOMAIN=' "$LICENCE_DIR/.env"; then
    warn "AEG keys already present in .env — preserving (delete the AEG block + re-run to regenerate)"
    # Keep the existing AEG_DOMAIN authoritative; just report a mismatch.
    cur=$(grep -E '^AEG_DOMAIN=' "$LICENCE_DIR/.env" | head -1 | cut -d= -f2- || true)
    [ "$cur" = "$AEG_DOMAIN" ] || warn "  .env AEG_DOMAIN=$cur differs from --aeg-domain $AEG_DOMAIN (keeping .env value)"
    AEG_DOMAIN="$cur"
else
    # Follow the SAME release channel as the licence box (stable vs latest).
    chan=$(grep -E '^LICENCE_TAG=' "$LICENCE_DIR/.env" | head -1 | cut -d= -f2- || true)
    chan=${chan:-stable}
    # cut -c1-24 (NOT head -c 24): cut reads stdin to EOF, so tr is never sent
    # SIGPIPE under `set -o pipefail` (which would abort the whole script).
    aeg_db_password=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-24)
    aeg_app_key=$(openssl rand -base64 32)   # AES-256 key for per-connector webhook secrets at rest
    cat >> "$LICENCE_DIR/.env" <<AEGENV

# ── Android Enterprise Gateway (AEG) — CO-LOCATED (added by add-aeg.sh) ──
# AEG runs in this stack behind the same Caddy; \${AEG_DOMAIN} → android-enterprise-gateway:8090.
# GCP service-account JSON is at $LICENCE_DIR/gcp/service-account.json (mounted read-only).
AEG_DOMAIN=$AEG_DOMAIN
AEG_DB_USERNAME=postgres
AEG_DB_PASSWORD=$aeg_db_password
AEG_GCP_PROJECT_ID=$gcp_project
AEG_APP_KEY=$aeg_app_key
AEG_CALLBACK_URL=https://$AEG_DOMAIN/api/v1/aeg/enterprises/callback
AEG_COMPANION_ENABLED=false
# Channel tag for the AEG image (matches the licence channel); arcops-updater
# (track mode) rewrites it on each applied update.
AEG_TAG=$chan
# Optional JVM override for AEG — defaults live in docker-compose-licence-aeg.yaml.
# AEG_JAVA_OPTS=-Xms128m -Xmx256m
AEGENV
    chmod 600 "$LICENCE_DIR/.env"
    log "AEG secrets appended to .env (channel: $chan, project: $gcp_project)"
fi

# 4c) Swap to the combined compose + Caddyfile. The track-mode updater then
# follows the combined files (the combined compose bakes ARCOPS_COMPOSE_URL /
# CADDYFILE_URL / TAG_VARS+=AEG_TAG into the updater env).
info "Fetching combined Caddyfile (licence + AEG)"
curl -fsSL "$COMMONS_REPO/Caddyfile.licence-aeg" -o "$LICENCE_DIR/Caddyfile.new"
info "Fetching combined docker-compose.yaml (licence + AEG)"
curl -fsSL "$COMMONS_REPO/src/main/resources/docker-compose-licence-aeg.yaml" -o "$LICENCE_DIR/docker-compose.yaml.new"
mv "$LICENCE_DIR/Caddyfile.new"          "$LICENCE_DIR/Caddyfile"
mv "$LICENCE_DIR/docker-compose.yaml.new" "$LICENCE_DIR/docker-compose.yaml"
log "Swapped to combined licence+AEG compose + Caddyfile"

# Validate the swapped compose (uses the AEG_* env just appended).
if ! docker compose config -q >/dev/null 2>&1; then
    error "Combined compose failed validation (bad download?)."
    rollback
    exit 1
fi
log "Combined compose validated"

# ═══════════════════════════════════════════════════════════════
step "5/5 — Pull AEG image + apply"
# ═══════════════════════════════════════════════════════════════

# Pull ONLY the new images (postgres:17 is likely already local from the licence
# stack). This avoids re-pulling the licence images, so licence-server is not
# upgraded as a side effect of adding AEG.
info "Pulling AEG image"
if ! docker compose pull android-enterprise-gateway postgres-aeg; then
    error "Pull failed. Check GHCR auth (docker login ghcr.io) and that the"
    error "android-enterprise-gateway image is published at the channel tag."
    rollback
    exit 1
fi

info "Applying (creates postgres-aeg + android-enterprise-gateway; recreates Caddy + updater; licence services untouched)"
if ! docker compose up -d; then
    error "docker compose up -d failed."
    rollback
    exit 1
fi

# ── Health gate ──────────────────────────────────────────────
info "Waiting for android-enterprise-gateway to become healthy"
aeg_healthy=false
max_wait=180; elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
    if docker compose ps android-enterprise-gateway 2>/dev/null | grep -q "healthy"; then
        aeg_healthy=true
        log "android-enterprise-gateway healthy"
        break
    fi
    sleep 5; elapsed=$((elapsed + 5))
    printf "  waiting %ss / %ss\r" "$elapsed" "$max_wait"
done
printf "\n"

if [ "$aeg_healthy" != true ]; then
    error "android-enterprise-gateway did not become healthy within ${max_wait}s."
    error "Check:  docker compose logs android-enterprise-gateway"
    rollback
    exit 1
fi

# Caddy fronts the LIVE licence domain too. The combined Caddyfile has an explicit
# tls directive for BOTH domains, so a missing AEG cert (or any Caddyfile error)
# makes Caddy fail to load → it crash-loops → licence HTTPS goes down. Verify Caddy
# is actually Up and roll back rather than print success over a dead Caddy.
if docker compose ps caddy 2>/dev/null | grep -q "Restarting" || \
   ! docker compose ps caddy 2>/dev/null | grep -qE "Up|healthy"; then
    error "Caddy is not Up — the combined Caddyfile failed to load (AEG cert missing?)."
    error "Check:  docker compose logs caddy"
    rollback
    exit 1
fi
log "Caddy up — both licence + AEG vhosts served"

# Past the point of failure — disarm the backstop so the success summary prints.
trap - ERR

if docker compose ps licence-server 2>/dev/null | grep -q "Up\|healthy"; then
    log "licence-server still running (not restarted)"
else
    warn "licence-server is not reporting Up — check 'docker compose ps' / logs."
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || docker compose ps
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e "${GREEN}${BOLD}AEG is co-located on the licence box.${NC}"
echo ""
echo -e "  ${BOLD}Licence:${NC}  https://$(grep -E '^LICENCE_DOMAIN=' "$LICENCE_DIR/.env" | head -1 | cut -d= -f2- || true)   (unchanged)"
echo -e "  ${BOLD}AEG:${NC}      https://$AEG_DOMAIN/api/v1/aeg/"
echo -e "  ${BOLD}Config:${NC}   $LICENCE_DIR/.env   (AEG_* appended; licence secrets preserved)"
echo -e "  ${BOLD}Backups:${NC}  $bak_compose , $bak_caddy"
echo ""
echo -e "${YELLOW}Next (per ArcOps customer + test.uconos.com):${NC}"
echo -e "  set  ${BOLD}AEG_BASE_URL=https://$AEG_DOMAIN${NC}  in their .env, then restart emm-mdm."
echo -e "  Then provision an emm-connector credential in the AEG portal/API."
echo ""
