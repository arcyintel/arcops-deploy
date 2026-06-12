#!/usr/bin/env bash
# generate-release-notes.sh VERSION SINCE_ISO UNTIL_ISO OUT_DIR
#
# Builds the structured auto release-notes JSON for one ArcOps version from
# the conventional-commit subjects of every product repo, over the half-open
# window (SINCE, UNTIL] — i.e. "everything that landed on main since the
# previous release tag". Output: OUT_DIR/notes/VERSION.json
#
# Requires: gh (authenticated via GH_TOKEN with contents:read on the product
# repos) + jq. ALL JSON is built by jq — commit subjects are never hand-
# interpolated into JSON strings, so quotes/Unicode/Turkish chars are safe.
#
# The output lands in the PRIVATE arcyintel/arcops-release-notes repo: raw
# commit subjects of the private product repos can describe security fixes
# and must not be committed into the public arcops-deploy repo.
set -euo pipefail

VERSION=$1
SINCE=$2
UNTIL=$3
OUT=$4

REPOS=${REPOS:-"commons back_core apple_mdm android_mdm windows_mdm gateway identity UconFrontend"}
TYPES='feat|fix|perf|refactor|docs|chore|ci|build|test'

mkdir -p "$OUT/notes"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for repo in $REPOS; do
  # --paginate emits one JSON array per page; flatten to an object stream
  # with --jq '.[]' and re-slurp so multi-page windows merge correctly.
  gh api --paginate \
    "repos/arcyintel/$repo/commits?sha=main&since=$SINCE&until=$UNTIL&per_page=100" \
    --jq '.[]' \
  | jq -s --arg repo "$repo" --arg types "$TYPES" '
      [ .[]
        | {sha: .sha[0:7], date: .commit.author.date,
           raw: (.commit.message | split("\n")[0])}
        | select(.raw | test("^Merge ") | not)
        | select(.raw | startswith("promote:") | not)
        | ((.raw | capture("^(?<type>" + $types + ")(\\((?<scope>[^)]*)\\))?(?<bang>!)?: *(?<subject>.+)$"))? // null) as $c
        | select($c != null)
        | {type: $c.type, scope: ($c.scope // null), breaking: ($c.bang == "!"),
           subject: $c.subject, sha: .sha, date: .date}
      ] | {repo: $repo, commits: .}' > "$TMP/$repo.json"
  echo "  $repo: $(jq '.commits | length' "$TMP/$repo.json") conventional commit(s)"
done

jq -s \
  --arg version "$VERSION" \
  --arg since "$SINCE" \
  --arg until "$UNTIL" \
  --arg releasedAt "$UNTIL" \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{version: $version, releasedAt: $releasedAt,
    range: {since: $since, until: $until},
    generatedAt: $generatedAt,
    repos: [ .[] | select(.commits | length > 0) ]}' \
  "$TMP"/*.json > "$OUT/notes/$VERSION.json"

echo "Wrote $OUT/notes/$VERSION.json ($(jq '[.repos[].commits | length] | add // 0' "$OUT/notes/$VERSION.json") commits across $(jq '.repos | length' "$OUT/notes/$VERSION.json") repos)"
