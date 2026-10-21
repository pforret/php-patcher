#!/usr/bin/env bash
# Show the PHP version (CLI and every PHP-FPM) on a list of servers over SSH,
# and with --upgrade upgrade the installed PHP packages, restart FPM and show the new version.
#
#   tools/php_hosts.sh web1 web2 client-vps          # show versions
#   tools/php_hosts.sh -f hosts.txt                  # host names from a file, one per line (# comments ok)
#   tools/php_hosts.sh --upgrade web1 web2           # apt/dnf upgrade of php packages, restart FPM, show again
#   tools/php_hosts.sh --all [-x REGEX] [--yes]      # every Host in ~/.ssh/config (and its Include files)
#
# --all skips wildcard/negated Host patterns and git hosts (github.com, gitlab.com, bitbucket.org, ...);
# -x REGEX skips more (e.g. -x 'pi|nas|^old-'). --all with --upgrade asks for confirmation unless --yes.
# --all also skips aliases of a server already in the list (same HostName and Port, via ssh -G).
# --list prints the selected hosts and exits (dry run).
# Assumes ~/.ssh/config resolves each name and that the remote user has passwordless sudo (for --upgrade).
# Debian/Ubuntu (apt, incl. the Ondřej Surý packages used by Forge) and RHEL/Alma/Rocky (dnf/yum, Remi).
#
# Status per version: OK (at or above the fixed release of its branch), PATCH (below it), EOL (8.1 or older).
# PHP_FIXED overrides the fixed releases. The defaults are the EXPECTED 21 Oct 2026 versions:
# check them against https://www.php.net/archive/2026.php before trusting the OK/PATCH column.
set -uo pipefail

PHP_FIXED="${PHP_FIXED:-8.5.12 8.4.27 8.3.36 8.2.35}"
upgrade=0
all=0
yes=0
list=0
exclude=""
hosts=()
GIT_HOSTS='^(github\.com|gitlab\.com|bitbucket\.org|ssh\.dev\.azure\.com|codeberg\.org|ssh\.github\.com)$'

# ssh_config_hosts <file>: print the Host names of an ssh config, following Include (relative to ~/.ssh)
ssh_config_hosts() {
  local f=$1 line inc
  [[ -r $f ]] || return 0
  while IFS= read -r line; do
    if [[ $line == INCLUDE\ * ]]; then
      for inc in ${line#INCLUDE }; do
        inc=${inc/#\~/$HOME}; [[ $inc == /* ]] || inc="$HOME/.ssh/$inc"
        for f in $inc; do ssh_config_hosts "$f"; done   # unquoted: Include allows globs
      done
    else
      echo "$line"
    fi
  done < <(awk 'tolower($1)=="host"{for(i=2;i<=NF;i++) print $i}
                tolower($1)=="include"{$1=""; print "INCLUDE" $0}' "$f")
}

usage() { awk 'NR>1 && /^#/{sub(/^# ?/, ""); print; next} NR>1{exit}' "$0"; exit "${1:-0}"; }

while (($#)); do
  case "$1" in
    --upgrade) upgrade=1 ;;
    --all) all=1 ;;
    --yes|-y) yes=1 ;;
    --list) list=1 ;;
    -x) shift; exclude="${1:?-x needs a regex}" ;;
    -f) shift; [[ -r "${1:-}" ]] || { echo "cannot read host file '${1:-}'" >&2; exit 1; }
        while read -r h _; do [[ -n "$h" && "$h" != \#* ]] && hosts+=("$h"); done < "$1" ;;
    -h|--help) usage ;;
    -*) echo "unknown option $1" >&2; usage 1 ;;
    *) hosts+=("$1") ;;
  esac
  shift
done
if ((all)); then
  seen=" "
  while read -r h; do
    [[ $h == *[\*\?]* || $h == \!* ]] && continue
    [[ $h =~ $GIT_HOSTS ]] && continue
    [[ -n $exclude && $h =~ $exclude ]] && continue
    target=$(ssh -n -G -F "$HOME/.ssh/config" "$h" 2>/dev/null | awk '$1=="hostname"{h=$2} $1=="port"{p=$2} END{print h ":" p}')
    [[ $seen == *" $target "* ]] && continue
    seen+="$target "
    hosts+=("$h")
  done < <(ssh_config_hosts "$HOME/.ssh/config" | awk '!seen[$0]++')
fi
((${#hosts[@]})) || { echo "no hosts given or found" >&2; usage 1; }

if ((list)); then printf '%s\n' "${hosts[@]}"; exit 0; fi

if ((all && upgrade && !yes)); then
  echo "Upgrade PHP on ${#hosts[@]} hosts: ${hosts[*]}"
  read -r -p "Continue? [y/N] " answer </dev/tty
  [[ $answer == [yY]* ]] || exit 1
fi

# Runs on the remote host: bash -s -- <upgrade 0|1> <fixed versions...>
remote_script=$(cat <<'REMOTE'
upgrade=$1; shift; fixed="$*"
shopt -s nullglob

status() {  # status <version>
  local v=$1 branch=${1%.*} f
  for f in $fixed; do
    if [[ ${f%.*} == "$branch" ]]; then
      [[ $(printf '%s\n%s\n' "$f" "$v" | sort -V | head -1) == "$f" ]] && echo OK || echo "PATCH (fixed in $f)"
      return
    fi
  done
  echo "EOL (no PHP fix for $branch)"
}

show() {
  local b v found=0
  if command -v php >/dev/null; then
    v=$(php -r 'echo PHP_VERSION;' 2>/dev/null); printf '  %-14s %-8s %s\n' "php (cli)" "$v" "$(status "$v")"; found=1
  fi
  for b in /usr/sbin/php-fpm* /usr/sbin/php*-fpm; do
    [[ -x $b ]] || continue
    v=$("$b" -v 2>/dev/null | awk 'NR==1{print $2}')
    printf '  %-14s %-8s %s\n' "$(basename "$b")" "$v" "$(status "$v")"; found=1
  done
  ((found)) || echo "  no PHP found"
}

do_upgrade() {
  sudo -n true 2>/dev/null || { echo "  ERROR: needs passwordless sudo"; return 1; }
  if command -v apt-get >/dev/null; then
    local pkgs
    pkgs=$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'php*' 'libapache2-mod-php*' 2>/dev/null | awk '$1=="ii"{print $2}')
    [[ -n $pkgs ]] || { echo "  no php packages installed via apt"; return 0; }
    echo "  apt: upgrading $(wc -w <<<"$pkgs") php packages"
    sudo -n apt-get update -qq || return 1
    # shellcheck disable=SC2086
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade \
      -o Dpkg::Options::=--force-confold $pkgs >/dev/null || return 1
  elif command -v dnf >/dev/null || command -v yum >/dev/null; then
    local pm; pm=$(command -v dnf || command -v yum)
    echo "  $(basename "$pm"): upgrading php*"
    sudo -n "$pm" -y -q upgrade 'php*' >/dev/null || return 1
  else
    echo "  ERROR: no apt-get, dnf or yum on this host"; return 1
  fi
  local svc
  for svc in $(systemctl list-units --type=service --state=running --no-legend --plain 'php*-fpm*' 2>/dev/null | awk '{print $1}'); do
    sudo -n systemctl restart "$svc" && echo "  restarted $svc"
  done
  # mod_php lives inside Apache: reload it so the new PHP is loaded
  for svc in apache2 httpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null && compgen -G "/etc/apache2/mods-enabled/php*.load" >/dev/null; then
      sudo -n systemctl reload "$svc" && echo "  reloaded $svc (mod_php)"
    fi
  done
}

echo "  $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
show
if ((upgrade)); then
  do_upgrade || exit 1
  echo "  after upgrade:"
  show
fi
REMOTE
)

rc=0
for h in "${hosts[@]}"; do
  echo "== $h"
  # shellcheck disable=SC2086
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" "bash -s -- $upgrade $PHP_FIXED" <<<"$remote_script"; then
    echo "  FAILED (ssh or upgrade error)"; rc=1
  fi
done
exit $rc
