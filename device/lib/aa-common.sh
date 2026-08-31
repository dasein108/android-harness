#!/data/data/com.termux/files/usr/bin/env bash
# android-harness :: shared shell library for device-side commands.
#
# Sourced by everything under ~/android-agent/bin. Keep it dependency-light:
# only coreutils + termux-api are assumed, and termux-api is probed, never
# assumed present.
#
# Exit code contract (used by every android-* command):
#   0  success
#   2  usage error (bad/missing arguments)
#   3  capability unavailable (Termux:API missing, no such sensor/API)
#   4  permission denied by Android (runtime permission not granted)
#   5  runtime failure (the underlying call ran and failed)

# These are the library's public surface: every android-* command relies on
# them, so shellcheck cannot see the uses from this file alone.
# shellcheck disable=SC2034
AA_ROOT="${AA_ROOT:-$HOME/android-agent}"
AA_LOGS="$AA_ROOT/logs"
AA_CONFIG="$AA_ROOT/config"
AA_TMP="$AA_ROOT/tmp"

AA_EXIT_OK=0
AA_EXIT_USAGE=2
AA_EXIT_UNAVAILABLE=3
AA_EXIT_PERMISSION=4
AA_EXIT_RUNTIME=5

aa_err()  { printf '%s\n' "$*" >&2; }
aa_die()  { local code="$1"; shift; aa_err "error: $*"; exit "$code"; }
aa_usage(){ aa_err "usage: $*"; exit "$AA_EXIT_USAGE"; }

# aa_log <component> <message...> — append to the local log. Logs stay on the
# device; nothing is shipped anywhere.
aa_log() {
  local comp="$1"; shift
  mkdir -p "$AA_LOGS" 2>/dev/null || return 0
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$comp" "$*" \
    >> "$AA_LOGS/agent.log" 2>/dev/null || true
}

aa_have() { command -v "$1" >/dev/null 2>&1; }

# aa_require_api <termux-command> — fail with code 3 when the Termux:API
# helper binary or the Termux:API app is missing, so callers never mistake an
# absent bridge for an empty result.
aa_require_api() {
  local cmd="$1"
  if ! aa_have "$cmd"; then
    aa_err "error: '$cmd' not found."
    aa_err "hint:  install the bridge with: pkg install termux-api"
    aa_err "hint:  and install the Termux:API app (F-Droid / GitHub release)."
    exit "$AA_EXIT_UNAVAILABLE"
  fi
}

# aa_json_escape <string> — minimal JSON string escaping for the few places we
# emit JSON by hand rather than through jq.
aa_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# aa_run_api <command> [args...] — run a termux-api command with a timeout so a
# missing Termux:API app cannot hang the agent forever, and translate the
# common failure shapes into our exit-code contract.
aa_run_api() {
  local cmd="$1"; shift
  aa_require_api "$cmd"
  local out rc
  if aa_have timeout; then
    out="$(timeout "${AA_API_TIMEOUT:-20}" "$cmd" "$@" 2>&1)"; rc=$?
  else
    out="$("$cmd" "$@" 2>&1)"; rc=$?
  fi
  if [ "$rc" -eq 124 ]; then
    aa_err "error: $cmd timed out after ${AA_API_TIMEOUT:-20}s."
    aa_err "hint:  the Termux:API app may not be installed or is being killed by battery optimisation."
    return "$AA_EXIT_UNAVAILABLE"
  fi
  if printf '%s' "$out" | grep -qiE 'permission (denied|to)|not granted|SecurityException'; then
    aa_err "$out"
    aa_err "hint:  grant the Android permission to Termux:API in Settings > Apps > Termux:API > Permissions."
    return "$AA_EXIT_PERMISSION"
  fi
  printf '%s' "$out"
  [ "$rc" -eq 0 ] || return "$AA_EXIT_RUNTIME"
  return 0
}

# --- on-device adb -----------------------------------------------------------
# When the phone is paired with its own adb it shows up twice: once as
# 127.0.0.1:PORT and once as emulator-NNNN, because adb aliases loopback ports
# into the emulator namespace. A bare `adb shell` then fails with "more than one
# device/emulator", so always target the one authorised transport explicitly.
AA_ADB_SERIAL=""

aa_adb_serial() {
  [ -n "$AA_ADB_SERIAL" ] && { printf '%s' "$AA_ADB_SERIAL"; return 0; }
  aa_have adb || return 1
  # Do not touch adb unless the owner explicitly enabled it. `adb devices` forks
  # a server that listens on 127.0.0.1:5037, so probing for the capability would
  # otherwise *create* a daemon — a status check must never do that.
  [ -f "$AA_CONFIG/adb-enabled" ] || return 1
  AA_ADB_SERIAL="$(adb devices 2>/dev/null | awk '$2=="device" {print $1; exit}')"
  [ -n "$AA_ADB_SERIAL" ] || return 1
  printf '%s' "$AA_ADB_SERIAL"
}

aa_adb() {
  local s
  s="$(aa_adb_serial)" || return 1
  adb -s "$s" "$@"
}

# True only when adb can actually run a command as the shell uid.
aa_adb_ready() { aa_adb shell true >/dev/null 2>&1; }

# aa_secret_guard <text> — refuse to print blobs that look like private key
# material. Cheap belt-and-braces so a clipboard dump never lands in a log.
aa_secret_guard() {
  case "$1" in
    *"PRIVATE KEY"*|*"BEGIN OPENSSH PRIVATE"*)
      aa_err "refusing to print content that looks like a private key"
      return 1 ;;
  esac
  return 0
}
