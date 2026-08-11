#!/bin/sh
# Runs from upstream's `run_path before-starting`, i.e. after the install or
# upgrade has finished and BEFORE Apache binds a port. Everything here has to
# happen in that window: the Railway domain is live the moment Apache answers,
# so a login seeded afterwards leaves a gap in which the instance is reachable
# in some other state.
set -e

# Upstream runs every before-starting hook through its own `run_as`, so this
# script is already the web user (www-data) -- no privilege juggling here, and
# arguments stay arguments so a generated password can contain anything.
occ() { php /var/www/html/occ "$@"; }

if [ ! -f /var/www/html/config/config.php ]; then
    echo "[railway] no config.php — install did not run, skipping post-install configuration"
    exit 0
fi

DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-}"

# 1. URLs. Railway terminates TLS at the edge and talks plain HTTP to the
# container, so without these Nextcloud writes http:// links into share mails,
# federated shares and the mobile clients' setup payloads.
if [ -n "$DOMAIN" ]; then
    occ config:system:set overwritehost --value="$DOMAIN"
    occ config:system:set overwriteprotocol --value="https"
    occ config:system:set overwrite.cli.url --value="https://$DOMAIN"
    occ config:system:set trusted_domains 1 --value="$DOMAIN"
fi

# 2. Trusted proxies, so the client address is the client's.
#
# The container's peer address on Railway is always the edge (100.64.0.0/10),
# so out of the box every request — every login attempt, every brute-force
# counter, every audit line — is attributed to one address. Measured on the
# stock image: eight failed WebDAV logins from eight distinct X-Forwarded-For
# clients recorded 0 attempts against each client and 8 against the peer, with
# a 25000 ms delay on that single shared bucket. That throttle punishes every
# user of the instance at once and singles out nobody.
#
# X-Real-IP is written by Apache from the FIRST X-Forwarded-For hop
# (railway-remoteip.conf) because Railway's edge appends itself to the header
# and that hop rotates per request. Trusting it is safe here because Railway
# REPLACES any inbound X-Forwarded-For at the edge, so the first address is the
# real client and a caller cannot forge it.
IDX=0
for PROXY in 127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 ::1 fd00::/8; do
    occ config:system:set trusted_proxies "$IDX" --value="$PROXY"
    IDX=$((IDX+1))
done
occ config:system:set forwarded_for_headers 0 --value=HTTP_X_REAL_IP

# 3. Redis for distributed cache and file locking, APCu for the local cache.
#
# Without transactional file locking two clients writing the same file can
# interleave; Nextcloud's own docs make Redis the recommendation for anything
# beyond a single user. The image's own entrypoint only wires Redis up as the
# PHP *session* handler, not as Nextcloud's cache or lock backend.
if [ -n "${REDIS_HOST:-}" ]; then
    occ config:system:set memcache.local --value='\OC\Memcache\APCu'
    occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
    occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
    occ config:system:set redis host --value="$REDIS_HOST"
    occ config:system:set redis port --value="${REDIS_HOST_PORT:-6379}" --type=integer
    if [ -n "${REDIS_HOST_PASSWORD:-}" ]; then
        occ config:system:set redis password --value="${REDIS_HOST_PASSWORD}"
    fi
else
    occ config:system:set memcache.local --value='\OC\Memcache\APCu'
fi

# 4. Background jobs.
#
# A fresh install runs background jobs in `ajax` mode, i.e. one job per page
# load — and a Nextcloud driven by sync clients and WebDAV loads no pages, so
# file scans, share expiry, trash and version cleanup, activity mails and app
# updates simply never run. Measured on the stock image: `backgroundjobs_mode`
# and `lastcron` both empty after a completed install. Switch to cron mode and
# actually run one inside the container (a Railway service cannot install a
# system crontab, and a second always-on service just for cron would double the
# deploy's cost).
occ config:app:set core backgroundjobs_mode --value=cron
occ config:system:set maintenance_window_start --value=1 --type=integer

CRON_INTERVAL="${NEXTCLOUD_CRON_INTERVAL:-300}"
(
    while true; do
        sleep "$CRON_INTERVAL"
        php -f /var/www/html/cron.php >/dev/null 2>&1 || true
    done
) &
echo "[railway] background cron started (every ${CRON_INTERVAL}s, backgroundjobs_mode=cron)"

# 5. The admin login, re-applied on every boot.
#
# The password is a Railway ${{secret}}, so it is the deployer's from the first
# deploy onward; re-applying it means a rotation is a redeploy rather than a
# support ticket, and it costs nothing when the value has not changed. Server
# side encryption is off by default, so resetting a password cannot orphan a
# user's keys.
if [ -n "${NEXTCLOUD_ADMIN_PASSWORD:-}" ]; then
    if OC_PASS="$NEXTCLOUD_ADMIN_PASSWORD" \
        php /var/www/html/occ user:resetpassword --password-from-env \
        "${NEXTCLOUD_ADMIN_USER:-admin}" >/dev/null 2>&1; then
        echo "[railway] admin login re-applied from the environment"
    fi
fi

# 6. Cosmetics that otherwise show as red warnings in Administration > Overview
# on a brand-new instance, and that a deployer cannot guess.
occ config:system:set default_phone_region --value="${NEXTCLOUD_DEFAULT_PHONE_REGION:-US}"
occ config:system:set trashbin_retention_obligation --value="auto, 30"
occ config:system:set versions_retention_obligation --value="auto, 30"

echo "[railway] post-install configuration applied"
