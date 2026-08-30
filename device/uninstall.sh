#!/data/data/com.termux/files/usr/bin/env bash
# android-harness :: reset / recovery
#
#   --soft              remove generated config, logs, tmp, shell + sshd blocks.
#                       Keeps commands, venvs, workspace.
#   --full              --soft plus the agent's own binaries, tools, node prefix
#                       and venvs. Keeps the workspace.
#   --purge-workspace   additionally delete $AA_ROOT/workspace. Explicit only.
#
# What this NEVER touches: Android shared storage, photos, documents, anything
# under $HOME outside $AA_ROOT (apart from the two marked blocks it wrote), and
# Termux packages other people may depend on.

set -uo pipefail

# Print this file's own header comment as the usage text, so it can never
# drift out of sync with a hard-coded line range.
usage_from_header() { sed -n '2,/^[^#]/p' "$0" | sed -e 's/^# //' -e 's/^#$//'; }

AA_ROOT="${AA_ROOT:-$HOME/android-agent}"
MODE=""
PURGE_WS=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --soft) MODE=soft; shift ;;
    --full) MODE=full; shift ;;
    --purge-workspace) PURGE_WS=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage_from_header; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "choose --soft or --full (see --help)" >&2; exit 2; }

say() { printf '%s\n' "$*"; }

# Guard rail: refuse to operate on anything that is not clearly our own tree.
case "$AA_ROOT" in
  "$HOME"/*) ;;
  *) echo "refusing: AA_ROOT='$AA_ROOT' is outside \$HOME" >&2; exit 1 ;;
esac
[ "$AA_ROOT" != "$HOME" ] || { echo "refusing: AA_ROOT must not be \$HOME" >&2; exit 1; }

say "android-harness reset"
say "  mode        : $MODE"
say "  agent root  : $AA_ROOT"
say "  workspace   : $([ "$PURGE_WS" -eq 1 ] && echo 'WILL BE DELETED' || echo 'preserved')"
say "  shared storage, photos, documents: never touched"
say ""

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Proceed? [y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) say "aborted"; exit 0 ;; esac
fi

# --- stop the control channel ---------------------------------------------
if pgrep -x sshd >/dev/null 2>&1; then
  pkill -x sshd && say "stopped sshd"
fi

# --- sshd config block ------------------------------------------------------
SSHD_CONF="$PREFIX/etc/ssh/sshd_config"
if [ -f "$SSHD_CONF" ] && grep -q '# >>> android-harness >>>' "$SSHD_CONF"; then
  sed -i '/# >>> android-harness >>>/,/# <<< android-harness <<</d' "$SSHD_CONF"
  say "removed sshd_config block (original saved at $SSHD_CONF.aa-orig)"
fi

# --- shell integration ------------------------------------------------------
if [ -f "$HOME/.bashrc" ] && grep -q '# >>> android-harness >>>' "$HOME/.bashrc"; then
  sed -i '/# >>> android-harness >>>/,/# <<< android-harness <<</d' "$HOME/.bashrc"
  say "removed ~/.bashrc block"
fi

# --- Termux:Widget shortcuts (only the ones we wrote) -----------------------
SHORTCUTS="$HOME/.shortcuts"
if [ -d "$SHORTCUTS" ]; then
  for f in "$SHORTCUTS"/*; do
    [ -f "$f" ] || continue
    grep -q '# android-harness shortcut' "$f" 2>/dev/null || continue
    rm -f "$f" && say "removed shortcut $(basename "$f")"
  done
  rmdir "$SHORTCUTS" 2>/dev/null && say "removed empty ~/.shortcuts"
fi

# --- soft state -------------------------------------------------------------
for d in config logs tmp output; do
  [ -d "$AA_ROOT/$d" ] && rm -rf "${AA_ROOT:?}/$d" && say "removed $d/"
done

if [ "$MODE" = full ]; then
  for d in bin lib scripts tools node python tests security; do
    [ -d "$AA_ROOT/$d" ] && rm -rf "${AA_ROOT:?}/$d" && say "removed $d/"
  done
  [ -f "$AA_ROOT/CLAUDE.md" ] && rm -f "$AA_ROOT/CLAUDE.md" && say "removed CLAUDE.md"
  # npm's global prefix pointed into the agent tree; put it back to the default.
  command -v npm >/dev/null 2>&1 && npm config delete prefix >/dev/null 2>&1 \
    && say "reset npm global prefix"
fi

if [ "$PURGE_WS" -eq 1 ] && [ -d "$AA_ROOT/workspace" ]; then
  rm -rf "${AA_ROOT:?}/workspace" && say "removed workspace/ (explicitly requested)"
fi

# Remove the root only when nothing of value is left in it.
if [ -d "$AA_ROOT" ] && [ -z "$(ls -A "$AA_ROOT" 2>/dev/null)" ]; then
  rmdir "$AA_ROOT" && say "removed empty $AA_ROOT"
fi

say ""
say "Authorized SSH keys in ~/.ssh/authorized_keys were left in place."
say "Remove the harness key by hand if you want the Mac locked out:"
say "  \$EDITOR ~/.ssh/authorized_keys"
say "RESET_RESULT=OK"
