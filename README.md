# nextcloud-railway

Railway-tuned wrapper around the official `nextcloud:34.0.2-apache` image, used by the
[Nextcloud Railway template](https://railway.com/templates).

Everything here exists because of something the platform does that the stock image does not
expect. Nothing is a fork: the upstream entrypoint still installs, upgrades and starts the
application, and all of the additions run through the hook directory upstream provides.

## What the wrapper changes

| Area | Stock behaviour on Railway | Here |
|---|---|---|
| Image tag | Listings track `nextcloud` / `nextcloud:apache`, so every redeploy is an unrequested major upgrade — and after two majors the container refuses to boot at all (`/entrypoint.sh:189-195`) | Pinned to `34.0.2` |
| Client address | The container's peer is always Railway's edge, so every request — and every brute-force counter — is attributed to one address | Apache lifts the first `X-Forwarded-For` hop into `X-Real-IP` and `mod_remoteip` trusts `100.64.0.0/10` |
| Background jobs | `backgroundjobs_mode` is unset (`ajax`), i.e. jobs run on page loads only; a sync-client instance never runs them | `cron` mode plus an in-container `cron.php` loop every 5 minutes |
| Admin account | Published blank and required by both competing listings; an empty value makes `occ maintenance:install` fail ten times and `exit 1` | Baked user `admin`, password from `${{secret(24)}}`, re-applied on every boot |
| Redis | Wired up as the PHP session handler only | Also `memcache.distributed` and `memcache.locking` (transactional file locking) |
| PHP | Fixed `memory_limit=512M` and `MaxRequestWorkers 150` whatever the plan size | Both sized from the container's cgroup limits |
| URLs | `overwrite*` unset, so links in share mails and client payloads are `http://` | `overwritehost` / `overwriteprotocol` / `overwrite.cli.url` from `RAILWAY_PUBLIC_DOMAIN` |

## Layout

- `Dockerfile` — pins the base image, installs the Apache config and the hook
- `railway-remoteip.conf` — first-XFF-hop extraction, `mod_remoteip` trust for Railway's CGNAT peer range
- `railway-entrypoint.sh` — `$PORT`, PHP and Apache sizing; execs upstream's entrypoint
- `hooks/before-starting/10-railway.sh` — everything that needs `occ`, run after the install and
  before Apache binds a port

## Environment

Set by the template; all optional here except the database.

| Variable | Meaning |
|---|---|
| `POSTGRES_HOST` / `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | Database, as upstream |
| `REDIS_HOST` / `REDIS_HOST_PORT` / `REDIS_HOST_PASSWORD` | Enables the Redis cache and lock backend |
| `NEXTCLOUD_ADMIN_PASSWORD` | Admin password; re-applied on every boot |
| `NEXTCLOUD_ADMIN_USER` | Defaults to `admin` |
| `NEXTCLOUD_CRON_INTERVAL` | Seconds between `cron.php` runs (default `300`) |
| `NEXTCLOUD_DEFAULT_PHONE_REGION` | Two-letter region for phone-number parsing (default `US`) |

## Licence

The wrapper scripts are MIT. Nextcloud itself is AGPL-3.0 and unmodified here.
