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

### Scripted: upgrade-ubuntu.sh

[`upgrade-ubuntu.sh`](../../upgrade-ubuntu.sh) runs the steps of this section over SSH, one verb
per stage. It never reboots and never runs `do-release-upgrade` by itself: those stay with you, in
your own terminal. Every verb ends with `STATUS: <OK|READY|DONE|BLOCKED|FAILED|NEEDS-ADMIN> ...`
and `NEXT: <command>` (exit code 0, 1 or 3), and saves its output in
`~/log/upgrade-ubuntu/<host>/<timestamp>.<verb>.log`.

```bash
./upgrade-ubuntu.sh password myhost      # once, in your terminal (see below)
./upgrade-ubuntu.sh status myhost        # read-only: which stage, what is next (run it any time)
./upgrade-ubuntu.sh nginx-down myhost    # stop + mask nginx: the sites stay offline across both hops
./upgrade-ubuntu.sh preflight myhost     # read-only: READY or BLOCKED, with the reason
#   take a provider snapshot now (DigitalOcean: Droplet → Snapshots)
./upgrade-ubuntu.sh prepare myhost       # backups, DB dump (also copied to your machine), mirror fix, full-upgrade
ssh -t myhost sudo reboot
./upgrade-ubuntu.sh upgrade myhost       # in your terminal: do-release-upgrade inside screen
#   reconnect after a drop: ssh -t myhost sudo screen -x upgrade
./upgrade-ubuntu.sh logs myhost          # the upgrader's logs, errors first
./upgrade-ubuntu.sh postflight myhost    # after the reboot: ppa:ondrej/php, reinstall PHP, restart services
#   on 22.04: preflight, prepare, reboot, upgrade, postflight once more for 24.04
./php-patcher.sh host myhost             # every PHP line OK? else --patch
./upgrade-ubuntu.sh nginx-up myhost
./upgrade-ubuntu.sh verify myhost        # OS, kernel, PHP vs --fixed, services, every site over HTTPS
./upgrade-ubuntu.sh cleanup myhost       # port 1022, *.distUpgrade/*.save, the stored password
```

Useful flags (before the verb): `--target jammy` to stop after one hop, `--no_dump` when there is no
MySQL (or you dump yourself), `--drop_php 7.4` to not reinstall an old PHP branch, `--disable
site1,site2` to switch off sites (nginx, crontab, supervisor) during postflight, `-f` to skip the
y/N question.

**The sudo password**: `password` asks for it once, checks it with `sudo -k -S true` on the server
and stores it AES-256 encrypted in `~/.config/upgrade-ubuntu/<host>.pw.enc`. The key is in the
macOS Keychain (on Linux: `~/.config/upgrade-ubuntu/.key`, 0600). Every sudo verb gives it to sudo
on stdin, so it never shows up in a command line or a log. `forget` deletes it, and the last
`cleanup` does too.

**Oracle MySQL**: postflight stops with `NEEDS-ADMIN` until `mysql.list` points to the new
release; run `ssh -t <host> sudo dpkg-reconfigure mysql-apt-config` and pick the new release and the
same MySQL series.

**If `prepare` cannot dump the databases** (`Access denied` for root): create `/root/.my.cnf` with
`[client]`, `user=root` and the password from the Forge provisioning e-mail, `chmod 600` it, or re-run with `--no_dump`.

### With Claude Code

The script is made to be run by an admin with Claude Code alongside:

- **You** run the steps that need a terminal: `password`, `upgrade` (the `do-release-upgrade`
  prompts), the reboots, and `dpkg-reconfigure mysql-apt-config`. Paste anything unexpected into
  the chat, especially the remove list you get with `d` before the upgrade starts.
- **Claude** can run the other verbs through its Bash tool once the password is stored (with `-f`;
  your permission prompt is the confirmation), reads the logs in `~/log/upgrade-ubuntu/<host>/`,
  and follows the `STATUS:`/`NEXT:` lines. `status` tells it where things stand after a break.
- A `NEEDS-ADMIN` status means the next step is yours; `BLOCKED` means fix the reason first.

### Before you start

```bash
# 1. a backup you can restore: a provider snapshot (DigitalOcean, Gandi, ...) and database dumps
sudo mysqldump --all-databases --single-transaction > ~/all-databases.sql
chmod 600 ~/all-databases.sql          # it holds every database, including the user hashes

# 2. note what is installed, to reinstall PHP after the upgrade
dpkg --get-selections | grep -E '^php' | awk '{print $1}' > ~/php-packages.txt
php -m > ~/php-modules.txt
cat ~/php-packages.txt                 # must not be empty

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
- Where MySQL comes from: `dpkg -l | grep -E 'mysql-(community-)?server'`. Ubuntu's
  `mysql-server-8.0` needs no attention. Oracle's `mysql-community-server` (from `repo.mysql.com`,
  common on Forge servers) loses its source during the upgrade, see the summary step below.
  Oracle 8.4 or 9.x has no Ubuntu equivalent: a swap to Ubuntu's 8.0 would be a downgrade
  that cannot start on the existing data directory.

### DigitalOcean: replace the mirror first

DigitalOcean droplets use `mirrors.digitalocean.com` in `/etc/apt/sources.list`. The upgrader does
not know that mirror: it disables those lines instead of rewriting them to the new release, finds no
Ubuntu archive left, and aborts with

```
the essential package 'ubuntu-minimal' could not be located
```

`/var/log/dist-upgrade/main.log` then shows `was disabled (unknown mirror)` for each line. Nothing
is changed on the server, but switch to the official archive before (re)trying:

```bash
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
sudo sed -i 's|http://mirrors.digitalocean.com/ubuntu|http://archive.ubuntu.com/ubuntu|g' /etc/apt/sources.list
sudo apt-get update
```

If `apt-get update` now warns `Target ... is configured multiple times in /etc/apt/sources.list:22
and /etc/apt/sources.list:58`, a line that already pointed at `archive.ubuntu.com` now duplicates a
renamed one: check it with `sed -n '58p' /etc/apt/sources.list` and comment it out.

To list the active sources, use `grep -h '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list`:
a recursive `grep -r` also reads the `.save` and `.distUpgrade` backups, which apt ignores.

### Upgrade to 22.04

```bash
sudo do-release-upgrade      # it runs itself inside screen; after a disconnect: sudo screen -x
```

What to answer:

- **Third-party sources disabled**: yes. All PPAs and vendor repositories are commented out
  during the upgrade, you re-add them for the new release afterwards.
- **Do you want to start the upgrade? y/N/d**: press `d` first and read the remove list.
  `mysql-community-*` or `php*` packages in it mean trouble: answer `N` (nothing has changed
  yet) and sort that out first. These removals are normal:
  - renamed or replaced libraries: `libgcc1` (now `libgcc-s1`), `fuse` (now `fuse3`),
    `libsemanage1`, `libsepol1-dev`, `libtss2-esys0`;
  - desktop leftovers: `gir1.2-mutter-6`, `libmutter-6-0`, `libwacom2`, `libgupnp-*`,
    `python3-twisted-bin`;
  - development headers such as `libmagickwand-dev`, `libcairo2-dev`, `librsvg2-dev`,
    `libfreetype-dev`, `libfontconfig1-dev`, `libwmf-dev`, and `libappindicator3-1`. They were
    installed to compile `imagick` with pecl, the Node `canvas` module, or for Chrome/Puppeteer
    (Browsershot). The runtime libraries stay; note the list and reinstall the headers afterwards
    if something still needs compiling.
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

With Oracle's MySQL, check it runs, then point its source at the new release:

```bash
systemctl status mysql
mysql --version
sudo dpkg-reconfigure mysql-apt-config        # pick jammy and the same MySQL series
sudo apt-get update
```

If MySQL does not start, do not delete `/var/lib/mysql` or force an upgrade: read
`sudo journalctl -u mysql -n 50` first; the dump and the snapshot are the fallback.

Re-enable the other third-party sources the upgrader commented out (`# disabled on upgrade to
jammy`) in `/etc/apt/sources.list.d/`. Sources with `nodistro` or no release in the URL (nodesource,
DigitalOcean agents) only need the line uncommented. If needed, reinstall the development headers that
were removed:

```bash
sudo apt-get install libmagickwand-dev libcairo2-dev librsvg2-dev libfreetype-dev libfontconfig1-dev
```

Check that the sites work before going on.

### Upgrade to 24.04

Same steps once more: `sudo apt-get update && sudo apt-get full-upgrade`, reboot,
`sudo do-release-upgrade`, the same answers, reboot, re-add the PHP source for noble and
reinstall `~/php-packages.txt`, then `sudo dpkg-reconfigure mysql-apt-config` for noble.
On DigitalOcean, first check that `mirrors.digitalocean.com` has not come back in the sources.

24.04 uses the deb822 format for apt sources: the Ubuntu archive moves to
`/etc/apt/sources.list.d/ubuntu.sources`, and `add-apt-repository` writes `.sources` files.

### Afterwards

```bash
php-patcher host <server>                # OS 24.04, PHP versions OK or PATCH
php-patcher --patch host <server>        # now finds newer PHP packages
```

Clean up the leftovers: `.distUpgrade` and `.save` files in `/etc/apt/sources.list.d/`, the
`~/php-packages.txt` list, `~/all-databases.sql`, `/etc/apt/sources.list.bak`, and the port 1022
firewall rule (`sudo ufw delete allow 1022/tcp`).

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
- **`the essential package 'ubuntu-minimal' could not be located`**: the Ubuntu mirror is unknown
  to the upgrader (DigitalOcean's, or another provider's) and was disabled. See
  [DigitalOcean: replace the mirror first](#digitalocean-replace-the-mirror-first). Details are in
  `/var/log/dist-upgrade/main.log`.
- **`Failure restarting some services for GNU libc upgrade: mysql`** during the upgrade: click OK
  and let it finish. The journal shows `status=217/USER` / `Failed to determine user credentials`:
  halfway through the libc upgrade, systemd cannot look up the `mysql` user. It is temporary,
  `sudo systemctl start mysql` (or the reboot) brings it back.
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
