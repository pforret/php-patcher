#!/usr/bin/env bash
### check-latest.sh: show the latest PHP release per branch, as published by php.net and the package sources
### Sources: php.net, git tags, endoflife.date, Homebrew (macOS), Docker, winget/choco/scoop (Windows), apt (Ubuntu/Debian), dnf/Remi (RHEL/Alma/Rocky), Plesk (Linux/Windows), apk (Alpine), pacman/AUR (Arch, Omarchy)
### Usage: ./check-latest.sh [--md] [-F "8.5.12 8.4.27 8.3.36 8.2.35"] [-u "noble jammy"] [-d "trixie bookworm"] [-r "10 9 8"] [-a "v3.24 edge"] [8.2 8.3 8.4 8.5]
### Needs curl and jq. A version behind the expected (-F/--fixed) one is marked with '<' (--md: 🟢 ok / 🟠 not yet / 🔴 not available / ⚠️ lookup failed = '?').
set -uo pipefail

branches=(8.2 8.3 8.4 8.5)
ubuntu_series="noble jammy" # focal (20.04): the PPA has no PHP packages for it
debian_series="trixie bookworm"
rhel_series="10 9 8"
alpine_series="v3.24 edge"
plesk_series="noble"
fixed="8.5.12 8.4.27 8.3.36 8.2.35" # same default as php-patcher --fixed
md=0
max_jobs=16

args=()
for arg in "$@"; do
  case $arg in
  --md) md=1 ;;
  --fixed) args+=(-F) ;;
  *) args+=("$arg") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

while getopts "u:d:r:a:F:mh" opt; do
  case $opt in
  F) fixed="$OPTARG" ;;
  m) md=1 ;;
  u) ubuntu_series="$OPTARG" ;;
  d) debian_series="$OPTARG" ;;
  r) rhel_series="$OPTARG" ;;
  a) alpine_series="$OPTARG" ;;
  *) sed -n '2,5s/^### //p' "$0" && exit 0 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -gt 0 ]] && branches=("$@")

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "$bin is required (brew install $bin / apt install $bin)" >&2; exit 1; }
done

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# a failed lookup (timeout, 5xx, rate limit) flags the cell; a 404 just means "not there"
failed() { touch "$tmp_dir/fail.${cell_id:-x}"; }
fetch() {
  local body code
  body=$(mktemp "$tmp_dir/body.XXXXXX")
  code=$(curl -sL --max-time "${fetch_timeout:-20}" --retry 2 --retry-delay 3 --retry-max-time 60 -o "$body" -w '%{http_code}' "$@" 2>/dev/null)
  case $code in
  2*) cat "$body" ;;
  404) ;;
  *) failed ;;
  esac
  rm -f "$body"
}
newest() { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1; }

## one function per source: print the latest x.y.z for branch $1 (empty = unknown)

src_phpnet() { fetch "https://www.php.net/releases/?json&version=$1" | jq -r '.version // empty'; }

github_token="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null)}" # without a token: 60 requests/hour

src_github() {
  # tags exist before the announcement and before any package is built
  fetch ${github_token:+-H "Authorization: Bearer $github_token"} "https://api.github.com/repos/php/php-src/git/matching-refs/tags/php-$1." |
    jq -r '.[].ref | sub("refs/tags/php-"; "")' | newest
}

src_eol() {
  [[ -f "$tmp_dir/eol.json" ]] || cell_id=cache.eol fetch "https://endoflife.date/api/php.json" >"$tmp_dir/eol.json"
  [[ -e "$tmp_dir/fail.cache.eol" ]] && failed
  jq -r --arg c "$1" '.[] | select(.cycle == $c) | .latest' "$tmp_dir/eol.json"
}

src_brew() {
  # Homebrew core: php = newest branch, php@x.y = older branches
  local v
  for formula in "php@$1" php; do
    v=$(fetch "https://formulae.brew.sh/api/formula/$formula.json" | jq -r '.versions.stable // empty')
    [[ "$v" == "$1".* ]] && echo "$v" && return
  done
}

src_shivammathur() {
  # tap formulas: php@x.y, or php for the newest branch
  local v formula
  for formula in "php@$1" php; do
    v=$(fetch "https://raw.githubusercontent.com/shivammathur/homebrew-php/master/Formula/$formula.rb" |
      grep -m1 -oE 'php-[0-9]+\.[0-9]+\.[0-9]+\.tar' | sed -E 's/^php-//; s/\.tar$//')
    [[ "$v" == "$1".* ]] && echo "$v" && return
  done
}

src_docker() {
  fetch "https://hub.docker.com/v2/repositories/library/php/tags?name=$1.&page_size=100" |
    jq -r '.results[].name' | newest
}

src_ondrej() {
  # Ondřej Surý PPA (Ubuntu, used by Forge): Published + Pending, for one series ($2)
  local status
  for status in Published Pending; do
    fetch "https://api.launchpad.net/1.0/~ondrej/+archive/ubuntu/php?ws.op=getPublishedSources&source_name=php$1&exact_match=true&status=$status&distro_series=https://api.launchpad.net/1.0/ubuntu/$2" |
      jq -r '.entries[].source_package_version'
  done | sed -E 's/-.*//' | newest
}

src_sury() {
  # packages.sury.org (Debian): one Packages index per series ($2)
  local index="$tmp_dir/sury.$2"
  [[ -f "$index" ]] || cell_id="cache.sury.$2" fetch "https://packages.sury.org/php/dists/$2/main/binary-amd64/Packages.gz" | gunzip >"$index" 2>/dev/null
  [[ -e "$tmp_dir/fail.cache.sury.$2" ]] && failed
  awk -v pkg="php$1-cli" '$1=="Package:" {p=$2} $1=="Version:" && p==pkg {print $2}' "$index" | sed -E 's/^[0-9]+://; s/-.*//' | newest
}

src_apt_local() {
  # what this machine's apt sources offer (only when run on Debian/Ubuntu)
  apt-cache policy "php$1-cli" 2>/dev/null | awk '/Candidate:/ {print $2}' | sed -E 's/^[0-9]+://; s/-.*//' | grep -v none
}

src_arch() {
  # Arch Linux official repo (also what Omarchy installs): php = newest branch, php-legacy = an older one
  [[ -f "$tmp_dir/arch.json" ]] || for pkg in php php-legacy; do
    cell_id=cache.arch fetch "https://archlinux.org/packages/search/json/?name=$pkg" | jq -r '.results[].pkgver'
  done >"$tmp_dir/arch.json"
  [[ -e "$tmp_dir/fail.cache.arch" ]] && failed
  grep -F "$1." "$tmp_dir/arch.json" | newest
}

src_aur() {
  # AUR phpXY packages, community-maintained
  fetch "https://aur.archlinux.org/rpc/v5/info?arg[]=php${1//./}" | jq -r '.results[].Version' | sed -E 's/-.*//' | newest
}

src_remi() {
  # Remi repo (RHEL/AlmaLinux/Rocky): one folder per branch and EL release ($2)
  fetch_timeout=60 fetch "https://rpms.remirepo.net/enterprise/$2/php${1//./}/x86_64/" |
    grep -oE "php-cli-$1\.[0-9]+-" | sed -E 's/^php-cli-//; s/-$//' | newest
}

src_alpine() {
  # Alpine community repo (also the base of the -alpine Docker images): one APKINDEX per release ($2)
  local index="$tmp_dir/alpine.$2"
  [[ -f "$index" ]] || cell_id="cache.alpine.$2" fetch "https://dl-cdn.alpinelinux.org/alpine/$2/community/x86_64/APKINDEX.tar.gz" | tar -xzO APKINDEX >"$index" 2>/dev/null
  [[ -e "$tmp_dir/fail.cache.alpine.$2" ]] && failed
  awk -v pkg="P:php${1//./}" '$0==pkg {p=1; next} /^P:/ {p=0} p && /^V:/ {print substr($0, 3)}' "$index" | sed -E 's/-r[0-9]+$//' | newest
}

src_plesk() {
  # Plesk's own PHP builds (plesk-phpXY), one apt repo per branch; series $2
  fetch "https://autoinstall.plesk.com/PHP${1//./}_17/dists/$2/all/binary-amd64/Packages.gz" | gunzip 2>/dev/null |
    awk -v pkg="plesk-php${1//./}-cli" '$1=="Package:" {p=$2} $1=="Version:" && p==pkg {print $2}' | sed -E 's/-.*//' | newest
}

src_plesk_win() {
  # Plesk for Windows: patch + build number glued together, 8.3.3520 = 8.3.35 build 20, 8.5.11020 = 8.5.11 build 020
  # so take the longest patch prefix that is not newer than php.net's
  local glued latest k patch=""
  glued=$(fetch "https://autoinstall-win.plesk.com/PHP${1//./}-WIN/php-$1-ms-noarch.inf3" |
    grep -m1 -oE "<package [^>]*version=\"$1\.[0-9]+\"" | grep -oE "version=\"$1\.[0-9]+" | sed "s/^version=\"$1\.//")
  [[ -z "$glued" ]] && return
  latest=$(src_phpnet "$1")
  latest=${latest##*.}
  for ((k = 1; k < ${#glued}; k++)); do
    [[ "${glued:k}" =~ ^0?[0-9]0$ ]] || continue
    ((10#${glued:0:k} <= ${latest:-99})) && patch=$((10#${glued:0:k}))
  done
  [[ -n "$patch" ]] && echo "$1.$patch"
}

src_windows() {
  # official Windows builds (also what winget/choco/scoop download)
  fetch "https://windows.php.net/downloads/releases/releases.json" | jq -r --arg b "$1" '.[$b].version // empty'
}

src_winget() {
  # microsoft/winget-pkgs: one folder per version under manifests/p/PHP/PHP/<major>/<minor>
  fetch ${github_token:+-H "Authorization: Bearer $github_token"} "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/p/PHP/PHP/${1/.//}" |
    jq -r '.[]?.name' | newest
}

src_choco() {
  fetch "https://community.chocolatey.org/api/v2/FindPackagesById()?id='php'&\$filter=startswith(Version,'$1.')" |
    grep -oE '<d:Version>[^<]+' | sed 's/<d:Version>//' | newest
}

src_scoop() {
  # Scoop "versions" bucket: phpXY for every branch
  fetch "https://raw.githubusercontent.com/ScoopInstaller/Versions/master/bucket/php${1//./}.json" | jq -r '.version // empty'
}

## output

declare -A release=([focal]="Ubuntu 20.04" [jammy]="Ubuntu 22.04" [noble]="Ubuntu 24.04" [resolute]="Ubuntu 26.04"
  [bullseye]="Debian 11" [bookworm]="Debian 12" [trixie]="Debian 13" [forky]="Debian 14")
local_os=$(. /etc/os-release 2>/dev/null && echo "${NAME:-} ${VERSION_ID:-}")

# links for the source column in --md mode
declare -A link=([endoflife.date]="https://endoflife.date/php")

# label|OS|function|argument
rows=("php.net|source|src_phpnet" "php-src git tag|source|src_github" "endoflife.date|-|src_eol"
  "Homebrew core|macOS|src_brew" "brew shivammathur/php|macOS|src_shivammathur" "Docker php image|Docker|src_docker"
  "windows.php.net|Windows|src_windows" "winget|Windows|src_winget" "Chocolatey|Windows|src_choco" "Scoop versions|Windows|src_scoop"
  "plesk windows|Windows|src_plesk_win")
for s in $ubuntu_series; do rows+=("apt ondrej $s|${release[$s]:-Ubuntu}|src_ondrej|$s"); done
for s in $debian_series; do rows+=("apt sury $s|${release[$s]:-Debian}|src_sury|$s"); done
for s in $plesk_series; do rows+=("plesk $s|${release[$s]:-Linux}|src_plesk|$s"); done
for s in $rhel_series; do rows+=("dnf remi el$s|RHEL/Alma/Rocky $s|src_remi|$s"); done
for s in $alpine_series; do rows+=("apk alpine $s|Alpine ${s#v}|src_alpine|$s"); done
rows+=("pacman extra|Arch / Omarchy|src_arch" "AUR phpXY|Arch / Omarchy|src_aur")
command -v apt-cache >/dev/null && rows+=("apt (this machine)|${local_os:-Linux}|src_apt_local")

# warm the shared caches, then look up every cell in parallel
src_eol 0 >/dev/null
src_arch 0 >/dev/null
for s in $debian_series; do src_sury 0 "$s" >/dev/null & done
for s in $alpine_series; do src_alpine 0 "$s" >/dev/null & done
wait
for i in "${!rows[@]}"; do
  IFS='|' read -r label os func arg <<<"${rows[$i]}"
  for b in "${branches[@]}"; do
    while (($(jobs -rp | wc -l) >= max_jobs)); do wait -n; done # too many at once and requests start failing
    cell_id="$i.$b" $func "$b" ${arg:+"$arg"} >"$tmp_dir/cell.$i.$b" 2>/dev/null &
  done
done
wait

declare -A expected reference
for v in $fixed; do expected[${v%.*}]="$v"; done
for b in "${branches[@]}"; do reference[$b]=$(cat "$tmp_dir/cell.0.$b"); done

is_behind() { [[ -n "$1" && -n "$2" && "$1" != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1) == "$1" ]]; }

print_row() {
  # $1 = label, $2 = OS, rest = cells
  local label="$1" os="$2"
  shift 2
  if ((md)); then
    printf "| %s | %s |" "$label" "$os"
    printf " %s |" "$@"
  else
    printf "%-24s%-20s" "$label" "$os"
    printf "%-11s" "$@"
  fi
  echo
}

print_row "source" "OS" "${branches[@]}"
if ((md)); then
  cells=("---" "---")
  for b in "${branches[@]}"; do cells+=("---"); done
  echo "|$(printf '%s|' "${cells[@]}")"
fi
cells=()
for b in "${branches[@]}"; do
  v="${expected[$b]:-}"
  ((md)) && [[ -n "$v" ]] && v="**$v**"
  cells+=("${v:--}")
done
print_row "expected (--fixed)" "-" "${cells[@]}"
for i in "${!rows[@]}"; do
  IFS='|' read -r label os func arg <<<"${rows[$i]}"
  cells=()
  for b in "${branches[@]}"; do
    v=$(cat "$tmp_dir/cell.$i.$b")
    if [[ -e "$tmp_dir/fail.$i.$b" ]]; then
      ((md)) && cells+=("⚠️${v:+ $v}") || cells+=("${v:+$v }?")
    elif [[ -z "$v" ]]; then
      ((md)) && cells+=("🔴") || cells+=("-")
    elif is_behind "$v" "${expected[$b]:-${reference[$b]}}"; then
      ((md)) && cells+=("🟠 $v") || cells+=("$v <")
    else
      ((md)) && cells+=("🟢 $v") || cells+=("$v")
    fi
  done
  ((md)) && [[ -n "${link[$label]:-}" ]] && label="[$label](${link[$label]})"
  print_row "$label" "$os" "${cells[@]}"
done
if ((md)); then
  echo
  echo "_🟢 = has the expected version, 🟠 = not yet, 🔴 = not available, ⚠️ = lookup failed. Checked $(date -u '+%Y-%m-%d %H:%M') UTC._"
fi
