# Mosquitto image with mosquitto-go-auth bolted on for HTTP-delegated
# per-device authentication of the V3 Windows agent. Apple / Android
# agents continue to land on the same broker; the plugin layer lets
# every Windows agent's CONNECT round-trip a quick HTTPS call into
# windows_mdm's MqttAuthController (services/agent/WindowsMqttAuthService).
#
# Built + pushed by .github/workflows/mosquitto-image.yml as
#   ghcr.io/arcyintel/mosquitto-with-go-auth:2   (+ :latest)
# The compose `mosquitto:` service pins :2 (major-version pin, independent of
# the ArcOps release line — the broker is infra, upgraded deliberately).
#
# Plugin source: iegomez/mosquitto-go-auth on Docker Hub (NOT ghcr — there is
# no ghcr mirror). Its tags are <plugin>-mosquitto_<broker> and the compiled
# plugin lives at /mosquitto/go-auth.so. We pin 3.0.0 built against mosquitto
# 2.0.18 and run the SAME broker patch so the plugin ABI matches exactly. The
# .so is copied to /usr/lib/mosquitto-go-auth.so to match the `auth_plugin`
# path in mosquitto.conf (the plugin block stays commented until the windows
# agent rollout flips allow_anonymous=false — until then this is a drop-in
# eclipse-mosquitto:2 with the .so present but unloaded).
ARG MOSQUITTO_VERSION=2.0.18
ARG GO_AUTH_TAG=3.0.0-mosquitto_2.0.18

FROM iegomez/mosquitto-go-auth:${GO_AUTH_TAG} AS plugin
# The plugin image carries the compiled plugin at /mosquitto/go-auth.so.

FROM eclipse-mosquitto:${MOSQUITTO_VERSION}

# Plugin binary into the broker's library path (matches mosquitto.conf's
# `auth_plugin /usr/lib/mosquitto-go-auth.so`).
COPY --from=plugin /mosquitto/go-auth.so /usr/lib/mosquitto-go-auth.so

# Default config — the deploy-time `mosquitto.conf` mounts over this file via a
# volume, but a sane baked-in copy keeps the image usable without the mount.
COPY mosquitto.conf /mosquitto/config/mosquitto.conf
