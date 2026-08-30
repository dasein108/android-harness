#!/data/data/com.termux/files/usr/bin/bash
# android-harness bootstrap (runs once, inside Termux)
#
# Purpose: establish an owner-controlled, localhost-only SSH channel so the Mac
# can drive provisioning over `adb forward` (USB). Nothing here listens on a
# public interface and nothing calls out to a remote control server.
set -u

LOG=/sdcard/Download/aa-bootstrap.log
PUB_SRC=/sdcard/Download/aa-authorized_key.pub
exec > >(tee "$LOG") 2>&1

echo "== android-harness bootstrap $(date) =="
echo "uname: $(uname -a)"
echo "id: $(id)"
echo "PREFIX=${PREFIX:-unset} HOME=$HOME"

fail() { echo "BOOTSTRAP_FAIL: $*"; echo "BOOTSTRAP_RESULT=FAIL"; exit 1; }

[ -f "$PUB_SRC" ] || fail "public key not found at $PUB_SRC"

# --- storage permission (idempotent; prompts once on first run) -------------
if [ ! -d "$HOME/storage" ]; then
  echo "-- requesting Termux storage access (approve the Android dialog)"
  termux-setup-storage
  sleep 6
fi

# --- packages ---------------------------------------------------------------
if ! command -v sshd >/dev/null 2>&1; then
  echo "-- installing openssh"
  pkg install -y openssh || fail "pkg install openssh failed"
fi
command -v sshd >/dev/null 2>&1 || fail "sshd still missing after install"

# --- authorized key ---------------------------------------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
KEY="$(cat "$PUB_SRC")"
touch "$HOME/.ssh/authorized_keys"
grep -qxF "$KEY" "$HOME/.ssh/authorized_keys" || echo "$KEY" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

# --- sshd config: localhost-only, pubkey-only -------------------------------
SSHD_CONF="$PREFIX/etc/ssh/sshd_config"
[ -f "$SSHD_CONF" ] || fail "missing $SSHD_CONF"
[ -f "$SSHD_CONF.aa-orig" ] || cp "$SSHD_CONF" "$SSHD_CONF.aa-orig"

# Drop any previous block we manage, then re-append. Idempotent by construction.
sed -i '/# >>> android-harness >>>/,/# <<< android-harness <<</d' "$SSHD_CONF"
cat >> "$SSHD_CONF" <<'CONF'
# >>> android-harness >>>
# Owner-controlled agent channel. Reachable only from the device itself,
# i.e. via `adb forward` over USB. Never bind 0.0.0.0 here.
ListenAddress 127.0.0.1
Port 8022
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
# <<< android-harness <<<
CONF

# --- restart sshd -----------------------------------------------------------
pkill -x sshd 2>/dev/null
sleep 1
sshd || fail "sshd failed to start"
sleep 2
pgrep -x sshd >/dev/null || fail "sshd not running after start"

echo "-- listeners --"
if command -v ss >/dev/null 2>&1; then
  ss -lntp 2>/dev/null
else
  netstat -lnt 2>/dev/null | head -20
fi

# Facts the Mac side needs in order to connect. The Termux login name is the
# synthesized Android app user (u0_aNNN), which the Mac cannot discover from adb.
echo "AA_USER=$(id -un)"
echo "AA_HOME=$HOME"
echo "AA_PREFIX=$PREFIX"
echo "BOOTSTRAP_RESULT=OK"
