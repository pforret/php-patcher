#!/usr/bin/env bash
### check-latest.sh: show the latest PHP release per branch, as published by php.net and the package sources
### Sources: php.net, git tags, endoflife.date, Homebrew (macOS), Docker, apt (Ubuntu/Debian), pacman/AUR (Arch, Omarchy)
### Usage: ./check-latest.sh [--md] [-F "8.5.12 8.4.27 8.3.36 8.2.35"] [-u "noble jammy"] [-d "trixie bookworm"] [8.2 8.3 8.4 8.5]
### Needs curl and jq. A version behind the expected (-F/--fixed) one is marked with '<'. --md = Markdown table.
set -uo pipefail

branches=(8.2 8.3 8.4 8.5)
ubuntu_series="noble jammy focal"
debian_series="trixie bookworm"
fixed="8.5.12 8.4.27 8.3.36 8.2.35" # same default as php-patcher --fixed
md=0

args=()
for arg in "$@"; do
  case $arg in
  --md) md=1 ;;
  --fixed) args+=(-F) ;;
  *) args+=("$arg") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

while getopts "u:d:F:mh" opt; do
  case $opt in
  F) fixed="$OPTARG" ;;
  m) md=1 ;;
  u) ubuntu_series="$OPTARG" ;;
  d) debian_series="$OPTARG" ;;
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

fetch() { curl -fsSL --max-time 20 "$@" 2>/dev/null; }
newest() { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1; }

## one function per source: print the latest x.y.z for branch $1 (empty = unknown)

src_phpnet() { fetch "https://www.php.net/releases/?json&version=$1" | jq -r '.version // empty'; }

src_github() {
  # tags exist before the announcement and before any package is built
  fetch "https://api.github.com/repos/php/php-src/git/matching-refs/tags/php-$1." |
    jq -r '.[].ref | sub("refs/tags/php-"; "")' | newest
}

src_eol() {
  [[ -f "$tmp_dir/eol.json" ]] || fetch "https://endoflife.date/api/php.json" >"$tmp_dir/eol.json"
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
  [[ -f "$index" ]] || fetch "https://packages.sury.org/php/dists/$2/main/binary-amd64/Packages.gz" | gunzip >"$index" 2>/dev/null
  awk -v pkg="php$1-cli" '$1=="Package:" {p=$2} $1=="Version:" && p==pkg {print $2}' "$index" | sed -E 's/^[0-9]+://; s/-.*//' | newest
}

src_apt_local() {
  # what this machine's apt sources offer (only when run on Debian/Ubuntu)
  apt-cache policy "php$1-cli" 2>/dev/null | awk '/Candidate:/ {print $2}' | sed -E 's/^[0-9]+://; s/-.*//' | grep -v none
}

src_arch() {
  # Arch Linux official repo (also what Omarchy installs): php = newest branch, php-legacy = an older one
  [[ -f "$tmp_dir/arch.json" ]] || for pkg in php php-legacy; do
    fetch "https://archlinux.org/packages/search/json/?name=$pkg" | jq -r '.results[].pkgver'
  done >"$tmp_dir/arch.json"
  grep -F "$1." "$tmp_dir/arch.json" | newest
}

src_aur() {
  # AUR phpXY packages, community-maintained
  fetch "https://aur.archlinux.org/rpc/v5/info?arg[]=php${1//./}" | jq -r '.results[].Version' | sed -E 's/-.*//' | newest
}

## output

declare -A release=([focal]="Ubuntu 20.04" [jammy]="Ubuntu 22.04" [noble]="Ubuntu 24.04" [resolute]="Ubuntu 26.04"
  [bullseye]="Debian 11" [bookworm]="Debian 12" [trixie]="Debian 13" [forky]="Debian 14")
local_os=$(. /etc/os-release 2>/dev/null && echo "${NAME:-} ${VERSION_ID:-}")

# label|OS|function|argument
rows=("php.net|source|src_phpnet" "php-src git tag|source|src_github" "endoflife.date|-|src_eol"
  "Homebrew core|macOS|src_brew" "brew shivammathur/php|macOS|src_shivammathur" "Docker php image|Docker|src_docker")
for s in $ubuntu_series; do rows+=("apt ondrej $s|${release[$s]:-Ubuntu}|src_ondrej|$s"); done
for s in $debian_series; do rows+=("apt sury $s|${release[$s]:-Debian}|src_sury|$s"); done
rows+=("pacman extra|Arch / Omarchy|src_arch" "AUR phpXY|Arch / Omarchy|src_aur")
command -v apt-cache >/dev/null && rows+=("apt (this machine)|${local_os:-Linux}|src_apt_local")

# warm the shared caches, then look up every cell in parallel
src_eol 0 >/dev/null
src_arch 0 >/dev/null
for s in $debian_series; do src_sury 0 "$s" >/dev/null & done
wait
for i in "${!rows[@]}"; do
  IFS='|' read -r label os func arg <<<"${rows[$i]}"
  for b in "${branches[@]}"; do
    $func "$b" ${arg:+"$arg"} >"$tmp_dir/cell.$i.$b" &
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
    printf "%-24s%-16s" "$label" "$os"
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
for b in "${branches[@]}"; do cells+=("${expected[$b]:--}"); done
print_row "expected (--fixed)" "-" "${cells[@]}"
for i in "${!rows[@]}"; do
  IFS='|' read -r label os func arg <<<"${rows[$i]}"
  cells=()
  for b in "${branches[@]}"; do
    v=$(cat "$tmp_dir/cell.$i.$b")
    mark=""
    is_behind "$v" "${expected[$b]:-${reference[$b]}}" && mark=" <"
    cells+=("${v:--}$mark")
  done
  print_row "$label" "$os" "${cells[@]}"
done
if ((md)); then
  echo
  echo "_'<' = behind the expected version. Checked $(date -u '+%Y-%m-%d %H:%M') UTC._"
fi
