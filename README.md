# php-patcher

Check — and optionally patch — the PHP version (CLI and every PHP-FPM) on all your SSH servers.

For each server it prints the OS and every PHP binary with a status:

- `OK` — at or above the first fixed release of its branch
- `PATCH (fixed in x.y.z)` — below it: upgrade
- `EOL (no PHP fix for 8.1)` — a branch that no longer gets fixes

```text
forge1-nuuzio  Ubuntu 20.04.6 LTS
  php (cli)      8.3.21   PATCH (fixed in 8.3.36)
  php-fpm8.2     8.2.28   PATCH (fixed in 8.2.35)
gandi1-forret
  FAILED  39108@console.sd5.gpaas.net: Permission denied (password,publickey).
```

## Install

```bash
git clone https://github.com/pforret/php-patcher.git
cd php-patcher
./php-patcher.sh install   # symlink in your PATH + bash/zsh completion
```

## Usage

```bash
php-patcher host web1                 # one server
php-patcher host web1,web2,web3       # several servers (comma-separated)
php-patcher file hosts.txt            # one host per line, # comments ok
php-patcher auto                      # every Host in ~/.ssh/config (and its Include files)

php-patcher -l auto                   # only list the hosts that would be used
php-patcher -I forge auto             # only hosts matching a regex (--include forge, no "=")
php-patcher -x 'pi|nas|^old-' auto    # skip hosts matching a regex
php-patcher --pick auto               # choose 1 host from the list (fzf, gum or a numbered menu)

php-patcher --patch host web1         # upgrade PHP packages, restart php-fpm, show versions again
php-patcher -f --patch auto           # patch everything without asking
```

Flags go **before** the verb (`php-patcher --patch auto`, not `php-patcher auto --patch`).

`auto` skips wildcard and negated `Host` patterns, git hosts (github.com, gitlab.com, bitbucket.org, …)
and aliases of a server that is already in the list (same HostName and Port).

The exit code is 1 when one or more hosts failed (ssh error or upgrade error).

## Fixed versions

The OK/PATCH status compares against `--fixed` (default `8.5.12 8.4.27 8.3.36 8.2.35`,
the **expected** releases of 21 Oct 2026). Check them against
<https://www.php.net/archive/2026.php> before trusting the status column, and override them with
`-F "8.5.12 8.4.27 8.3.36 8.2.35"` or in a `.env` file next to the script.
Set `--released` (default `2026-10-21 14:00`, UTC) to when they come out: before that moment the
script warns that no host can get them yet.

```bash
fixed="8.5.12 8.4.27 8.3.36 8.2.35"
released="2026-10-21 14:00"
exclude="pi|nas"
include="forge"
```

## Requirements

- `ssh` and `awk` locally; `fzf` (optional) for `--pick`
- every host name resolves via `~/.ssh/config`, with key-based login (BatchMode, no passwords)
- for `--patch`: `sudo` on the server (without a password, or you get asked for it; with `-f` or
  without a terminal it prints the `ssh -t` command to run yourself), and apt (Debian/Ubuntu, incl. the Ondřej Surý
  packages used by Forge) or dnf/yum (RHEL/Alma/Rocky, Remi)

## Tests

```bash
bats tests/    # offline: fake ssh/fzf and a temporary HOME, no server is contacted
```

Built with [bashew](https://github.com/pforret/bashew).
