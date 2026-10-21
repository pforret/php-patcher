#!/usr/bin/env bats
# offline tests for php-patcher.sh: a fake HOME with its own ~/.ssh/config,
# and fake ssh/fzf binaries (tests/fixtures/bin) so no server is ever contacted

setup() {
  # own temp dir: BATS_TEST_TMPDIR does not exist in older bats (e.g. 0.4)
  TEST_TMP="$(mktemp -d)"
  REAL_SSH="$(command -v ssh)"
  export REAL_SSH
  export HOME="$TEST_TMP/home"
  export PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export GIT_SSH_COMMAND=false # -h runs a git update check: keep it offline
  SCRIPT="$BATS_TEST_DIRNAME/../php-patcher.sh"
  mkdir -p "$HOME/.ssh/conf.d"
  cat >"$HOME/.ssh/config" <<'EOF'
Host web1 # main web server
  HostName 10.0.0.1
Host web1-alias
  HostName 10.0.0.1
Host *.internal !nope github.com
  User git
Host old-box pi
  User admin
Include conf.d/*
EOF
  echo "Host db1 db2" >"$HOME/.ssh/conf.d/extra"
  printf '%s\n' "# servers" "" "web1" "web3   # note" "  " >"$TEST_TMP/hosts.txt"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "-h shows the new verbs and flags" {
  run "$SCRIPT" -h
  [[ $status -eq 0 ]]
  [[ $output == *"host,file,auto"* ]]
  [[ $output == *"--patch"* ]]
  [[ $output == *"--pick"* ]]
}

@test "-l auto lists the usable ssh config hosts" {
  run "$SCRIPT" -l auto
  [[ $status -eq 0 ]]
  [[ "${lines[*]}" == "web1 old-box pi db1 db2" ]]
}

@test "-l -x skips hosts matching the regex" {
  run "$SCRIPT" -l -x 'pi|^old-' auto
  [[ $status -eq 0 ]]
  [[ "${lines[*]}" == "web1 db1 db2" ]]
}

@test "-l file reads the first word, skips comments and blank lines" {
  run "$SCRIPT" -l file "$TEST_TMP/hosts.txt"
  [[ $status -eq 0 ]]
  [[ "${lines[*]}" == "web1 web3" ]]
}

@test "file with a missing file fails" {
  run "$SCRIPT" file "$TEST_TMP/nope.txt"
  [[ $output == *"cannot read host file"* ]]
}

@test "host without a name fails" {
  run "$SCRIPT" host
  [[ $output == *"need a host"* ]]
}

@test "host web1 shows the versions" {
  run "$SCRIPT" host web1
  [[ $status -eq 0 ]]
  [[ $output == *"web1  FakeOS"* ]]
  [[ $output == *"8.4.27"* ]]
  [[ $output == *"bash -s -- 0 8.5.12"* ]]
}

@test "-f --patch host web1 asks the remote to patch" {
  run "$SCRIPT" -f --patch host web1
  [[ $status -eq 0 ]]
  [[ $output == *"bash -s -- 1 "* ]]
}

@test "--fixed rejects anything but x.y.z" {
  run "$SCRIPT" -F '8.4; rm -rf /' host web1
  [[ $output == *"invalid --fixed"* ]]
}

@test "a failed host gives exit 1 and the other hosts still run" {
  printf '%s\n' bad1 web1 >"$TEST_TMP/mixed.txt"
  run "$SCRIPT" file "$TEST_TMP/mixed.txt"
  [[ $status -eq 1 ]]
  [[ $output == *"FAILED"* ]]
  [[ $output != *"post-quantum"* ]]
  [[ $output == *"web1  FakeOS"* ]]
}

@test "auto with an argument is refused" {
  run "$SCRIPT" auto --patch
  [[ $output == *"auto takes no argument"* ]]
}

@test "--pick auto runs on the picked host only" {
  (: </dev/tty) 2>/dev/null || skip "no terminal"
  run "$SCRIPT" --pick auto
  [[ $status -eq 0 ]]
  [[ $output == *"old-box  FakeOS"* ]]
  [[ $output != *"web1  FakeOS"* ]]
}

@test "--pick with 1 host needs no picker" {
  run "$SCRIPT" --pick host web1
  [[ $status -eq 0 ]]
  [[ $output == *"web1  FakeOS"* ]]
}

@test "--pick with --list is refused" {
  run "$SCRIPT" -l --pick auto
  [[ $output == *"cannot be combined"* ]]
}

@test "host takes a comma-separated list" {
  run "$SCRIPT" -l host 'web1, web2,,web1,web3'
  [[ $status -eq 0 ]]
  [[ "${lines[*]}" == "web1 web2 web3" ]]
  run "$SCRIPT" host web1,web2
  [[ $status -eq 0 ]]
  [[ $output == *"web1  FakeOS"*"web2  FakeOS"* ]]
  run "$SCRIPT" host web1,-oProxyCommand=x
  [[ $output == *"invalid host"* ]]
}

@test "-I keeps only hosts matching the regex" {
  run "$SCRIPT" -l -I '^(web|db)' auto
  [[ $status -eq 0 ]]
  [[ "${lines[*]}" == "web1 db1 db2" ]]
  run "$SCRIPT" -l --include 'web' -x 'web3' host web1,web2,web3,db1
  [[ "${lines[*]}" == "web1 web2" ]]
}

@test "a host that needs a sudo password shows the ssh command to run (-f: no prompt)" {
  run "$SCRIPT" -f --patch host sudo1
  [[ $status -eq 1 ]]
  [[ $output == *"needs a sudo password"* ]]
  [[ $output == *"run it yourself: "*"ssh -t sudo1 'sudo apt-get update && sudo apt-get install -y --only-upgrade php8.4-fpm'"* ]]
  [[ $output != *"SUDO_CMD"* ]]
}

@test "versions show their php.net release date, cached in ~/.cache" {
  run "$SCRIPT" host web1
  [[ $status -eq 0 ]]
  [[ $output == *"8.4.27"*"released 2025-11-06, "*"ago"* ]]
  grep -q '^7.4.33 2022-11-03$' "$HOME/.cache/php-patcher/php-releases.txt"
}

@test "without php.net the versions are shown without a release date" {
  FAKE_CURL_FAIL=1 run "$SCRIPT" -R "" host web1
  [[ $status -eq 0 ]]
  [[ $output == *"8.4.27"* ]]
  [[ $output != *"released"* ]]
}

@test "before --released there is a warning, after it there is none" {
  run "$SCRIPT" -R "2999-01-01 14:00" host web1
  [[ $status -eq 0 ]]
  [[ $output == *"only released at 2999-01-01 14:00 UTC"* ]]
  run "$SCRIPT" -R "2000-01-01 14:00" host web1
  [[ $output != *"only released"* ]]
  run "$SCRIPT" -R "" host web1
  [[ $output != *"only released"* ]]
}

@test "--released rejects anything but YYYY-MM-DD HH:MM" {
  run "$SCRIPT" -R "tomorrow" host web1
  [[ $output == *"invalid --released"* ]]
}
