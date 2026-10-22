#!/usr/bin/env bash
### ==============================================================================
### SO HOW DO YOU PROCEED WITH YOUR SCRIPT?
### 1. define the flags/options/parameters and defaults you need in Option:config()
### 2. implement the different verbs in Script:main() directly or with helper functions do_action1
### 3. implement helper functions you defined in previous step
### ==============================================================================
###
### FOR LLMs: QUICK REFERENCE
### -------------------------
### ADDING NEW VERBS: In Option:config(), add verb to the choice line (e.g., "action1,action2,newverb")
###                   then add a case block in Script:main(): newverb) do_newverb ;;
###
### BUILT-IN VERBS: check   => show all options/flags/parameters and required programs
###                 env     => generate an example .env file
###                 install => install required programs, symlink the script, set up bash/zsh completion
###                 update  => update the script to the latest version (git pull)
###
### OPTIONS/FLAGS become variables:
###   flag|f|FORCE|...        => $FORCE (0 or 1)
###   option|o|output|...|x   => $output (default "x")
###   param|1|input|...       => $input (required positional arg)
###
### ENV FILES: Automatically loaded in order (later files override earlier):
###   1. <script_folder>/.env
###   2. <script_folder>/.<script_prefix>.env
###   3. <script_folder>/<script_prefix>.env
###   4. ./.env (current dir, if different from script folder)
###   5. ./.<script_prefix>.env
###   6. ./<script_prefix>.env
###
### Os:require "binary" ["package"] - check if binary exists, die if not
###   Os:require "awk"                      => check for awk, suggest: brew install awk
###   Os:require "convert" "imagemagick"    => check for convert, suggest: brew install imagemagick
###   Os:require "prog" "pip install prog"  => check for prog, suggest: pip install prog
###   With -f/--FORCE flag: auto-installs missing binaries instead of dying
###
### IO FUNCTIONS and effect of --QUIET (-Q) and --VERBOSE (-V):
###   IO:print "msg"   : normal output (stdout)     - hidden by -Q
###   IO:debug "msg"   : debug info (stderr)        - only shown with -V
###   IO:success "msg" : success message (stdout)   - hidden by -Q
###   IO:announce "msg": announcement + 1s pause    - hidden by -Q
###   IO:alert "msg"   : warning message (stderr)   - always shown
###   IO:die "msg"     : error message + exit       - always shown
###   IO:progress "msg": overwriting progress line  - hidden by -Q
###   IO:log "msg"     : append to $log_file        - not affected by -Q/-V
###   IO:confirm "?"   : ask y/N question           - skipped (=yes) with -f/--FORCE
###
### STRING FUNCTIONS:
###   Str:trim "  text  "                => "text" (remove leading/trailing whitespace)
###   Str:lower "HELLO"                  => "hello"
###   Str:upper "hello"                  => "HELLO"
###   Str:ascii "café"                   => "cafe" (remove diacritics)
###   Str:slugify "Hello World!"         => "hello-world" (URL-safe)
###   Str:slugify "Hello World!" "_"     => "hello_world" (custom separator)
###   Str:title "hello world"            => "HelloWorld"
###   Str:title "hello world" "_"        => "Hello_World"
###   Str:digest 8 <<< "text"            => "d3b07384" (MD5 hash, first N chars)
### ==============================================================================

### Created by Peter Forret ( pforret ) on 2026-10-22
### Based on https://github.com/pforret/bashew 1.22.1
script_version="0.0.1" # if there is a VERSION.md in this script's folder, that will have priority over this version number
readonly script_author="peter@forret.com"
readonly script_created="2026-10-22"
readonly run_as_root=-1 # run_as_root: 0 = don't check anything / 1 = script MUST run as root / -1 = script MAY NOT run as root
readonly script_description="in-place Ubuntu LTS upgrade (20.04 → 22.04 → 24.04) of a Forge server over SSH"

function Option:config() {
  ### SYNTAX: type|short|long|description[|default][|choices]
  ###
  ### flag   => -x or --xxxx sets $xxxx=1 (default: 0)
  ### option => -x <val> or --xxxx <val> sets $xxxx=val
  ### list   => -x <v1> -x <v2> sets ${xxxx[@]} array
  ### param  => positional arg: 1=required, ?=optional, n=multiple
  ### choice => positional arg with validation against allowed values
  grep <<<"
#commented lines will be filtered
flag|h|help|show usage
flag|Q|QUIET|no output
flag|V|VERBOSE|also show debug messages
flag|f|FORCE|do not ask for confirmation (always yes)
option|L|LOG_DIR|folder for log files |$HOME/log/$script_prefix
option|T|TMP_DIR|folder for temp files|/tmp/$script_prefix
option|t|target|Ubuntu codename to end on (jammy or noble)|noble
option|F|fixed|first fixed release per PHP branch|8.5.12 8.4.27 8.3.36 8.2.35
option|d|drop_php|PHP versions not to reinstall in postflight, comma-separated (e.g. 7.4)|
option|s|disable|sites to disable in postflight, comma-separated|
flag|n|no_dump|skip the MySQL dump in prepare
choice|1|action|action to perform|password,forget,status,preflight,disk,nginx-down,prepare,upgrade,logs,postflight,nginx-up,verify,cleanup,check,env,install,update
param|?|host|ssh host (as in ~/.ssh/config)
" -v -e '^#' -e '^\s*$'
}

#####################################################################
## Put your Script:main script here
#####################################################################

function Script:main() {
  ## TO ADD A NEW VERB: 1) add it to choice line in Option:config()
  ##                    2) add a case block below: myverb) do_myverb ;;
  ##                    3) implement do_myverb() function
  IO:log "[$script_basename] $script_version started"
  local rc=0

  Os:require "awk"
  Os:require "ssh"
  Os:require "openssl"

  case "${action,,}" in # ${action,,} = lowercase $action
  password)
    #TIP: use «$script_prefix password <server>» once, in your own terminal: asks the sudo password, checks it and stores it encrypted
    #TIP:> $script_prefix password myhost
    need_host
    do_password
    rc=$?
    ;;

  forget)
    #TIP: use «$script_prefix forget <server>» to delete the stored sudo password
    #TIP:> $script_prefix forget myhost
    need_host
    do_forget
    rc=$?
    ;;

  status)
    #TIP: use «$script_prefix status <server>» to see where the upgrade stands and what comes next (read-only)
    #TIP:> $script_prefix status myhost
    need_host
    with_log status do_status
    rc=$?
    ;;

  preflight)
    #TIP: use «$script_prefix preflight <server>» for a read-only READY / BLOCKED report before the next hop
    #TIP:> $script_prefix preflight myhost
    #TIP:> $script_prefix --target jammy preflight myhost
    need_host
    with_log preflight do_preflight
    rc=$?
    ;;

  disk)
    #TIP: use «$script_prefix disk <server>» to see where the disk space went (read-only, needs sudo)
    #TIP:> $script_prefix disk myhost
    need_host
    with_log disk do_disk
    rc=$?
    ;;

  nginx-down)
    #TIP: use «$script_prefix nginx-down <server>» to stop and mask nginx: all sites go offline until nginx-up
    #TIP:> $script_prefix nginx-down myhost
    need_host
    with_log nginx-down do_nginx_down
    rc=$?
    ;;

  prepare)
    #TIP: use «$script_prefix prepare <server>» for backups, the DB dump, the mirror fix and a full apt upgrade before do-release-upgrade
    #TIP:> $script_prefix prepare myhost
    #TIP:> $script_prefix --no_dump prepare myhost
    need_host
    with_log prepare do_prepare
    rc=$?
    ;;

  upgrade)
    #TIP: use «$script_prefix upgrade <server>» in your own terminal to run do-release-upgrade inside screen (interactive)
    #TIP:> $script_prefix upgrade myhost
    need_host
    do_upgrade
    rc=$?
    ;;

  logs)
    #TIP: use «$script_prefix logs <server>» to show the do-release-upgrade and screen logs from the server
    #TIP:> $script_prefix logs myhost
    need_host
    with_log logs do_logs
    rc=$?
    ;;

  postflight)
    #TIP: use «$script_prefix postflight <server>» after do-release-upgrade and the reboot: PHP back from ppa:ondrej/php, services restarted
    #TIP:> $script_prefix postflight myhost
    #TIP:> $script_prefix --drop_php 7.4 --disable old.example.com postflight myhost
    need_host
    with_log postflight do_postflight
    rc=$?
    ;;

  nginx-up)
    #TIP: use «$script_prefix nginx-up <server>» to bring the sites back once PHP is patched
    #TIP:> $script_prefix nginx-up myhost
    need_host
    with_log nginx-up do_nginx_up
    rc=$?
    ;;

  verify)
    #TIP: use «$script_prefix verify <server>» to check OS, kernel, PHP vs --fixed, services and every site over HTTPS
    #TIP:> $script_prefix verify myhost
    need_host
    with_log verify do_verify
    rc=$?
    ;;

  cleanup)
    #TIP: use «$script_prefix cleanup <server>» to close port 1022 and remove the upgrade leftovers (and the stored password, on the final release)
    #TIP:> $script_prefix cleanup myhost
    need_host
    with_log cleanup do_cleanup
    rc=$?
    ;;

  check | env)
    ## leave this default action, it will make it easier to test your script
    #TIP: use «$script_prefix check» to check if this script is ready to execute and what values the options/flags are
    #TIP:> $script_prefix check
    #TIP: use «$script_prefix env» to generate an example .env file
    #TIP:> $script_prefix env > .env
    Script:check
    ;;

  update)
    ## leave this default action, it will make it easier to test your script
    #TIP: use «$script_prefix update» to update to the latest version
    #TIP:> $script_prefix update
    Script:git_pull
    ;;

  install)
    ## leave this default action, it will make it easier to install your script
    #TIP: use «$script_prefix install» to install dependencies and set up bash completion
    #TIP:> $script_prefix install
    Script:install
    ;;

  *)
    IO:die "action [$action] not recognized"
    ;;
  esac
  IO:log "[$script_basename] ended after $SECONDS secs (rc=$rc)"
  if ((rc)); then
    # Script:exit always exits 0: drop the error trap and exit with the verb's code ourselves
    trap - INT TERM EXIT
    exit "$rc"
  fi
  #TIP: >>> bash script created with «pforret/bashew»
  #TIP: >>> the full runbook: docs/faq/ubuntu20.md
}

#####################################################################
## Put your helper scripts here
## Available variables: all flags/options from Option:config()
## Useful functions: IO:print, IO:debug, IO:die, IO:success, IO:confirm
##                   Os:require "binary" [install_cmd], Os:tempfile [ext]
#####################################################################

# exit codes of every server verb: 0 = OK/READY/DONE, 1 = BLOCKED/FAILED, 3 = NEEDS-ADMIN
# (the last two lines of the output are always «STATUS: ...» and «NEXT: ...», for humans and for Claude)

backup_root="/var/backups/ubuntu-upgrade"
fallback_ssh_port=1022
min_root_free_mb=5120
min_boot_free_mb=300
declare -A fact=()

function die_usage() {
  # die_usage <message>: like IO:die, but with exit code 2 (bashew's IO:die exits 0)
  IO:print "${txtError}${char_fail} $script_basename${txtReset}: $*" >&2
  trap - INT TERM EXIT
  exit 2
}

# shellcheck disable=SC2154 # host/action/target are set by Option:initialize/Option:parse via eval
function need_host() {
  # host is optional for check/env/install/update, required for all server verbs
  [[ -n "${host:-}" ]] || die_usage "need a host: $script_prefix $action <server>"
  [[ $host == -* ]] && die_usage "invalid host [$host] (put flags before the verb)"
  case "$target" in
  jammy | noble) ;;
  *) die_usage "--target must be jammy or noble, not [$target]" ;;
  esac
  self_cmd
}

function self_cmd() {
  # how to call this script again in the NEXT: lines (with --target when it is not the default)
  local dir
  dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
  if [[ $dir == "$PWD" ]]; then self="./$(basename "$0")"; else self="$0"; fi
  [[ $target != noble ]] && self="$self --target $target"
  return 0
}

function finish() {
  # finish <WORD> <detail> [next]: the last 2 lines of every verb, and its exit code
  local word="$1" detail="$2" next="${3:-}"
  echo ""
  echo "STATUS: $word $detail"
  [[ -n "$next" ]] && echo "NEXT: $next"
  case "$word" in
  OK | READY | DONE) return 0 ;;
  NEEDS-ADMIN) return 3 ;;
  *) return 1 ;;
  esac
}

function with_log() {
  # with_log <verb> <function>: run it with stdout+stderr also going to $LOG_DIR/<host>/<timestamp>.<verb>.log
  local verb="$1" fn="$2" dir log
  dir="$LOG_DIR/${host//\//_}"
  mkdir -p "$dir" && chmod 700 "$dir"
  log="$dir/$(date '+%Y%m%d-%H%M%S').$verb.log"
  (umask 077 && : >"$log")
  {
    echo "log: $log"
    "$fn"
  } 2>&1 | tee -a "$log"
  return "${PIPESTATUS[0]}"
}

function next_codename() {
  # next_codename <codename>: the next Ubuntu LTS that do-release-upgrade goes to
  case "$1" in
  focal) echo jammy ;;
  jammy) echo noble ;;
  *) echo "" ;;
  esac
}

function codename_rank() {
  case "$1" in
  focal) echo 20 ;;
  jammy) echo 22 ;;
  noble) echo 24 ;;
  *) echo 0 ;;
  esac
}

### sudo password store: one AES-256 file per host, the key in the macOS Keychain (or a 0600 key file)

function pw_dir() {
  local d="${UPGRADE_UBUNTU_HOME:-$HOME/.config/upgrade-ubuntu}"
  mkdir -p "$d" && chmod 700 "$d"
  echo "$d"
}

function pw_keystore() {
  case "${UPGRADE_UBUNTU_KEYSTORE:-}" in
  file | keychain)
    echo "$UPGRADE_UBUNTU_KEYSTORE"
    return 0
    ;;
  esac
  if [[ $(uname -s) == Darwin ]] && command -v security >/dev/null; then echo keychain; else echo file; fi
}

function pw_key() {
  # pw_key: print the encryption key, create it the first time
  local key="" file
  if [[ $(pw_keystore) == keychain ]]; then
    key=$(security find-generic-password -s upgrade-ubuntu -a key -w 2>/dev/null) || key=""
    if [[ -z "$key" ]]; then
      key=$(openssl rand -hex 32)
      # the key (not the password) is briefly in argv here
      security add-generic-password -U -s upgrade-ubuntu -a key -w "$key" >/dev/null 2>&1 || return 1
    fi
  else
    file="$(pw_dir)/.key"
    [[ -s "$file" ]] || (umask 077 && openssl rand -hex 32 >"$file")
    key=$(<"$file")
  fi
  [[ -n "$key" ]] && printf '%s' "$key"
}

function pw_file() {
  echo "$(pw_dir)/${1//\//_}.pw.enc"
}

function pw_has() {
  [[ -s "$(pw_file "$1")" ]]
}

function pw_save() {
  # pw_save <host>: encrypt the password on stdin; the key goes to openssl in its environment, never in argv
  local file key
  file=$(pw_file "$1")
  key=$(pw_key) || return 1
  (umask 077 && K="$key" openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:K -out "$file.tmp") &&
    mv "$file.tmp" "$file"
}

function pw_load() {
  # pw_load <host>: print the decrypted password (only ever call it inside $(...))
  local file key
  file=$(pw_file "$1")
  [[ -s "$file" ]] || return 1
  key=$(pw_key) || return 1
  K="$key" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:K -in "$file" 2>/dev/null
}

function pw_forget() {
  local file
  file=$(pw_file "$1")
  [[ -f "$file" ]] || return 1
  rm -f "$file"
}

### running things on the server

function ssh_opts() {
  printf '%s\n' -T -o BatchMode=yes -o ConnectTimeout=10
}

function remote_ro() {
  # remote_ro <script>: run it as the ssh user, no sudo; stdin is /dev/null
  local err_file rc
  err_file=$(Os:tempfile err)
  # shellcheck disable=SC2046,SC2029 # ssh_opts: one option per line (IFS splits on newlines); the script is quoted here on purpose
  ssh $(ssh_opts) "$host" "LC_ALL=C.UTF-8 bash -c $(printf '%q' "$1")" </dev/null 2>"$err_file"
  rc=$?
  # drop the OpenSSH 10 post-quantum warning ("** WARNING: connection is not using a post-quantum ...")
  grep -v '^\*\* ' "$err_file" >&2
  return "$rc"
}

function remote_sudo() {
  # remote_sudo <script> [raw]: run it as root, sudo gets the stored password as the only line on stdin
  # (so apt/dpkg inside the script see EOF, never the rest of a script). Without «raw», the script's
  # stderr is merged into stdout. Returns 3 = no stored password, 4 = password rejected, 255 = ssh failed.
  local script="$1" raw="${2:-}" pw err_file rc
  pw_has "$host" || return 3
  pw=$(pw_load "$host") || return 3
  [[ -n "$pw" ]] || return 3
  [[ -z "$raw" ]] && script="exec 2>&1"$'\n'"$script"
  err_file=$(Os:tempfile err)
  # shellcheck disable=SC2046,SC2029 # ssh_opts: one option per line (IFS splits on newlines); the script is quoted here on purpose
  printf '%s\n' "$pw" |
    ssh $(ssh_opts) "$host" "sudo -k -S -p '' env LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive bash -c $(printf '%q' "$script")" 2>"$err_file"
  rc=$?
  unset pw
  if ((rc == 1)) && grep -qE 'incorrect password|Sorry, try again|no password was provided' "$err_file"; then
    rc=4
  fi
  grep -v -e '^\*\* ' -e 'Sorry, try again' -e 'incorrect password' -e 'no password was provided' "$err_file" >&2
  return "$rc"
}

function remote_fail() {
  # remote_fail <rc> <what>: the STATUS for a failed remote_ro/remote_sudo
  case "$1" in
  3) finish NEEDS-ADMIN "no stored sudo password for $host" "$self password $host   (in your own terminal)" ;;
  4) finish BLOCKED "the stored sudo password was rejected on $host" "$self password $host   (in your own terminal)" ;;
  255) finish FAILED "cannot connect to $host over ssh" "ssh $host true   (check ~/.ssh/config and the keys)" ;;
  *) finish FAILED "$2 failed on $host (exit $1), see the output above" "$self logs $host" ;;
  esac
}

function vars_script() {
  # vars_script NAME=value ...: shell assignments to put in front of a remote script, safely quoted
  local pair
  for pair in "$@"; do
    printf '%s=%q\n' "${pair%%=*}" "${pair#*=}"
  done
}

function facts_script() {
  # key=value facts about the server, readable without sudo (status and the guards of the other verbs)
  cat <<'REMOTE'
shopt -s nullglob
st() { local o; o=$(systemctl "$1" "$2" 2>/dev/null) || true; printf '%s' "${o:-$3}"; }
codename=$(lsb_release -cs 2>/dev/null || echo unknown)
echo "codename=$codename"
echo "desc=$(lsb_release -ds 2>/dev/null || echo unknown)"
echo "kernel=$(uname -r)"
echo "nginx_enabled=$(st is-enabled nginx missing)"
echo "nginx_active=$(st is-active nginx inactive)"
hops=""
for d in /var/backups/ubuntu-upgrade/*-to-*/; do d=${d%/}; hops+="${d##*/} "; done
echo "hops=${hops% }"
[[ -f /var/run/reboot-required ]] && echo "reboot_required=1" || echo "reboot_required=0"
# the [x] in the patterns keeps pgrep from matching this script's own command line
pgrep -f '[d]o-release-upgrade|[u]buntu-release-upgrader-|[D]istUpgradeView' >/dev/null && echo "upgrader_running=1" || echo "upgrader_running=0"
missing=0 total=0
for list in /var/backups/ubuntu-upgrade/*-to-"$codename"/php-packages.txt; do
  while read -r p; do
    [[ -n $p ]] || continue
    total=$((total + 1))
    [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null) == installed ]] || missing=$((missing + 1))
  done <"$list"
done
echo "php_total=$total"
echo "php_missing=$missing"
echo "cruft=$(find /etc/apt \( -name '*.distUpgrade' -o -name '*.save' \) 2>/dev/null | wc -l | tr -d ' ')"
REMOTE
}

function load_facts() {
  # load_facts: fill ${fact[...]} from the server; returns the ssh exit code
  local out key value rc
  out=$(remote_ro "$(facts_script)")
  rc=$?
  ((rc)) && return "$rc"
  fact=()
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] && fact[$key]="$value"
  done <<<"$out"
  [[ -n "${fact[codename]:-}" ]] || return 1
}

function decide_stage() {
  # decide_stage: «WORD|detail|next» for the current ${fact[...]}, used by status and logs
  local code="${fact[codename]:-unknown}" hops=" ${fact[hops]:-} " to masked=0
  local missing="${fact[php_missing]:-0}" total="${fact[php_total]:-0}"
  [[ ${fact[nginx_enabled]:-} == masked ]] && masked=1
  to=$(next_codename "$code")

  if (($(codename_rank "$code") == 0)); then
    echo "BLOCKED|$host runs ${fact[desc]:-$code}: this script only knows focal, jammy and noble|"
    return
  fi
  if (($(codename_rank "$code") > $(codename_rank "$target"))); then
    echo "BLOCKED|$host is already past --target $target (on $code)|"
    return
  fi
  if [[ $hops == *"-to-$code "* ]] && ((missing > 0)); then
    echo "OK|on $code after do-release-upgrade, $missing of $total PHP packages still missing|$self postflight $host"
    return
  fi
  if [[ $code == "$target" ]]; then
    if ((masked)) || [[ ${fact[nginx_active]:-} != active ]]; then
      echo "OK|on $code with PHP reinstalled, sites still offline (nginx ${fact[nginx_enabled]:-?}/${fact[nginx_active]:-?})|./php-patcher.sh host $host (all OK? else --patch), then $self nginx-up $host"
    elif [[ $hops != "  " ]] || ((${fact[cruft]:-0} > 0)); then
      echo "OK|on $code with the sites online|$self verify $host, then $self cleanup $host"
    else
      echo "DONE|on $code, sites online, nothing left to clean up|"
    fi
    return
  fi
  if [[ $hops == *" $code-to-$to "* ]]; then
    if ((${fact[upgrader_running]:-0})); then
      echo "NEEDS-ADMIN|do-release-upgrade $code → $to is running|ssh -t $host sudo screen -x upgrade   (in your own terminal; or $self logs $host)"
    elif ((${fact[reboot_required]:-0})); then
      echo "NEEDS-ADMIN|prepared for $code → $to, a reboot is pending|ssh -t $host sudo reboot   (or the Forge dashboard), then $self upgrade $host"
    else
      echo "NEEDS-ADMIN|prepared for $code → $to|$self upgrade $host   (in your own terminal)"
    fi
    return
  fi
  if ((!masked)); then
    echo "OK|on $code, next hop $code → $to; nginx is not masked yet (${fact[nginx_enabled]:-?}/${fact[nginx_active]:-?})|$self nginx-down $host"
    return
  fi
  echo "OK|on $code, sites offline, ready for the $code → $to hop|$self preflight $host, then $self prepare $host"
}

function stage_finish() {
  # stage_finish: finish with what decide_stage says
  local stage word detail next rc
  load_facts
  rc=$?
  ((rc)) && {
    remote_fail "$rc" "reading the server state"
    return
  }
  stage=$(decide_stage)
  IFS='|' read -r word detail next <<<"$stage"
  finish "$word" "$detail" "$next"
}

function show_facts() {
  echo "## $host: upgrade status (target: $target)"
  echo ""
  echo "- OS: ${fact[desc]:-?} (${fact[codename]:-?}), kernel ${fact[kernel]:-?}"
  echo "- nginx: ${fact[nginx_enabled]:-?} / ${fact[nginx_active]:-?}"
  echo "- prepared hops: ${fact[hops]:-none}"
  echo "- reboot pending: $( ((${fact[reboot_required]:-0})) && echo yes || echo no) · do-release-upgrade running: $( ((${fact[upgrader_running]:-0})) && echo yes || echo no)"
  echo "- PHP packages of the last hop missing: ${fact[php_missing]:-0} of ${fact[php_total]:-0}"
  echo "- upgrade leftovers in /etc/apt: ${fact[cruft]:-0}"
}

function guard_facts() {
  # guard_facts: load_facts, or finish with the reason; returns non-zero when the verb must stop
  local rc
  load_facts
  rc=$?
  if ((rc)); then
    remote_fail "$rc" "reading the server state"
    return 1
  fi
}

### the verbs

function do_password() {
  local user pw tries=0 rc
  if ! Os:has_tty; then
    finish NEEDS-ADMIN "the sudo password must be typed in a terminal" "$self password $host   (in your own terminal)"
    return
  fi
  user=$(ssh -n -G "$host" 2>/dev/null | awk '$1=="user"{print $2}')
  while ((tries < 3)); do
    IFS= read -r -s -p "sudo password for ${user:-?}@$host: " pw </dev/tty
    echo >&2
    if [[ -z "$pw" ]]; then
      finish FAILED "no password given"
      return
    fi
    # shellcheck disable=SC2046 # ssh_opts is one option per line, IFS splits on newlines
    printf '%s\n' "$pw" | ssh $(ssh_opts) "$host" "sudo -k -S -p '' true" >/dev/null 2>&1
    rc=$?
    if ((rc == 0)); then
      if ! printf '%s' "$pw" | pw_save "$host"; then
        unset pw
        finish FAILED "could not store the password"
        return
      fi
      unset pw
      finish OK "sudo password for $host stored, encrypted in $(pw_file "$host") (key: $(pw_keystore))" "$self status $host"
      return
    fi
    if ((rc == 255)); then
      unset pw
      finish FAILED "cannot connect to $host over ssh" "ssh $host true   (check ~/.ssh/config and the keys)"
      return
    fi
    tries=$((tries + 1))
    IO:alert "sudo on $host rejected that password"
  done
  unset pw
  finish FAILED "sudo on $host rejected the password 3 times"
}

function do_forget() {
  if pw_forget "$host"; then
    finish OK "stored sudo password for $host deleted"
  else
    finish OK "there was no stored sudo password for $host"
  fi
}

function do_status() {
  guard_facts || return
  show_facts
  echo "- stored sudo password: $(pw_has "$host" && echo yes || echo "no ($self password $host)")"
  local stage word detail next
  stage=$(decide_stage)
  IFS='|' read -r word detail next <<<"$stage"
  finish "$word" "$detail" "$next"
}

function do_preflight() {
  local script rc
  script="$(vars_script HOST="$host" TARGET="$target" MIN_ROOT="$min_root_free_mb" MIN_BOOT="$min_boot_free_mb")"$'\n'
  script+=$(
    cat <<'REMOTE'
shopt -s nullglob
blockers=(); warnings=()
st() { local o; o=$(systemctl "$1" "$2" 2>/dev/null) || true; printf '%s' "${o:-$3}"; }
codename=$(lsb_release -cs 2>/dev/null || echo unknown)
desc=$(lsb_release -ds 2>/dev/null || echo unknown)
case "$codename" in focal) to=jammy ;; jammy) to=noble ;; *) to="" ;; esac
case "$codename:$TARGET" in
  focal:jammy|focal:noble|jammy:noble) hop="$codename → $to" ;;
  "$TARGET:$TARGET") hop="none"; blockers+=("already on $desc: nothing to upgrade (postflight / verify / cleanup)") ;;
  *) hop="none"; blockers+=("$desc ($codename) cannot be taken to $TARGET by this script") ;;
esac

nginx_enabled=$(st is-enabled nginx missing)
nginx_active=$(st is-active nginx inactive)
[[ "$nginx_enabled" == "masked" && "$nginx_active" != "active" ]] ||
  blockers+=("nginx is $nginx_enabled/$nginx_active: take the sites offline first with nginx-down")

prompt=$(grep -E '^Prompt=' /etc/update-manager/release-upgrades 2>/dev/null | cut -d= -f2)
[[ "$prompt" == "lts" ]] || warnings+=("Prompt=${prompt:-unset} in /etc/update-manager/release-upgrades (prepare sets lts)")

lists=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list)
active=$(grep -hE '^deb ' "${lists[@]}" 2>/dev/null)
if grep -qs 'mirrors.digitalocean.com' /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; then
  mirror="mirrors.digitalocean.com (prepare swaps it to archive.ubuntu.com)"
  warnings+=("apt mirror is mirrors.digitalocean.com: do-release-upgrade aborts on it ('ubuntu-minimal' could not be located); prepare fixes this")
else
  mirror=$(grep -E '^deb ' /etc/apt/sources.list 2>/dev/null | head -1 | awk '{print $2}')
  [[ -z "$mirror" ]] && mirror=$(grep -hE '^URIs:' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null | head -1 | awk '{print $2}')
fi
# duplicates as apt sees them once the mirror is swapped (a trailing / on the URI does not matter)
dups=$(sed -E 's|https?://mirrors\.digitalocean\.com/ubuntu/?|http://archive.ubuntu.com/ubuntu|; s|/ | |; s/[[:space:]]+/ /g' <<<"$active" | sort | uniq -d)
[[ -n "$dups" ]] && warnings+=("duplicate apt source line(s) after the mirror swap, prepare comments them out: $(tr '\n' ';' <<<"$dups")")
while read -r line; do
  [[ -n $line ]] && warnings+=("dead source, the upgrader disables it; re-add a current one afterwards if still needed: $line")
done < <(grep -E 'deb\.nodesource\.com/node_1[0-6]\.x|ppa\.setup-php\.com' <<<"$active"; [[ $codename == focal ]] && grep -E 'ppa\.launchpad(content)?\.net/ondrej/(nginx|apache2)' <<<"$active")
grep -q 'deb\.nodesource\.com' <<<"$active" && warnings+=("nodesource: after the upgrade, set up a current Node LTS with the nodistro repository (https://github.com/nodesource/distributions)")
third_party=$(ls /etc/apt/sources.list.d/ 2>/dev/null | grep -vE '\.(save|distUpgrade)$' | tr '\n' ' ')

root_free=$(df -Pm / | awk 'NR==2{print $4}')
boot_free=$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')
[[ -z "$boot_free" ]] && boot_free=$root_free
root_pct=$(df -P / | awk 'NR==2{print $5}')
cache_mb=$(du -smc ~/.cache/composer ~/.composer/cache ~/.npm/_cacache 2>/dev/null | awk 'END{print $1+0}')
(( root_free >= MIN_ROOT )) || blockers+=("only ${root_free} MB free on / (need ${MIN_ROOT}): composer/npm caches take ${cache_mb} MB (composer clear-cache); also apt-get clean, journalctl --vacuum-size=200M; see the disk verb")
(( boot_free >= MIN_BOOT )) || blockers+=("only ${boot_free} MB free on /boot (need ${MIN_BOOT}): remove old kernels")

php_bins=$(for b in /usr/bin/php[0-9].[0-9]; do [[ -x $b ]] && printf '%s=%s ' "${b##*/php}" "$($b -r 'echo PHP_VERSION;' 2>/dev/null)"; done)
php_pkgs=$(dpkg --get-selections 2>/dev/null | grep -cE '^php')

mysql_pkg=$(dpkg -l 2>/dev/null | awk '/^ii +mysql-(community-)?server[ -]/ {print $2" "$3}' | head -1)
[[ -z "$mysql_pkg" ]] && mysql_pkg=$(dpkg -l 2>/dev/null | awk '/^ii +mariadb-server[ -]/ {print $2" "$3}' | head -1)
[[ -z "$mysql_pkg" ]] && mysql_pkg="none installed"
case "$mysql_pkg" in
  mysql-community-server*)
    series=$(awk '{print $2}' <<<"$mysql_pkg" | cut -d. -f1,2)
    warnings+=("MySQL is Oracle's mysql-community-server $series (repo.mysql.com): after the upgrade, postflight prints how to point mysql-apt-config at the new release")
    [[ $series != 8.0 ]] && warnings+=("Oracle MySQL $series has no Ubuntu equivalent: keep it on repo.mysql.com, never swap it to Ubuntu's mysql-server-8.0 (that is a downgrade the data directory cannot start on)")
    ;;
esac
mysql_cnf_err=$(mysqld --validate-config 2>&1 | grep -m1 'ERROR' || true)
[[ -n "$mysql_cnf_err" ]] && warnings+=("MySQL option files are invalid: '${mysql_cnf_err#*] }'; mysqld skips the rest of that file, fix it after the upgrade (see the runbook)")

ed25519=$(grep -c 'ssh-ed25519' ~/.ssh/authorized_keys 2>/dev/null || true); ed25519=${ed25519:-0}
(( ed25519 > 0 )) || warnings+=("no ssh-ed25519 key in ~/.ssh/authorized_keys: newer OpenSSH refuses SHA-1 (ssh-rsa) signatures; add an ed25519 key and keep the provider console at hand")

command -v screen >/dev/null || warnings+=("screen is not installed (prepare installs it)")
command -v do-release-upgrade >/dev/null || warnings+=("update-manager-core is not installed (prepare installs it)")
[[ -f /var/run/reboot-required ]] && warnings+=("a reboot is pending (/var/run/reboot-required): reboot after prepare, before upgrade")

sites=$(ls /etc/nginx/sites-enabled 2>/dev/null | grep -vcE '^(default|000-.*)$')
cron_lines=$(crontab -l 2>/dev/null | grep -vcE '^(#|$)' || true); cron_lines=${cron_lines:-0}

printf '## %s: upgrade preflight (target: %s)\n\n' "$HOST" "$TARGET"
printf -- '- **OS:** %s (%s), kernel %s, hop: %s\n' "$desc" "$codename" "$(uname -r)" "$hop"
printf -- '- **nginx:** %s / %s\n' "$nginx_enabled" "$nginx_active"
printf -- '- **Disk:** / %s MB free (%s used), /boot %s MB free, composer/npm caches %s MB\n' "$root_free" "$root_pct" "$boot_free" "$cache_mb"
printf -- '- **apt mirror:** %s\n' "$mirror"
printf -- '- **3rd-party sources:** %s\n' "${third_party:-none}"
printf -- '- **Prompt=:** %s\n' "${prompt:-unset}"
printf -- '- **PHP binaries:** %s(%s php* packages selected)\n' "$php_bins" "$php_pkgs"
printf -- '- **MySQL package:** %s\n' "$mysql_pkg"
printf -- '- **ed25519 keys in authorized_keys:** %s\n' "$ed25519"
printf -- '- **nginx sites enabled:** %s · **crontab lines:** %s\n' "$sites" "$cron_lines"
printf '\n'
if (( ${#warnings[@]} )); then
  printf '### Warnings\n\n'; for w in "${warnings[@]}"; do printf -- '- ⚠ %s\n' "$w"; done; printf '\n'
fi
if (( ${#blockers[@]} )); then
  printf '### Blockers\n\n'; for b in "${blockers[@]}"; do printf -- '- ❌ %s\n' "$b"; done; printf '\n'
  exit 1
fi
exit 0
REMOTE
  )
  remote_ro "$script"
  rc=$?
  case "$rc" in
  0) finish READY "$host can start the next hop" "take a provider snapshot (DigitalOcean: Droplet → Snapshots), then $self prepare $host" ;;
  1) finish BLOCKED "fix the ❌ lines above, then run preflight again" "$self preflight $host" ;;
  *) remote_fail "$rc" "preflight" ;;
  esac
}

function do_disk() {
  local rc
  remote_sudo "$(
    cat <<'REMOTE'
echo "## disk report"; echo
df -h / /boot 2>/dev/null; echo
echo "### biggest directories (depth 2)"
du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -20; echo
echo "### MySQL data and binary logs   → free: mysql -e 'PURGE BINARY LOGS BEFORE NOW() - INTERVAL 1 DAY;'"
du -sh /var/lib/mysql 2>/dev/null
du -ch /var/lib/mysql/binlog.* /var/lib/mysql/mysql-bin.* 2>/dev/null | tail -1 || echo "none"
echo "### rotated / compressed logs   → free: find /var/log -regex '.*\.\(gz\|[0-9]\)' -delete"
find /var/log -regex '.*\.\(gz\|[0-9]\)' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {printf "%.1f MB in %d files\n", s/1048576, NR}'
echo "### systemd journal   → free: journalctl --vacuum-size=200M"
journalctl --disk-usage 2>/dev/null | sed 's/^/   /'
echo "### apt cache   → free: apt-get clean"
du -sh /var/cache/apt 2>/dev/null
echo "### Laravel logs per site   → free: find /home/forge/*/storage/logs -name 'laravel-*.log' -mtime +7 -delete"
du -sh /home/forge/*/storage/logs 2>/dev/null | sort -rh | head -8
echo "### storage/app per site (uploads: do NOT delete blindly)"
du -sh /home/forge/*/storage/app 2>/dev/null | sort -rh | head -8
echo "### composer / npm caches   → free: composer clear-cache (as forge); rm -rf /home/forge/.npm/_cacache"
du -sh /home/forge/.composer/cache /home/forge/.cache/composer /home/forge/.npm/_cacache /root/.composer/cache /root/.cache/composer 2>/dev/null
echo "### /tmp   → leftover PHP uploads (/tmp/php*) can go once nginx is down"
du -sh /tmp 2>/dev/null
echo "### kernels installed   → free: apt-get purge linux-image-<old>-generic linux-modules-<old>-generic"
dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/ {print "   "$2"  "$3}'
echo "   running: $(uname -r)"
echo "### deleted-but-open files (space only comes back when the holder restarts)"
lsof -nP +L1 2>/dev/null | awk 'NR>1 {s+=$7} END {printf "   %.1f MB held by %d open deleted files\n", s/1048576, NR-1}'
lsof -nP +L1 2>/dev/null | awk 'NR>1 {print "   "$1" pid "$2" "$10}' | sort | uniq -c | sort -rn | head -5
REMOTE
  )"
  rc=$?
  ((rc)) && {
    remote_fail "$rc" "disk report"
    return
  }
  finish OK "disk report for $host" "$self preflight $host"
}

function do_nginx_down() {
  local rc
  IO:confirm "Take ALL sites on $host offline (stop + mask nginx)?" || {
    finish FAILED "cancelled (run with -f when there is no terminal)"
    return
  }
  # shellcheck disable=SC2016 # the $(...) must expand on the server
  remote_sudo 'systemctl stop nginx; systemctl mask nginx; printf "nginx: %s / %s\n" "$(systemctl is-enabled nginx 2>&1)" "$(systemctl is-active nginx 2>&1)"'
  rc=$?
  ((rc)) && {
    remote_fail "$rc" "nginx-down"
    return
  }
  echo "nginx is stopped and masked: every site on $host is OFFLINE, also across the reboots"
  finish OK "nginx is down on $host" "$self preflight $host"
}

function do_nginx_up() {
  local rc
  IO:confirm "Bring the sites on $host back online (unmask + start nginx)?" || {
    finish FAILED "cancelled (run with -f when there is no terminal)"
    return
  }
  # shellcheck disable=SC2016 # the $(...) must expand on the server
  remote_sudo 'systemctl unmask nginx && nginx -t && systemctl enable --now nginx && printf "nginx: %s / %s\n" "$(systemctl is-enabled nginx)" "$(systemctl is-active nginx)"'
  rc=$?
  ((rc)) && {
    remote_fail "$rc" "nginx-up"
    return
  }
  finish OK "nginx is back on $host" "$self verify $host"
}

function do_prepare() {
  local code to hop script rc dump local_dump
  guard_facts || return
  code="${fact[codename]}"
  to=$(next_codename "$code")
  if [[ -z "$to" || $code == "$target" ]] || (($(codename_rank "$code") >= $(codename_rank "$target"))); then
    finish BLOCKED "$host is on $code: nothing to prepare for --target $target" "$self status $host"
    return
  fi
  if [[ ${fact[nginx_enabled]:-} != masked ]]; then
    finish BLOCKED "nginx is ${fact[nginx_enabled]:-?}/${fact[nginx_active]:-?}: take the sites offline first" "$self nginx-down $host"
    return
  fi
  hop="$code-to-$to"
  IO:confirm "Prepare $host for $code → $to (backups, DB dump, mirror fix, apt full-upgrade)?" || {
    finish FAILED "cancelled (run with -f when there is no terminal)"
    return
  }

  script="$(vars_script B="$backup_root/$hop" ROOT="$backup_root" FROM="$code" PORT="$fallback_ssh_port")"$'\n'
  script+=$(
    cat <<'REMOTE'
set -e
shopt -s nullglob
mkdir -p "$B"
chmod 755 "$ROOT" "$B"
echo "→ backups into $B"
dpkg --get-selections | awk '$1 ~ /^php/ && $2 == "install" {print $1}' >"$B/php-packages.txt"
chmod 644 "$B/php-packages.txt"
for b in /usr/bin/php[0-9].[0-9]; do "$b" -m >"$B/php-modules-${b##*/php}.txt" 2>/dev/null || true; done
dpkg -l >"$B/dpkg-list.txt"
# the first run of prepare keeps the original apt sources: a re-run must not overwrite them with swapped ones
[ -f "$B/sources.list.bak" ] || cp -a /etc/apt/sources.list "$B/sources.list.bak"
[ -d "$B/sources.list.d.bak" ] || cp -a /etc/apt/sources.list.d "$B/sources.list.d.bak"
for d in php nginx supervisor mysql; do
  if [ -d "/etc/$d" ]; then rm -rf "$B/etc-$d"; cp -a "/etc/$d" "$B/etc-$d"; chmod 700 "$B/etc-$d"; fi
done
crontab -l -u forge >"$B/crontab-forge.txt" 2>/dev/null || true
ls /etc/nginx/sites-enabled >"$B/sites-enabled.txt" 2>/dev/null || true
lsb_release -a >"$B/lsb_release.txt" 2>/dev/null || true
echo "   $(wc -l <"$B/php-packages.txt") php packages recorded"

dedupe() {  # comment out deb lines that repeat an earlier one (a trailing / on the URI and extra spaces do not count)
  local f=$1 tmp
  tmp=$(mktemp)
  awk '/^deb /{ k=$0; gsub(/[ \t]+/," ",k); gsub(/\/ /," ",k); if (seen[k]++) { print "# duplicate (upgrade-ubuntu): " $0; next } } { print }' "$f" >"$tmp"
  if ! cmp -s "$f" "$tmp"; then cat "$tmp" >"$f"; echo "→ $f: duplicate source lines commented out"; fi
  rm -f "$tmp"
}
for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
  [ -f "$f" ] || continue
  if grep -q 'mirrors.digitalocean.com' "$f"; then
    echo "→ $f: mirrors.digitalocean.com → archive.ubuntu.com"
    sed -i -E 's|https?://mirrors\.digitalocean\.com/ubuntu|http://archive.ubuntu.com/ubuntu|g' "$f"
    if grep -q 'mirrors.digitalocean.com' "$f"; then echo "✗ a mirrors.digitalocean.com entry survived: fix $f by hand"; exit 1; fi
  fi
done
dedupe /etc/apt/sources.list

echo "→ Prompt=lts"
sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades 2>/dev/null || true
grep -qs '^Prompt=lts' /etc/update-manager/release-upgrades || echo 'Prompt=lts' >>/etc/update-manager/release-upgrades
echo "→ ufw allow $PORT/tcp (do-release-upgrade's fallback sshd)"
ufw allow "$PORT/tcp" >/dev/null 2>&1 || echo "   (ufw not active or not installed: skipped)"

echo "→ apt-get update + full-upgrade ($FROM must be fully up to date before the release upgrade)"
apt-get update || true
if ! apt-cache policy | grep -qE "ubuntu\.com/ubuntu/? $FROM(-updates)?/main"; then
  echo "✗ apt-get update did not fetch the Ubuntu archive for $FROM: check /etc/apt/sources.list (see docs/faq/apt.md)"
  exit 1
fi
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y -o Dpkg::Options::=--force-confold install screen update-manager-core
apt-get -y autoremove --purge
apt-get clean
journalctl --vacuum-size=200M >/dev/null 2>&1 || true
echo "→ disk after cleanup:"
df -h / /boot 2>/dev/null | awk '!seen[$1]++'
[ -f /var/run/reboot-required ] && echo "→ a reboot is pending" || true
REMOTE
  )
  remote_sudo "$script"
  rc=$?
  ((rc)) && {
    remote_fail "$rc" "prepare"
    return
  }

  # shellcheck disable=SC2154 # no_dump is set by Option:initialize/Option:parse via eval
  if ((no_dump)); then
    echo "→ no MySQL dump (--no_dump): the provider snapshot is the only database backup"
  else
    local_dump="$LOG_DIR/${host//\//_}/all-databases.$(date '+%Y%m%d-%H%M%S').sql.gz"
    echo "→ MySQL dump to $backup_root/$hop/all-databases.sql.gz on the server + $local_dump here:"
    dump="$(vars_script B="$backup_root/$hop")"$'\n'
    dump+=$(
      cat <<'REMOTE'
set -o pipefail
umask 077
command -v mysqldump >/dev/null || { echo "no mysqldump on this server" >&2; exit 5; }
need=$(du -sm /var/lib/mysql 2>/dev/null | cut -f1); free=$(df -Pm "$B" | awk 'NR==2{print $4}')
if (( ${need:-0} > ${free:-0} )); then echo "not enough space for the dump: MySQL uses ${need} MB, ${free} MB free" >&2; exit 7; fi
mysqldump --all-databases --single-transaction --routines --events --triggers 2>"$B/mysqldump.err" | gzip | tee "$B/all-databases.sql.gz"
rc=$?
chmod 600 "$B/all-databases.sql.gz"
if grep -q 'Access denied' "$B/mysqldump.err"; then cat "$B/mysqldump.err" >&2; exit 6; fi
if (( rc )); then cat "$B/mysqldump.err" >&2; exit "$rc"; fi
REMOTE
    )
    (umask 077 && remote_sudo "$dump" raw >"$local_dump")
    rc=$?
    case "$rc" in
    0)
      if [[ -s "$local_dump" ]] && gzip -t "$local_dump" 2>/dev/null; then
        echo "   dump OK: $(du -h "$local_dump" | cut -f1) ($local_dump)"
      else
        finish FAILED "the local copy of the dump is empty or broken: $local_dump" "$self prepare $host"
        return
      fi
      ;;
    5)
      rm -f "$local_dump"
      echo "   no MySQL on $host: no dump"
      ;;
    6)
      rm -f "$local_dump"
      finish BLOCKED "root cannot log in to MySQL for the dump" "create /root/.my.cnf on $host ([client] user=root password=... ; chmod 600; the password is in the Forge provisioning e-mail), or re-run with --no_dump: $self --no_dump prepare $host"
      return
      ;;
    7)
      rm -f "$local_dump"
      finish BLOCKED "not enough disk space on $host for the dump" "$self disk $host"
      return
      ;;
    *)
      rm -f "$local_dump"
      remote_fail "$rc" "the MySQL dump"
      return
      ;;
    esac
  fi
  finish OK "$host is prepared for $code → $to; backups in $backup_root/$hop" "reboot: ssh -t $host sudo reboot   (or the Forge dashboard), then $self upgrade $host   (in your own terminal)"
}

function show_upgrade_answers() {
  cat <<'EOF'
What to answer in do-release-upgrade (docs/faq/ubuntu20.md):
  - third-party sources will be disabled        → yes (Enter)
  - "Do you want to start the upgrade? y/N/d"   → d first, read the REMOVE list:
                                                  any php* or mysql-community-* in it → N, and ask for help
  - modified configuration files                → keep your version (N, the default)
  - "Remove obsolete packages?"                 → NO (they include PHP and its extensions)
  - restart services automatically              → yes
  - "Failure restarting ... mysql" (libc)       → OK, it comes back after the reboot
  - at the end: reboot                          → yes
Lost the connection? ssh -t <host> sudo screen -x upgrade
EOF
}

function do_upgrade() {
  local code to cmd
  guard_facts || return
  code="${fact[codename]}"
  to=$(next_codename "$code")
  if [[ " ${fact[hops]:-} " != *" $code-to-$to "* ]]; then
    finish BLOCKED "$host is on $code and not prepared for a hop" "$self status $host"
    return
  fi
  if ((${fact[upgrader_running]:-0})); then
    finish NEEDS-ADMIN "do-release-upgrade is already running on $host" "ssh -t $host sudo screen -x upgrade   (in your own terminal)"
    return
  fi
  if ((${fact[reboot_required]:-0})); then
    finish NEEDS-ADMIN "reboot $host first (pending after prepare)" "ssh -t $host sudo reboot   (or the Forge dashboard), then $self upgrade $host"
    return
  fi
  cmd="sudo mkdir -p /var/log/dist-upgrade && sudo screen -L -Logfile /var/log/dist-upgrade/screen.log -S upgrade do-release-upgrade"
  if [[ -t 0 && -t 1 ]] && Os:has_tty; then
    show_upgrade_answers
    echo ""
    # -f alone does not start an interactive upgrade: this always asks
    FORCE=0 IO:confirm "Start do-release-upgrade $code → $to on $host now?" || {
      finish FAILED "cancelled"
      return
    }
    ssh -t "$host" "$cmd"
    # 255: the server closed the connection, i.e. the upgrade rebooted it
    if (($? == 255)); then
      finish NEEDS-ADMIN "do-release-upgrade ended on $host and it is rebooting" "wait a few minutes, then $self status $host"
      return
    fi
    finish NEEDS-ADMIN "do-release-upgrade ended on $host (or was detached)" "if it did not reboot: ssh -t $host sudo reboot; then $self status $host"
    return
  fi
  show_upgrade_answers
  finish NEEDS-ADMIN "do-release-upgrade $code → $to is interactive: run it in your own terminal" "$self upgrade $host   (or by hand: ssh -t $host \"$cmd\")"
}

function do_logs() {
  local rc
  remote_sudo "$(
    cat <<'REMOTE'
d=/var/log/dist-upgrade
[ -d $d ] || { echo "no $d yet: do-release-upgrade has not run"; exit 0; }
for f in main.log apt.log; do
  [ -f "$d/$f" ] || continue
  echo "### $d/$f: errors and warnings (last 20)"
  grep -nE 'ERROR|was disabled|could not be located|Failed|^E: ' "$d/$f" | tail -20
  echo
done
[ -f $d/main.log ] && { echo "### $d/main.log (last 40 lines)"; tail -n 40 $d/main.log; echo; }
if [ -f $d/screen.log ]; then
  echo "### $d/screen.log (last 60 lines, what was on screen)"
  tail -n 200 $d/screen.log | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][A-Z0-9]//g; s/\x1b[=>]//g' | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 60
fi
REMOTE
  )"
  rc=$?
  ((rc)) && {
    remote_fail "$rc" "reading the logs"
    return
  }
  stage_finish
}

function do_postflight() {
  local code hop from script rc
  guard_facts || return
  code="${fact[codename]}"
  hop=""
  for from in focal jammy; do
    [[ " ${fact[hops]:-} " == *" $from-to-$code "* ]] && hop="$from-to-$code"
  done
  if [[ -z "$hop" ]]; then
    finish BLOCKED "$host is on $code, and no prepared hop ends there: has do-release-upgrade finished and rebooted?" "$self status $host"
    return
  fi
  IO:confirm "Run postflight on $host ($hop): re-add ppa:ondrej/php, reinstall PHP, restart services?" || {
    finish FAILED "cancelled (run with -f when there is no terminal)"
    return
  }
  # shellcheck disable=SC2154 # drop_php/disable are set by Option:initialize/Option:parse via eval
  script="$(vars_script B="$backup_root/$hop" CODE="$code" DROP="$drop_php" DISABLE="$disable")"$'\n'
  script+=$(
    cat <<'REMOTE'
set -e
shopt -s nullglob
[ "$(lsb_release -cs)" = "$CODE" ] || { echo "✗ not on $CODE"; exit 1; }
[ -f "$B/php-packages.txt" ] || { echo "✗ $B/php-packages.txt missing: was prepare run?"; exit 1; }
echo "→ ppa:ondrej/php for $CODE"
command -v add-apt-repository >/dev/null || apt-get -y install software-properties-common
rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list.distUpgrade
add-apt-repository -y ppa:ondrej/php >/dev/null
apt-get update || true
echo "→ PHP package list (dropping: ${DROP:-nothing})"
want=$(cat "$B/php-packages.txt")
for v in $(echo "$DROP" | tr ',' ' '); do want=$(awk -v p="php$v" 'index($0, p "-") != 1 && $0 != p' <<<"$want"); done
install=""
for p in $want; do
  if apt-cache show "$p" >/dev/null 2>&1; then install="$install $p"; else echo "   skip $p (not available on $CODE)"; fi
done
echo "→ installing $(echo $install | wc -w) PHP packages"
# shellcheck disable=SC2086
apt-get -y -o Dpkg::Options::=--force-confold install $install
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
for v in $(echo "$DROP" | tr ',' ' '); do
  if dpkg -l "php$v*" 2>/dev/null | grep -q '^ii'; then
    echo "→ purging php$v packages"
    apt-get -y purge "php$v*" || true
  fi
done
echo "→ sources the upgrader disabled (re-add each one for $CODE if it is still needed):"
{ grep -l 'disabled on upgrade' /etc/apt/sources.list.d/*.list 2>/dev/null; grep -l '^Enabled: no' /etc/apt/sources.list.d/*.sources 2>/dev/null; } | sed 's/^/   /' || true
if grep -qs 'deb.nodesource.com' /etc/apt/sources.list.d/*; then
  echo "   nodesource: set up a current Node LTS with the nodistro repository: https://github.com/nodesource/distributions"
fi
for s in $(echo "$DISABLE" | tr ',' ' '); do
  echo "→ disabling site $s"
  rm -f "/etc/nginx/sites-enabled/$s"
  if crontab -l -u forge 2>/dev/null | grep -q "/home/forge/$s/"; then
    crontab -l -u forge | grep -v "/home/forge/$s/" | crontab -u forge -
    echo "   forge crontab line(s) for $s removed"
  fi
  for c in $(grep -ls "/home/forge/$s/" /etc/supervisor/conf.d/*.conf 2>/dev/null); do
    mv "$c" "$c.disabled"; echo "   supervisor program $c disabled"
  done
done
if command -v supervisorctl >/dev/null; then supervisorctl reread >/dev/null || true; supervisorctl update >/dev/null || true; fi
echo "→ restarting php-fpm"
for d in /etc/php/*/; do
  v=$(basename "$d")
  if systemctl restart "php$v-fpm" 2>/dev/null; then echo "   php$v-fpm restarted"; else echo "   php$v-fpm: no unit"; fi
done
echo "→ restarting supervisor programs (queue workers keep the old, deleted php binary until restarted)"
if command -v supervisorctl >/dev/null; then supervisorctl restart all 2>&1 | sed 's/^/   /' || true; else echo "   no supervisor"; fi
nginx -t 2>&1 | sed 's/^/   /' || true
echo "→ MySQL: $(systemctl is-active mysql 2>/dev/null || true) $(mysql --version 2>/dev/null || true)"
echo "→ PHP binaries now:"
for b in /usr/bin/php[0-9].[0-9]; do [ -x "$b" ] && printf '   %s %s\n' "${b##*/php}" "$("$b" -r 'echo PHP_VERSION;')"; done
# Oracle MySQL: its apt source has to be pointed at the new release by hand (a dialog)
if dpkg -l 2>/dev/null | grep -qE '^ii +mysql-community-server[ -]'; then
  if ! grep -hsE '^deb .*repo\.mysql\.com' /etc/apt/sources.list.d/*.list | grep -q " $CODE "; then
    echo "→ Oracle MySQL: /etc/apt/sources.list.d/mysql.list does not point at $CODE yet"
    exit 10
  fi
fi
exit 0
REMOTE
  )
  remote_sudo "$script"
  rc=$?
  case "$rc" in
  0) ;;
  10)
    # dpkg-reconfigure alone keeps the stored codename (no dialog) and rewrites mysql.list with the old release
    finish NEEDS-ADMIN "PHP is back; Oracle MySQL's apt source still needs $code" "ssh -t $host 'echo \"mysql-apt-config mysql-apt-config/repo-codename select $code\" | sudo debconf-set-selections && sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure mysql-apt-config && sudo apt-get update && sudo apt-get install --only-upgrade \"mysql-community-*\"'   (EXPKEYSIG B7B3B788A8D3785C: see docs/faq/ubuntu20.md), then $self status $host"
    return
    ;;
  *)
    remote_fail "$rc" "postflight"
    return
    ;;
  esac
  if [[ $code != "$target" ]]; then
    finish OK "$host is on $code with PHP back; the sites stay offline for the $code → $(next_codename "$code") hop" "$self preflight $host, then $self prepare $host"
  else
    finish OK "$host is on $code with PHP back; nginx is still DOWN" "./php-patcher.sh host $host   (every line OK? else ./php-patcher.sh --patch host $host), then $self nginx-up $host"
  fi
}

# shellcheck disable=SC2154 # fixed is set by Option:initialize/Option:parse via eval
function do_verify() {
  local script rc=0 remote_rc sudo_out stale ufw1022 sites site code bad=0 n=0
  script="$(vars_script HOST="$host" TARGET="$target" FIXED="$fixed")"$'\n'
  script+=$(
    cat <<'REMOTE'
shopt -s nullglob
fail=0
st() { local o; o=$(systemctl "$1" "$2" 2>/dev/null) || true; printf '%s' "${o:-$3}"; }
codename=$(lsb_release -cs 2>/dev/null); desc=$(lsb_release -ds 2>/dev/null)
running=$(uname -r)
latest=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
printf '## %s: upgrade verify\n\n' "$HOST"
if [[ "$codename" == "$TARGET" ]]; then printf -- '- ✅ **OS:** %s\n' "$desc"; else printf -- '- ❌ **OS:** %s (expected %s)\n' "$desc" "$TARGET"; fail=1; fi
if [[ "$running" == "$latest" ]]; then printf -- '- ✅ **Kernel:** %s (latest installed)\n' "$running"; else printf -- '- ❌ **Kernel:** running %s, installed %s: REBOOT NEEDED\n' "$running" "$latest"; fail=1; fi
printf -- '- **PHP:**\n'
for d in /etc/php/*/; do
  v=$(basename "$d")
  pkgver=""
  [[ $(dpkg-query -W -f='${db:Status-Status}' "php$v-cli" 2>/dev/null) == installed ]] &&
    pkgver=$(dpkg-query -W -f='${Version}' "php$v-cli" 2>/dev/null | sed 's/^[0-9]*://; s/[-+].*//')
  want=""
  for f in $FIXED; do [[ ${f%.*} == "$v" ]] && want=$f; done
  fpm=$(st is-active "php$v-fpm" inactive)
  if [[ -z "$pkgver" ]]; then printf -- '    - ⚠ %s: /etc/php/%s exists but php%s-cli is not installed\n' "$v" "$v" "$v"; continue; fi
  if [[ -z "$want" ]]; then printf -- '    - ⚠ %s: %s (end of life, no fixed version), fpm %s\n' "$v" "$pkgver" "$fpm"
  elif dpkg --compare-versions "$pkgver" ge "$want"; then printf -- '    - ✅ %s: %s ≥ %s, fpm %s\n' "$v" "$pkgver" "$want" "$fpm"
  else printf -- '    - ❌ %s: %s < %s, fpm %s\n' "$v" "$pkgver" "$want" "$fpm"; fail=1; fi
  if [[ $fpm != active ]] && [[ -e /lib/systemd/system/php$v-fpm.service ]]; then printf -- '      ❌ php%s-fpm is %s\n' "$v" "$fpm"; fail=1; fi
done
if dpkg -l 2>/dev/null | grep -qE '^ii +(mysql-(community-)?server|mariadb-server)[ -]'; then
  mysql_state=$(st is-active mysql inactive)
  mysql_ver=$(mysql --version 2>/dev/null | sed 's/, for.*//')
  if [[ "$mysql_state" == "active" ]]; then printf -- '- ✅ **MySQL:** %s (%s)\n' "$mysql_state" "$mysql_ver"; else printf -- '- ❌ **MySQL:** %s\n' "$mysql_state"; fail=1; fi
fi
ne=$(st is-enabled nginx missing); na=$(st is-active nginx inactive)
if [[ "$ne" != "masked" && "$na" == "active" ]]; then printf -- '- ✅ **nginx:** %s / %s\n' "$ne" "$na"; else printf -- '- ❌ **nginx:** %s / %s (nginx-up)\n' "$ne" "$na"; fail=1; fi
failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[[ -z "$failed_units" ]] && printf -- '- ✅ **systemd:** no failed units\n' || printf -- '- ⚠ **systemd failed units:** %s\n' "$failed_units"
cruft=$(find /etc/apt \( -name '*.distUpgrade' -o -name '*.save' \) 2>/dev/null | wc -l | tr -d ' ')
[[ "$cruft" == "0" ]] && printf -- '- ✅ no *.distUpgrade / *.save left in /etc/apt\n' || printf -- '- ⚠ %s *.distUpgrade / *.save files in /etc/apt (cleanup)\n' "$cruft"
printf -- '- **Sites enabled:** %s\n' "$(ls /etc/nginx/sites-enabled 2>/dev/null | grep -vE '^(default|000-.*)$' | tr '\n' ' ')"
exit $fail
REMOTE
  )
  remote_ro "$script"
  remote_rc=$?
  ((remote_rc == 255)) && {
    remote_fail 255 "verify"
    return
  }
  ((remote_rc)) && rc=1

  if pw_has "$host"; then
    # shellcheck disable=SC2016 # expands on the server
    sudo_out=$(remote_sudo "grep -lE ' /(usr|lib|opt).*\(deleted\)\$' /proc/[0-9]*/maps 2>/dev/null | wc -l; ufw status 2>/dev/null | grep -c '$fallback_ssh_port/tcp' || true" 2>/dev/null | tr -d ' ')
    stale=$(sed -n 1p <<<"$sudo_out")
    ufw1022=$(sed -n 2p <<<"$sudo_out")
    if [[ -z "$stale" ]]; then
      echo "- ⚠ **Stale binaries:** could not check (sudo failed)"
    elif [[ "$stale" == "0" ]]; then
      echo "- ✅ **Stale binaries:** no process maps a deleted file"
    else
      echo "- ❌ **Stale binaries:** $stale processes still map deleted files: supervisorctl restart all, or reboot once more"
      rc=1
    fi
    [[ "${ufw1022:-0}" != "0" ]] && echo "- ⚠ **ufw:** still allows $fallback_ssh_port/tcp (cleanup removes it)"
  else
    echo "- ⚠ **Stale binaries / ufw:** not checked (no stored sudo password: $self password $host)"
  fi

  echo ""
  echo "### HTTPS probes (from this machine)"
  echo ""
  sites=$(remote_ro 'ls /etc/nginx/sites-enabled 2>/dev/null' 2>/dev/null | grep -vE '^(default|000-.*)$')
  while read -r site; do
    [[ -z "$site" ]] && continue
    n=$((n + 1))
    code=$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "https://$site/" 2>/dev/null) || true
    code=${code:-000}
    case "$code" in
    2* | 3* | 401) echo "- ✅ $site → $code" ;;
    403 | 404) echo "- ⚠ $site → $code (served, but check the app: IP allow-list? no root route?)" ;;
    *)
      echo "- ❌ $site → $code"
      bad=$((bad + 1))
      ;;
    esac
  done <<<"$sites"
  echo ""
  echo "$n sites probed, $bad failing"
  ((bad)) && rc=1
  if ((rc)); then
    finish FAILED "fix the ❌ lines above, then verify again" "$self verify $host"
  else
    finish OK "$host is on $target and everything checks out" "$self cleanup $host"
  fi
}

function do_cleanup() {
  local rc
  guard_facts || return
  IO:confirm "Clean up the upgrade leftovers on $host (port $fallback_ssh_port, *.distUpgrade, *.save)?" || {
    finish FAILED "cancelled (run with -f when there is no terminal)"
    return
  }
  remote_sudo "$(vars_script ROOT="$backup_root" PORT="$fallback_ssh_port")"$'\n'"$(
    cat <<'REMOTE'
if ufw status 2>/dev/null | grep -q "$PORT/tcp"; then ufw delete allow "$PORT/tcp" >/dev/null && echo "→ ufw rule for $PORT/tcp removed"; else echo "→ no ufw rule for $PORT/tcp"; fi
echo "→ removing upgrade leftovers in /etc/apt:"
find /etc/apt \( -name '*.distUpgrade' -o -name '*.save' \) 2>/dev/null | sed 's/^/   /'
find /etc/apt \( -name '*.distUpgrade' -o -name '*.save' \) -delete 2>/dev/null
apt-get -y autoremove --purge >/dev/null 2>&1 || true
apt-get clean
echo "→ still on the server (delete when the provider snapshot goes, after a week):"
du -sh "$ROOT"/* 2>/dev/null | sed 's/^/   /' || echo "   $ROOT absent"
df -h / | tail -1
REMOTE
  )"
  rc=$?
  ((rc)) && {
    remote_fail "$rc" "cleanup"
    return
  }
  echo "→ on this machine:"
  find "$LOG_DIR/${host//\//_}" -name 'all-databases.*.sql.gz' -exec ls -lh {} + 2>/dev/null | sed 's/^/   /'
  if [[ ${fact[codename]:-} == "$target" ]]; then
    pw_forget "$host" && echo "→ stored sudo password for $host deleted"
    finish OK "$host is cleaned up" "after a week of clean running: delete the provider snapshot, ssh -t $host sudo rm -rf $backup_root, and rm $LOG_DIR/${host//\//_}/all-databases.*.sql.gz"
  else
    finish OK "$host is cleaned up between hops" "$self status $host"
  fi
}

#####################################################################
################### DO NOT MODIFY BELOW THIS LINE ###################
#####################################################################

action=""
error_prefix=""
git_repo_remote=""
git_repo_root=""
install_package=""
os_kernel=""
os_machine=""
os_name=""
os_version=""
script_basename=""
script_hash="?"
script_lines="?"
script_prefix=""
shell_brand=""
shell_version=""
temp_files=()

# set strict mode -  via http://redsymbol.net/articles/unofficial-bash-strict-mode/
# removed -e because it made basic [[ testing ]] difficult
set -uo pipefail
IFS=$'\n\t'
FORCE=0
help=0

#to enable VERBOSE even before option parsing
VERBOSE=0
[[ $# -gt 0 ]] && [[ $1 == "-v" ]] && VERBOSE=1

#to enable QUIET even before option parsing
QUIET=0
[[ $# -gt 0 ]] && [[ $1 == "-q" ]] && QUIET=1

txtReset=""
txtError=""
txtInfo=""
txtInfo=""
txtWarn=""
txtBold=""
txtItalic=""
txtUnderline=""

char_succes="OK "
char_fail="!! "
char_alert="?? "
char_wait="..."
info_icon="(i)"
config_icon="[c]"
clean_icon="[c]"
require_icon="[r]"

### stdIO:print/stderr output
function IO:initialize() {
  script_started_at="$(Tool:time)"
  IO:debug "script $script_basename started at $script_started_at"

  [[ "${BASH_SOURCE[0]:-}" != "${0}" ]] && sourced=1 || sourced=0
  [[ -t 1 ]] && piped=0 || piped=1 # detect if output is piped
  if [[ $piped -eq 0 && -n "$TERM" ]]; then
    txtReset=$(tput sgr0)
    txtError=$(tput setaf 160)
    txtInfo=$(tput setaf 2)
    txtWarn=$(tput setaf 214)
    txtBold=$(tput bold)
    txtItalic=$(tput sitm)
    txtUnderline=$(tput smul)
  fi

  [[ $(echo -e '\xe2\x82\xac') == '€' ]] && unicode=1 || unicode=0 # detect if unicode is supported
  if [[ $unicode -gt 0 ]]; then
    char_succes="✅"
    char_fail="⛔"
    char_alert="✴️"
    char_wait="⏳"
    info_icon="🌼"
    config_icon="🌱"
    clean_icon="🧽"
    require_icon="🔌"
  fi
  error_prefix="${txtError}>${txtReset}"
}

function IO:print() {
  ((QUIET)) && true || printf '%b\n' "$*"
}

function IO:debug() {
  ((VERBOSE)) && IO:print "${txtInfo}# $* ${txtReset}" >&2
  true
}

function IO:die() {
  IO:print "${txtError}${char_fail} $script_basename${txtReset}: $*" >&2
  Os:beep
  Script:exit
}

function IO:alert() {
  IO:print "${txtWarn}${char_alert}${txtReset}: ${txtUnderline}$*${txtReset}" >&2
}

function IO:success() {
  IO:print "${txtInfo}${char_succes}${txtReset}  ${txtBold}$*${txtReset}"
}

function IO:announce() {
  IO:print "${txtInfo}${char_wait}${txtReset}  ${txtItalic}$*${txtReset}"
  sleep 1
}

function IO:progress() {
  ((QUIET)) || (
    local screen_width
    screen_width=$(tput cols 2>/dev/null || echo 80)
    local rest_of_line
    rest_of_line=$((screen_width - 5))

    if ((piped)); then
      IO:print "... $*" >&2
    else
      printf "... %-${rest_of_line}b\r" "$*                                             " >&2
    fi
  )
}

function IO:countdown() {
  local seconds=${1:-5}
  local message=${2:-Countdown :}
  local i

  if ((piped)); then
    IO:print "$message $seconds seconds"
  else
    for ((i = 0; i < "$seconds"; i++)); do
      IO:progress "${txtInfo}$message $((seconds - i)) seconds${txtReset}"
      sleep 1
    done
    IO:print "                         "
  fi
}

### interactive
function IO:confirm() {
  ((FORCE)) && return 0
  read -r -p "$1 [y/N] " -n 1
  echo " "
  [[ $REPLY =~ ^[Yy]$ ]]
}

function IO:question() {
  local ANSWER
  local DEFAULT=${2:-}
  read -r -p "$1 ($DEFAULT) > " ANSWER
  [[ -z "$ANSWER" ]] && echo "$DEFAULT" || echo "$ANSWER"
}

function IO:log() {
  [[ -n "${log_file:-}" ]] && echo "$(date '+%H:%M:%S') | $*" >>"$log_file"
}

function Tool:calc() {
  awk "BEGIN {print $*} ; "
}

function Tool:round() {
  local number="${1}"
  local decimals="${2:-0}"

  awk "BEGIN {print sprintf( \"%.${decimals}f\" , $number )};"
}

function Tool:time() {
  if [[ $(command -v perl) ]]; then
    perl -MTime::HiRes=time -e 'printf "%f\n", time'
  elif [[ $(command -v php) ]]; then
    php -r 'printf("%f\n",microtime(true));'
  elif [[ $(command -v python) ]]; then
    python -c 'import time; print(time.time()) '
  elif [[ $(command -v python3) ]]; then
    python3 -c 'import time; print(time.time()) '
  elif [[ $(command -v node) ]]; then
    node -e 'console.log(+new Date() / 1000)'
  elif [[ $(command -v ruby) ]]; then
    ruby -e 'STDOUT.puts(Time.now.to_f)'
  else
    date '+%s.000'
  fi
}

function Tool:throughput() {
  local time_started="$1"
  [[ -z "$time_started" ]] && time_started="$script_started_at"
  local operations="${2:-1}"
  local name="${3:-operation}"

  local time_finished
  local duration
  local seconds
  time_finished="$(Tool:time)"
  duration="$(Tool:calc "$time_finished - $time_started")"
  seconds="$(Tool:round "$duration")"
  local ops
  if [[ "$operations" -gt 1 ]]; then
    if [[ $operations -gt $seconds ]]; then
      ops=$(Tool:calc "$operations / $duration")
      ops=$(Tool:round "$ops" 3)
      duration=$(Tool:round "$duration" 2)
      IO:print "$operations $name finished in $duration secs: $ops $name/sec"
    else
      ops=$(Tool:calc "$duration / $operations")
      ops=$(Tool:round "$ops" 3)
      duration=$(Tool:round "$duration" 2)
      IO:print "$operations $name finished in $duration secs: $ops sec/$name"
    fi
  else
    duration=$(Tool:round "$duration" 2)
    IO:print "$name finished in $duration secs"
  fi
}

function Tool:pick() {
  # pick one option from a list, interactively
  # usage: <<< "option1\noption2" Tool:pick [prompt] [other] [default] [timeout]
  #   input  : options as lines on stdin
  #   output : the chosen option on stdout (empty + return 1 when cancelled or no options)
  #   prompt : text shown with the list (default: "Pick one:")
  #   other  : when non-empty, an extra option with this label is added ("1" = "other: ...")
  #            choosing it lets the user type their own answer, which is returned instead
  #   default: returned when no choice can be made: on timeout, when FORCE is set,
  #            or when there is no terminal to ask on (cron, CI, ...); defaults to the first option
  #   timeout: seconds to wait for a choice before returning the default (0 = wait forever)
  # uses fzf if available, otherwise gum, otherwise a bash-only numbered menu
  local prompt="${1:-Pick one:}"
  local other_option="${2:-}"
  local default="${3:-}"
  local timeout="${4:-0}"
  [[ "$other_option" == "1" ]] && other_option="other: ..."

  local -a options=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && options+=("$line")
  done
  ((${#options[@]} == 0)) && return 1
  [[ -z "$default" ]] && default="${options[0]}"
  [[ -n "$other_option" ]] && options+=("$other_option")

  # non-interactive: forced, or no terminal to ask on -> use the default
  if ((FORCE)) || ! Os:has_tty; then
    echo "$default"
    return 0
  fi

  local hint=""
  ((timeout > 0)) && hint=" (default '$default' after ${timeout}s)"
  local -a read_timeout=()
  ((timeout > 0)) && read_timeout=(-t "$timeout")

  local choice="" timed_out=0
  if [[ $(command -v fzf) ]]; then
    choice=$(printf '%s\n' "${options[@]}" | Tool:_pick_timeout "$timeout" fzf --height="~40%" --layout=reverse --header="$prompt$hint")
    [[ "$choice" == $'\a' ]] && timed_out=1
  elif [[ $(command -v gum) ]]; then
    choice=$(Tool:_pick_timeout "$timeout" gum choose --header="$prompt$hint" "${options[@]}")
    [[ "$choice" == $'\a' ]] && timed_out=1
  else
    # bash-only numbered menu (like 'select', but with timeout support)
    # stdin was used for the options, so read the answer from the terminal
    local reply i status
    for i in "${!options[@]}"; do
      printf '%2d) %s\n' "$((i + 1))" "${options[$i]}" >&2
    done
    while true; do
      IFS= read -r ${read_timeout[@]+"${read_timeout[@]}"} -p "$prompt$hint " reply </dev/tty
      status=$?
      ((status > 128)) && timed_out=1 && echo >&2 && break # timeout
      ((status > 0)) && break                             # ctrl-d / no input
      if [[ "$reply" =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= ${#options[@]})); then
        choice="${options[reply - 1]}"
        break
      fi
    done
  fi
  if ((timed_out)); then
    echo "$default"
    return 0
  fi
  if [[ -n "$other_option" && "$choice" == "$other_option" ]]; then
    # let the user type their own answer
    choice=""
    IFS= read -r ${read_timeout[@]+"${read_timeout[@]}"} -p "$prompt$hint " choice </dev/tty
    if (($? > 128)); then # timeout
      echo >&2
      echo "$default"
      return 0
    fi
    choice="$(Str:trim "$choice")"
  fi
  [[ -z "$choice" ]] && return 1
  echo "$choice"
}

function Tool:_pick_timeout() {
  # run an interactive picker (fzf/gum) with a timeout, used by Tool:pick
  # usage: Tool:_pick_timeout <seconds> <command> [args...]
  # after <seconds> the picker is terminated and a BEL character is output instead
  # <seconds> = 0: no timeout
  local seconds="$1"
  shift
  if ((seconds <= 0)); then
    "$@"
    return $?
  fi
  local marker
  marker="$(mktemp)"
  rm -f "$marker"
  "$@" <&0 & # keep stdin (the options), a background command would get /dev/null otherwise
  local pid=$!
  # watchdog: without stdout/stderr, so it does not keep the caller's pipe open after the pick
  (
    sleep "$seconds" || exit 0 # killed before the timeout: do nothing
    touch "$marker"
    kill "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local watchdog=$!
  wait "$pid"
  local status=$?
  local timed_out=0
  [[ -f "$marker" ]] && timed_out=1
  # stop the watchdog (its sleep first, so the watchdog exits without firing)
  [[ $(command -v pkill) ]] && pkill -P "$watchdog" 2>/dev/null
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  rm -f "$marker"
  if ((timed_out)); then
    stty sane 2>/dev/null </dev/tty # in case the picker did not restore the terminal
    printf '\a'
    return 0
  fi
  return $status
}

function Os:has_tty() {
  # true when there is a terminal to interact with (false in cron, CI, pipes without a tty)
  ( : </dev/tty ) 2>/dev/null
}

### string processing

function Str:trim() {
  local var="$*"
  # remove leading whitespace characters
  var="${var#"${var%%[![:space:]]*}"}"
  # remove trailing whitespace characters
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

function Str:lower() {
  if [[ -n "$1" ]]; then
    local input="$*"
    echo "${input,,}"
  else
    awk '{print tolower($0)}'
  fi
}

function Str:upper() {
  if [[ -n "$1" ]]; then
    local input="$*"
    echo "${input^^}"
  else
    awk '{print toupper($0)}'
  fi
}

function Str:ascii() {
  # remove all characters with accents/diacritics to latin alphabet
  # shellcheck disable=SC2020
  sed 'y/àáâäæãåāǎçćčèéêëēėęěîïííīįìǐłñńôöòóœøōǒõßśšûüǔùǖǘǚǜúūÿžźżÀÁÂÄÆÃÅĀǍÇĆČÈÉÊËĒĖĘĚÎÏÍÍĪĮÌǏŁÑŃÔÖÒÓŒØŌǑÕẞŚŠÛÜǓÙǕǗǙǛÚŪŸŽŹŻ/aaaaaaaaaccceeeeeeeeiiiiiiiilnnooooooooosssuuuuuuuuuuyzzzAAAAAAAAACCCEEEEEEEEIIIIIIIILNNOOOOOOOOOSSSUUUUUUUUUUYZZZ/'
}

function Str:slugify() {
  # Str:slugify <input> <separator>
  # Str:slugify "Jack, Jill & Clémence LTD"      => jack-jill-clemence-ltd
  # Str:slugify "Jack, Jill & Clémence LTD" "_"  => jack_jill_clemence_ltd
  separator="${2:-}"
  [[ -z "$separator" ]] && separator="-"
  Str:lower "$1" |
    Str:ascii |
    awk '{
          gsub(/[\[\]@#$%^&*;,.:()<>!?\/+=_]/," ",$0);
          gsub(/^  */,"",$0);
          gsub(/  *$/,"",$0);
          gsub(/  */,"-",$0);
          gsub(/[^a-z0-9\-]/,"");
          print;
          }' |
    sed "s/-/$separator/g"
}

function Str:title() {
  # Str:title <input> <separator>
  # Str:title "Jack, Jill & Clémence LTD"     => JackJillClemenceLtd
  # Str:title "Jack, Jill & Clémence LTD" "_" => Jack_Jill_Clemence_Ltd
  separator="${2:-}"
  # shellcheck disable=SC2020
  Str:lower "$1" |
    tr 'àáâäæãåāçćčèéêëēėęîïííīįìłñńôöòóœøōõßśšûüùúūÿžźż' 'aaaaaaaaccceeeeeeeiiiiiiilnnoooooooosssuuuuuyzzz' |
    awk '{ gsub(/[\[\]@#$%^&*;,.:()<>!?\/+=_-]/," ",$0); print $0; }' |
    awk '{
          for (i=1; i<=NF; ++i) {
              $i = toupper(substr($i,1,1)) tolower(substr($i,2))
          };
          print $0;
          }' |
    sed "s/ /$separator/g" |
    cut -c1-50
}

function Str:digest() {
  local length=${1:-6}
  if [[ -n $(command -v md5sum) ]]; then
    # regular linux
    md5sum | cut -c1-"$length"
  else
    # macos
    md5 | cut -c1-"$length"
  fi
}

# Gha: function should only be run inside of a Github Action

function Gha:finish() {
  [[ -z "${RUNNER_OS:-}" ]] && IO:die "This should only run inside a Github Action, don't run it on your machine"
  local timestamp message
  git config user.name "Bashew Runner"
  git config user.email "actions@users.noreply.github.com"
  git add -A
  timestamp="$(date -u)"
  message="$timestamp < $script_basename $script_version"
  IO:print "Commit Message: $message"
  git commit -m "${message}" || exit 0
  git pull --rebase
  git push
  IO:success "Commit OK!"
}

trap "IO:die \"ERROR \$? after \$SECONDS seconds \n\
\${error_prefix} last command : '\$BASH_COMMAND' \" \
\$(< \$script_install_path awk -v lineno=\$LINENO \
'NR == lineno {print \"\${error_prefix} from line \" lineno \" : \" \$0}')" INT TERM EXIT
# cf https://askubuntu.com/questions/513932/what-is-the-bash-command-variable-good-for

Script:exit() {
  local temp_file
  for temp_file in "${temp_files[@]-}"; do
    [[ -f "$temp_file" ]] && (
      IO:debug "Delete temp file [$temp_file]"
      rm -f "$temp_file"
    )
  done
  trap - INT TERM EXIT
  IO:debug "$script_basename finished after $SECONDS seconds"
  exit 0
}

Script:check_version() {
  (
    # shellcheck disable=SC2164
    pushd "$script_install_folder" &>/dev/null
    if [[ -d .git ]]; then
      local remote
      remote="$(git remote -v | grep fetch | awk 'NR == 1 {print $2}')"
      IO:progress "Check for updates - $remote"
      git remote update &>/dev/null
      if [[ $(git rev-list --count "HEAD...HEAD@{upstream}" 2>/dev/null) -gt 0 ]]; then
        IO:print "There is a more recent update of this script - run <<$script_prefix update>> to update"
      else
        IO:progress "                                         "
      fi
    fi
    # shellcheck disable=SC2164
    popd &>/dev/null
  )
}

Script:git_pull() {
  # run in background to avoid problems with modifying a running interpreted script
  (
    sleep 1
    cd "$script_install_folder" && git pull
  ) &
}

Script:install() {
  # install everything this script needs to run: required binaries, a symlink in the PATH
  # and bash/zsh completion - all steps are optional and can be skipped
  IO:announce "Install [$script_prefix] on this machine"
  Script:install_requirements
  Script:install_symlink
  Script:install_completion
  IO:success "[$script_prefix] is ready to use"
}

Script:install_requirements() {
  # check all binaries this script needs (from the Os:require calls) and install the missing ones
  local requirements=()
  local requirement binary hint instructions words
  IO:print "${txtInfo}1. requirements${txtReset}"
  mapfile -t requirements < <(Script:list_requirements)
  if [[ ${#requirements[@]} -eq 0 ]]; then
    IO:print "   no external programs required"
    return 0
  fi
  for requirement in "${requirements[@]-}"; do
    [[ -z "$requirement" ]] && continue
    binary="${requirement%%$'\t'*}"
    hint="${requirement#*$'\t'}"
    if command -v "$binary" &>/dev/null; then
      IO:success "   [$binary] is installed"
      continue
    fi
    words=$(echo "$hint" | wc -w)
    instructions="$install_package $binary"
    [[ $words -eq 1 ]] && instructions="$install_package $hint"
    [[ $words -gt 1 ]] && instructions="$hint"
    instructions="$(Str:trim "$instructions")"
    if [[ -z "$instructions" ]]; then
      IO:alert "   [$binary] is missing - no idea how to install it on $os_name"
      continue
    fi
    if IO:confirm "   [$binary] is missing - install it with <<$instructions>>?"; then
      eval "$instructions"
    else
      IO:alert "   [$binary] is missing - install it later with: $instructions"
    fi
  done
}

Script:list_requirements() {
  # list every binary this script needs, as <binary><tab><install hint>
  # only real calls are used, not the ones in comments or in the documentation
  grep -E '^[[:space:]]*Os:require[[:space:]]+"' "$script_install_path" |
    awk '
    BEGIN { FS="\"" }
    NF >= 3 { print $2 "\t" (NF >= 5 ? $4 : "") }
    ' |
    sort -u
}

Script:install_symlink() {
  # make this script callable as [$script_prefix] from anywhere
  local folder link_path link_target script_target
  local bin_folder=""
  script_target="$script_install_folder/$(basename "$script_install_path")" # always use the absolute path for the symlink
  IO:print "${txtInfo}2. symlink${txtReset}"
  if [[ "$script_target" == *"/.basher/"* ]] || [[ -n "${BASHER_ROOT:-}" && "$script_target" == "${BASHER_ROOT:-}/"* ]]; then
    IO:print "   skipped: [$script_prefix] was installed with basher, which takes care of this"
    return 0
  fi
  for folder in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
    [[ -d "$folder" ]] && [[ -w "$folder" ]] && bin_folder="$folder" && break
  done
  if [[ -z "$bin_folder" ]]; then
    if IO:confirm "   no writable folder found - create [$HOME/.local/bin]?"; then
      mkdir -p "$HOME/.local/bin"
      bin_folder="$HOME/.local/bin"
    else
      IO:alert "   skipped: no writable folder found ($HOME/.local/bin, $HOME/bin, /usr/local/bin)"
      return 0
    fi
  fi
  [[ ":$PATH:" == *":$bin_folder:"* ]] || IO:alert "   [$bin_folder] is not in your PATH - add: export PATH=\"$bin_folder:\$PATH\""
  link_path="$bin_folder/$script_prefix"
  if [[ -e "$link_path" ]]; then
    link_target="$(Os:follow_link "$link_path")"
    if [[ "$link_target" == "$script_target" ]]; then
      IO:success "   [$link_path] already points to this script"
    else
      IO:alert "   skipped: [$link_path] already exists and points to [$link_target]"
    fi
    return 0
  fi
  if IO:confirm "   create symlink [$link_path]?"; then
    ln -s "$script_target" "$link_path"
    IO:success "   $link_path -> $script_target"
  fi
}

Script:install_completion() {
  # generate the completion script and activate it in the bash/zsh startup files
  local completion_folder="$HOME/.bash_completion.d"
  local completion_file="$completion_folder/$script_prefix"
  IO:print "${txtInfo}3. completion${txtReset}"
  Os:folder "$completion_folder" 3650
  Script:completion >"$completion_file"
  IO:success "   $completion_file"
  Script:install_startup "$HOME/.bashrc" "source \"$completion_file\""
  Script:install_startup "$HOME/.zshrc" "autoload -U +X bashcompinit && bashcompinit && source \"$completion_file\""
}

Script:install_startup() {
  # add a line to a shell startup file, but only once
  local startup_file="$1"
  local startup_line="$2"
  if [[ ! -f "$startup_file" ]]; then
    IO:debug "$config_icon skip [$startup_file]: does not exist"
    return 0
  fi
  if grep -q -F "$startup_line" "$startup_file"; then
    IO:success "   already activated in [$startup_file]"
    return 0
  fi
  if IO:confirm "   activate completion in [$startup_file]?"; then
    {
      echo ""
      echo "# added by [$script_basename install] on $execution_day"
      echo "$startup_line"
    } >>"$startup_file"
    IO:success "   activated in [$startup_file] - restart your shell to use it"
  fi
}

Script:completion() {
  # generate a bash/zsh completion script, based on the flags/options/choices in Option:config
  local keywords
  keywords="$(Option:config |
    awk '
    BEGIN { FS="|" }
    $1 ~ /flag|option|list|secret/ { print "-" $2 ; print "--" $3 }
    $1 ~ /choice/ { n = split($5, values, ","); for (i = 1; i <= n; i++) print values[i] }
    ' |
    sort -u |
    tr '\n' ' ')"
  keywords="$(Str:trim "$keywords")"
  cat <<END_OF_COMPLETION
# bash/zsh completion for [$script_basename] - generated by [$script_basename install]
_${script_prefix}_completion() {
  local current
  current="\${COMP_WORDS[COMP_CWORD]}"
  # shellcheck disable=SC2207
  COMPREPLY=(\$(compgen -W "$keywords" -- "\$current"))
}
complete -F _${script_prefix}_completion $script_prefix
END_OF_COMPLETION
}

Script:show_tips() {
  ((sourced)) && return 0
  # shellcheck disable=SC2016
  grep <"${BASH_SOURCE[0]}" -v '$0' |
    awk \
      -v green="$txtInfo" \
      -v yellow="$txtWarn" \
      -v reset="$txtReset" \
      '
      /TIP: /  {$1=""; gsub(/«/,green); gsub(/»/,reset); print "*" $0}
      /TIP:> / {$1=""; print " " yellow $0 reset}
      ' |
    awk \
      -v script_basename="$script_basename" \
      -v script_prefix="$script_prefix" \
      '{
      gsub(/\$script_basename/,script_basename);
      gsub(/\$script_prefix/,script_prefix);
      print ;
      }'
}

Script:check() {
  local name
  if [[ -n $(Option:filter flag) ]]; then
    IO:print "## ${txtInfo}boolean flags${txtReset}:"
    Option:filter flag |
      grep -v help |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter option) ]]; then
    IO:print "## ${txtInfo}option defaults${txtReset}:"
    Option:filter option |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter list) ]]; then
    IO:print "## ${txtInfo}list options${txtReset}:"
    Option:filter list |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter param) ]]; then
    if ((piped)); then
      IO:debug "Skip parameters for .env files"
    else
      IO:print "## ${txtInfo}parameters${txtReset}:"
      Option:filter param |
        while read -r name; do
          declare -p "$name" | cut -d' ' -f3-
        done
    fi
  fi

  if [[ -n $(Option:filter choice) ]]; then
    if ((piped)); then
      IO:debug "Skip choices for .env files"
    else
      IO:print "## ${txtInfo}choice${txtReset}:"
      Option:filter choice |
        while read -r name; do
          declare -p "$name" | cut -d' ' -f3-
        done
    fi
  fi

  IO:print "## ${txtInfo}required commands${txtReset}:"
  Script:show_required
}

Option:usage() {
  IO:print "Program : ${txtInfo}$script_basename${txtReset}  by ${txtWarn}$script_author${txtReset}"
  IO:print "Version : ${txtInfo}v$script_version${txtReset} (${txtWarn}$script_modified${txtReset})"
  IO:print "Purpose : ${txtInfo}$script_description${txtReset}"
  echo -n "Usage   : $script_basename"
  Option:config |
    awk '
  BEGIN { FS="|"; OFS=" "; oneline="" ; fulltext="Flags, options and parameters:"}
  $1 ~ /flag/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [flag] %s [default: off]",$2,$3,$4) ;
    oneline  = oneline " [-" $2 "]"
    }
  $1 ~ /option/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [option] %s",$2,$3 " <?>",$4) ;
    if($5!=""){fulltext = fulltext "  [default: " $5 "]"; }
    oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /list/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [list] %s (array)",$2,$3 " <?>",$4) ;
    fulltext = fulltext "  [default empty]";
    oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /secret/  {
    fulltext = fulltext sprintf("\n    -%1s|--%s <%s>: [secret] %s",$2,$3,"?",$4) ;
      oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /param/ {
    if($2 == "1"){
          fulltext = fulltext sprintf("\n    %-17s: [parameter] %s","<"$3">",$4);
          oneline  = oneline " <" $3 ">"
     }
     if($2 == "?"){
          fulltext = fulltext sprintf("\n    %-17s: [parameter] %s (optional)","<"$3">",$4);
          oneline  = oneline " <" $3 "?>"
     }
     if($2 == "n"){
          fulltext = fulltext sprintf("\n    %-17s: [parameters] %s (1 or more)","<"$3">",$4);
          oneline  = oneline " <" $3 " …>"
     }
    }
  $1 ~ /choice/ {
        fulltext = fulltext sprintf("\n    %-17s: [choice] %s","<"$3">",$4);
        if($5!=""){fulltext = fulltext "  [options: " $5 "]"; }
        oneline  = oneline " <" $3 ">"
    }
    END {print oneline; print fulltext}
  '
}

function Option:filter() {
  Option:config | grep "$1|" | cut -d'|' -f3 | sort | grep -v '^\s*$'
}

function Script:show_required() {
  grep 'Os:require' "$script_install_path" |
    grep -v -E '\(\)|grep|# Os:require' |
    awk -v install="# $install_package " '
    function ltrim(s) { sub(/^[ "\t\r\n]+/, "", s); return s }
    function rtrim(s) { sub(/[ "\t\r\n]+$/, "", s); return s }
    function trim(s) { return rtrim(ltrim(s)); }
    NF == 2 {print install trim($2); }
    NF == 3 {print install trim($3); }
    NF > 3  {$1=""; $2=""; $0=trim($0); print "# " trim($0);}
  ' |
    sort -u
}

function Option:initialize() {
  local init_command
  init_command=$(Option:config |
    grep -v "VERBOSE|" |
    awk '
    BEGIN { FS="|"; OFS=" ";}
    $1 ~ /flag/   && $5 == "" {print $3 "=0; "}
    $1 ~ /flag/   && $5 != "" {print $3 "=\"" $5 "\"; "}
    $1 ~ /option/ && $5 == "" {print $3 "=\"\"; "}
    $1 ~ /option/ && $5 != "" {print $3 "=\"" $5 "\"; "}
    $1 ~ /choice/   {print $3 "=\"\"; "}
    $1 ~ /list/     {print $3 "=(); "}
    $1 ~ /secret/   {print $3 "=\"\"; "}
    ')
  if [[ -n "$init_command" ]]; then
    eval "$init_command"
  fi
}

function Option:has_single() { Option:config | grep 'param|1|' >/dev/null; }
function Option:has_choice() { Option:config | grep 'choice|1' >/dev/null; }
function Option:has_optional() { Option:config | grep 'param|?|' >/dev/null; }
function Option:has_multi() { Option:config | grep 'param|n|' >/dev/null; }

function Option:parse() {
  if [[ $# -eq 0 ]]; then
    Option:usage >&2
    Script:exit
  fi

  ## first process all the -x --xxxx flags and options
  while true; do
    # flag <flag> is saved as $flag = 0/1
    # option <option> is saved as $option
    if [[ $# -eq 0 ]]; then
      ## all parameters processed
      break
    fi
    if [[ ! $1 == -?* ]]; then
      ## all flags/options processed
      break
    fi
    local save_option
    save_option=$(Option:config |
      awk -v opt="$1" '
        BEGIN { FS="|"; OFS=" ";}
        $1 ~ /flag/   &&  "-"$2 == opt {print $3"=1"}
        $1 ~ /flag/   && "--"$3 == opt {print $3"=1"}
        $1 ~ /option/ &&  "-"$2 == opt {print $3"=${2:-}; shift"}
        $1 ~ /option/ && "--"$3 == opt {print $3"=${2:-}; shift"}
        $1 ~ /list/ &&  "-"$2 == opt {print $3"+=(${2:-}); shift"}
        $1 ~ /list/ && "--"$3 == opt {print $3"=(${2:-}); shift"}
        $1 ~ /secret/ &&  "-"$2 == opt {print $3"=${2:-}; shift #noshow"}
        $1 ~ /secret/ && "--"$3 == opt {print $3"=${2:-}; shift #noshow"}
        ')
    if [[ -n "$save_option" ]]; then
      if echo "$save_option" | grep shift >>/dev/null; then
        local save_var
        save_var=$(echo "$save_option" | cut -d= -f1)
        IO:debug "$config_icon parameter: ${save_var}=$2"
      else
        IO:debug "$config_icon flag: $save_option"
      fi
      eval "$save_option"
    else
      IO:die "cannot interpret option [$1]"
    fi
    shift
  done

  ((help)) && (
    Option:usage
    Script:check_version
    IO:print "                                  "
    echo "### TIPS & EXAMPLES"
    Script:show_tips

  ) && Script:exit

  local option_list
  local option_count
  local choices
  local single_params
  ## then run through the given parameters
  if Option:has_choice; then
    choices=$(Option:config | awk -F"|" '
      $1 == "choice" && $2 == 1 {print $3}
      ')
    option_list=$(xargs <<<"$choices")
    option_count=$(wc <<<"$choices" -w | xargs)
    IO:debug "$config_icon Expect : $option_count choice(s): $option_list"
    [[ $# -eq 0 ]] && IO:die "need the choice(s) [$option_list]"

    local choices_list
    local valid_choice
    local param
    for param in $choices; do
      [[ $# -eq 0 ]] && IO:die "need choice [$param]"
      [[ -z "$1" ]] && IO:die "need choice [$param]"
      IO:debug "$config_icon Assign : $param=$1"
      # check if choice is in list
      choices_list=$(Option:config | awk -F"|" -v choice="$param" '$1 == "choice" && $3 = choice {print $5}')
      valid_choice=$(tr <<<"$choices_list" "," "\n" | grep "$1")
      [[ -z "$valid_choice" ]] && IO:die "choice [$1] is not valid, should be in list [$choices_list]"

      eval "$param=\"$1\""
      shift
    done
  else
    IO:debug "$config_icon No choices to process"
    choices=""
    option_count=0
  fi

  if Option:has_single; then
    single_params=$(Option:config | awk -F"|" '
      $1 == "param" && $2 == 1 {print $3}
      ')
    option_list=$(xargs <<<"$single_params")
    option_count=$(wc <<<"$single_params" -w | xargs)
    IO:debug "$config_icon Expect : $option_count single parameter(s): $option_list"
    [[ $# -eq 0 ]] && IO:die "need the parameter(s) [$option_list]"

    for param in $single_params; do
      [[ $# -eq 0 ]] && IO:die "need parameter [$param]"
      [[ -z "$1" ]] && IO:die "need parameter [$param]"
      IO:debug "$config_icon Assign : $param=$1"
      eval "$param=\"$1\""
      shift
    done
  else
    IO:debug "$config_icon No single params to process"
    single_params=""
    option_count=0
  fi

  if Option:has_optional; then
    local optional_params
    local optional_count
    optional_params=$(Option:config | grep 'param|?|' | cut -d'|' -f3)
    optional_count=$(wc <<<"$optional_params" -w | xargs)
    IO:debug "$config_icon Expect : $optional_count optional parameter(s): $(echo "$optional_params" | xargs)"

    for param in $optional_params; do
      IO:debug "$config_icon Assign : $param=${1:-}"
      eval "$param=\"${1:-}\""
      shift
    done
  else
    IO:debug "$config_icon No optional params to process"
    optional_params=""
    optional_count=0
  fi

  if Option:has_multi; then
    #IO:debug "Process: multi param"
    local multi_count
    local multi_param
    multi_count=$(Option:config | grep -c 'param|n|')
    multi_param=$(Option:config | grep 'param|n|' | cut -d'|' -f3)
    IO:debug "$config_icon Expect : $multi_count multi parameter: $multi_param"
    ((multi_count > 1)) && IO:die "cannot have >1 'multi' parameter: [$multi_param]"
    ((multi_count > 0)) && [[ $# -eq 0 ]] && IO:die "need the (multi) parameter [$multi_param]"
    # save the rest of the params in the multi param
    if [[ -n "$*" ]]; then
      IO:debug "$config_icon Assign : $multi_param=$*"
      eval "$multi_param=( $* )"
    fi
  else
    multi_count=0
    multi_param=""
    [[ $# -gt 0 ]] && IO:die "cannot interpret extra parameters"
  fi
}

function Os:require() {
  local install_instructions
  local binary
  local words
  local path_binary
  # $1 = binary that is required
  binary="$1"
  path_binary=$(command -v "$binary" 2>/dev/null)
  [[ -n "$path_binary" ]] && IO:debug "️$require_icon required [$binary] -> $path_binary" && return 0
  # during the [install] action, Script:install takes care of the missing binaries, so don't die here
  [[ "${action,,}" == "install" ]] && IO:debug "$require_icon missing [$binary] - will be installed by [install]" && return 0
  # $2 = how to install it
  IO:alert "$script_basename needs [$binary] but it cannot be found"
  words=$(echo "${2:-}" | wc -w)
  install_instructions="$install_package $1"
  [[ $words -eq 1 ]] && install_instructions="$install_package $2"
  [[ $words -gt 1 ]] && install_instructions="${2:-}"
  if ((FORCE)); then
    IO:announce "Installing [$1] ..."
    eval "$install_instructions"
  else
    IO:alert "1) install package  : $install_instructions"
    IO:alert "2) check path       : export PATH=\"[path of your binary]:\$PATH\""
    IO:die "Missing program/script [$binary]"
  fi
}

function Os:folder() {
  if [[ -n "$1" ]]; then
    local folder="$1"
    local max_days=${2:-365}
    if [[ ! -d "$folder" ]]; then
      IO:debug "$clean_icon Create folder : [$folder]"
      mkdir -p "$folder"
    else
      IO:debug "$clean_icon Cleanup folder: [$folder] - delete files older than $max_days day(s)"
      find "$folder" -mtime "+$max_days" -type f -exec rm {} \;
    fi
  fi
}

function Os:follow_link() {
  [[ ! -L "$1" ]] && echo "$1" && return 0 ## if it's not a symbolic link, return immediately
  local file_folder link_folder link_name symlink
  file_folder="$(dirname "$1")"                                                                                   ## check if file has absolute/relative/no path
  [[ "$file_folder" != /* ]] && file_folder="$(cd -P "$file_folder" &>/dev/null && pwd)"                          ## a relative path was given, resolve it
  symlink=$(readlink "$1")                                                                                        ## follow the link
  link_folder=$(dirname "$symlink")                                                                               ## check if link has absolute/relative/no path
  [[ -z "$link_folder" ]] && link_folder="$file_folder"                                                           ## if no link path, stay in same folder
  [[ "$link_folder" == \.* ]] && link_folder="$(cd -P "$file_folder" && cd -P "$link_folder" &>/dev/null && pwd)" ## a relative link path was given, resolve it
  link_name=$(basename "$symlink")
  IO:debug "$info_icon Symbolic ln: $1 -> [$link_folder/$link_name]"
  Os:follow_link "$link_folder/$link_name" ## recurse
}

function Os:notify() {
  # cf https://levelup.gitconnected.com/5-modern-bash-scripting-techniques-that-only-a-few-programmers-know-4abb58ddadad
  local message="$1"
  local source="${2:-$script_basename}"

  [[ -n $(command -v notify-send) ]] && notify-send "$source" "$message"                                      # for Linux
  [[ -n $(command -v osascript) ]] && osascript -e "display notification \"$message\" with title \"$source\"" # for MacOS
}

function Os:busy() {
  # show spinner as long as process $pid is running
  local pid="$1"
  local message="${2:-}"
  local frames=("|" "/" "-" "\\")
  (
    while kill -0 "$pid" &>/dev/null; do
      for frame in "${frames[@]}"; do
        printf "\r[ $frame ] %s..." "$message"
        sleep 0.5
      done
    done
    printf "\n"
  )
}

function Os:beep() {
  if [[ -n "$TERM" ]]; then
    tput bel
  fi
}

function Script:meta() {

  script_prefix=$(basename "${BASH_SOURCE[0]}" .sh)
  script_basename=$(basename "${BASH_SOURCE[0]}")
  execution_day=$(date "+%Y-%m-%d")

  script_install_path="${BASH_SOURCE[0]}"
  IO:debug "$info_icon Script path: $script_install_path"
  script_install_path=$(Os:follow_link "$script_install_path")
  IO:debug "$info_icon Linked path: $script_install_path"
  script_install_folder="$(cd -P "$(dirname "$script_install_path")" && pwd)"
  IO:debug "$info_icon In folder  : $script_install_folder"
  if [[ -f "$script_install_path" ]]; then
    script_hash=$(Str:digest <"$script_install_path" 8)
    script_lines=$(awk <"$script_install_path" 'END {print NR}')
  fi

  # get shell/operating system/versions
  shell_brand="sh"
  shell_version="?"
  [[ -n "${ZSH_VERSION:-}" ]] && shell_brand="zsh" && shell_version="$ZSH_VERSION"
  [[ -n "${BASH_VERSION:-}" ]] && shell_brand="bash" && shell_version="$BASH_VERSION"
  [[ -n "${FISH_VERSION:-}" ]] && shell_brand="fish" && shell_version="$FISH_VERSION"
  [[ -n "${KSH_VERSION:-}" ]] && shell_brand="ksh" && shell_version="$KSH_VERSION"
  IO:debug "$info_icon Shell type : $shell_brand - version $shell_version"
  if [[ "$shell_brand" == "bash" && "${BASH_VERSINFO:-0}" -lt 4 ]]; then
    IO:die "Bash version 4 or higher is required - current version = ${BASH_VERSINFO:-0}"
  fi

  os_kernel=$(uname -s)
  os_version=$(uname -r)
  os_machine=$(uname -m)
  install_package=""
  case "$os_kernel" in
  CYGWIN* | MSYS* | MINGW*)
    os_name="Windows"
    ;;
  Darwin)
    os_name=$(sw_vers -productName)       # macOS
    os_version=$(sw_vers -productVersion) # 11.1
    install_package="brew install"
    ;;
  Linux | GNU*)
    if [[ $(command -v lsb_release) ]]; then
      # 'normal' Linux distributions
      os_name=$(lsb_release -i | awk -F: '{$1=""; gsub(/^[\s\t]+/,"",$2); gsub(/[\s\t]+$/,"",$2); print $2}')    # Ubuntu/Raspbian
      os_version=$(lsb_release -r | awk -F: '{$1=""; gsub(/^[\s\t]+/,"",$2); gsub(/[\s\t]+$/,"",$2); print $2}') # 20.04
    else
      # Synology, QNAP,
      os_name="Linux"
    fi
    [[ -x /bin/apt-cyg ]] && install_package="apt-cyg install"     # Cygwin
    [[ -x /bin/dpkg ]] && install_package="dpkg -i"                # Synology
    [[ -x /opt/bin/ipkg ]] && install_package="ipkg install"       # Synology
    [[ -x /usr/sbin/pkg ]] && install_package="pkg install"        # BSD
    [[ -x /usr/bin/pacman ]] && install_package="pacman -S"        # Arch Linux
    [[ -x /usr/bin/zypper ]] && install_package="zypper install"   # Suse Linux
    [[ -x /usr/bin/emerge ]] && install_package="emerge"           # Gentoo
    [[ -x /usr/bin/yum ]] && install_package="yum install"         # RedHat RHEL/CentOS/Fedora
    [[ -x /usr/bin/apk ]] && install_package="apk add"             # Alpine
    [[ -x /usr/bin/apt-get ]] && install_package="apt-get install" # Debian
    [[ -x /usr/bin/apt ]] && install_package="apt install"         # Ubuntu
    ;;

  esac
  IO:debug "$info_icon System OS  : $os_name ($os_kernel) $os_version on $os_machine"
  IO:debug "$info_icon Package mgt: $install_package"

  # get last modified date of this script
  script_modified="??"
  [[ "$os_kernel" == "Linux" ]] && script_modified=$(stat -c %y "$script_install_path" 2>/dev/null | cut -c1-16) # generic linux
  [[ "$os_kernel" == "Darwin" ]] && script_modified=$(stat -f "%Sm" "$script_install_path" 2>/dev/null)          # for MacOS

  IO:debug "$info_icon Version  : $script_version"
  IO:debug "$info_icon Created  : $script_created"
  IO:debug "$info_icon Modified : $script_modified"

  IO:debug "$info_icon Lines    : $script_lines lines / md5: $script_hash"
  IO:debug "$info_icon User     : $USER@$HOSTNAME"

  # if run inside a git repo, detect for which remote repo it is
  if git status &>/dev/null; then
    git_repo_remote=$(git remote -v | awk '/(fetch)/ {print $2}')
    IO:debug "$info_icon git remote : $git_repo_remote"
    git_repo_root=$(git rev-parse --show-toplevel)
    IO:debug "$info_icon git folder : $git_repo_root"
  fi

  # get script version from VERSION.md file - which is automatically updated by pforret/setver
  [[ -f "$script_install_folder/VERSION.md" ]] && script_version=$(cat "$script_install_folder/VERSION.md")
  # get script version from git tag file - which is automatically updated by pforret/setver
  [[ -n "$git_repo_root" ]] && [[ -n "$(git tag &>/dev/null)" ]] && script_version=$(git tag --sort=version:refname | tail -1)
}

function Script:initialize() {
  log_file=""
  if [[ -n "${TMP_DIR:-}" ]]; then
    # clean up TMP folder after 1 day
    Os:folder "$TMP_DIR" 1
  fi
  if [[ -n "${LOG_DIR:-}" ]]; then
    # clean up LOG folder after 1 month
    Os:folder "$LOG_DIR" 30
    log_file="$LOG_DIR/$script_prefix.$execution_day.log"
    IO:debug "$config_icon log_file: $log_file"
  fi
}

function Os:tempfile() {
  local extension=${1:-txt}
  local file="${TMP_DIR:-/tmp}/$execution_day.$RANDOM.$extension"
  IO:debug "$config_icon tmp_file: $file"
  temp_files+=("$file")
  echo "$file"
}

function Os:import_env() {
  local env_files
  if [[ $(pwd) == "$script_install_folder" ]]; then
    env_files=(
      "$script_install_folder/.env"
      "$script_install_folder/.$script_prefix.env"
      "$script_install_folder/$script_prefix.env"
    )
  else
    env_files=(
      "$script_install_folder/.env"
      "$script_install_folder/.$script_prefix.env"
      "$script_install_folder/$script_prefix.env"
      "./.env"
      "./.$script_prefix.env"
      "./$script_prefix.env"
    )
  fi

  local env_file
  for env_file in "${env_files[@]}"; do
    if [[ -f "$env_file" ]]; then
      IO:debug "$config_icon Read  dotenv: [$env_file]"
      local clean_file
      clean_file=$(Os:clean_env "$env_file")
      # shellcheck disable=SC1090
      source "$clean_file" && rm "$clean_file"
    fi
  done
}

function Os:clean_env() {
  local input="$1"
  local output="$1.__.sh"
  [[ ! -f "$input" ]] && IO:die "Input file [$input] does not exist"
  IO:debug "$clean_icon Clean dotenv: [$output]"
  awk <"$input" '
      function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
      function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
      function trim(s) { return rtrim(ltrim(s)); }
      /=/ { # skip lines with no equation
        $0=trim($0);
        if(substr($0,1,1) != "#"){ # skip comments
          equal=index($0, "=");
          key=trim(substr($0,1,equal-1));
          val=trim(substr($0,equal+1));
          if(match(val,/^".*"$/) || match(val,/^\047.*\047$/)){
            print key "=" val
          } else {
            print key "=\"" val "\""
          }
        }
      }
  ' >"$output"
  echo "$output"
}

IO:initialize # output settings
Script:meta   # find installation folder

[[ $run_as_root == 1 ]] && [[ $UID -ne 0 ]] && IO:die "user is $USER, MUST be root to run [$script_basename]"
[[ $run_as_root == -1 ]] && [[ $UID -eq 0 ]] && IO:die "user is $USER, CANNOT be root to run [$script_basename]"

Option:initialize # set default values for flags & options
Os:import_env     # load .env, .<prefix>.env, <prefix>.env (script folder + cwd)

if [[ $sourced -eq 0 ]]; then
  Option:parse "$@" # overwrite with specified options if any
  Script:initialize # clean up folders
  Script:main       # run Script:main program
  Script:exit       # exit and clean up
else
  # just disable the trap, don't execute Script:main
  trap - INT TERM EXIT
fi
