# Do it yourself: check and patch PHP by hand

`php-patcher` only automates what is on this page. If you'd rather not run a 1,700-line script,
these are the few commands it boils down to. Run them on each server yourself (or prefix each with
`ssh <server> '...'`). Nothing here needs more than the standard tools of each OS.

## 1. Check

### Which PHP is installed?

A server often has **more than one PHP**: the command-line `php`, one `php-fpm` per version
that serves the websites, and sometimes Apache's `mod_php`. Check all of them, because the CLI
version says nothing about what your sites run on.

**Linux** (Ubuntu/Debian, Forge, RHEL/Alma/Rocky):

```bash
php -v                                              # command-line PHP
for b in /usr/sbin/php*fpm*; do "$b" -v | head -1; done  # PHP-FPM, one per version
ls /etc/apache2/mods-enabled/php*.load 2>/dev/null  # Apache mod_php, if any
. /etc/os-release && echo "$PRETTY_NAME"            # the OS release decides which PHP you can get
```

**macOS** (Homebrew, Laravel Valet):

```bash
which -a php && php -v
brew list --versions | grep -E '^php'               # every Homebrew PHP
```

Laravel Herd and MAMP ship their own PHP: check the version in their app window.

**Windows** (PowerShell):

```powershell
where.exe php
php -v
```

XAMPP, Laragon and WampServer have their own PHP folder (e.g. `C:\xampp\php\php.exe -v`).

### What is the latest release?

Look at <https://www.php.net/downloads> or <https://www.php.net/supported-versions.php>, or ask
php.net for the newest release of one branch:

```bash
curl -s 'https://www.php.net/releases/index.php?json&version=8.3' | grep -o '"version":"[^"]*"'
```

```powershell
(Invoke-RestMethod 'https://www.php.net/releases/index.php?json&version=8.3').version
```

Compare it with what you found:

- **Same version:** you are up to date.
- **Lower patch number** (8.3.21 vs 8.3.35): patch it, see below.
- **Branch not listed as supported** (8.1 or older): it gets no more security fixes at all. Plan
  an upgrade to a newer branch, which is a code change, not a patch.

On Ubuntu/Debian, the version from `php -v` can carry a distro suffix such as `7.4.3-4ubuntu2.29`.
Those packages come from Ubuntu itself and get security fixes backported without changing the
`7.4.3` part, so comparing with php.net says little. Check them with `apt list --upgradable` instead.

## 2. Patch

A patch upgrade (8.3.21 → 8.3.35) stays on the same branch: no code changes, no config
migration. It does restart PHP, which drops the requests that are running at that moment.

### Ubuntu / Debian (incl. Laravel Forge)

```bash
sudo apt-get update
apt list --upgradable 2>/dev/null | grep -i php     # what will change
sudo apt-get install --only-upgrade $(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'php*' | awk '$1=="ii"{print $2}')
sudo systemctl restart 'php*-fpm'                   # every PHP-FPM version
sudo systemctl reload apache2                       # only if you use Apache mod_php
php -v                                              # check again
```

`--only-upgrade` upgrades the PHP packages that are already installed and installs nothing new.
`apt-get upgrade` would also work, but upgrades everything on the server.

**If this does not get you a newer PHP:**

- **No newer version is offered at all:** your OS release may have lost its PHP repository.
  Ubuntu 20.04, for example, gets no more PHP 8.x. See [faq/ondrej.md](faq/ondrej.md).
- **`apt-get update` shows `E:` lines, or apt says `Unmet dependencies`:** see [faq/apt.md](faq/apt.md).
- **A release came out today:** the packages usually follow some hours after php.net.

### RHEL / AlmaLinux / Rocky / Fedora

```bash
sudo dnf check-update 'php*'
sudo dnf upgrade 'php*'
sudo systemctl restart php-fpm
php -v
```

With Remi's repository and several PHP versions side by side (`php83-php-fpm`, ...), restart each
of them: `systemctl list-units 'php*fpm*'`.

### macOS (Homebrew)

```bash
brew update
brew upgrade php            # or: brew upgrade php@8.3
brew services restart php   # only if PHP runs as a service (php-fpm)
php -v
```

With Laravel Valet, finish with `valet restart`. Laravel Herd updates its PHP versions from its own
settings window.

### Windows

The upgrade depends on how PHP was installed:

- **winget:** `winget upgrade --id <ID>` (find the ID with `winget list php`).
- **Scoop:** `scoop update php` (or `php83` from the `versions` bucket).
- **Chocolatey:** `choco upgrade php`.
- **Zip from windows.php.net:**
  1. Download the newer zip of the same branch and the same build (Thread Safe or Non Thread Safe, x64).
  2. Unpack it over a copy of your PHP folder, keeping your `php.ini` and any extra extension DLLs.
  3. Switch the folder.
- **XAMPP, Laragon, WampServer:** use their own update, or replace their `php` folder as for the zip.

Then restart whatever runs PHP (IIS: `iisreset`, Apache: restart the service) and check `php -v`.

### Docker

The PHP version is part of the image: pull the newer image and rebuild your own on top of it.

```bash
docker pull php:8.3-fpm
docker compose build --pull && docker compose up -d
docker compose exec <service> php -v
```

## After patching

Run the checks from step 1 again. The website PHP (php-fpm, mod_php) must show the new version,
not just `php -v`. If you can, open a page of the site, or a `phpinfo()` page you delete right
after.
