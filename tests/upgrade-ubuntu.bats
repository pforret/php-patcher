#!/usr/bin/env bats
# offline tests for upgrade-ubuntu.sh: a temporary HOME, and fake ssh/security binaries
# (tests/fixtures/upgrade-bin) so no server and no real Keychain is ever touched

setup() {
  TEST_TMP="$(mktemp -d)"
  REAL_SSH="$(command -v ssh)"
  export REAL_SSH
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
  export PATH="$BATS_TEST_DIRNAME/fixtures/upgrade-bin:$PATH"
  export GIT_SSH_COMMAND=false # -h runs a git update check: keep it offline
  export UPGRADE_UBUNTU_KEYSTORE=file
  SCRIPT="$BATS_TEST_DIRNAME/../upgrade-ubuntu.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

store_password() {
  # store_password <host> <password>: like the password verb, without a terminal
  bash -c 'source "$1"; printf "%s" "$3" | pw_save "$2"' _ "$SCRIPT" "$1" "$2"
}

@test "-h lists every verb and the noble default" {
  run "$SCRIPT" -h
  [[ $status -eq 0 ]]
  [[ $output == *"password,forget,status,preflight,disk,nginx-down,prepare,upgrade,logs,postflight,nginx-up,verify,cleanup"* ]]
  [[ $output == *"[default: noble]"* ]]
}

@test "a server verb without a host exits 2" {
  run "$SCRIPT" status
  [[ $status -eq 2 ]]
  [[ $output == *"need a host"* ]]
}

@test "a host that starts with - is refused" {
  run "$SCRIPT" status -oProxyCommand=x
  [[ $status -eq 2 ]]
  [[ $output == *"invalid host"* ]]
}

@test "--target must be jammy or noble" {
  run "$SCRIPT" -t bionic status focal1
  [[ $status -eq 2 ]]
  [[ $output == *"jammy or noble"* ]]
}

@test "next_codename: focal → jammy → noble → nothing" {
  run bash -c 'source "$1"; echo "$(next_codename focal) $(next_codename jammy) [$(next_codename noble)]"' _ "$SCRIPT"
  [[ $output == "jammy noble []" ]]
}

@test "password store round trip with a key file, private permissions" {
  store_password web1 'p@ss word!'
  run bash -c 'source "$1"; pw_load web1' _ "$SCRIPT"
  [[ $output == 'p@ss word!' ]]
  [[ $(stat -f %Lp "$HOME/.config/upgrade-ubuntu" 2>/dev/null || stat -c %a "$HOME/.config/upgrade-ubuntu") == 700 ]]
  [[ $(stat -f %Lp "$HOME/.config/upgrade-ubuntu/web1.pw.enc" 2>/dev/null || stat -c %a "$HOME/.config/upgrade-ubuntu/web1.pw.enc") == 600 ]]
  [[ $(stat -f %Lp "$HOME/.config/upgrade-ubuntu/.key" 2>/dev/null || stat -c %a "$HOME/.config/upgrade-ubuntu/.key") == 600 ]]
  ! grep -q 'p@ss' "$HOME/.config/upgrade-ubuntu/web1.pw.enc"
}

@test "password store round trip with the (fake) Keychain" {
  export UPGRADE_UBUNTU_KEYSTORE=keychain
  store_password web1 secret
  [[ -s "$HOME/keychain/upgrade-ubuntu.key" ]]
  [[ ! -e "$HOME/.config/upgrade-ubuntu/.key" ]]
  run bash -c 'source "$1"; pw_load web1' _ "$SCRIPT"
  [[ $output == secret ]]
}

@test "forget deletes the stored password" {
  store_password web1 secret
  run "$SCRIPT" forget web1
  [[ $status -eq 0 ]]
  [[ $output == *"STATUS: OK"* ]]
  [[ ! -e "$HOME/.config/upgrade-ubuntu/web1.pw.enc" ]]
}

@test "password without a terminal: NEEDS-ADMIN" {
  (: </dev/tty) 2>/dev/null && skip "this test needs to run without a terminal"
  run "$SCRIPT" password sudo1
  [[ $status -eq 3 ]]
  [[ $output == *"STATUS: NEEDS-ADMIN"* ]]
}

@test "a sudo verb without a stored password: NEEDS-ADMIN, points to the password verb" {
  run "$SCRIPT" -f nginx-down sudo1
  [[ $status -eq 3 ]]
  [[ $output == *"STATUS: NEEDS-ADMIN no stored sudo password for sudo1"* ]]
  [[ $output == *"NEXT: "*"password sudo1"* ]]
}

@test "a sudo verb without -f and without a terminal is cancelled" {
  store_password sudo1 secret
  run "$SCRIPT" nginx-down sudo1 </dev/null
  [[ $status -eq 1 ]]
  [[ $output == *"cancelled"* ]]
  [[ ! -e "$HOME/ssh.calls" ]]
}

@test "the sudo password only travels on stdin, never in argv or the log" {
  store_password sudo1 secret
  run "$SCRIPT" -f nginx-down sudo1
  [[ $status -eq 0 ]]
  [[ $output == *"STATUS: OK nginx is down on sudo1"* ]]
  grep -q '^STDIN: secret' "$HOME/ssh.calls"
  ! grep '^ARGS:' "$HOME/ssh.calls" | grep -q secret
  log=$(find "$HOME/log/upgrade-ubuntu/sudo1" -name '*.nginx-down.log')
  [[ -s $log ]]
  grep -q 'STATUS: OK' "$log"
  ! grep -q secret "$log"
}

@test "a wrong stored password: BLOCKED, points to the password verb" {
  store_password sudo1 wrong
  run "$SCRIPT" -f nginx-down sudo1
  [[ $status -eq 1 ]]
  [[ $output == *"STATUS: BLOCKED the stored sudo password was rejected"* ]]
  [[ $output != *"Sorry, try again"* ]]
}

@test "status: nginx still running on focal → nginx-down" {
  run "$SCRIPT" status focal1
  [[ $status -eq 0 ]]
  [[ $output == *"next hop focal → jammy"* ]]
  [[ $output == *"NEXT: "*"nginx-down focal1"* ]]
}

@test "status: masked on focal → preflight, then prepare" {
  run "$SCRIPT" status masked1
  [[ $output == *"NEXT: "*"preflight masked1, then "*"prepare masked1"* ]]
}

@test "status: prepared → NEEDS-ADMIN upgrade in your own terminal" {
  run "$SCRIPT" status prepared1
  [[ $status -eq 3 ]]
  [[ $output == *"upgrade prepared1   (in your own terminal)"* ]]
}

@test "status: on jammy with PHP missing → postflight" {
  run "$SCRIPT" status jammyup1
  [[ $output == *"60 of 68 PHP packages still missing"* ]]
  [[ $output == *"NEXT: "*"postflight jammyup1"* ]]
}

@test "status: a server past --target is BLOCKED" {
  run "$SCRIPT" --target jammy status noble1
  [[ $status -eq 1 ]]
  [[ $output == *"already past --target jammy"* ]]
}

@test "status: finished on noble → DONE" {
  run "$SCRIPT" status noble1
  [[ $status -eq 0 ]]
  [[ $output == *"STATUS: DONE"* ]]
}

@test "status: ssh fails → FAILED cannot connect" {
  run "$SCRIPT" status bad1
  [[ $status -eq 1 ]]
  [[ $output == *"STATUS: FAILED cannot connect to bad1"* ]]
  [[ $output != *"post-quantum"* ]]
}

@test "preflight: nginx running → BLOCKED; masked → READY" {
  run "$SCRIPT" preflight focal1
  [[ $status -eq 1 ]]
  [[ $output == *"STATUS: BLOCKED"* ]]
  run "$SCRIPT" preflight masked1
  [[ $status -eq 0 ]]
  [[ $output == *"STATUS: READY"* ]]
  [[ $output == *"snapshot"* ]]
}

@test "prepare refuses while nginx is not masked" {
  store_password focal1 secret
  run "$SCRIPT" -f prepare focal1
  [[ $status -eq 1 ]]
  [[ $output == *"take the sites offline first"* ]]
  ! grep -q 'sudo -k -S' "$HOME/ssh.calls"
}

@test "upgrade without a terminal: NEEDS-ADMIN with the screen command" {
  run "$SCRIPT" upgrade prepared1
  [[ $status -eq 3 ]]
  [[ $output == *"screen -L -Logfile /var/log/dist-upgrade/screen.log -S upgrade do-release-upgrade"* ]]
  [[ $output == *"Remove obsolete packages?"*"NO"* ]]
}

@test "upgrade on a host that is not prepared: BLOCKED" {
  run "$SCRIPT" upgrade masked1
  [[ $status -eq 1 ]]
  [[ $output == *"not prepared"* ]]
}

@test "postflight on focal: BLOCKED, no hop ends there" {
  store_password masked1 secret
  run "$SCRIPT" -f postflight masked1
  [[ $status -eq 1 ]]
  [[ $output == *"no prepared hop ends there"* ]]
}

@test "postflight on jammy runs as root and points to the next hop" {
  store_password jammyup1 secret
  run "$SCRIPT" -f postflight jammyup1
  [[ $status -eq 0 ]]
  [[ $output == *"the sites stay offline for the jammy → noble hop"* ]]
  grep -q 'ondrej/php' "$HOME/ssh.calls"
}
