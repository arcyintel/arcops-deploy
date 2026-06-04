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
# Plugin source: https://github.com/iegomez/mosquitto-go-auth
# Pinned to a tagged release rather than `latest` so a runtime breaking
# change in the plugin can't ripple through to boxes on an image pull.
ARG MOSQUITTO_VERSION=2.0
ARG GO_AUTH_VERSION=v3.0.0

FROM ghcr.io/iegomez/mosquitto-go-auth:${GO_AUTH_VERSION} AS plugin
# The plugin image exposes /mosquitto-go-auth.so at the root.

FROM eclipse-mosquitto:${MOSQUITTO_VERSION}

# Plugin binary into the broker's library path.
COPY --from=plugin /mosquitto-go-auth.so /usr/lib/mosquitto-go-auth.so

# Default config — the deploy-time `mosquitto.conf` mounts over this
# file via a volume, but having a sane baked-in copy means the image
# is usable without the deploy-time mount during local CI tests.
COPY mosquitto.conf /mosquitto/config/mosquitto.conf
