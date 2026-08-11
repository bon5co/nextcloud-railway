#!/bin/sh
# Railway shim for the official Nextcloud apache image. Runs before upstream's
# /entrypoint.sh, which installs or upgrades the instance and then execs Apache.
set -e

PORT_ACTUAL="${PORT:-8080}"

# 0. Exactly one MPM.
#
# The image enables mpm_prefork alone, and `apache2ctl -M` in a local container
# agrees — but on Railway the same image dies at start with
# "AH00534: apache2: Configuration error: More than one MPM loaded." and
# crash-loops. Both competing listings carry an `a2dismod mpm_event` in their
# start command for this, so it is not specific to this build. Force the state
# the image intends, and ignore the failures when a module is already in it.
a2dismod mpm_event mpm_worker >/dev/null 2>&1 || true
rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
a2enmod mpm_prefork >/dev/null 2>&1 || true
echo "[railway] mpm: $(ls /etc/apache2/mods-enabled | grep -i mpm | tr '\n' ' ')| loads: $(grep -rl 'LoadModule mpm' /etc/apache2 2>/dev/null | grep -v mods-available | tr '\n' ' ')"

# 1. Apache listens on the port Railway injected.
#
# The image bakes `Listen 80` and a <VirtualHost *:80>. Railway's HTTP
# healthcheck dials the port it injected rather than the domain's target port,
# so an app pinned to anything else fails the deploy while still answering every
# real request. Rewrite both before Apache reads them.
sed -ri "s/^Listen 80$/Listen ${PORT_ACTUAL}/" /etc/apache2/ports.conf
sed -ri "s/<VirtualHost \*:80>/<VirtualHost *:${PORT_ACTUAL}>/" /etc/apache2/sites-available/000-default.conf
if ! grep -q '^ServerName ' /etc/apache2/apache2.conf; then
    echo "ServerName localhost" >> /etc/apache2/apache2.conf
fi

# 2. PHP sized from the cgroup, not from a fixed 512M.
#
# The image ships memory_limit=512M (conf.d/nextcloud.ini) whatever the plan is,
# so a deploy with 8 GB still refuses a large photo-library scan or a
# server-side zip of a big folder. Take 25% of the container limit, floored at
# the upstream default so a small plan is never made worse.
MEM_MAX=""
if [ -r /sys/fs/cgroup/memory.max ]; then
    MEM_MAX="$(cat /sys/fs/cgroup/memory.max)"
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    MEM_MAX="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
fi
case "$MEM_MAX" in
    ''|max|*[!0-9]*) MEM_MB="" ;;
    *) MEM_MB=$(( MEM_MAX / 1048576 )) ;;
esac
if [ -n "$MEM_MB" ] && [ "$MEM_MB" -gt 0 ] 2>/dev/null; then
    PHP_MB=$(( MEM_MB / 4 ))
    [ "$PHP_MB" -lt 512 ] && PHP_MB=512
    # NOT ${PHP_MEMORY_LIMIT:-...}: the base image already sets PHP_MEMORY_LIMIT
    # to 512M in its own ENV, so a :- default would never fire. The deployer's
    # override has its own name.
    PHP_MEMORY_LIMIT="${NEXTCLOUD_PHP_MEMORY_LIMIT:-${PHP_MB}M}"
    export PHP_MEMORY_LIMIT
    OPC_MB=$(( MEM_MB / 16 ))
    [ "$OPC_MB" -lt 128 ] && OPC_MB=128
    [ "$OPC_MB" -gt 512 ] && OPC_MB=512
    PHP_OPCACHE_MEMORY_CONSUMPTION="${NEXTCLOUD_PHP_OPCACHE_MB:-$OPC_MB}"
    export PHP_OPCACHE_MEMORY_CONSUMPTION
fi

# 3. Apache child count sized from the cgroup too.
#
# mpm_prefork's stock MaxRequestWorkers is 150, and every Nextcloud child is a
# full PHP interpreter. 150 x memory_limit is far past any Railway plan, so a
# burst of sync clients gets the container OOM-killed instead of queued.
# (`set --` is deliberately not used to parse cpu.max: it would overwrite the
# positional parameters that carry the image's CMD into the exec below.)
CPU_QUOTA=""
if [ -r /sys/fs/cgroup/cpu.max ]; then
    CPU_QUOTA="$(awk '{ if ($1 != "max" && $2 > 0) printf "%d", ($1 / $2) }' /sys/fs/cgroup/cpu.max 2>/dev/null || true)"
fi
case "$CPU_QUOTA" in
    ''|0|*[!0-9]*) CPU_QUOTA=2 ;;
esac
WORKERS=16
if [ -n "$MEM_MB" ] && [ "$MEM_MB" -gt 0 ] 2>/dev/null; then
    WORKERS=$(( MEM_MB / 96 ))
    [ "$WORKERS" -lt 8 ] && WORKERS=8
    [ "$WORKERS" -gt 150 ] && WORKERS=150
fi
cat > /etc/apache2/conf-available/railway-limits.conf <<EOF
<IfModule mpm_prefork_module>
    StartServers 2
    MinSpareServers 2
    MaxSpareServers 5
    MaxRequestWorkers ${WORKERS}
    MaxConnectionsPerChild 2000
</IfModule>
EOF
a2enconf railway-limits >/dev/null 2>&1 || true

echo "[railway] Nextcloud wrapper: port=${PORT_ACTUAL} php_memory=${PHP_MEMORY_LIMIT:-<image default>} opcache_mb=${PHP_OPCACHE_MEMORY_CONSUMPTION:-<image default>} apache_workers=${WORKERS} cpu_quota=${CPU_QUOTA}"

exec /entrypoint.sh "$@"
