# SH4 — MQTT Broker Auth Flip Runbook

Closes the open-broker finding: mosquitto runs `allow_anonymous true` today, so
anyone reaching the broker can pub/sub every device topic (incl. publishing fake
commands). This runbook flips the broker to authenticated CONNECT.

## What "auth on" means here

- **`files` backend** — one SHARED principal `arcops-backend` (passwords.txt +
  baked acl.conf) covers the apple/android agents **and** the 3 backend service
  MQTT clients (apple-mdm / android-mdm / windows-mdm).
- **`http` backend** — per-device Windows agents auth against
  `windows-mdm:8087 /api/windows/agent/mqtt/{auth,acl,superuser}` (200=allow,
  403=deny). The two backends are OR-combined.

## The cred triangle (all three MUST be byte-identical)

```
.env  MQTT_PASSWORD
   ==  hash in  mosquitto/secrets/passwords.txt  (principal: arcops-backend)
   ==  the password apple/android serve agents at /auth  (AgentAuthResponse.mqtt)
```
apple/android `AgentAuthServiceImpl` serves `mqttProperties.username/password`
(= `MQTT_USERNAME`/`MQTT_PASSWORD` env) to agents, and the backends' own
`MqttConfig` CONNECTs with the same values. So one password drives all three.
If they diverge, the flip rejects backends and/or agents.

## Durability + propagation model

| Artefact | Where it lives | Recreate-durable? | Reaches customers? |
|----------|----------------|-------------------|--------------------|
| `acl.conf` (static topic structure) | **BAKED** into image at `/mosquitto/config/acl.conf` | yes (in image) | yes (image pull) |
| `passwords.txt` (secret) | host `./mosquitto/secrets/` via **directory** bind-mount | yes (host file) | no (host secret — by design) |
| `mosquitto.conf` (flip switch) | host `./mosquitto/mosquitto.conf`, synced by updater from arcops-deploy `main` | yes | yes (updater) |

Image built + pushed by `arcops-deploy/.github/workflows/mosquitto-image.yml`
(context `src/main/resources/mosquitto/`) → `ghcr.io/arcyintel/mosquitto-with-go-auth:2`.
The committed `mosquitto.conf` stays **anonymous** (the updater syncs it to every
box). `mosquitto.conf.auth` is the **flip target**, applied manually on the box.

---

## EDGE FLIP (test.uconos.com) — ordered, gated, with rollback

> Run on the deploy box, in `$ARCOPS_DIR` (e.g. `/opt/arcops`). Each gate must
> pass before the next step. `BROKER=ghcr.io/arcyintel/mosquitto-with-go-auth:2`.

### 0. Pause the updater (so it can't overwrite mosquitto.conf mid-flip)
```bash
docker compose stop arcops-updater 2>/dev/null || true   # or: systemctl stop arcops-update.timer
```

### 1. Ensure the cred triangle: .env creds + passwords.txt
```bash
cd "$ARCOPS_DIR"
grep -E '^MQTT_(USERNAME|PASSWORD)=' .env        # both must be NON-blank
# If blank, set them (username MUST be arcops-backend):
#   MQTT_USERNAME=arcops-backend
#   MQTT_PASSWORD=<paste a strong secret>
MQ_U=$(grep -E '^MQTT_USERNAME=' .env | cut -d= -f2-)
MQ_P=$(grep -E '^MQTT_PASSWORD=' .env | cut -d= -f2-)
mkdir -p mosquitto/secrets
docker run --rm -v "$ARCOPS_DIR/mosquitto/secrets:/seed" "$BROKER" \
  mosquitto_passwd -b -c /seed/passwords.txt "$MQ_U" "$MQ_P"
chmod 600 mosquitto/secrets/passwords.txt
test -s mosquitto/secrets/passwords.txt && echo "GATE 1 OK: passwords.txt seeded"
```

### 2. Recreate backends with creds — STILL ANONYMOUS broker (verify reconnect)
```bash
docker compose up -d --force-recreate apple-mdm android-mdm windows-mdm
# GATE 2: each service connected to the broker (broker still anonymous, so the
# creds are sent but ignored — proves the env wiring without risking the flip).
for s in apple-mdm android-mdm windows-mdm; do
  docker compose logs --since 2m "$s" 2>&1 | grep -iE 'mqtt.*connect' | tail -2
done
# Also confirm devices still online in the UI before proceeding.
```

### 3. Pull the rebuilt broker image (baked acl.conf)
```bash
docker compose pull mosquitto
docker run --rm "$BROKER" sh -c 'test -f /mosquitto/config/acl.conf && echo "GATE 3 OK: acl.conf baked"'
```

### 4. FLIP: swap in the auth config + recreate mosquitto
```bash
cp mosquitto/mosquitto.conf mosquitto/mosquitto.conf.anon.bak      # rollback source
cp mosquitto/mosquitto.conf.auth mosquitto/mosquitto.conf          # <-- THE FLIP
docker compose up -d --force-recreate mosquitto
sleep 8
docker compose ps mosquitto    # GATE 4a: STATE = healthy (credentialed healthcheck passes)
docker compose logs --since 1m mosquitto 2>&1 | grep -iE 'go-auth|backend|error' | tail -20
```

### 5. Verify auth end-to-end (the real gates)
```bash
# 5a — anonymous CONNECT is now REJECTED (the whole point):
docker run --rm --network arcops_arcops-internal "$BROKER" \
  mosquitto_sub -h mosquitto -t 'arcops/#' -C 1 -W 3 ; echo "exit=$? (NON-zero = anonymous denied = GOOD)"

# 5b — shared creds CONNECT is ACCEPTED:
docker run --rm --network arcops_arcops-internal "$BROKER" \
  mosquitto_sub -h mosquitto -u "$MQ_U" -P "$MQ_P" -t '$SYS/broker/uptime' -C 1 -W 3 ; echo "exit=$? (0 = GOOD)"

# 5c — backend services authenticated-reconnect:
for s in apple-mdm android-mdm windows-mdm; do
  docker compose logs --since 2m "$s" 2>&1 | grep -iE 'mqtt.*(connect|reconnect)' | tail -1
done

# 5d — the 4 enrolled Windows devices auth via the http backend
#      (windows-mdm logs the /api/windows/agent/mqtt/auth hits):
docker compose logs --since 3m windows-mdm 2>&1 | grep -iE 'mqtt/(auth|acl)' | tail -10

# 5e — apple/android agents reconnect: confirm devices report online in the UI
#      within ~1 keepalive (≤120s).
```

### ROLLBACK (any gate fails)
```bash
cd "$ARCOPS_DIR"
cp mosquitto/mosquitto.conf.anon.bak mosquitto/mosquitto.conf   # restore anonymous
docker compose up -d --force-recreate mosquitto
docker compose ps mosquitto                                     # healthy
# Devices reconnect anonymously within one keepalive. Re-start the updater
# only AFTER you have decided to retry or abandon.
```

### 6. Resume the updater
```bash
docker compose up -d arcops-updater    # or: systemctl start arcops-update.timer
```

---

## ⚠️ Customer rollout (STABLE PROMOTE) — prerequisite, NOT part of the edge flip

The updater syncs **`mosquitto.conf`** from arcops-deploy `main` to every
customer box. **Therefore the committed `mosquitto.conf` MUST stay anonymous.**
If a future change makes the committed `mosquitto.conf` the auth variant and it
reaches a `:stable` promote, every existing customer box would have auth turned
on **without a `passwords.txt`** → fleet-wide broker blackout.

**Migration prerequisite before auth can ride a stable promote to customers:**
1. Ship a step (updater hook / setup.sh re-run / one-shot script) that seeds
   `mosquitto/secrets/passwords.txt` from each box's existing `.env`
   `MQTT_PASSWORD` (the `mosquitto_passwd` command in step 1 above), on ALL
   existing boxes, BEFORE the auth conf is allowed to sync.
2. Only after that migration is confirmed fleet-wide may the auth conf become
   the synced `mosquitto.conf`.

Until then: customers get the **baked acl.conf** (harmless, inert) and the
**secrets directory mount** (empty, inert) via image + compose, but the broker
stays anonymous because the synced `mosquitto.conf` is anonymous. New installs
via `setup.sh` also start anonymous but are seeded flip-ready (passwords.txt
generated), so their flip is the manual step-4 swap with zero anonymous gap.
