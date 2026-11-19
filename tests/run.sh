#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tests for sbx-signing-agent, run against a stand-in sbx (tests/fake-bin/sbx).
#
# Nothing real is touched. Each test gets its own temporary folder, throwaway
# keys, and its own ssh-agent on a socket inside that folder. Your SSH agent,
# ~/.ssh and your sbx settings are never used.
#
# Usage:  tests/run.sh [test-name...]      (default: all tests)
#         tests/run.sh --list
#
# Needs bash, OpenSSH 8.4 or later (for SSH_ASKPASS_REQUIRE) and git 2.32 or
# later (for GIT_CONFIG_GLOBAL). The shell tests also use sh, dash and zsh when
# they're installed, and skip them if not.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../sbx-signing-agent"
[[ -x "$SCRIPT" ]] || { echo "not executable: $SCRIPT" >&2; exit 2; }

# Never talk to the caller's agent, the caller's settings or the real sbx.
unset SSH_AUTH_SOCK SSH_AGENT_PID SBX_SIGNING_KEY SBX_SIGNING_SOCK SBX_SIGNING_LIFETIME FAKE_SBX_NO_GET
export PATH="$HERE/fake-bin:$PATH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sbx-signing-agent-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# --- Helpers (used inside a test) ---------------------------------------------

fail() { printf '    FAIL: %s\n' "$*"; FAILED=1; }
skip() { printf '    (skipped: %s)\n' "$*"; }

# Run the script under test; sets OUT (stdout+stderr) and RC.
sa() { OUT="$("$SCRIPT" "$@" 2>&1 </dev/null)"; RC=$?; }

expect_rc()      { [[ $RC -eq $1 ]] || fail "exit code $RC, expected $1. Output: $OUT"; }
expect_out()     { grep -qF -- "$1" <<<"$OUT" || fail "output doesn't contain '$1'. Output: $OUT"; }
expect_not_out() { ! grep -qF -- "$1" <<<"$OUT" || fail "output contains '$1'. Output: $OUT"; }

fingerprint() { ssh-keygen -lf "$1" -E sha256 | awk '{print $2}'; }
# Key lines start with the bit count; this skips "The agent has no identities."
agent_keys()  { SSH_AUTH_SOCK=./a.sock ssh-add -l -E sha256 2>/dev/null | awk '/^[0-9]/ {print $2}'; }
agent_pid()   { cat a.pid 2>/dev/null; }
alive()       { kill -0 "$1" 2>/dev/null; }
wait_dead()   { local _; for _ in $(seq 20); do alive "$1" || return 0; sleep 0.1; done; return 1; }

expect_only_key() {
  local got; got="$(agent_keys)"
  [[ "$got" == "$1" ]] || fail "agent holds '${got//$'\n'/, }', expected exactly $1"
}
expect_no_agent() {
  [[ ! -e a.sock ]] || fail "socket a.sock still exists"
  [[ ! -e a.pid ]]  || fail "PID file a.pid still exists"
}

# Start an ssh-agent on ./a.sock that sbx-signing-agent didn't start.
start_foreign_agent() {
  local out
  out="$(ssh-agent -a ./a.sock -s)"
  FOREIGN_PID="$(sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p' <<<"$out")"
  EXTRA_PIDS+=("$FOREIGN_PID")
}

# Make ssh-add read passphrases from this script instead of a terminal. ssh-add
# keeps asking after a wrong passphrase until it gets an empty one, so after
# the given answers this prints an empty line, which makes ssh-add give up.
use_askpass() {
  printf '%s\n' "$@" >askpass.answers
  cat >askpass <<'EOF'
#!/bin/sh
n=$(cat askpass.count 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >askpass.count
sed -n "${n}p" askpass.answers
EOF
  chmod +x askpass
  export SSH_ASKPASS="$PWD/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}"
}

# --- Tests ----------------------------------------------------------------------
# Each runs in a fresh folder holding an unencrypted throwaway key (key, key.pub),
# with SBX_SIGNING_SOCK=./a.sock. A relative socket path stays far below the
# ~104-character limit for Unix sockets, however long $TMPDIR is.

t_help() {
  sa --help;  expect_rc 0; expect_out "Usage:"
  sa help;    expect_rc 0; expect_out "Usage:"
  sa bogus;   expect_rc 2; expect_out "Usage:"
  sa;         expect_rc 2
}

t_start_fresh() {
  sa start
  expect_rc 0
  expect_out "Started signing agent"
  expect_out "Loaded $(fingerprint key.pub) for 5m."
  [[ -S a.sock ]] || fail "no socket at a.sock"
  alive "$(agent_pid)" || fail "agent from a.pid isn't running"
  expect_only_key "$(fingerprint key.pub)"
}

t_start_reuses_agent() {
  sa start; local first; first="$(agent_pid)"
  sa start
  expect_rc 0
  expect_out "Reusing running signing agent."
  [[ "$(agent_pid)" == "$first" ]] || fail "PID changed from $first to $(agent_pid)"
  expect_only_key "$(fingerprint key.pub)"
}

t_setup_pins_socket() {
  sa setup
  expect_rc 0
  grep -qxF "settings set ssh.agentSocketPath ./a.sock" sbx.log || fail "setup didn't pin the socket. sbx calls: $(cat sbx.log)"
  grep -qxF "daemon restart" sbx.log || fail "setup didn't restart the daemon. sbx calls: $(cat sbx.log)"
  expect_only_key "$(fingerprint key.pub)"
}

t_status_when_pinned() {
  sa setup
  sa status
  expect_rc 0
  expect_out "Signing agent: running (PID $(agent_pid)) at ./a.sock"
  expect_out "$(fingerprint key.pub)"
  expect_out "(pinned)"
}

t_status_when_not_running() {
  sa status
  expect_rc 0
  expect_out "Signing agent: not running"
}

t_warns_when_not_pinned() {
  sa start
  expect_rc 0
  expect_out "WARNING: sbx ssh.agentSocketPath is '<unset>'"
  echo /some/other.sock >sbx.state
  sa status
  expect_out "WARNING: sbx ssh.agentSocketPath is '/some/other.sock'"
}

t_sbx_without_settings_get() {
  export FAKE_SBX_NO_GET=1
  sa start
  expect_rc 0
  expect_out "couldn't read sbx's ssh.agentSocketPath"
  expect_only_key "$(fingerprint key.pub)"
}

t_stop() {
  sa start; local pid; pid="$(agent_pid)"
  sa stop
  expect_rc 0
  expect_out "Stopped signing agent (PID $pid)."
  wait_dead "$pid" || fail "agent $pid still running after stop"
  expect_no_agent
}

t_stop_when_not_running() {
  sa stop
  expect_rc 0
  expect_out "Signing agent was not running."
}

t_cleans_up_after_crash() {
  sa start; local old; old="$(agent_pid)"
  kill -9 "$old"; wait_dead "$old" || fail "couldn't kill agent $old"
  [[ -S a.sock ]] || fail "test setup: expected a stale socket after kill -9"
  sa start
  expect_rc 0
  expect_out "Started signing agent"
  [[ "$(agent_pid)" != "$old" ]] || fail "still using the dead agent's PID $old"
  expect_only_key "$(fingerprint key.pub)"
}

t_refuses_foreign_agent() {
  start_foreign_agent
  sa start
  expect_rc 1
  expect_out "wasn't started by this script; refusing to use it."
  [[ -z "$(agent_keys)" ]] || fail "a key was loaded into the foreign agent"
  sa stop
  expect_rc 1
  expect_out "not killing it blindly"
  alive "$FOREIGN_PID" || fail "the foreign agent was killed"
  [[ -S a.sock ]] || fail "the foreign agent's socket was removed"
}

t_stop_ignores_unrelated_pid() {
  # The PID file points at a process that isn't ssh-agent, as after PID reuse.
  sleep 60 & local other=$!; EXTRA_PIDS+=("$other")
  echo "$other" >a.pid
  sa stop
  expect_rc 0
  expect_out "Signing agent was not running."
  alive "$other" || fail "stop killed unrelated process $other"
}

t_removes_extra_keys() {
  sa start
  ssh-keygen -q -t ed25519 -N '' -C other-key -f other
  SSH_AUTH_SOCK=./a.sock ssh-add -q other 2>/dev/null
  [[ "$(agent_keys | wc -l)" -eq 2 ]] || fail "test setup: expected 2 keys in the agent"
  sa start
  expect_rc 0
  expect_only_key "$(fingerprint key.pub)"
}

t_wrong_passphrase_stops_agent() {
  ssh-keygen -q -p -P '' -N right-pass -f key >/dev/null
  use_askpass wrong-pass
  sa start
  expect_rc 1
  expect_out "failed to load"
  expect_no_agent
}

t_right_passphrase_loads_key() {
  ssh-keygen -q -p -P '' -N right-pass -f key >/dev/null
  use_askpass right-pass
  sa start
  expect_rc 0
  expect_only_key "$(fingerprint key.pub)"
}

t_passphrase_key_without_pub() {
  # Without key.pub, the fingerprint comes from the encrypted private key, which
  # must work without asking for the passphrase a second time.
  ssh-keygen -q -p -P '' -N right-pass -f key >/dev/null
  local want; want="$(fingerprint key.pub)"; rm key.pub
  use_askpass right-pass
  sa start
  expect_rc 0
  expect_only_key "$want"
  [[ "$(cat askpass.count)" -eq 1 ]] || fail "passphrase asked $(cat askpass.count) times, expected once"
}

t_mismatched_pub_fails_closed() {
  ssh-keygen -q -t ed25519 -N '' -C other-key -f other
  cp other.pub key.pub
  sa start
  expect_rc 1
  expect_out "does not hold exactly the expected key"
  expect_out "key.pub belongs to a different key"
  expect_no_agent
}

t_missing_key() {
  rm key key.pub
  sa start
  expect_rc 1
  expect_out "signing key not found"
  expect_no_agent
}

t_lifetime_expires() {
  export SBX_SIGNING_LIFETIME=2s
  sa start
  expect_rc 0
  sleep 3
  sa status
  expect_out "No keys loaded"
  [[ -z "$(agent_keys)" ]] || fail "key still loaded after its lifetime"
}

# Replace the throwaway key with an older PEM-format RSA key and no .pub.
use_pem_key() {
  rm -f key key.pub
  ssh-keygen -q -m PEM -t rsa -b 2048 -N "$1" -C pem-key -f key && rm key.pub
}

t_plain_pem_key_without_pub() {
  use_pem_key ''
  sa start
  expect_rc 0
  expect_out "Loaded SHA256:"
  [[ -n "$(agent_keys)" ]] || fail "agent holds no key"
}

t_encrypted_pem_key_without_pub_fails_closed() {
  use_pem_key 'passw0rd'
  use_askpass 'passw0rd'
  sa start
  expect_rc 1
  expect_out "ssh-keygen -y -f"
  expect_no_agent
}

# allowed-signers reads git's global config; point it at a file in the test folder.
use_git_config() {
  export GIT_CONFIG_GLOBAL="$PWD/gitconfig"
  : >gitconfig
  [[ $# -eq 0 ]] || git config --global user.email "$1"
}
pub_of() { awk 'NR == 1 {print $1" "$2}' "$1"; }

t_allowed_signers_from_agent() {
  use_git_config agent@example.com
  sa start
  ssh-keygen -q -t ed25519 -N '' -C other -f other && mv other.pub key.pub  # .pub now differs
  sa allowed-signers
  expect_rc 0
  [[ "$(head -n 1 <<<"$OUT")" == "agent@example.com namespaces=\"git\" $(SSH_AUTH_SOCK=./a.sock ssh-add -L | awk '{print $1" "$2}')" ]] \
    || fail "line isn't the agent's key. Output: $OUT"
  expect_out "point git at it"
}

t_allowed_signers_from_pub() {
  use_git_config
  git config --global gpg.ssh.allowedSignersFile "$PWD/signers"
  sa allowed-signers me@example.com
  expect_rc 0
  [[ "$(head -n 1 <<<"$OUT")" == "me@example.com namespaces=\"git\" $(pub_of key.pub)" ]] \
    || fail "line isn't from key.pub. Output: $OUT"
  expect_out "Add this line to $PWD/signers"
}

t_allowed_signers_without_key() {
  use_git_config me@example.com
  rm key.pub
  sa allowed-signers
  expect_rc 1
  expect_out "run '"
}

t_allowed_signers_needs_email() {
  use_git_config
  sa allowed-signers
  expect_rc 1
  expect_out "no user.email"
}

t_allowed_signers_rejects_patterns() {
  use_git_config
  local bad
  for bad in '*' 'a@x,b@y' 'a b@x' '!a@x' 'a?@x' 'a"@x'; do
    sa allowed-signers "$bad"
    [[ $RC -eq 1 ]] || fail "accepted '$bad'. Output: $OUT"
  done
}

t_refuses_to_be_sourced_by_bash() {
  OUT="$(bash -c '. "$1" start; echo "after:$?"' _ "$SCRIPT" 2>&1)"
  expect_out "don't source it"
  expect_out "after:1"
  [[ ! -e a.sock ]] || fail "an agent was started"
}

t_refuses_other_shells() {
  local sh
  for sh in sh dash zsh; do
    if ! command -v "$sh" >/dev/null 2>&1; then skip "$sh isn't installed"; continue; fi
    # Single quotes are intended: the child shell expands these, not this one.
    # shellcheck disable=SC2016
    if [[ -n "$("$sh" -c 'echo "${BASH_VERSION:-}"')" ]]; then skip "$sh is bash here"; continue; fi
    OUT="$("$sh" "$SCRIPT" start 2>&1)"; RC=$?
    expect_rc 1
    expect_out "run this with bash"
    # shellcheck disable=SC2016
    OUT="$("$sh" -c '. "$1" start; echo "after:$?"' _ "$SCRIPT" 2>&1)"
    expect_out "run this with bash"
    expect_out "after:1"
  done
  [[ ! -e a.sock ]] || fail "an agent was started"
}

# --- Runner -----------------------------------------------------------------------

cleanup_test() {
  local pid
  for pid in $(agent_pid) ${EXTRA_PIDS[@]+"${EXTRA_PIDS[@]}"}; do kill "$pid" 2>/dev/null; done
}

run_test() {
  (
    local dir="$ROOT/$1"
    mkdir -p "$dir" && cd "$dir" || exit 1
    FAILED=0; EXTRA_PIDS=()
    trap cleanup_test EXIT
    export FAKE_SBX_LOG="$dir/sbx.log" FAKE_SBX_STATE="$dir/sbx.state"
    export SBX_SIGNING_KEY="$dir/key" SBX_SIGNING_SOCK=./a.sock SBX_SIGNING_LIFETIME=5m
    : >sbx.log
    ssh-keygen -q -t ed25519 -N '' -C test-key -f key
    "t_$1"
    exit "$FAILED"
  )
}

# Not mapfile, and no empty arrays under set -u: macOS ships bash 3.2.
# Word splitting is safe here: test names are function names, with no spaces or globs.
# shellcheck disable=SC2207
ALL=($(declare -F | awk '$3 ~ /^t_/ { sub(/^t_/, "", $3); print $3 }'))
if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${ALL[@]}"; exit 0; fi
if [[ $# -gt 0 ]]; then TESTS=("$@"); else TESTS=("${ALL[@]}"); fi

passed=0; failed=0
for t in "${TESTS[@]}"; do
  declare -F "t_$t" >/dev/null || { echo "unknown test: $t (see --list)" >&2; exit 2; }
  if run_test "$t"; then echo "ok   $t"; passed=$((passed + 1))
  else echo "FAIL $t"; failed=$((failed + 1)); fi
done
echo
echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]
