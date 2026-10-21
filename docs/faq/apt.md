# Obsolete apt sources

Third-party apt sources (PPAs, vendor repositories) die: the vendor drops your Ubuntu release,
retires a product version, or rotates its signing key. One dead source makes `apt-get update`
fail as a whole, and that blocks unattended security updates and scripts that stop on the first
error.

Since 2026-10-21, `php-patcher --patch` carries on after a failed `apt-get update` with a WARNING
and upgrades from the sources that did work. Still fix the server, so that its other packages get
updates again.

For Ondřej's PHP/nginx/apache2 repositories specifically, see [ondrej.md](ondrej.md).

## Find the culprit

```bash
sudo apt-get update 2>&1 | grep -E '^(E|W):'
grep -rl 'nodesource' /etc/apt/sources.list /etc/apt/sources.list.d/   # which file holds a URL
```

Sources live in `/etc/apt/sources.list`, `/etc/apt/sources.list.d/*.list` (one-line format) and
`/etc/apt/sources.list.d/*.sources` (deb822 format, the default since Ubuntu 24.04).

## Disable a source

apt only reads files ending in `.list` or `.sources`, so renaming is a clean, reversible fix:

```bash
cd /etc/apt/sources.list.d
sudo mv nodesource.list nodesource.list.disabled
sudo apt-get update
```

For a `.sources` file you can also add `Enabled: no` to its stanza. Files ending in `.save` are
backups made by `add-apt-repository`. apt ignores them, so they can stay.

Disabling a source never removes packages: what was installed from it keeps working, it only
stops getting updates. `apt-cache policy <package>` shows which source (if any) still offers it.

## The errors, one by one

### `403 Forbidden` and `is no longer signed`

```
E: Failed to fetch https://ppa.launchpadcontent.net/ondrej/nginx/ubuntu/dists/jammy/InRelease  403  Forbidden
E: The repository 'https://ppa.launchpadcontent.net/ondrej/nginx/ubuntu jammy InRelease' is no longer signed.
```

The repository was removed or closed (here: the `ondrej/nginx` PPA, see [ondrej.md](ondrej.md)).
"No longer signed" is just the follow-up: apt has no signed index anymore. Disable the source.

### `does not have a Release file` / `no longer has a Release file` (404)

```
E: The repository 'https://deb.nodesource.com/node_18.x jammy Release' no longer has a Release file.
```

The vendor dropped that version or that Ubuntu release. Seen on our servers:

| Source                                   | What happened                                   | Fix |
|------------------------------------------|-------------------------------------------------|-----|
| `deb.nodesource.com/node_18.x jammy`     | Node 18 is EOL, its repository is gone (404)    | disable; if Node is still needed, add NodeSource for Node 22 (`node_22.x nodistro main`) |
| `ppa.setup-php.com/ondrej/php focal`     | PHP mirror, 404 for Ubuntu 20.04                | disable; focal needs an OS upgrade for newer PHP |
| `archive.ubuntu.com` for a non-LTS release that reached end of life | moved to `old-releases.ubuntu.com` | switch the URL to `old-releases.ubuntu.com`, then upgrade the OS |

### `503 Service Unavailable` (W:, not E:)

```
W: Failed to fetch https://ppa.launchpadcontent.net/ubuntuhandbook1/ffmpeg9/ubuntu/dists/noble/InRelease  503  Service Unavailable
W: Some index files failed to download. They have been ignored, or old ones used instead.
```

Not a dead source: the server is temporarily overloaded or down. All Ubuntu PPAs share
`ppa.launchpadcontent.net`, so this hits every PPA at once, Ondřej's PHP PPA included. It
happened on 2026-10-21 right after a PHP security release. apt keeps the package lists it had and
carries on (hence `W:`). Don't disable the source: wait and run `apt-get update` again later.

### `EXPKEYSIG`, `NO_PUBKEY`, `The following signatures were invalid`

```
W: GPG error: http://repo.mysql.com/apt/ubuntu focal InRelease: The following signatures were invalid: EXPKEYSIG B7B3B788A8D3785C MySQL Release Engineering
```

The signing key expired (MySQL's `B7B3B788A8D3785C` expired on 2025-10-22) or was rotated. Either
install the vendor's new key (usually a `*-keyring` package or a `.gpg`/`.asc` download into
`/etc/apt/keyrings/` or `/usr/share/keyrings/`, referenced with `[signed-by=...]` in the source
line), or disable the source if you no longer need it. `apt-key` is deprecated: don't add new keys
with it.

### `Release file ... is expired` / `is not valid yet`

The `Valid-Until` date in the repository's index lies in the past (abandoned repository) or the
server clock is wrong. Check `timedatectl` first, then treat the source as dead.

### No error at all, but nothing gets upgraded

The worst kind: the repository still answers, but has stopped publishing for your release. For
example, Ondřej's PHP PPA still serves an index for Ubuntu 20.04, but it contains 0 packages. You
only notice because versions never move:

```bash
apt-cache policy php8.3-fpm     # "Installed" stays the newest "Candidate", with only the local /var/lib/dpkg/status as source
```

`php-patcher --patch` reports this as `ERROR: no newer PHP packages ...`: on Ubuntu 20.04 "has no PHP repository anymore", elsewhere "in the package sources yet".

## Related: `Unmet dependencies` after an interrupted upgrade

Not an obsolete source, but it shows up in the same runs:

```
E: Unmet dependencies. Try 'apt --fix-broken install' with no packages (or specify a solution).
 vim : Depends: vim-runtime (= 2:8.2.3995-1ubuntu2.29) but 2:8.2.3995-1ubuntu2.28 is to be installed
```

An earlier apt run (often unattended-upgrades) stopped halfway. `dpkg -l | grep -v '^ii'` shows
the half-done packages (`iU` = unpacked but not configured). apt refuses to install anything else
until they are repaired. That also means the server has silently stopped getting security
updates: on forge3, 214 packages were waiting.

```bash
sudo apt-get -s -f install       # dry run: shows what the repair would do, needs no root
sudo dpkg --configure -a
sudo apt-get -f install
sudo apt-get upgrade             # catch up on everything that was blocked
```

## Checking a server without sudo

```bash
ssh server 'ls /etc/apt/sources.list.d/; apt-get -s upgrade | tail -1; dpkg -l | grep -v "^ii" | tail -n +6'
```
