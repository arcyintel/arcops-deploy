#!/usr/bin/env bash
#
# arcops-export-release.sh — build a self-contained OFFLINE release bundle for
# air-gapped / enterprise customers. Runs on an ONLINE machine with ghcr access.
#
# Produces  arcops-release-<version>.tar.gz  containing:
#   manifest.json          the release manifest for this version
#   images.tar.gz          `docker save` of every service image at :<version>
#   docker-compose.yaml    that version's compose
#   Caddyfile              that version's reverse-proxy config
#   mosquitto.conf         that version's broker config
#   .env.template          that version's env reference (for the additive merge)
#
# Hand-carry the bundle to the air-gapped box, then:
#   sudo ./arcops-update.sh --bundle arcops-release-<version>.tar.gz
#
# Usage:
#   ./arcops-export-release.sh --version 1.5.0 \
#       --manifest-url https://licence.acme.com/api/release/manifest
#   ./arcops-export-release.sh --version 1.5.0 \
#       --manifest-file ./manifest-stable.json   # offline-side manifest source

set -euo pipefail

VERSION=""
MANIFEST_URL=""
MANIFEST_FILE=""
CHANNEL=${ARCOPS_CHANNEL:-stable}
OUT_DIR=${OUT_DIR:-.}
GHCR_ORG=${GHCR_ORG:-arcyintel}

log() { printf '[export] %s\n' "$*"; }
die() { printf '[export][ERROR] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    --version)       VERSION="$2"; shift 2 ;;
    --manifest-url)  MANIFEST_URL="$2"; shift 2 ;;
    --manifest-file) MANIFEST_FILE="$2"; shift 2 ;;
    --channel)       CHANNEL="$2"; shift 2 ;;
    --out)           OUT_DIR="$2"; shift 2 ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *)               die "unknown option: $1" ;;
  esac
done

for t in docker curl jq tar gzip; do
  if ! command -v "$t" >/dev/null 2>&1; then die "missing tool: $t"; fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. Obtain the manifest (URL or local file).
if [ -n "$MANIFEST_FILE" ]; then
  cp "$MANIFEST_FILE" "$WORK/manifest.json" || die "cannot read $MANIFEST_FILE"
elif [ -n "$MANIFEST_URL" ]; then
  murl="$MANIFEST_URL"
  case "$murl" in *channel=*) ;; *\?*) murl="$murl&channel=$CHANNEL" ;; *) murl="$murl?channel=$CHANNEL" ;; esac
  log "fetching manifest: $murl"
  curl -fsSL --retry 3 "$murl" -o "$WORK/manifest.json" || die "manifest fetch failed"
else
  die "need --manifest-url or --manifest-file"
fi
if ! jq -e .version "$WORK/manifest.json" >/dev/null 2>&1; then die "manifest invalid"; fi

mver=$(jq -r .version "$WORK/manifest.json")
if [ -z "$VERSION" ]; then VERSION="$mver"; fi
if [ "$VERSION" != "$mver" ]; then die "manifest version ($mver) != --version ($VERSION); pass a matching manifest"; fi
log "exporting release $VERSION"

# 2. Pull + save every service image at its manifest-pinned version.
images=()
while IFS= read -r line; do
  svc="${line%%=*}"; ver="${line#*=}"
  images+=("ghcr.io/$GHCR_ORG/$svc:$ver")
done < <(jq -r '.services | to_entries[] | "\(.key)=\(.value)"' "$WORK/manifest.json")
if [ "${#images[@]}" -eq 0 ]; then die "manifest .services empty"; fi

log "pulling ${#images[@]} images (this is the slow part on a thin link)"
for img in "${images[@]}"; do
  log "  pull $img"
  docker pull "$img" || die "pull failed: $img"
done

log "saving images → images.tar.gz"
docker save "${images[@]}" | gzip > "$WORK/images.tar.gz" || die "docker save failed"

# 3. Fetch the version's host files referenced by the manifest.
fetch() { # url dest label
  if [ -z "$1" ] || [ "$1" = "null" ]; then log "WARN: no url for $3 — bundle will omit it"; return 0; fi
  curl -fsSL --retry 3 "$1" -o "$2" || die "fetch failed: $1"
}
fetch "$(jq -r '.composeUrl // ""'       "$WORK/manifest.json")" "$WORK/docker-compose.yaml" compose
fetch "$(jq -r '.caddyfileUrl // ""'     "$WORK/manifest.json")" "$WORK/Caddyfile"           caddyfile
fetch "$(jq -r '.mosquittoConfUrl // ""' "$WORK/manifest.json")" "$WORK/mosquitto.conf"      mosquitto
fetch "$(jq -r '.envTemplateUrl // ""'   "$WORK/manifest.json")" "$WORK/.env.template"       env-template

# 4. Package.
mkdir -p "$OUT_DIR"
bundle="$OUT_DIR/arcops-release-$VERSION.tar.gz"
tar -C "$WORK" -czf "$bundle" \
  manifest.json images.tar.gz \
  $( [ -f "$WORK/docker-compose.yaml" ] && echo docker-compose.yaml ) \
  $( [ -f "$WORK/Caddyfile" ] && echo Caddyfile ) \
  $( [ -f "$WORK/mosquitto.conf" ] && echo mosquitto.conf ) \
  $( [ -f "$WORK/.env.template" ] && echo .env.template )

log "DONE → $bundle  ($(du -h "$bundle" | cut -f1))"
log "Transfer it to the air-gapped box and run: sudo ./arcops-update.sh --bundle $(basename "$bundle")"
