# Railway-tuned Nextcloud (self-hosted Google Drive / Dropbox alternative).
#
# Pinned to 34.0.2 rather than tracking `nextcloud` / `nextcloud:apache`.
# The upstream entrypoint refuses to start when the data on the volume is more
# than one major version behind the image (/entrypoint.sh:189-195,
# "It is only possible to upgrade one major version at a time"), and it refuses
# outright when the data is NEWER than the image (/entrypoint.sh:184-185).
# Nextcloud ships a major roughly every four months and a Railway redeploy is a
# routine event, so an unpinned tag means (a) every redeploy is an unrequested
# major upgrade with one-way database migrations, and (b) an instance left
# alone across two majors comes back as a container that will not boot at all.
FROM nextcloud:34.0.2-apache

# Recover the real client address.
#
# Railway's edge sets X-Forwarded-For to "<client>, <edge>" and the edge hop
# rotates per request; the container's own peer address is always the edge
# (100.64.0.0/10). The stock image ships mod_remoteip reading X-Real-IP with
# RemoteIPInternalProxy limited to RFC1918, so on Railway nothing matches and
# every request is attributed to the proxy. Measured on this image with no
# override: eight failed WebDAV logins from eight distinct X-Forwarded-For
# clients recorded 0 brute-force attempts against each client address and 8
# against the peer, with a 25000 ms delay applied to that single shared bucket.
# So the throttle punishes every user of the instance at once and singles out
# nobody.
#
# The fix is the first X-Forwarded-For address only (a whole-header key rotates
# with the edge hop and never matches twice). Apache extracts it into X-Real-IP,
# which the stock remoteip config already consumes once 100.64.0.0/10 is
# trusted. Safe on Railway because the edge REPLACES any inbound
# X-Forwarded-For, so the first hop is the client and cannot be spoofed.
COPY railway-remoteip.conf /etc/apache2/conf-available/railway-remoteip.conf
RUN a2enmod headers setenvif remoteip >/dev/null && \
    a2enconf railway-remoteip >/dev/null

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY hooks/before-starting/10-railway.sh /docker-entrypoint-hooks.d/before-starting/10-railway.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh \
      /docker-entrypoint-hooks.d/before-starting/10-railway.sh

# Baked, NOT published as template variables: templateGenerate keeps a
# variable's default only when the live value is a Railway expression, so a
# literal default is dropped and the variable republishes as a blank REQUIRED
# field on the deploy form. Both competing listings publish
# NEXTCLOUD_ADMIN_USER and NEXTCLOUD_ADMIN_PASSWORD that way, and an empty
# value there is terminal rather than merely inconvenient: upstream runs
# `occ maintenance:install` with an empty --admin-user, prints
# "Set an admin Login." and retries ten times at ten-second intervals before
# `exit 1` (/entrypoint.sh:256-268), so the deploy never serves one request.
# POSTGRES_DB / POSTGRES_USER are baked for the same reason: on the generated
# template they would be literals, and templateGenerate drops a literal default
# and republishes the variable as blank-and-required. `postgres:17-alpine` with
# only POSTGRES_PASSWORD set creates the user `postgres` and a database of the
# same name, which is what these match.
ENV POSTGRES_DB=postgres \
    POSTGRES_USER=postgres \
    NEXTCLOUD_ADMIN_USER=admin \
    NEXTCLOUD_DATA_DIR=/var/www/html/data \
    NEXTCLOUD_UPDATE=1 \
    PHP_UPLOAD_LIMIT=16G

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["apache2-foreground"]
