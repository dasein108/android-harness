#!/data/data/com.termux/files/usr/bin/env bash
# android-harness :: install directly on the phone, from Termux, with no
# computer involved.
#
# Usage, inside Termux:
#   pkg install curl
#   curl -fsSL https://raw.githubusercontent.com/dasein108/android-harness/main/phone-install.sh -o install.sh
#   less install.sh      # read it first
#   bash install.sh
#
# Options:
#   --media          also install imagemagick, ffmpeg, poppler
#   --no-claude      skip Claude Code
#   --with-server    also configure the loopback SSH channel, for a computer
#                    to connect over USB later. Off by default: with no computer
#                    in the picture there is nothing to connect.
#   --dir PATH       where to keep the checkout (default ~/android-harness-src)

set -uo pipefail

# Print this file's own header comment as the usage text.
usage_from_header() { sed -n '2,/^[^#]/p' "$0" | sed -e 's/^# //' -e 's/^#$//'; }

REPO_URL="https://github.com/dasein108/android-harness.git"
TARBALL_URL="https://codeload.github.com/dasein108/android-harness/tar.gz"
SRC_DIR="$HOME/android-harness-src"
PROVISION_ARGS="--shortcuts --phone-only"

while [ $# -gt 0 ]; do
  case "$1" in
    --media)       PROVISION_ARGS="$PROVISION_ARGS --media"; shift ;;
    --no-claude)   PROVISION_ARGS="$PROVISION_ARGS --no-claude"; shift ;;
    --with-server) PROVISION_ARGS="${PROVISION_ARGS/--phone-only/}"; shift ;;
    --dir)         SRC_DIR="${2:?--dir needs a path}"; shift 2 ;;
    -h|--help)     usage_from_header; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
die()  { red "error: $*"; exit 1; }
step() { printf '\n'; bold "==> $*"; }

# ---------------------------------------------------------------------------
step "Checking we are in Termux on Android"

[ -n "${PREFIX:-}" ] || die "PREFIX is unset — run this inside Termux."
case "$PREFIX" in
  /data/data/com.termux/files/usr) ;;
  *) die "unexpected PREFIX=$PREFIX; this is not a normal Termux install." ;;
esac
dim "device : $(getprop ro.product.model 2>/dev/null) / Android $(getprop ro.build.version.release 2>/dev/null)"
dim "arch   : $(uname -m)"
dim "termux : ${TERMUX_VERSION:-unknown}"

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) red "architecture $(uname -m) is not aarch64 — Claude Code has no build for it."
     dim "Everything else will still work; add --no-claude to skip that step." ;;
esac

# ---------------------------------------------------------------------------
step "Termux:API app"

# The helper binaries come from a package; the bridge itself is a separate app
# that has to be installed by hand, from the same source as Termux.
if ! command -v termux-battery-status >/dev/null 2>&1; then
  dim "the termux-api package will be installed in a moment"
elif timeout 10 termux-battery-status >/dev/null 2>&1; then
  grn "Termux:API app responds"
else
  red "the termux-api package is installed but the Termux:API *app* is not responding."
  dim "Install it from the same source as Termux (F-Droid or GitHub releases):"
  dim "  https://f-droid.org/packages/com.termux.api/"
  dim "Continuing — the Android bridge will simply be unavailable until you do."
fi

# ---------------------------------------------------------------------------
step "Fetching the harness"

if ! command -v git >/dev/null 2>&1; then
  dim "installing git"
  pkg install -y git >/dev/null 2>&1 || die "could not install git"
fi

if [ -d "$SRC_DIR/.git" ]; then
  grn "updating $SRC_DIR"
  git -C "$SRC_DIR" pull --quiet --ff-only || \
    red "update failed; continuing with what is on disk"
elif [ -d "$SRC_DIR" ]; then
  grn "using $SRC_DIR"
else
  bold "cloning $REPO_URL"
  if ! git clone --quiet --depth 1 "$REPO_URL" "$SRC_DIR"; then
    # Fall back to a tarball, which needs no git and works on flaky links.
    dim "git clone failed; trying the tarball"
    mkdir -p "$SRC_DIR"
    curl -fL "$TARBALL_URL/main" -o "$HOME/.aa-src.tar.gz" || die "download failed"
    tar xzf "$HOME/.aa-src.tar.gz" -C "$SRC_DIR" --strip-components=1 || die "extract failed"
    rm -f "$HOME/.aa-src.tar.gz"
  fi
fi

[ -f "$SRC_DIR/device/install.sh" ] || die "$SRC_DIR does not look like the harness"
grn "source: $SRC_DIR"

# ---------------------------------------------------------------------------
step "Provisioning"

# shellcheck disable=SC2086
bash "$SRC_DIR/device/install.sh" $PROVISION_ARGS
rc=$?
[ $rc -eq 0 ] || die "provisioning reported failures — read the step log above"

# shellcheck disable=SC1090
. "$HOME/android-agent/config/environment"

# ---------------------------------------------------------------------------
step "Verifying"

"$HOME/android-agent/tests/e2e.sh" || red "some checks did not pass — see above"
echo
"$HOME/android-agent/security/audit.sh" || die "SECURITY AUDIT FAILED — do not use this install until it is explained"

# ---------------------------------------------------------------------------
step "Done"

cat <<'DONE'

  claude                     Claude Code, right here (first run: /login)
  android-agent-status       what this device can do
  android-permissions        grant camera / location / mic via Settings
  android-permissions setup  guided walk through the sensitive ones

  One-tap launcher: install Termux:Widget, then long-press your home screen ->
  Widgets -> Termux:Widget -> pick "claude".

  Open a NEW Termux session (or run: . ~/android-agent/config/environment)
  so the commands above are on your PATH.

DONE
grn "setup complete"
