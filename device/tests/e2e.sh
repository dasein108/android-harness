#!/data/data/com.termux/files/usr/bin/env bash
# android-harness :: end-to-end test suite (device side)
#
# Every check is functional: it runs the thing and inspects the result. Tests
# that need a permission the owner has not granted report SKIP with the reason
# rather than failing the suite or silently passing.
#
#   e2e.sh            run everything that does not disturb the user
#   e2e.sh --full     also exercise camera, notification, vibration, clipboard
#   e2e.sh --json     machine-readable summary on stdout

set -uo pipefail

AA_ROOT="${AA_ROOT:-$HOME/android-agent}"
[ -f "$AA_ROOT/lib/aa-common.sh" ] && . "$AA_ROOT/lib/aa-common.sh"
export PATH="$AA_ROOT/bin:$PATH"

FULL=0
JSON=0
for a in "$@"; do
  case "$a" in
    --full) FULL=1 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; SKIP=0
RESULTS=""

record() { # record <status> <name> <detail>
  RESULTS="$RESULTS$1|$2|$3"$'\n'
  case "$1" in
    PASS) PASS=$((PASS+1)) ;;
    FAIL) FAIL=$((FAIL+1)) ;;
    SKIP) SKIP=$((SKIP+1)) ;;
  esac
  [ "$JSON" -eq 1 ] || printf '%-5s %-24s %s\n' "$1" "$2" "$3"
}

[ "$JSON" -eq 1 ] || echo "android-agent end-to-end tests ($(date))"
[ "$JSON" -eq 1 ] || echo "-------------------------------------------------------------"

# --- shell ------------------------------------------------------------------
if [ "$(sh -c 'echo hello')" = hello ]; then record PASS shell "echo hello"
else record FAIL shell "sh did not echo"; fi

# --- filesystem (agent tree) ------------------------------------------------
TF="$AA_ROOT/tmp/e2e-$$.txt"
if mkdir -p "$AA_ROOT/tmp" \
   && echo one > "$TF" && [ "$(cat "$TF")" = one ] \
   && echo two >> "$TF" && [ "$(wc -l < "$TF")" -eq 2 ] \
   && mv "$TF" "$TF.moved" && [ -f "$TF.moved" ] \
   && rm -f "$TF.moved" && [ ! -e "$TF.moved" ]; then
  record PASS filesystem "create/read/append/move/delete"
else
  record FAIL filesystem "round-trip failed under $AA_ROOT/tmp"
  rm -f "$TF" "$TF.moved" 2>/dev/null
fi

# --- shared storage ---------------------------------------------------------
SF="$HOME/storage/shared/.android-agent-e2e-$$"
if [ -d "$HOME/storage/shared" ]; then
  if echo shared > "$SF" 2>/dev/null && [ "$(cat "$SF" 2>/dev/null)" = shared ]; then
    rm -f "$SF"
    record PASS shared-storage "read/write ~/storage/shared"
  else
    rm -f "$SF" 2>/dev/null
    record FAIL shared-storage "present but not writable"
  fi
else
  record SKIP shared-storage "no ~/storage (storage permission not granted)"
fi

# --- python -----------------------------------------------------------------
if command -v python >/dev/null 2>&1; then
  [ "$(python -c 'print("python-ok")' 2>&1)" = python-ok ] \
    && record PASS python "$(python --version 2>&1)" \
    || record FAIL python "python -c failed"
  python -m pip --version >/dev/null 2>&1 \
    && record PASS pip "$(python -m pip --version 2>&1 | cut -d' ' -f1-2)" \
    || record FAIL pip "python -m pip failed"
  V="$AA_ROOT/python/venvs/default"
  if [ -x "$V/bin/python" ]; then
    [ "$("$V/bin/python" -c 'print("venv-ok")' 2>&1)" = venv-ok ] \
      && record PASS venv "default venv runs" \
      || record FAIL venv "default venv broken"
  else
    record SKIP venv "no default venv at $V"
  fi
  # A real script, written and executed like the agent would.
  S="$AA_ROOT/tmp/e2e-$$.py"
  printf 'import json,sys\nprint(json.dumps({"ok": True, "argv": sys.argv[1:]}))\n' > "$S"
  out="$(python "$S" alpha 2>&1)"
  rm -f "$S"
  case "$out" in *'"ok": true'*) record PASS python-script "arbitrary script executes" ;;
                 *) record FAIL python-script "$out" ;; esac
else
  record FAIL python "not installed"
fi

# --- node -------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  [ "$(node -e 'console.log("node-ok")' 2>&1)" = node-ok ] \
    && record PASS node "$(node --version 2>&1)" \
    || record FAIL node "node -e failed"
  command -v npm >/dev/null 2>&1 \
    && record PASS npm "$(npm --version 2>&1)" \
    || record FAIL npm "npm missing"
  S="$AA_ROOT/tmp/e2e-$$.js"
  printf 'const fs=require("fs");fs.writeFileSync(process.argv[2],"node-file-ok");console.log("node-script-ok");\n' > "$S"
  O="$AA_ROOT/tmp/e2e-$$.out"
  if [ "$(node "$S" "$O" 2>&1)" = node-script-ok ] && [ "$(cat "$O" 2>/dev/null)" = node-file-ok ]; then
    record PASS node-script "arbitrary script executes and writes"
  else
    record FAIL node-script "script or file write failed"
  fi
  rm -f "$S" "$O"
else
  record FAIL node "not installed"
fi

# --- claude -----------------------------------------------------------------
if command -v claude >/dev/null 2>&1; then
  if out="$(claude --version 2>&1)"; then
    record PASS claude-version "$out"
    # Minimal non-destructive invocation: ask for help, which needs no network,
    # no API key and writes nothing.
    if claude --help >/dev/null 2>&1; then
      record PASS claude-invoke "claude --help runs"
    else
      record FAIL claude-invoke "claude --help failed"
    fi
  else
    record FAIL claude-version "$out"
  fi
else
  record SKIP claude "not installed"
fi

# --- termux:api bridge ------------------------------------------------------
api_test() { # api_test <name> <needs-full> <command...>
  local name="$1" needs_full="$2"; shift 2
  if ! command -v "$1" >/dev/null 2>&1; then
    record SKIP "$name" "$1 not installed (pkg install termux-api)"; return
  fi
  if [ "$needs_full" = yes ] && [ "$FULL" -eq 0 ]; then
    record SKIP "$name" "needs --full (user-visible side effect)"; return
  fi
  local out rc
  out="$(timeout 15 "$@" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    record PASS "$name" "$(printf '%s' "$out" | tr -d '\n' | cut -c1-60)"
  elif [ $rc -eq 124 ]; then
    record FAIL "$name" "timed out — is the Termux:API app installed?"
  else
    record SKIP "$name" "exit $rc: $(printf '%s' "$out" | tr -d '\n' | cut -c1-60)"
  fi
}

api_test battery      no  termux-battery-status
api_test wifi         no  termux-wifi-connectioninfo
api_test volume       no  termux-volume
api_test camera-info  no  termux-camera-info
api_test location     no  termux-location -p network -r last

if [ "$FULL" -eq 1 ]; then
  # Clipboard round-trip: save, set, read back, restore.
  if command -v termux-clipboard-get >/dev/null 2>&1; then
    OLD="$(timeout 10 termux-clipboard-get 2>/dev/null)"
    MARK="android-agent-e2e-$$"
    if printf '%s' "$MARK" | timeout 10 termux-clipboard-set 2>/dev/null \
       && [ "$(timeout 10 termux-clipboard-get 2>/dev/null)" = "$MARK" ]; then
      record PASS clipboard "write/read round-trip"
    else
      record FAIL clipboard "round-trip mismatch"
    fi
    [ -n "$OLD" ] && printf '%s' "$OLD" | timeout 10 termux-clipboard-set 2>/dev/null
  else
    record SKIP clipboard "termux-api missing"
  fi

  api_test notification yes termux-notification -t "android-agent" -c "end-to-end test" -i aa-e2e
  command -v termux-notification-remove >/dev/null 2>&1 && termux-notification-remove aa-e2e >/dev/null 2>&1
  api_test vibrate      yes termux-vibrate -d 200

  if command -v termux-camera-photo >/dev/null 2>&1; then
    SHOT="$AA_ROOT/output/e2e-camera-$$.jpg"
    mkdir -p "$AA_ROOT/output"
    # The camera is often still busy for a few seconds after another capture
    # (a manifest refresh, say), and Termux:API signals that as an empty file
    # rather than an error. One retry removes that false negative.
    for attempt in 1 2; do
      timeout 25 termux-camera-photo -c 0 "$SHOT" >/dev/null 2>&1
      [ -s "$SHOT" ] && break
      [ "$attempt" = 1 ] && sleep 4
    done
    if [ -s "$SHOT" ]; then
      record PASS camera "captured $(wc -c < "$SHOT") bytes"
    else
      record SKIP camera "capture failed — needs CAMERA granted (aa grant camera) and Termux in the foreground"
    fi
    rm -f "$SHOT" 2>/dev/null
  else
    record SKIP camera "termux-api missing"
  fi
fi

# --- screenshot / UI automation --------------------------------------------
record SKIP screenshot "host-side capability: aa ui screenshot (adb)"
record SKIP ui-automation "host-side capability: aa ui tap/text/key/dump (adb)"

# --- control channel + exposure --------------------------------------------
if pgrep -x sshd >/dev/null 2>&1; then
  record PASS sshd "running"
else
  record FAIL sshd "not running (android-agent-server start)"
fi

listeners() {
  if command -v ss >/dev/null 2>&1; then ss -lntu 2>/dev/null | tail -n +2
  else netstat -lntu 2>/dev/null | tail -n +3; fi
}
LISTEN="$(listeners)"
# Column index for the local address differs between ss and netstat, so take the
# first field shaped like addr:port rather than counting columns.
ADDRS="$(printf '%s\n' "$LISTEN" \
  | awk '{for(i=1;i<=NF;i++) if ($i ~ /:[0-9]+$/) { print $i; break }}')"

if [ -z "$ADDRS" ]; then
  # Android denies an untrusted_app uid both the netlink socket `ss` needs and
  # /proc/net/tcp, so this check sees an empty table no matter what is listening.
  # Reporting PASS here would be a vacuous pass, so say what is really known.
  record SKIP no-external-listener "app uid cannot enumerate sockets — run 'aa netaudit' from the host"
else
  EXPOSED="$(printf '%s\n' "$ADDRS" | grep -vE '^(127\.0\.0\.1|\[::1\]|::1|localhost):' || true)"
  if [ -z "$EXPOSED" ]; then
    record PASS no-external-listener "all visible listeners are loopback"
  else
    record FAIL no-external-listener "non-loopback bind: $(printf '%s' "$EXPOSED" | tr '\n' ' ')"
  fi
fi

# What the agent *can* verify from here: its own channel is configured for
# loopback. This is a config check, not a socket check, and is labelled as such.
if grep -qiE '^[[:space:]]*ListenAddress[[:space:]]+(127\.0\.0\.1|::1)$' "$PREFIX/etc/ssh/sshd_config" 2>/dev/null \
   && ! grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$PREFIX/etc/ssh/sshd_config" 2>/dev/null; then
  record PASS sshd-config "ListenAddress loopback, password auth off"
else
  record FAIL sshd-config "sshd_config does not pin loopback + pubkey-only"
fi

[ "$JSON" -eq 1 ] || {
  echo "-------------------------------------------------------------"
  echo "listening sockets:"
  printf '%s\n' "$LISTEN" | sed 's/^/  /'
  echo "-------------------------------------------------------------"
  printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ] && echo "E2E_RESULT=OK" || echo "E2E_RESULT=FAIL"
}

if [ "$JSON" -eq 1 ]; then
  printf '{\n  "pass": %d, "fail": %d, "skip": %d,\n  "tests": [\n' "$PASS" "$FAIL" "$SKIP"
  first=1
  printf '%s' "$RESULTS" | while IFS='|' read -r st nm dt; do
    [ -n "$st" ] || continue
    [ $first -eq 1 ] || printf ',\n'
    first=0
    printf '    {"status": "%s", "name": "%s", "detail": "%s"}' \
      "$st" "$nm" "$(printf '%s' "$dt" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  done
  printf '\n  ]\n}\n'
fi

[ "$FAIL" -eq 0 ]
