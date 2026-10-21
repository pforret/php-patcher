# Ondřej Surý's repositories (PHP, nginx, apache2)

Ondřej Surý maintains the PHP packages in Debian, and publishes newer PHP (and nginx/apache2)
builds for Ubuntu as Launchpad PPAs. Laravel Forge installs PHP from `ppa:ondrej/php`, so on a
Forge server **every PHP security fix arrives through that PPA**. When the PPA stops serving your
Ubuntu release, `php-patcher --patch` can no longer bring PHP up to date.

For problems with other dead apt sources (nodesource, MySQL keys, ...), see [apt.md](apt.md).

## Status (checked 2026-10-21)

| Source                                 | Ubuntu 20.04 focal                  | 22.04 jammy                    | 24.04 noble                    |
|----------------------------------------|-------------------------------------|--------------------------------|--------------------------------|
| `ppa:ondrej/php` (launchpadcontent)    | index served, **0 packages**, frozen since 2025-06-09 | active (8.3.35, 2026-10-12) | active (8.3.35, 2026-10-12) |
| `ppa:ondrej/apache2`                   | index served, **0 packages**        | active                         | active                         |
| `ppa:ondrej/nginx`, `ondrej/nginx-mainline` | **403 Forbidden**              | **403 Forbidden**              | **403 Forbidden**              |
| `packages.sury.org/php`                | 404 (no focal)                      | available                      | available                      |
| `ppa.setup-php.com` (mirror of the PPA) | 404                                | up to date (8.3.36 at 18:12 UTC) | up to date (8.3.36 at 18:12 UTC) |

`packages.sury.org/php` also serves Ubuntu 26.04 `resolute` and Debian `bullseye`, `bookworm`, `trixie`.

The PHP PPA description says it **is being merged into `packages.sury.org/php`**: for Ubuntu
26.04 that repository is already the canonical source, for older releases a migration path is
announced "in the upcoming weeks", and jammy and noble can keep using the PPA for now.

Forge servers use one of two source files for the same packages:

- `ondrej-ubuntu-php-<release>.list`: the Launchpad PPA itself (`ppa.launchpadcontent.net`), on older servers
- `ondrej-php.list`: the `ppa.setup-php.com` mirror (with `/usr/share/keyrings/ondrej-php.gpg`), on newer servers

**On 2026-10-21, the day of a PHP security release, `ppa.launchpadcontent.net` mostly answered
`503 Service Unavailable`.** At 19:00 UTC, `packages.sury.org` served 8.4.27 and 8.3.36 for jammy
and noble, and so did the `ppa.setup-php.com` mirror (since 18:12 UTC). Servers on the Launchpad
PPA could not get them. For those, moving is recommended, see
[Moving to packages.sury.org](#moving-to-packagessuryorg).

The PPA only builds for Ubuntu LTS releases that are still in standard support. Expect jammy to
be dropped when its standard support ends (April 2027), the way focal was in 2025.

## Symptoms and fixes

### `403 Forbidden` + `is no longer signed` for `ondrej/nginx`

```
E: Failed to fetch https://ppa.launchpadcontent.net/ondrej/nginx/ubuntu/dists/jammy/InRelease  403  Forbidden
E: The repository 'https://ppa.launchpadcontent.net/ondrej/nginx/ubuntu jammy InRelease' is no longer signed.
```

The nginx PPA is gone (the Launchpad API returns 404 for it), for every Ubuntu release. The
second line is only apt's follow-up to the 403. `apt-get update` fails as a whole, which also
blocks scripts that stop on the first error.

Fix: disable the source. nginx stays installed and keeps running, it just gets no more updates
from that PPA.

```bash
cd /etc/apt/sources.list.d
ls ondrej-ubuntu-nginx-*                     # e.g. ondrej-ubuntu-nginx-jammy.list
sudo mv ondrej-ubuntu-nginx-jammy.list ondrej-ubuntu-nginx-jammy.list.disabled
sudo apt-get update                          # should now be clean (for this source)
```

For nginx updates afterwards, use Ubuntu's own `nginx` package or the official nginx.org repository.
`apt-cache policy nginx` shows which version each source offers.

### `503 Service Unavailable` for `ondrej/php`

```
W: Failed to fetch https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/noble/InRelease  503  Service Unavailable
```

Launchpad is overloaded or down (it serves every PPA, so other PPAs show the same). apt keeps its
old package lists, so you don't get the new PHP. You can wait and retry, or
[move to packages.sury.org](#moving-to-packagessuryorg), which is where the PPA is going anyway.

### Ubuntu 20.04: no errors, but no newer PHP either

On focal, the launchpad PPA still answers, but its package list is empty, so `apt-get update` is
clean and `apt-get install --only-upgrade php8.3-fpm` silently does nothing. Some servers were
switched to the `ppa.setup-php.com` mirror, which now returns 404 for focal.

`php-patcher` warns about this for Ubuntu 20.04 and older, and a `--patch` run ends with
`ERROR: no newer PHP packages: Ubuntu 20.04 has no PHP repository anymore`.

Fix: there is no apt source left for PHP 8.x on focal. Move the sites to a new Ubuntu 24.04 server
(easiest with Forge), or upgrade in place 20.04 → 22.04 → 24.04, see [ubuntu20.md](ubuntu20.md). Going to 22.04 only buys time
until April 2027.

Building PHP from source or running it in Docker also works, but takes the server out of Forge's
normal PHP management.

### A PHP release is out, but apt does not have it yet

php.net publishes a release (e.g. 8.3.36 on 2026-10-21 at 14:00 UTC), and the PPA builds follow
**some hours later**. Until then, `--patch` can only reach the previous patch release and the host
stays `PATCH`. `php-patcher` warns about this while the current time is before `--released`.

Check what the PPA offers right now:

```bash
apt-cache policy php8.3-fpm                  # on the server, after apt-get update
```

Or without a server:

```bash
curl -s https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/noble/main/binary-amd64/Packages.gz |
  gunzip | awk '/^Package: php8.3-fpm$/{p=1} p&&/^Version/{print $2; p=0}' | sort -V | tail -1
```

### Signing key errors (`NO_PUBKEY`, `EXPKEYSIG`)

The PHP PPA is signed with key `B8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6` (fingerprint from the
Launchpad API). Re-adding the PPA fetches the current key:

```bash
sudo add-apt-repository -y ppa:ondrej/php
```

`packages.sury.org` uses its own keyring package instead (`debsuryorg-archive-keyring`, installed
to `/usr/share/keyrings/debsuryorg-archive-keyring.gpg`), see <https://packages.sury.org/php/README.txt>.

## Moving to packages.sury.org

For Ubuntu 22.04 jammy and 24.04 noble (and 26.04, where it is the only source). Not for 20.04:
sury.org has no focal. The PPA says it is being merged into this repository, and on release day it
was reachable and up to date when the PPA was not.

The recipe ([suggested on r/PHP](https://www.reddit.com/r/PHP/comments/1xbno6r/comment/pi0mpvo/)
for the 503s on release day) is: remove the PPA source, run sury.org's install script, update.
Its `rm ondrej-ubuntu-php-*.list` misses Forge's `ondrej-php.list` (the mirror), so here are the same
steps for both file names, with the script read before it runs:

```bash
curl -fsSL https://packages.sury.org/php/README.txt -o /tmp/sury-php.sh
cat /tmp/sury-php.sh                 # 13 lines: installs the sury keyring, writes /etc/apt/sources.list.d/php.list
cd /etc/apt/sources.list.d
for f in ondrej-php.list ondrej-ubuntu-php-*.list; do [ -e "$f" ] && sudo mv "$f" "$f.disabled"; done
sudo sh /tmp/sury-php.sh             # ends with apt-get update
apt-cache policy php8.4-fpm          # candidate now from packages.sury.org
```

Then patch as usual (`php-patcher --patch host <server>`, or [DIY.md](../DIY.md)). Renaming
(`.disabled`) instead of deleting keeps the way back open:

```bash
sudo rm /etc/apt/sources.list.d/php.list
for f in /etc/apt/sources.list.d/ondrej-php.list.disabled /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list.disabled; do
  [ -e "$f" ] && sudo mv "$f" "${f%.disabled}"
done
sudo apt-get update
```

Good to know:

- Package names stay the same (`php8.4-fpm`, ...), only the version suffix changes: PPA builds
  end in `+ubuntu24.04.1+deb.sury.org+1`, sury.org builds in `+0~20261021.57+ubuntu24.04~1...`.
  apt sees the PPA build of the same PHP version as slightly newer, so it doesn't "downgrade" you.
  The switch takes effect at the next PHP release.
- On the `ppa.setup-php.com` mirror there is less reason to move today: it was up to date on
  release day. It mirrors the PPA, though, so it will follow the PPA when that is retired.
- Forge adds `ppa:ondrej/php` again when you install another PHP version from its dashboard.
  Having both sources is harmless, but then the PPA's 503s show up again: disable it again after that.
- php-patcher prints a `TIP:` line pointing here when a host on the PPA (or its mirror) does not reach `--fixed`.

## Links

- PPA: <https://launchpad.net/~ondrej/+archive/ubuntu/php>
- Repository: <https://packages.sury.org/php/>
- Issue tracker: <https://deb.sury.org/#bug-reporting>
