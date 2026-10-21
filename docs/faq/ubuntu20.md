# Upgrading Ubuntu 20.04 to 22.04 or 24.04

Ubuntu 20.04 focal left standard support on 2025-05-31. Since then no apt source ships PHP 8.x
for it: Ondřej's PPA serves an empty package list for focal, and `packages.sury.org` and the
`ppa.setup-php.com` mirror have no focal at all (see [ondrej.md](ondrej.md)). On such a server,
`php-patcher --patch` ends with `ERROR: no newer PHP packages: Ubuntu 20.04 has no PHP repository
anymore`, and the only real fix is a newer Ubuntu.

Ubuntu Pro (ESM) keeps 20.04 itself patched until 2030, but it covers the Ubuntu archive only
(PHP 7.4 on focal), not the PHP 8.x packages from Ondřej's PPA.

## Which target?

| Target            | Standard support until | PHP source after the upgrade                          |
|-------------------|------------------------|-------------------------------------------------------|
| 22.04 jammy       | April 2027             | `ppa:ondrej/php` or `packages.sury.org/php`           |
| 24.04 noble       | April 2029             | `ppa:ondrej/php` or `packages.sury.org/php`           |

Go to **24.04**. Stopping at 22.04 only buys time until April 2027, when the PPA will drop jammy
the way it dropped focal.

## Option A: new server, move the sites (recommended)

The safest route, and the usual one on Laravel Forge, which does not upgrade the OS of a server
it manages:

1. Provision a new Ubuntu 24.04 server (with Forge: same PHP versions, database, and so on).
2. Recreate the sites, deploy them from git, copy `.env` files, storage/uploads and cron jobs.
3. Dump the databases on the old server and import them on the new one.
4. Lower the DNS TTL a day before, switch DNS, check the logs, request new TLS certificates.
5. Keep the old server (or a snapshot of it) for a week, then delete it.

Pros: no downtime during the move, a rollback is just a DNS change, the new server is clean.
Cons: more manual work per site, the server gets a new IP address (firewalls, allow-lists, SPF).

## Option B: in-place upgrade 20.04 → 22.04 → 24.04

`do-release-upgrade` only goes from one LTS to the next, so this is **two upgrades** with a reboot
in between. Each takes 15–45 minutes, the sites are down or degraded during it.

### Before you start

```bash
# 1. a backup you can restore: a provider snapshot (DigitalOcean, Gandi, ...) and database dumps
sudo mysqldump --all-databases --single-transaction > ~/all-databases.sql

# 2. note what is installed, to reinstall PHP after the upgrade
dpkg --get-selections | grep -E '^php' | awk '{print $1}' > ~/php-packages.txt
php -m > ~/php-modules.txt

# 3. free disk space (at least 5 GB on /, 300 MB on /boot)
df -h / /boot
sudo apt-get autoremove --purge

# 4. a fully updated 20.04, and a clean apt-get update (see apt.md for dead sources)
sudo apt-get update && sudo apt-get full-upgrade
sudo reboot
```

Also check:

- `/etc/update-manager/release-upgrades` has `Prompt=lts`, otherwise `do-release-upgrade`
  reports `No new release found`.
- Port 1022 is open in the firewall (`sudo ufw allow 1022/tcp`): over SSH, the upgrader starts an
  extra sshd on that port as a fallback in case the main one breaks halfway.
- You have console access through the provider's web panel, in case SSH does not come back.

### Upgrade to 22.04

```bash
sudo do-release-upgrade      # it runs itself inside screen; after a disconnect: sudo screen -x
```

What to answer:

- **Third-party sources disabled**: yes. All PPAs and vendor repositories are commented out
  during the upgrade, you re-add them for the new release afterwards.
- **Modified configuration files** (`sshd_config`, `php.ini`, `my.cnf`, nginx, ...): keep your
  version (`N`, the default) unless you know the new one is better. Diff with `D` if unsure.
- **Remove obsolete packages**: **No**. The PHP 8.x packages came from the PPA that is now
  disabled, so the upgrader sees them as obsolete and would remove PHP and its extensions.
- **Restart services automatically**: yes.

Reboot when asked, then:

```bash
lsb_release -d                           # Ubuntu 22.04.x LTS
sudo add-apt-repository -y ppa:ondrej/php     # or packages.sury.org, see ondrej.md
sudo apt-get update
sudo apt-get install $(cat ~/php-packages.txt)   # rebuilds PHP for jammy
sudo apt-get full-upgrade
```

Check that the sites work before going on.

### Upgrade to 24.04

Same steps once more: `sudo apt-get update && sudo apt-get full-upgrade`, reboot,
`sudo do-release-upgrade`, the same answers, reboot, re-add the PHP source for noble and
reinstall `~/php-packages.txt`.

24.04 uses the deb822 format for apt sources: the Ubuntu archive moves to
`/etc/apt/sources.list.d/ubuntu.sources`, and `add-apt-repository` writes `.sources` files.

### Afterwards

```bash
php-patcher host <server>                # OS 24.04, PHP versions OK or PATCH
php-patcher --patch host <server>        # now finds newer PHP packages
```

Clean up the leftovers: `.distUpgrade` and `.save` files in `/etc/apt/sources.list.d/`, the
`~/php-packages.txt` list, and the port 1022 firewall rule (`sudo ufw delete allow 1022/tcp`).

## What changes between 20.04 and 24.04

| Component     | 20.04        | 22.04        | 24.04        | Watch out for |
|---------------|--------------|--------------|--------------|---------------|
| OpenSSH       | 8.2          | 8.9          | 9.6          | `ssh-rsa` (SHA-1) signatures are refused from 22.04 on: old deploy keys or clients may fail to log in |
| OpenSSL       | 1.1.1        | 3.0          | 3.0          | legacy ciphers and short keys rejected; old TLS client certificates may break |
| MySQL         | 8.0          | 8.0          | 8.0          | none if it comes from Ubuntu; the `repo.mysql.com` source must be re-added for the new release (its old key expired, see apt.md) |
| PostgreSQL    | 12           | 14           | 16           | the old cluster keeps running on the old version: move it with `pg_upgradecluster` |
| Python 3      | 3.8          | 3.10         | 3.12         | pip installs into the system Python are blocked from 24.04 on (`externally-managed-environment`) |
| Node.js       | from nodesource | from nodesource | from nodesource | re-add the nodesource source for the new release |
| Kernel        | 5.4          | 5.15         | 6.8          | custom kernels or DKMS modules need rebuilding |

## When things go wrong

- **`No new release found`**: `Prompt=lts` missing, 20.04 not fully updated, or (for 22.04 → 24.04)
  the server cannot reach `changelogs.ubuntu.com`.
- **Upgrade interrupted**: log in again (port 22 or 1022, or the provider console), then
  `sudo screen -x` to reattach, or finish with `sudo dpkg --configure -a && sudo apt-get -f install`.
- **PHP gone after the upgrade**: you answered yes to removing obsolete packages. Re-add the PHP
  source and `sudo apt-get install $(cat ~/php-packages.txt)`; the configuration in
  `/etc/php/` stays unless the packages were purged.
- **SSH login refused after the upgrade**: an old RSA key or client, see the OpenSSH row above.
  Use the provider console and add an `ed25519` key.
- **Nothing helps**: restore the snapshot and take option A.

## References

- Ubuntu upgrade guide: <https://documentation.ubuntu.com/server/how-to/software/upgrade-your-release/>
- Release cycle and support dates: <https://ubuntu.com/about/release-cycle>
- Ubuntu 22.04 and 24.04 release notes: <https://discourse.ubuntu.com/t/jammy-jellyfish-release-notes/24668>,
  <https://discourse.ubuntu.com/t/noble-numbat-release-notes/39890>
- PHP sources per Ubuntu release: [ondrej.md](ondrej.md), dead apt sources: [apt.md](apt.md)
