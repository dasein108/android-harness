#!/usr/bin/env bash
# android-harness :: one-shot setup, run on the Mac (or any Linux host with adb).
#
# Takes a phone with Termux installed and leaves it with a verified agent
# environment: Python, Node, Claude Code, the Android bridge, a loopback-only
# SSH channel over USB, and a security audit that has to pass.
#
# Usage:
#   ./install.sh                       everything, default permission profile
#   ./install.sh --profile minimal     no camera or location
#   ./install.sh --media               also imagemagick, ffmpeg, poppler
#   ./install.sh --dir ~/code/android-harness
#   ./install.sh --no-claude           skip the Claude Code step
#   ./install.sh --yes                 do not stop to ask anything
#
# Safe to re-run: every step detects what is already in place.

set -uo pipefail

# Print this file's own header comment as the usage text, so it can never
# drift out of sync with a hard-coded line range.
usage_from_header() { sed -n '2,/^[^#]/p' "$0" | sed -e 's/^# //' -e 's/^#$//'; }

REPO_URL="https://github.com/dasein108/android-harness.git"
TARGET_DIR="${AA_DIR:-$HOME/android-harness}"
BRANCH="main"
PROFILE="default"
PROVISION_ARGS="--shortcuts"
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a name}"; shift 2 ;;
    --dir)     TARGET_DIR="${2:?--dir needs a path}"; shift 2 ;;
    --branch)  BRANCH="${2:?--branch needs a name}"; shift 2 ;;
    --media)   PROVISION_ARGS="$PROVISION_ARGS --media"; shift ;;
    --no-claude) PROVISION_ARGS="$PROVISION_ARGS --no-claude"; shift ;;
    --no-shortcuts) PROVISION_ARGS="${PROVISION_ARGS/--shortcuts/}"; shift ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) usage_from_header; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
die()  { red "error: $*"; exit 1; }

step() { printf '\n'; bold "==> $*"; }

ask() { # ask <prompt> ; 0 = yes
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf '%s [Y/n] ' "$1"
  local a; read -r a </dev/tty || return 1
  case "$a" in ""|y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
step "Host prerequisites"

case "$(uname -s)" in
  Darwin|Linux) dim "host: $(uname -s) $(uname -m)" ;;
  *) die "unsupported host OS: $(uname -s). This runs on macOS or Linux." ;;
esac

command -v git >/dev/null 2>&1 || die "git is required"
command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (used to decode /proc/net during the audit)"

if ! command -v adb >/dev/null 2>&1; then
  red "adb (Android platform-tools) is not installed."
  if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
    if ask "install it now with: brew install --cask android-platform-tools ?"; then
      brew install --cask android-platform-tools || die "brew install failed"
    else
      die "adb is required"
    fi
  else
    die "install Android platform-tools and re-run (apt install adb, or https://developer.android.com/tools/releases/platform-tools)"
  fi
fi
grn "adb: $(adb version | head -1)"

# ---------------------------------------------------------------------------
step "Repository"

# When this script is already inside a checkout, use it. When it was piped in
# from a URL, clone first.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -n "$SELF_DIR" ] && [ -x "$SELF_DIR/mac/aa" ]; then
  TARGET_DIR="$SELF_DIR"
  grn "using this checkout: $TARGET_DIR"
elif [ -x "$TARGET_DIR/mac/aa" ]; then
  grn "existing checkout: $TARGET_DIR"
  if [ -d "$TARGET_DIR/.git" ] && ask "pull the latest changes?"; then
    git -C "$TARGET_DIR" pull --ff-only || red "pull failed; continuing with what is on disk"
  fi
else
  bold "cloning $REPO_URL -> $TARGET_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR" || die "clone failed"
fi

AA="$TARGET_DIR/mac/aa"
[ -x "$AA" ] || die "$AA is missing or not executable"

# ---------------------------------------------------------------------------
step "Device"

n="$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
if [ "$n" != 1 ]; then
  red "expected exactly one authorised device over USB, found $n."
  dim "  - plug the phone in with a data-capable cable"
  dim "  - enable Developer options, then USB debugging"
  dim "  - approve the 'Allow USB debugging?' prompt on the phone"
  adb devices -l
  die "no single device"
fi
grn "device: $(adb devices -l | awk 'NR==2{print $1}') $(adb shell getprop ro.product.model | tr -d '\r'), Android $(adb shell getprop ro.build.version.release | tr -d '\r')"

for pkg in com.termux com.termux.api; do
  if adb shell pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:$pkg"; then
    grn "$pkg installed"
  else
    red "$pkg is NOT installed on the phone."
    dim "  Install both Termux and Termux:API from F-Droid or the GitHub releases."
    dim "  They must come from the same source or Android will reject the second one."
    dim "  https://f-droid.org/packages/com.termux/"
    dim "  https://f-droid.org/packages/com.termux.api/"
    die "missing $pkg"
  fi
done

# ---------------------------------------------------------------------------
step "Control key"

KEY="$TARGET_DIR/keys/android_agent_ed25519"
mkdir -p "$TARGET_DIR/keys"; chmod 700 "$TARGET_DIR/keys"
if [ -f "$KEY" ]; then
  grn "reusing $KEY"
else
  ssh-keygen -t ed25519 -N '' -C "android-agent@$(hostname -s)" -f "$KEY" >/dev/null || die "ssh-keygen failed"
  grn "generated $KEY"
fi
chmod 600 "$KEY"; chmod 644 "$KEY.pub"
dim "fingerprint: $(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')"

# ---------------------------------------------------------------------------
step "Screen"

if [ "$(adb shell dumpsys window 2>/dev/null | grep -m1 isKeyguardShowing | tr -d '\r ' | cut -d= -f2)" = "true" ]; then
  red "the phone is locked."
  dim "The next step types one command into the Termux app, and a keyguard blocks that."
  printf 'unlock the phone, then press Enter: '
  read -r _ </dev/tty || true
fi
adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

# ---------------------------------------------------------------------------
step "Bootstrap: loopback SSH channel over USB"

if "$AA" shell 'echo ok' 2>/dev/null | grep -q ok; then
  grn "channel already up"
else
  "$AA" bootstrap || die "bootstrap failed — see the message above"
fi

# ---------------------------------------------------------------------------
step "Provision the device"

# shellcheck disable=SC2086
"$AA" provision $PROVISION_ARGS || die "provisioning reported failures — read the step log above"

# ---------------------------------------------------------------------------
step "Permissions (profile: $PROFILE)"

"$AA" permissions --profile "$PROFILE" || die "could not apply the permission profile"
echo
"$AA" permissions show

# ---------------------------------------------------------------------------
step "Verify"

"$AA" ui launch com.termux >/dev/null 2>&1   # camera needs Termux in the foreground
"$AA" test --full || red "some tests did not pass — see above"
echo
"$AA" audit || die "SECURITY AUDIT FAILED — do not use this install until it is explained"

# ---------------------------------------------------------------------------
step "Done"

cat <<DONE

  $ $AA claude          run Claude Code on the phone (first run: /login)
  $ $AA shell           a shell on the phone
  $ $AA ui screenshot   capture the screen
  $ $AA permissions     review or change what the agent may do
  $ $AA help            everything else

  On the phone: open Termux and type 'claude', or tap the Termux:Widget
  shortcut. Home screen -> long press -> Widgets -> Termux:Widget -> claude.

DONE

if ! command -v aa >/dev/null 2>&1; then
  for d in "$HOME/.local/bin" /usr/local/bin; do
    [ -d "$d" ] || continue
    case ":$PATH:" in *":$d:"*) ;; *) continue ;; esac
    if ask "link 'aa' into $d so you can run it from anywhere?"; then
      ln -sf "$AA" "$d/aa" && grn "linked $d/aa -> $AA"
    fi
    break
  done
fi

grn "setup complete"
