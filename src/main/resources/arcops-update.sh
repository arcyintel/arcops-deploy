#!/usr/bin/env bash
#
# ArcOps — atomic, backed-up, health-gated update of an /opt/arcops install.
#
# Single source of update truth, used by:
#   1. the `arcops-updater` release-agent container (online, manifest-driven),
#   2. air-gapped operators (offline, --bundle),
#   3. manual operator override.
#
# Updates BOTH the container images AND the host-side files under $ARCOPS_DIR
# (docker-compose.yaml, .env, Caddyfile, mosquitto.conf) to a pinned ArcOps
# version, then verifies health and rolls back on failure.
#
# Modes:
#   Online  : --version X.Y.Z | --channel stable  [--manifest-url URL]
#   Edge    : --channel edge   (test/staging — tracks the moving :latest tag +
#             main host files continuously, NO manifest; the place you validate
#             a build before promoting it to stable for the fleet)
#   Offline : --bundle arcops-release-X.Y.Z.tar.gz   (from arcops-export-release.sh)
#
# Exit: 0 applied / 5 nothing-to-do / 10 preflight / 20 fetch / 30 apply / 40 health(rolled back)
#
# Usage:
#   sudo ./arcops-update.sh --channel stable
#   sudo ./arcops-update.sh --version 1.5.0
#   sudo ./arcops-update.sh --bundle ./arcops-release-1.5.0.tar.gz
#   sudo ./arcops-update.sh --channel stable --dry-run

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────
ARCOPS_DIR=${ARCOPS_DIR:-/opt/arcops}
CHANNEL=${ARCOPS_CHANNEL:-stable}
MANIFEST_URL=${ARCOPS_MANIFEST_URL:-}      # set by setup.sh; licence-server /api/release/manifest or git-tag raw URL
TARGET_VERSION=""
BUNDLE=""
DRY_RUN=false
HEALTH_TIMEOUT=${ARCOPS_HEALTH_TIMEOUT:-300}
KEEP_BACKUPS=${ARCOPS_KEEP_BACKUPS:-5}
SELF_SERVICE=${ARCOPS_SELF_SERVICE:-arcops-updater}   # excluded from recreate so it never kills itself mid-apply
# Health-gated services (space-separated; override per stack via env — e.g. the
# licence stack sets just "licence-server").
read -ra HEALTH_SERVICES <<< "${ARCOPS_HEALTH_SERVICES:-gateway back-core identity apple-mdm android-mdm windows-mdm}"

# ── Update mode ──────────────────────────────────────────────
# manifest : versioned, semver-gated, reads the release manifest (customer stable).
# track    : follows a MOVING tag (+ fetched host files), applies on any change,
#            no manifest. Used by the test/edge box AND the licence stack (test
#            tracks :latest, prod tracks :stable). Default derives from channel
#            (edge⇒track, else⇒manifest); override via ARCOPS_UPDATE_MODE so a
#            prod licence box can be MODE=track + TRACK_TAG=stable.
MODE=${ARCOPS_UPDATE_MODE:-auto}
if [ "$MODE" = auto ]; then
  if [ "$CHANNEL" = edge ]; then MODE=track; else MODE=manifest; fi
fi

# Host files come from the PUBLIC arcops-deploy repo via plain raw (no token).
# Images stay in private ghcr (pulled with the box's ghcr creds). The licence
# stack overrides COMPOSE/CADDYFILE to its own files.
DEPLOY_SLUG=${ARCOPS_DEPLOY_SLUG:-arcyintel/arcops-deploy}

# track-mode knobs. Defaults = the customer edge box (unchanged behavior).
# Empty MOSQUITTO/ENV_TEMPLATE URL ⇒ skip (`-` not `:-`: explicit-empty disables).
TRACK_TAG=${ARCOPS_TRACK_TAG:-${ARCOPS_EDGE_TAG:-latest}}
TRACK_REF=${ARCOPS_TRACK_REF:-main}     # arcops-deploy ref track-mode pulls host files from
TRACK_BASE="https://raw.githubusercontent.com/$DEPLOY_SLUG/$TRACK_REF"
TRACK_COMPOSE_URL=${ARCOPS_COMPOSE_URL:-$TRACK_BASE/src/main/resources/docker-compose-production.yaml}
TRACK_MOSQUITTO_URL=${ARCOPS_MOSQUITTO_URL-$TRACK_BASE/src/main/resources/mosquitto/mosquitto.conf}
TRACK_ENV_TEMPLATE_URL=${ARCOPS_ENV_TEMPLATE_URL-$TRACK_BASE/src/main/resources/.env.template}
TRACK_CADDYFILE_URL=${ARCOPS_CADDYFILE_URL:-${ARCOPS_EDGE_CADDYFILE_URL:-}}
TAG_VARS=${ARCOPS_TAG_VARS:-GATEWAY_TAG BACK_CORE_TAG IDENTITY_TAG APPLE_MDM_TAG ANDROID_MDM_TAG WINDOWS_MDM_TAG FRONTEND_TAG}

log()  { printf '[arcops-update] %s\n' "$*"; }
warn() { printf '[arcops-update][WARN] %s\n' "$*" >&2; }
err()  { printf '[arcops-update][ERROR] %s\n' "$*" >&2; }
die()  { err "$2"; exit "$1"; }

while [ $# -gt 0 ]; do
  case $1 in
    --version)      TARGET_VERSION="$2"; shift 2 ;;
    --channel)      CHANNEL="$2"; shift 2 ;;
    --manifest-url) MANIFEST_URL="$2"; shift 2 ;;
    --bundle)       BUNDLE="$2"; shift 2 ;;
    --arcops-dir)   ARCOPS_DIR="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      sed -n '2,27p' "$0"; exit 0 ;;
    *)              die 10 "unknown option: $1" ;;
  esac
done

COMPOSE="docker compose -f $ARCOPS_DIR/docker-compose.yaml --env-file $ARCOPS_DIR/.env"
TS=$(date -u +%Y%m%d-%H%M%S)
BACKUP_DIR="$ARCOPS_DIR/backups/$TS"
INSTALLED_VERSION="0.0.0"
WORK=""
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK" 2>/dev/null || true; fi; }
trap cleanup EXIT

# semver: returns 0 (true) iff $1 > $2
semver_gt() {
  if [ "$1" = "$2" ]; then return 1; fi
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

env_get() { grep -E "^$1=" "$ARCOPS_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# Replace-or-append KEY=VALUE in .env. Top-level so both merge_env and the
# bind-mounted-config staging below can use it.
set_env_kv() {  # key value
  if grep -qE "^$1=" "$ARCOPS_DIR/.env"; then
    sed -i "s|^$1=.*|$1=$2|" "$ARCOPS_DIR/.env"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ARCOPS_DIR/.env"
  fi
}

# Services to force-recreate because a BIND-MOUNTED config file changed. A
# changed mounted file does NOT alter the container spec, so `docker compose
# up -d` leaves the container running with the OLD config it read at startup
# (mosquitto/caddy have no hot-reload). Populated by stage_files, consumed by
# apply().
RECREATE_SVCS=""

# True when a bind-mounted config differs from the checksum the owning service
# was last (re)created with (recorded in .env). The DESIRED config is the freshly
# fetched $WORK copy when present, else the on-disk file. Keying off a RECORDED
# marker — not an on-disk diff — is what converges a file a PRIOR cycle staged
# but never reloaded (the bug this fixes: config on disk, stale config in the
# running process, no future diff to re-trigger).
bind_config_stale() {  # workbasename destpath envkey
  local src
  if [ -f "$WORK/$1" ]; then src="$WORK/$1"; elif [ -f "$2" ]; then src="$2"; else return 1; fi
  [ "sha256:$(sha256sum "$src" | cut -d' ' -f1)" != "$(env_get "$3")" ]
}

# OR of every tracked bind-mounted config — a manifest/track gate helper.
bind_config_changed() {
  bind_config_stale mosquitto.conf "$ARCOPS_DIR/mosquitto/mosquitto.conf" MOSQUITTO_CONF_SHA \
    || bind_config_stale Caddyfile "$ARCOPS_DIR/Caddyfile" CADDYFILE_SHA
}

# ── 1. Preflight ─────────────────────────────────────────────
preflight() {
  if [ ! -f "$ARCOPS_DIR/docker-compose.yaml" ]; then die 10 "no compose at $ARCOPS_DIR — not an ArcOps host?"; fi
  if [ ! -f "$ARCOPS_DIR/.env" ]; then die 10 "no .env at $ARCOPS_DIR"; fi
  for t in docker curl jq; do
    if ! command -v "$t" >/dev/null 2>&1; then die 10 "missing tool: $t"; fi
  done
  if ! docker compose version >/dev/null 2>&1; then die 10 "docker compose plugin missing"; fi
  local iv; iv=$(env_get INSTALLED_VERSION)
  if [ -n "$iv" ]; then INSTALLED_VERSION="$iv"; fi
  WORK=$(mktemp -d)
  log "installed=$INSTALLED_VERSION mode=$MODE channel=$CHANNEL dir=$ARCOPS_DIR"
}

# ── 2. Resolve release → $WORK/{manifest.json, docker-compose.yaml, Caddyfile, mosquitto.conf, .env.template} ──
fetch_url() {  # url dest label
  if [ -z "$1" ] || [ "$1" = "null" ]; then warn "no URL for $3 — keeping existing"; return 0; fi
  # Public arcops-deploy → plain raw fetch (no token; images use ghcr creds).
  if ! curl -fsSL --retry 3 --retry-delay 5 "$1" -o "$2"; then die 20 "fetch failed: $1"; fi
}

# Track mode: no manifest. Fetch the stack's host files; pin tags to TRACK_TAG.
# track_has_change decides whether anything actually moved. Stack-agnostic —
# the licence stack points TRACK_COMPOSE_URL/etc. at its own compose.
resolve_track() {
  log "track mode — tag :$TRACK_TAG, source $TRACK_COMPOSE_URL"
  TARGET_VERSION="$TRACK_TAG"
  fetch_url "$TRACK_COMPOSE_URL" "$WORK/docker-compose.yaml" compose
  if [ -n "$TRACK_MOSQUITTO_URL" ];    then fetch_url "$TRACK_MOSQUITTO_URL"    "$WORK/mosquitto.conf" mosquitto; fi
  if [ -n "$TRACK_ENV_TEMPLATE_URL" ]; then fetch_url "$TRACK_ENV_TEMPLATE_URL" "$WORK/.env.template"  env-template; fi
  if [ -n "$TRACK_CADDYFILE_URL" ];    then fetch_url "$TRACK_CADDYFILE_URL"    "$WORK/Caddyfile"      caddyfile; fi
}

resolve_release() {
  if [ "$MODE" = track ] && [ -z "$BUNDLE" ]; then resolve_track; return 0; fi
  if [ -n "$BUNDLE" ]; then
    log "offline bundle: $BUNDLE"
    if [ ! -f "$BUNDLE" ]; then die 20 "bundle not found: $BUNDLE"; fi
    tar -xzf "$BUNDLE" -C "$WORK" || die 20 "bundle extract failed"
    if [ ! -f "$WORK/manifest.json" ]; then die 20 "bundle missing manifest.json"; fi
    TARGET_VERSION=$(jq -r .version "$WORK/manifest.json")
    if [ -f "$WORK/images.tar.gz" ] && [ "$DRY_RUN" = false ]; then
      log "loading images from bundle"
      gunzip -c "$WORK/images.tar.gz" | docker load || die 20 "docker load failed"
    fi
    return 0
  fi

  if [ -z "$MANIFEST_URL" ]; then die 20 "no --manifest-url / ARCOPS_MANIFEST_URL set"; fi
  local murl="$MANIFEST_URL"
  case "$murl" in
    *channel=*) ;;
    *\?*)       murl="$murl&channel=$CHANNEL" ;;
    *)          murl="$murl?channel=$CHANNEL" ;;
  esac
  log "fetching manifest: $murl"
  if ! curl -fsSL --retry 3 --retry-delay 5 "$murl" -o "$WORK/manifest.json"; then die 20 "manifest fetch failed"; fi
  if ! jq -e .version "$WORK/manifest.json" >/dev/null 2>&1; then die 20 "manifest invalid (no .version)"; fi

  local mver; mver=$(jq -r .version "$WORK/manifest.json")
  if [ -n "$TARGET_VERSION" ] && [ "$TARGET_VERSION" != "$mver" ]; then
    warn "requested $TARGET_VERSION but $CHANNEL manifest is $mver — using manifest"
  fi
  TARGET_VERSION="$mver"

  local minfrom; minfrom=$(jq -r '.minFromVersion // "0.0.0"' "$WORK/manifest.json")
  if semver_gt "$minfrom" "$INSTALLED_VERSION"; then
    die 20 "manifest needs minFromVersion=$minfrom but installed=$INSTALLED_VERSION — step through $minfrom first"
  fi

  fetch_url "$(jq -r '.composeUrl // ""'       "$WORK/manifest.json")" "$WORK/docker-compose.yaml" compose
  fetch_url "$(jq -r '.caddyfileUrl // ""'     "$WORK/manifest.json")" "$WORK/Caddyfile"           caddyfile
  fetch_url "$(jq -r '.mosquittoConfUrl // ""' "$WORK/manifest.json")" "$WORK/mosquitto.conf"      mosquitto
  fetch_url "$(jq -r '.envTemplateUrl // ""'   "$WORK/manifest.json")" "$WORK/.env.template"       env-template

  # Verify pinned checksums (tamper / partial-fetch guard).
  local f want got
  for f in docker-compose.yaml Caddyfile mosquitto.conf; do
    want=$(jq -r --arg k "$f" '.configChecksums[$k] // ""' "$WORK/manifest.json")
    if [ -z "$want" ] || [ "$want" = "null" ] || [ ! -f "$WORK/$f" ]; then continue; fi
    got="sha256:$(sha256sum "$WORK/$f" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then die 20 "checksum mismatch $f (want $want got $got)"; fi
  done
  log "resolved release $TARGET_VERSION ($CHANNEL)"
}

should_update() {
  if [ -n "$BUNDLE" ]; then return 0; fi
  if semver_gt "$TARGET_VERSION" "$INSTALLED_VERSION"; then return 0; fi
  log "already at $INSTALLED_VERSION (>= $TARGET_VERSION) — nothing to do"
  return 1
}

# Local image IDs the current compose's tags resolve to (one ref=id per line).
# Includes SELF_SERVICE so an updater self-update is detected in track mode too.
track_image_digests() {
  $COMPOSE config --images 2>/dev/null | sort -u | while IFS= read -r ref; do
    if [ -z "$ref" ]; then continue; fi
    printf '%s=%s\n' "$ref" "$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || echo none)"
  done
}

# Per-service isolated pulls for the track-mode freshness check.
#
# A single global `compose pull` lets ONE registry failure cancel every other
# in-flight pull (seen live 2026-06-10: docker.io TLS handshake timeouts on the
# pinned infra images "context canceled" the ghcr ArcOps pulls; the digest
# compare then saw no change and new releases were silently skipped with
# "nothing new"). Two changes close that hole:
#   1. only MOVING-tag (:$TRACK_TAG) services get a per-cycle registry check —
#      pinned refs (postgres:17, redis, ...) are pulled implicitly by `up -d`
#      when missing or when the compose file changes, so re-checking them every
#      cycle only adds registry exposure;
#   2. each service pulls in its OWN invocation, so one registry's outage
#      cannot cancel another registry's pull.
# Sets TRACK_PULL_DEGRADED=true when any pull failed, so the caller never
# reports a confident "up to date" off an incomplete check.
TRACK_PULL_DEGRADED=false
track_pull() {
  local cfg svc ref failures=0
  cfg=$($COMPOSE config --format json 2>/dev/null || true)
  for svc in $($COMPOSE config --services 2>/dev/null); do
    ref=""
    if [ -n "$cfg" ]; then ref=$(jq -r --arg s "$svc" '.services[$s].image // ""' <<<"$cfg"); fi
    case "$ref" in
      ''|*":$TRACK_TAG") ;;  # moving tag (or unresolvable ref) → check every cycle
      *) if docker image inspect "$ref" >/dev/null 2>&1; then continue; fi ;;
    esac
    if ! $COMPOSE pull --quiet "$svc" >/dev/null 2>&1; then
      warn "track: pull failed for $svc — will retry next cycle"
      failures=$((failures + 1))
    fi
  done
  if [ "$failures" -gt 0 ]; then TRACK_PULL_DEGRADED=true; fi
}

# Track-mode change gate (replaces semver). Pulls TRACK_TAG and compares image
# digests, and diffs the fetched host files against the running ones. True ⇒
# something moved ⇒ apply; false ⇒ nothing new ⇒ exit 5 (watchtower-equivalent tick).
track_has_change() {
  local changed=false
  if [ -f "$WORK/docker-compose.yaml" ] && ! cmp -s "$WORK/docker-compose.yaml" "$ARCOPS_DIR/docker-compose.yaml"; then
    log "track: docker-compose.yaml changed"; changed=true
  fi
  # Bind-mounted configs: compare against the checksum the service was last
  # (re)created with, NOT a plain on-disk diff — so a config a prior cycle staged
  # but never reloaded (the up-d-doesn't-recreate-on-mount-change bug) is still
  # detected and converged.
  if bind_config_stale mosquitto.conf "$ARCOPS_DIR/mosquitto/mosquitto.conf" MOSQUITTO_CONF_SHA; then
    log "track: mosquitto.conf differs from the loaded config — recreate pending"; changed=true
  fi
  if bind_config_stale Caddyfile "$ARCOPS_DIR/Caddyfile" CADDYFILE_SHA; then
    log "track: Caddyfile differs from the loaded config — recreate pending"; changed=true
  fi
  local before after
  before=$(track_image_digests)
  log "track: pulling :$TRACK_TAG to check for new images"
  track_pull
  after=$(track_image_digests)
  if [ "$before" != "$after" ]; then log "track: new image digest(s) pulled"; changed=true; fi
  [ "$changed" = true ]
}

# ── 3. Backup (files + DB) ───────────────────────────────────
backup() {
  if [ "$DRY_RUN" = true ]; then log "[dry-run] would back up → $BACKUP_DIR"; return 0; fi
  mkdir -p "$BACKUP_DIR"
  cp -a "$ARCOPS_DIR/.env" "$BACKUP_DIR/.env" 2>/dev/null || true
  cp -a "$ARCOPS_DIR/docker-compose.yaml" "$BACKUP_DIR/docker-compose.yaml" 2>/dev/null || true
  if [ -f "$ARCOPS_DIR/Caddyfile" ]; then cp -a "$ARCOPS_DIR/Caddyfile" "$BACKUP_DIR/Caddyfile"; fi
  if [ -d "$ARCOPS_DIR/mosquitto" ]; then cp -a "$ARCOPS_DIR/mosquitto" "$BACKUP_DIR/mosquitto"; fi
  # Managed-file library volume (FILE_DISTRIBUTION). The uploaded binaries live
  # in a named volume, NOT the DB — pg_dump only captures the managed_file
  # metadata rows, so without this the actual files are lost on a rollback.
  # Discover the real volume name from back-core's /var/arcops/files mount so we
  # stay agnostic to the compose project prefix; tar it via a throwaway busybox.
  local bcc filevol
  bcc=$(docker ps --format '{{.Names}}' | grep -E 'back.?core' | grep -v postgres | head -1)
  if [ -n "$bcc" ]; then
    filevol=$(docker inspect "$bcc" \
      --format '{{range .Mounts}}{{if eq .Destination "/var/arcops/files"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
    if [ -n "$filevol" ]; then
      if docker run --rm -v "$filevol":/v:ro -v "$BACKUP_DIR":/b busybox \
           tar czf /b/back_core_files.tar.gz -C /v . 2>/dev/null; then
        log "backup: managed-file volume $filevol → back_core_files.tar.gz"
      else
        warn "managed-file volume backup failed (continuing — DB + config still backed up)"
        rm -f "$BACKUP_DIR/back_core_files.tar.gz"
      fi
    fi
  fi
  # Per-container DB dump. The user/db are discovered from EACH postgres
  # container's own env (POSTGRES_USER/POSTGRES_DB) rather than a single global
  # .env key, so one routine serves every stack:
  #   • main stack    → POSTGRES_DB=molsec_uconos, one service schema per
  #                     container (back_core, apple_mdm, android_mdm, windows_mdm)
  #   • identity      → POSTGRES_DB=molsec_uconos but its schema is 'uconid', NOT
  #                     the container-derived 'identity'
  #   • licence stack → POSTGRES_DB=arcops_license (user from LICENCE_DB_USERNAME,
  #                     not DB_USERNAME), data in the 'public' schema
  # We restrict the dump to the container-derived schema only when that schema
  # actually exists; otherwise we dump the whole database (correct for licence +
  # identity, a harmless superset for the rest). The dump connects over the local
  # socket (trust auth in the postgres image) so no password is needed.
  local c dbu dbn schema nsflag derr
  for c in $(docker ps --format '{{.Names}}' | grep -E '^postgres-' || true); do
    schema="${c#postgres-}"; schema="${schema//-/_}"
    dbu=$(docker exec "$c" printenv POSTGRES_USER 2>/dev/null || true)
    if [ -z "$dbu" ]; then dbu=$(env_get DB_USERNAME); dbu=${dbu:-postgres}; fi
    dbn=$(docker exec "$c" printenv POSTGRES_DB 2>/dev/null || true)
    if [ -z "$dbn" ]; then dbn=$(env_get DB_NAME); dbn=${dbn:-molsec_uconos}; fi
    nsflag=""
    if docker exec "$c" psql -U "$dbu" -d "$dbn" -tAc \
         "SELECT 1 FROM information_schema.schemata WHERE schema_name='$schema'" 2>/dev/null | grep -q 1; then
      nsflag="-n $schema"
    fi
    derr="$BACKUP_DIR/${schema}.pg_dump.err"
    # shellcheck disable=SC2086
    if docker exec "$c" pg_dump -U "$dbu" -d "$dbn" $nsflag 2>"$derr" | gzip > "$BACKUP_DIR/${schema}.sql.gz"; then
      rm -f "$derr"
    else
      rm -f "$BACKUP_DIR/${schema}.sql.gz"
      warn "pg_dump $schema (db=$dbn user=$dbu) failed: $(head -1 "$derr" 2>/dev/null) (continuing — snapshot only)"
    fi
  done
  grep -E '_TAG=' "$ARCOPS_DIR/.env" > "$BACKUP_DIR/tags.previous" 2>/dev/null || true
  log "backup → $BACKUP_DIR"
  # prune old backups (keep newest KEEP_BACKUPS)
  ls -1dt "$ARCOPS_DIR"/backups/*/ 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -rf || true
}

# ── 4. .env merge (additive; secrets untouched) + pin tags ───
merge_env() {
  if [ "$DRY_RUN" = true ]; then log "[dry-run] would merge env + pin tags → $TARGET_VERSION"; return 0; fi
  if [ -f "$WORK/.env.template" ]; then
    local added=0 line key
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      key="${line%%=*}"
      if ! grep -qE "^${key}=" "$ARCOPS_DIR/.env"; then
        printf '%s\n' "$line" >> "$ARCOPS_DIR/.env"
        added=$((added + 1))
      fi
    done < "$WORK/.env.template"
    if [ "$added" -gt 0 ]; then log "merged $added new env key(s) (existing values preserved)"; fi
  fi
  if [ "$MODE" = track ]; then
    # track mode: pin every stack tag var to the moving TRACK_TAG.
    local var
    for var in $TAG_VARS; do set_env_kv "$var" "$TRACK_TAG"; done
  else
    # manifest mode: pin each service to its manifest-declared version.
    set_tag() {  # ENVKEY service
      local v; v=$(jq -r --arg s "$2" '.services[$s] // ""' "$WORK/manifest.json" 2>/dev/null || true)
      if [ -z "$v" ] || [ "$v" = "null" ]; then v="$TARGET_VERSION"; fi
      set_env_kv "$1" "$v"
    }
    set_tag GATEWAY_TAG gateway
    set_tag BACK_CORE_TAG back-core
    set_tag IDENTITY_TAG identity
    set_tag APPLE_MDM_TAG apple-mdm
    set_tag ANDROID_MDM_TAG android-mdm
    set_tag WINDOWS_MDM_TAG windows-mdm
    set_tag FRONTEND_TAG frontend
  fi
  set_env_kv INSTALLED_VERSION "$TARGET_VERSION"
}

# ── 5. Stage new host files + apply ──────────────────────────
# Stage a bind-mounted host config + arrange a reload. Copies the fetched file
# (when present) into place, then — if the result differs from the checksum the
# service was last (re)created with — marks the service for force-recreate in
# apply() and records the new checksum. Works even when nothing was fetched this
# cycle but a prior cycle staged a file the running process never reloaded.
stage_bind_config() {  # workbasename destpath envkey service
  if [ -f "$WORK/$1" ]; then cp -f "$WORK/$1" "$2"; fi
  [ -f "$2" ] || return 0
  local cur; cur="sha256:$(sha256sum "$2" | cut -d' ' -f1)"
  if [ "$cur" != "$(env_get "$3")" ]; then
    log "$1 changed → force-recreate $4 to reload the bind-mounted config"
    RECREATE_SVCS="$RECREATE_SVCS $4"
    set_env_kv "$3" "$cur"
  fi
}

stage_files() {
  if [ "$DRY_RUN" = true ]; then log "[dry-run] would stage compose/Caddyfile/mosquitto.conf"; return 0; fi
  if [ -f "$WORK/docker-compose.yaml" ]; then cp -f "$WORK/docker-compose.yaml" "$ARCOPS_DIR/docker-compose.yaml"; fi
  stage_bind_config Caddyfile      "$ARCOPS_DIR/Caddyfile"                  CADDYFILE_SHA      caddy
  stage_bind_config mosquitto.conf "$ARCOPS_DIR/mosquitto/mosquitto.conf"  MOSQUITTO_CONF_SHA mosquitto
}

compose_targets() {  # all services except SELF_SERVICE
  $COMPOSE config --services 2>/dev/null | grep -vx "$SELF_SERVICE" || true
}

apply() {
  if [ "$DRY_RUN" = true ]; then log "[dry-run] would pull + up -d (excluding $SELF_SERVICE)"; return 0; fi
  # track mode already pulled in track_has_change; bundle loaded images from tar.
  if [ -z "$BUNDLE" ] && [ "$MODE" != track ]; then
    log "pulling images"
    $COMPOSE pull 2>&1 | tail -8 || die 30 "compose pull failed"
  fi
  log "applying (up -d, excluding $SELF_SERVICE so we don't kill ourselves)"
  local targets; targets=$(compose_targets)
  # shellcheck disable=SC2086
  $COMPOSE up -d --remove-orphans $targets || die 30 "compose up failed"

  # Bind-mounted config changes (mosquitto.conf / Caddyfile) don't alter the
  # container spec, so the up -d above won't reload them. Force-recreate the
  # owning services flagged by stage_files (never the updater itself; --no-deps
  # so we don't cascade-restart their dependents).
  local svc seen=""
  for svc in $RECREATE_SVCS; do
    case " $seen " in *" $svc "*) continue ;; esac
    seen="$seen $svc"
    if [ "$svc" = "$SELF_SERVICE" ]; then continue; fi
    if ! $COMPOSE config --services 2>/dev/null | grep -qx "$svc"; then continue; fi
    log "reloading bind-mounted config → force-recreate $svc"
    $COMPOSE up -d --no-deps --force-recreate "$svc" || warn "force-recreate $svc failed"
  done
}

# ── 6. Health gate ───────────────────────────────────────────
health_gate() {
  if [ "$DRY_RUN" = true ]; then log "[dry-run] would health-gate"; return 0; fi
  log "health gate (timeout ${HEALTH_TIMEOUT}s)"
  local waited=0 ok s
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    ok=true
    for s in "${HEALTH_SERVICES[@]}"; do
      if ! $COMPOSE ps "$s" 2>/dev/null | grep -q "healthy"; then ok=false; break; fi
    done
    if [ "$ok" = true ]; then log "all services healthy"; return 0; fi
    sleep 10; waited=$((waited + 10))
  done
  return 1
}

# ── 7. Rollback ──────────────────────────────────────────────
rollback() {
  err "health gate FAILED — rolling back config + images"
  if [ -f "$BACKUP_DIR/.env" ]; then cp -f "$BACKUP_DIR/.env" "$ARCOPS_DIR/.env"; fi
  if [ -f "$BACKUP_DIR/docker-compose.yaml" ]; then cp -f "$BACKUP_DIR/docker-compose.yaml" "$ARCOPS_DIR/docker-compose.yaml"; fi
  if [ -f "$BACKUP_DIR/Caddyfile" ]; then cp -f "$BACKUP_DIR/Caddyfile" "$ARCOPS_DIR/Caddyfile"; fi
  if [ -d "$BACKUP_DIR/mosquitto" ]; then cp -af "$BACKUP_DIR/mosquitto/." "$ARCOPS_DIR/mosquitto/"; fi
  local targets; targets=$(compose_targets)
  # shellcheck disable=SC2086
  $COMPOSE up -d $targets || err "rollback compose up ALSO failed — manual intervention needed"
  warn "rolled back. DB NOT auto-restored; per-schema snapshots are in $BACKUP_DIR/*.sql.gz if a migration must be reverted."
}

# Note: a box's running version is reported to the licence-server Fleet view by
# the GATEWAY (X-Installed-Version header on its hourly, authenticated
# /license/check) — not from here. So this script has no separate phone-home.

# ── main ─────────────────────────────────────────────────────
preflight
resolve_release
if [ "$MODE" = track ] && [ -z "$BUNDLE" ]; then
  if ! track_has_change; then
    if [ "$TRACK_PULL_DEGRADED" = true ]; then
      warn "track: pull degraded — up-to-date NOT confirmed (will retry next cycle)"
    else
      log "track: nothing new — up to date"
    fi
    exit 5
  fi
  log "track: change detected — applying :$TRACK_TAG"
else
  # Apply when the version advances OR a bind-mounted config drifted from the
  # loaded checksum (so a config-only change converges without a version bump).
  if ! should_update && ! bind_config_changed; then exit 5; fi
  log "updating $INSTALLED_VERSION → $TARGET_VERSION"
fi
backup
merge_env
stage_files
if apply && health_gate; then
  log "UPDATE OK — now at $TARGET_VERSION"
  exit 0
else
  rollback
  exit 40
fi
