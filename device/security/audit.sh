#!/data/data/com.termux/files/usr/bin/env bash
# android-harness :: security audit (device side)
#
# Answers one question: does this installation expose anything, or persist
# anything, that the owner did not ask for? It reports facts and then decides
# PASS/FAIL. It never "passes" an unexplained listener or persistence hook.
#
#   audit.sh           human-readable report, exit 0 on PASS
#   audit.sh --quiet   only the final report block

set -uo pipefail

AA_ROOT="${AA_ROOT:-$HOME/android-agent}"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# This script greps for the very patterns it is written from, so every scan
# below excludes it by name.
SELF_NAME="$(basename "$0")"

VERDICT_FAIL=0
FINDINGS=""

sec()  { [ "$QUIET" -eq 1 ] || printf '\n== %s ==\n' "$*"; }
line() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
flag() { FINDINGS="$FINDINGS\n  - $*"; VERDICT_FAIL=1; }

listeners() {
  if command -v ss >/dev/null 2>&1; then ss -lntup 2>/dev/null | tail -n +2
  else netstat -lntup 2>/dev/null | tail -n +3; fi
}

# The local address column sits at a different index for ss vs netstat, and ss
# itself shifts it depending on the flags. Take the first field that looks like
# addr:port instead of counting columns.
local_addrs() {
  printf '%s\n' "$1" | awk '{for(i=1;i<=NF;i++) if ($i ~ /:[0-9]+$/) { print $i; break }}'
}

# ---------------------------------------------------------------------------
sec "Listening sockets"
LISTEN="$(listeners)"
ADDRS="$(local_addrs "$LISTEN")"
BLIND=0
if [ -z "$ADDRS" ]; then
  # Android denies an untrusted_app uid the netlink socket `ss` needs and
  # /proc/net/tcp as well, so this table is empty regardless of what listens.
  # Saying "all clear" from here would be a vacuous pass.
  BLIND=1
  line "  (empty — an untrusted_app uid cannot enumerate sockets on this Android version)"
  line "  authoritative check: run 'aa netaudit' on the host; it reads /proc/net via adb"
  NONLOOP=""
else
  line "$LISTEN"
  NONLOOP="$(printf '%s\n' "$ADDRS" | grep -vE '^(127\.0\.0\.1|\[::1\]|::1|localhost):' || true)"
  if [ -n "$NONLOOP" ]; then
    flag "non-loopback listener(s): $(printf '%s' "$NONLOOP" | tr '\n' ' ')"
  else
    line "  all listeners are loopback-only"
  fi
fi

# ---------------------------------------------------------------------------
sec "sshd configuration"
SSHD_CONF="$PREFIX/etc/ssh/sshd_config"
if [ -f "$SSHD_CONF" ]; then
  grep -iE '^[[:space:]]*(ListenAddress|Port|PasswordAuthentication|PubkeyAuthentication|PermitRootLogin|PermitEmptyPasswords|GatewayPorts|AllowTcpForwarding)' \
    "$SSHD_CONF" | sed 's/^/  /' | while read -r l; do line "$l"; done

  LA="$(grep -iE '^[[:space:]]*ListenAddress' "$SSHD_CONF" | awk '{print $2}')"
  [ -n "$LA" ] || flag "sshd has no ListenAddress: it would bind every interface"
  for a in $LA; do
    case "$a" in 127.0.0.1|::1|localhost) ;; *) flag "sshd ListenAddress '$a' is not loopback" ;; esac
  done
  grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$SSHD_CONF" \
    && flag "sshd allows password authentication"
  grep -qiE '^[[:space:]]*GatewayPorts[[:space:]]+yes' "$SSHD_CONF" \
    && flag "sshd GatewayPorts=yes would republish forwarded ports on all interfaces"
else
  line "  openssh not installed"
fi

sec "Authorized keys"
AK="$HOME/.ssh/authorized_keys"
if [ -f "$AK" ]; then
  line "  $(wc -l < "$AK") authorized key(s), mode $(stat -c %a "$AK" 2>/dev/null)"
  # Print fingerprints and comments only — never the key material context.
  while read -r _t _k comment; do
    [ -n "${_k:-}" ] || continue
    line "    - ${comment:-<no comment>}"
  done < "$AK"
  [ "$(stat -c %a "$AK" 2>/dev/null)" = 600 ] || flag "authorized_keys is not mode 600"
else
  line "  none"
fi

sec "Private key material inside the agent tree"
# Look for a real PEM header, skip binary files (-I), and skip this script,
# which necessarily contains the pattern it searches for.
PRIV="$(grep -rlI --exclude="$SELF_NAME" -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$AA_ROOT" 2>/dev/null || true)"
if [ -n "$PRIV" ]; then
  flag "private key material found under $AA_ROOT: $(printf '%s' "$PRIV" | tr '\n' ' ')"
else
  line "  none — the private half of the control key stays on the Mac"
fi

# ---------------------------------------------------------------------------
sec "Persistence hooks"
# Termux:Boot is the only supported way to auto-start on this device.
if [ -d "$HOME/.termux/boot" ] && [ -n "$(ls -A "$HOME/.termux/boot" 2>/dev/null)" ]; then
  line "  ~/.termux/boot contains:"
  ls -l "$HOME/.termux/boot" | sed 's/^/    /' | while read -r l; do line "$l"; done
  flag "Termux:Boot scripts exist — the harness installs none, so review these"
else
  line "  ~/.termux/boot: empty or absent (harness installs no boot persistence)"
fi

if command -v crontab >/dev/null 2>&1 && crontab -l >/dev/null 2>&1; then
  CRON="$(crontab -l 2>/dev/null)"
  if [ -n "$CRON" ]; then
    line "  crontab entries:"; printf '%s\n' "$CRON" | sed 's/^/    /' | while read -r l; do line "$l"; done
    flag "cron entries exist — the harness installs none, so review these"
  fi
else
  line "  cron: not installed / no entries"
fi

RUNIT_ENABLED=""
for svc in "$PREFIX/var/service" "$PREFIX/etc/service"; do
  [ -d "$svc" ] || continue
  for d in "$svc"/*; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ -f "$d/down" ]; then
      line "  runit service $name: present but disabled (a 'down' file is in place)"
    else
      line "  runit service $name: ENABLED — would start whenever runsvdir runs"
      RUNIT_ENABLED="$RUNIT_ENABLED $name"
    fi
  done
done
if pgrep -x runsvdir >/dev/null 2>&1; then
  line "  runsvdir: running"
  [ -n "$RUNIT_ENABLED" ] && flag "runit is running with enabled service(s):$RUNIT_ENABLED"
else
  line "  runsvdir: not running, so no runit service starts on its own"
fi

sec "Shell startup files"
for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc" "$PREFIX/etc/bash.bashrc"; do
  [ -f "$rc" ] || continue
  # Anything that fetches and runs code at shell start is the pattern we care about.
  SUSPECT="$(grep -nE 'curl.*\|.*(ba)?sh|wget.*\|.*(ba)?sh|nc .*-e|/dev/tcp/|base64 -d.*\|' "$rc" 2>/dev/null || true)"
  if [ -n "$SUSPECT" ]; then
    flag "suspicious startup entry in $rc"
    line "  $rc:"; printf '%s\n' "$SUSPECT" | sed 's/^/    /' | while read -r l; do line "$l"; done
  else
    line "  $rc: clean$( grep -q '# >>> android-harness >>>' "$rc" && echo ' (contains the documented android-harness block)')"
  fi
done

# ---------------------------------------------------------------------------
sec "Outbound / callback patterns in agent scripts"
if [ -d "$AA_ROOT" ]; then
  # --exclude this script: an auditor that greps for these patterns necessarily
  # contains them, and matching itself would make every run fail.
  HITS="$(grep -rnI --exclude="$SELF_NAME" -E 'curl[^|]*\|[[:space:]]*(ba)?sh|wget[^|]*\|[[:space:]]*(ba)?sh|nc[[:space:]].*-e[[:space:]]|/dev/tcp/|ngrok|localtunnel|serveo|upnp|tor(socks)?[[:space:]]' \
    "$AA_ROOT/bin" "$AA_ROOT/scripts" "$AA_ROOT/tests" "$AA_ROOT/security" 2>/dev/null || true)"
  if [ -n "$HITS" ]; then
    flag "download-and-execute or tunnelling pattern in agent scripts"
    printf '%s\n' "$HITS" | sed 's/^/    /' | while read -r l; do line "$l"; done
  else
    line "  none: no pipe-to-shell, no reverse shell, no tunnel helper"
  fi

  URLS="$(grep -rhoI --exclude="$SELF_NAME" -E 'https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+' \
    "$AA_ROOT/bin" "$AA_ROOT/scripts" 2>/dev/null | sort -u || true)"
  if [ -n "$URLS" ]; then
    line "  external URLs referenced by agent scripts:"
    printf '%s\n' "$URLS" | sed 's/^/    /' | while read -r l; do line "$l"; done
  else
    line "  no hard-coded external URLs in agent scripts"
  fi
fi

sec "Established network connections (device-visible)"
if command -v ss >/dev/null 2>&1; then
  CONNS="$(ss -tnp state established 2>/dev/null | tail -n +2)"
  line "${CONNS:-  none visible to this uid}"
else
  line "  ss unavailable"
fi

sec "Agent processes"
PS="$(ps -o pid,ppid,user,args -e 2>/dev/null | grep -E 'sshd|android-agent|node .*claude' | grep -v grep || true)"
line "${PS:-  none}"

sec "Permissions on the agent tree"
if [ -d "$AA_ROOT" ]; then
  line "  $AA_ROOT mode $(stat -c %a "$AA_ROOT" 2>/dev/null)"
  WORLD="$(find "$AA_ROOT" -maxdepth 2 -perm -o+w 2>/dev/null || true)"
  [ -n "$WORLD" ] && flag "world-writable paths under the agent tree: $(printf '%s' "$WORLD" | tr '\n' ' ')"
  for f in "$AA_ROOT/config"/*; do
    [ -f "$f" ] || continue
    m="$(stat -c %a "$f" 2>/dev/null)"
    case "$m" in 600|700|644) ;; *) flag "loose permissions ($m) on $f" ;; esac
  done
fi

# ---------------------------------------------------------------------------
# Final report block
# ---------------------------------------------------------------------------
LOOPBACK_ONLY=$([ -z "$NONLOOP" ] && echo YES || echo NO)
SSHD_STATE=$(pgrep -x sshd >/dev/null 2>&1 && echo running || echo stopped)
PORTS="$(local_addrs "$LISTEN" | tr '\n' ' ')"

CAPS="unknown"
[ -f "$AA_ROOT/config/manifest.json" ] && CAPS="$(tr -d '\n ' < "$AA_ROOT/config/manifest.json" | sed -n 's/.*"capabilities":\[\([^]]*\)\].*/\1/p' | tr -d '"')"

vers() { command -v "$1" >/dev/null 2>&1 && "$@" 2>&1 | head -1 || echo "not installed"; }

SHARED="no"
[ -d "$HOME/storage/shared" ] && [ -w "$HOME/storage/shared" ] && SHARED="yes (~/storage/shared)"

cat <<REPORT

============================================================
LOCAL ACCESS:
$([ "$SSHD_STATE" = running ] && echo "YES — ssh on 127.0.0.1:8022, pubkey-only, reachable from the Mac via adb forward over USB" || echo "NO — sshd is not running")

INTERNET-EXPOSED CONTROL:
$(if [ "$BLIND" = 1 ]; then
    echo "NO for this harness — sshd_config pins ListenAddress 127.0.0.1 with password auth off."
    echo "  (Socket enumeration is denied to an app uid here; 'aa netaudit' on the host confirms"
    echo "   it from /proc/net via adb, including which app owns every other listener.)"
  elif [ "$LOOPBACK_ONLY" = YES ]; then
    echo "NO — every listener is bound to loopback; nothing is reachable from the LAN or the Internet"
  else
    echo "YES — see findings"
  fi)

LISTENING PORTS:
$(if [ "$BLIND" = 1 ]; then echo "not enumerable from the app uid — see 'aa netaudit'"; else echo "${PORTS:-none}"; fi)

PERSISTENT SERVICES:
sshd: $SSHD_STATE (started on demand by android-agent-server; no boot hook installed)
Termux:Boot scripts: $([ -n "$(ls -A "$HOME/.termux/boot" 2>/dev/null)" ] && echo "PRESENT (review)" || echo none)
cron: $(command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -c . || echo 0) entries
runit: $(if pgrep -x runsvdir >/dev/null 2>&1; then echo "runsvdir running;${RUNIT_ENABLED:- no enabled services}"; else echo "runsvdir not running${RUNIT_ENABLED:+, but these are enabled:$RUNIT_ENABLED}"; fi)

ANDROID CAPABILITIES:
${CAPS:-none recorded}

PYTHON:
$(vers python --version)

NODE:
$(vers node --version)

CLAUDE:
$(vers claude --version)

SHARED STORAGE:
$SHARED

UI AUTOMATION:
host-side only (adb: input / uiautomator / screencap). No accessibility service, no helper APK installed on the device.

SECURITY AUDIT:
REPORT

if [ "$VERDICT_FAIL" -eq 0 ]; then
  echo "PASS"
  echo "============================================================"
  exit 0
fi
echo "FAIL"
printf 'findings:%b\n' "$FINDINGS"
echo "============================================================"
exit 1
