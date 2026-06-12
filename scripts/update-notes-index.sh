#!/usr/bin/env bash
# update-notes-index.sh OUT_DIR
#
# Rebuilds releases-index.json from every notes/<version>.json in OUT_DIR.
# The index is what ReleaseNotesSyncJob polls: [{version, releasedAt,
# generatedAt}] sorted by semver ascending. generatedAt is the re-sync
# trigger — regenerating a version's notes bumps it, and the licence server
# re-fetches that version on the next cycle.
set -euo pipefail

OUT=$1

if ! ls "$OUT"/notes/*.json >/dev/null 2>&1; then
  echo '[]' > "$OUT/releases-index.json"
  echo "No notes files — wrote empty index."
  exit 0
fi

jq -s '[ .[] | {version, releasedAt, generatedAt} ]
       | sort_by(.version | split(".") | map(tonumber))' \
  "$OUT"/notes/*.json > "$OUT/releases-index.json"

echo "Index rebuilt: $(jq 'length' "$OUT/releases-index.json") version(s)"
