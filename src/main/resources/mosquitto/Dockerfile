# Mosquitto image with mosquitto-go-auth for HTTP-delegated per-device
# authentication of the V3 Windows agent + shared-creds files backend for
# apple/android agents + backend service clients. The plugin layer lets every
# Windows agent's CONNECT round-trip a quick HTTPS call into windows_mdm's
# MqttAuthController (services/agent/WindowsMqttAuthService).
#
# Built + pushed by .github/workflows/mosquitto-image.yml as
#   ghcr.io/arcyintel/mosquitto-with-go-auth:2   (+ :latest)
# The compose `mosquitto:` service pins :2 (major-version pin, independent of
# the ArcOps release line — the broker is infra, upgraded deliberately).
#
# ── WHY single-stage FROM the plugin image (2026-06-10 fix) ─────────
# The previous multi-stage build COPYed iegomez's /mosquitto/go-auth.so INTO a
# stock eclipse-mosquitto:2.0.18 and the broker REFUSED to load it:
#     Error relocating mosquitto-go-auth.so: runtime.tlsg:
#     initial-exec TLS resolves to dynamic definition
# i.e. the plugin .so's TLS/libc build did not match the destination base.
# The robust fix is to run the plugin ON THE BASE IT WAS BUILT FOR: the
# iegomez image already IS eclipse-mosquitto 2.0.18 + a loadable go-auth
# plugin at /mosquitto/go-auth.so, same entrypoint/paths/user (1883). So we use
# it directly and only layer our config on top. mosquitto.conf.auth points
# auth_plugin at /mosquitto/go-auth.so (the plugin's native location).
ARG GO_AUTH_TAG=3.0.0-mosquitto_2.0.18

FROM iegomez/mosquitto-go-auth:${GO_AUTH_TAG}

# Default config — the deploy-time `mosquitto.conf` mounts over this file via a
# volume, but a sane baked-in copy keeps the image usable without the mount.
COPY mosquitto.conf /mosquitto/config/mosquitto.conf

# ── acl.conf — BAKED (SH4 broker-auth) ──────────────────────────────
# STATIC config (topic structure for the shared `arcops-backend` principal —
# not a secret, not per-deployment), so it lives IN the image rather than a
# host bind-mount: recreate-durable + customer-propagating. The auth config
# references this exact baked path (`auth_opt_acl_path /mosquitto/config/acl.conf`).
# INERT while allow_anonymous=true. passwords.txt is NOT baked — it is a secret,
# host-side, via a directory bind-mount (see docker-compose).
COPY acl.conf /mosquitto/config/acl.conf

# The iegomez base's CMD points mosquitto at /etc/mosquitto/mosquitto.conf
# (which doesn't even exist here); override to the eclipse-mosquitto
# convention /mosquitto/config/mosquitto.conf where our config + the
# compose bind-mount + the baked acl.conf live. ENTRYPOINT (tini --) stays.
CMD ["/usr/sbin/mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]
