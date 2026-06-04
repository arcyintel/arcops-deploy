# arcops-updater — the ArcOps release agent.
#
# Build context = the commons repo root:
#   docker build -f updater/Dockerfile -t ghcr.io/arcyintel/arcops-updater .
#
# Tiny image: docker CLI + compose plugin + the shared update script. Runs in
# the customer stack with /opt/arcops + the docker socket bind-mounted, and
# drives the whole-box update from the release manifest. Replaces watchtower.
FROM docker:27-cli

# bash (scripts), curl + jq (manifest), coreutils (GNU `sort -V` for semver,
# sha256sum, date, mktemp), findutils (GNU xargs -r), gzip + tar (offline
# bundle / pg_dump snapshots), docker-cli-compose (the `docker compose` plugin).
RUN apk add --no-cache bash curl jq coreutils findutils gzip tar docker-cli-compose

# The single source of update logic (also published standalone for manual /
# air-gapped use), plus the polling-loop entrypoint.
COPY src/main/resources/arcops-update.sh /usr/local/bin/arcops-update.sh
COPY updater/entrypoint.sh               /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/arcops-update.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
