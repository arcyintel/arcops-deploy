#!/usr/bin/env bash
#
# arcops-updater entrypoint — the release agent loop.
#
# Long-running container in the ArcOps stack (bind-mounts /opt/arcops +
# /var/run/docker.sock). Every poll interval it asks arcops-update.sh to
# bring the box to the channel's latest stable version. arcops-update.sh
# is the single source of update logic (backup → fetch → .env merge →
# compose up [self excluded] → health-gate → rollback). This wrapper adds:
#   - the polling loop (survives errors — never exits the loop),
#   - the SELF-UPDATE hand-off: after a release that changed the installed
#     version, recreate THIS updater via a short-lived detached helper so the
#     updater can pick up its own new image without killing itself mid-apply.
#
# Deliberately NOT `set -e`: a failed/rolled-back update must not stop polling.
set -uo pipefail

ARCOPS_DIR=${ARCOPS_DIR:-/opt/arcops}
POLL=${ARCOPS_UPDATE_POLL_INTERVAL:-3600}
AUTO=${ARCOPS_AUTO_UPDATE:-true}
CHANNEL=${ARCOPS_CHANNEL:-stable}
SELF_SERVICE=${ARCOPS_SELF_SERVICE:-arcops-updater}
export ARCOPS_DIR ARCOPS_CHANNEL="$CHANNEL" ARCOPS_SELF_SERVICE="$SELF_SERVICE"

log() { printf '[arcops-updater] %s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

installed_version() {
  grep -E '^INSTALLED_VERSION=' "$ARCOPS_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# The image this very container runs (has docker + compose + this entrypoint).
self_image() {
  docker inspect --format '{{.Image}}' "$(hostname)" 2>/dev/null \
    || echo "ghcr.io/arcyintel/arcops-updater:${ARCOPS_UPDATER_TAG:-stable}"
}

# Recreate ONLY the updater (picks up its freshly-pulled image) from a
# detached, --rm helper that outlives our own recreation. compose no-ops if
# the image/config didn't change, so this is safe to call after any applied
# release.
self_update_handoff() {
  local img; img=$(self_image)
  log "self-update hand-off (recreating $SELF_SERVICE via transient helper)"
  docker run -d --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$ARCOPS_DIR:$ARCOPS_DIR" \
    --entrypoint sh \
    "$img" \
    -c "sleep 8; docker compose -f '$ARCOPS_DIR/docker-compose.yaml' --env-file '$ARCOPS_DIR/.env' up -d --no-deps '$SELF_SERVICE'" \
    >/dev/null 2>&1 \
    || log "WARN: self-update hand-off could not start (will retry next cycle)"
}

run_once() {
  if [ "$AUTO" != "true" ]; then
    log "auto-update disabled (ARCOPS_AUTO_UPDATE=$AUTO) — operator runs arcops-update.sh"
    return 0
  fi
  log "checking channel=$CHANNEL (installed=$(installed_version))"
  # arcops-update.sh exit contract: 0 = applied, 5 = nothing-to-do, other = failed/rolled-back.
  # We branch on the code (not an INSTALLED_VERSION diff) so this also fires on
  # the edge channel, where the marker stays "edge" but images/config can move.
  local rc=0
  arcops-update.sh --channel "$CHANNEL" || rc=$?
  case "$rc" in
    0)  log "update applied — self-update hand-off"; self_update_handoff ;;
    5)  : ;;  # nothing new this cycle
    *)  log "update exited $rc (rolled back / failed / unreachable) — retry next cycle" ;;
  esac
}

log "arcops-updater started (poll=${POLL}s auto=$AUTO channel=$CHANNEL dir=$ARCOPS_DIR)"
# small startup jitter so a fleet doesn't stampede the manifest/registry at once
sleep $(( (RANDOM % 30) + 5 ))
while true; do
  run_once
  sleep "$POLL"
done
