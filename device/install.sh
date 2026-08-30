#!/data/data/com.termux/files/usr/bin/env bash
# android-harness :: device provisioner
#
# Idempotent. Safe to run repeatedly. Detects what already works, installs only
# what is missing, and validates every step functionally rather than by parsing
# prose. Exits non-zero if a required component cannot be made to work.
#
# It never touches Android shared storage contents, never opens a non-loopback
# listener, and never installs boot persistence.
#
# Usage:
#   install.sh [--media] [--shortcuts] [--no-claude] [--claude-version X.Y.Z]
#              [--no-packages]

set -uo pipefail

AA_ROOT="${AA_ROOT:-$HOME/android-agent}"
SRC_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

WITH_MEDIA=0
DO_CLAUDE=1
DO_PACKAGES=1
DO_SHORTCUTS=0
CLAUDE_VERSION="${AA_CLAUDE_VERSION:-latest}"

while [ $# -gt 0 ]; do
  case "$1" in
    --media) WITH_MEDIA=1; shift ;;
    --shortcuts) DO_SHORTCUTS=1; shift ;;
    --no-claude) DO_CLAUDE=0; shift ;;
    --no-packages) DO_PACKAGES=0; shift ;;
    --claude-version) CLAUDE_VERSION="${2:?--claude-version needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
STEP=0
FAILED=""
WARNED=""

say()  { printf '%s\n' "$*"; }
step() { STEP=$((STEP+1)); printf '\n[%02d] %s\n' "$STEP" "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
warn() { printf '   WARN  %s\n' "$*"; WARNED="$WARNED\n  - $*"; }
bad()  { printf '   FAIL  %s\n' "$*"; FAILED="$FAILED\n  - $*"; }
die()  { printf '\nfatal: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
step "Preflight: verify we are actually inside Termux on Android"
# ---------------------------------------------------------------------------
[ -n "${PREFIX:-}" ] || die "PREFIX is unset; this script must run inside Termux."
case "$PREFIX" in
  /data/data/com.termux/files/usr) ;;
  *) die "unexpected PREFIX=$PREFIX; expected the Termux prefix." ;;
esac
[ -d "$HOME" ] || die "HOME=$HOME does not exist."

ARCH="$(uname -m)"
say "   uname   : $(uname -a)"
say "   arch    : $ARCH"
say "   id      : $(id)"
say "   home    : $HOME"
say "   prefix  : $PREFIX"
say "   PATH    : $PATH"
case "$ARCH" in
  aarch64|arm64) ok "64-bit ARM device" ;;
  *) warn "architecture '$ARCH' is not aarch64; Claude Code's Linux ARM64 path will not apply." ;;
esac

# ---------------------------------------------------------------------------
step "Agent directory tree"
# ---------------------------------------------------------------------------
for d in bin lib scripts config logs workspace tools python python/venvs node tmp output tests security; do
  mkdir -p "$AA_ROOT/$d"
done
chmod 700 "$AA_ROOT" "$AA_ROOT/config" "$AA_ROOT/logs"
ok "$AA_ROOT (mode $(stat -c %a "$AA_ROOT" 2>/dev/null || echo '?'))"

# ---------------------------------------------------------------------------
step "Termux packages"
# ---------------------------------------------------------------------------
CORE_PKGS="openssh git curl wget jq python termux-api ripgrep procps iproute2 file tar unzip openssl termux-exec"
MEDIA_PKGS="imagemagick ffmpeg poppler"

# Node is deliberately conditional. A working Node is never replaced: swapping
# `nodejs` for `nodejs-lts` (or the reverse) can uninstall the other and break
# whatever was installed globally against it, Claude Code included.
if node -e 'process.exit(0)' >/dev/null 2>&1; then
  say "   node already present ($(node --version 2>/dev/null)) — leaving it alone"
else
  CORE_PKGS="$CORE_PKGS nodejs-lts"
fi

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

if [ "$DO_PACKAGES" -eq 1 ]; then
  MISSING=""
  for p in $CORE_PKGS; do pkg_installed "$p" || MISSING="$MISSING $p"; done
  if [ "$WITH_MEDIA" -eq 1 ]; then
    for p in $MEDIA_PKGS; do pkg_installed "$p" || MISSING="$MISSING $p"; done
  fi

  if [ -n "${MISSING# }" ]; then
    say "   installing:${MISSING}"
    # Package sources are the Termux project's own repositories, already
    # configured and signed-by-default in $PREFIX/etc/apt. We add none.
    pkg update -y >>"$AA_ROOT/logs/install.log" 2>&1 || warn "pkg update reported errors (see logs/install.log)"
    # shellcheck disable=SC2086
    if pkg install -y $MISSING >>"$AA_ROOT/logs/install.log" 2>&1; then
      ok "packages installed"
    else
      warn "some packages failed to install; per-component checks below decide severity"
    fi
  else
    ok "all required packages already present"
  fi
else
  ok "package step skipped (--no-packages)"
fi

for p in git curl python node npm ssh sshd rg jq; do
  if have "$p"; then ok "$p -> $(command -v "$p")"; else bad "$p not on PATH"; fi
done

# ---------------------------------------------------------------------------
step "Android shared storage"
# ---------------------------------------------------------------------------
if [ ! -d "$HOME/storage" ]; then
  say "   requesting storage access (approve the Android dialog on the device)"
  termux-setup-storage || warn "termux-setup-storage returned an error"
  sleep 6
fi
if [ -d "$HOME/storage/shared" ]; then
  probe="$HOME/storage/shared/.android-agent-probe"
  if echo probe > "$probe" 2>/dev/null && [ "$(cat "$probe" 2>/dev/null)" = probe ]; then
    rm -f "$probe"
    ok "shared storage readable+writable at \$HOME/storage/shared"
    for sub in DCIM Pictures Download Documents Movies Music; do
      [ -d "$HOME/storage/shared/$sub" ] && say "   present: ~/storage/shared/$sub"
    done
  else
    rm -f "$probe" 2>/dev/null
    warn "\$HOME/storage/shared exists but is not writable"
  fi
else
  warn "no \$HOME/storage — storage permission was not granted; shared-storage capability stays off"
fi

# ---------------------------------------------------------------------------
step "Install agent commands"
# ---------------------------------------------------------------------------
install -m 700 -d "$AA_ROOT/bin" "$AA_ROOT/lib"
cp "$SRC_DIR/lib/aa-common.sh" "$AA_ROOT/lib/aa-common.sh"
chmod 600 "$AA_ROOT/lib/aa-common.sh"
n=0
for f in "$SRC_DIR"/bin/*; do
  [ -f "$f" ] || continue
  cp "$f" "$AA_ROOT/bin/$(basename "$f")"
  chmod 700 "$AA_ROOT/bin/$(basename "$f")"
  n=$((n+1))
done
ok "$n commands installed into $AA_ROOT/bin"

for extra in tests security; do
  if [ -d "$SRC_DIR/$extra" ]; then
    cp "$SRC_DIR/$extra"/* "$AA_ROOT/$extra/" 2>/dev/null
    chmod 700 "$AA_ROOT/$extra"/* 2>/dev/null
  fi
done
[ -f "$SRC_DIR/CLAUDE.md" ] && cp "$SRC_DIR/CLAUDE.md" "$AA_ROOT/CLAUDE.md"

# ---------------------------------------------------------------------------
step "Environment file and shell integration"
# ---------------------------------------------------------------------------
ENV_FILE="$AA_ROOT/config/environment"
cat > "$ENV_FILE" <<ENVEOF
# android-harness environment. Sourced by ~/.bashrc via a marked block.
# Generated by install.sh — edit config/environment.local for local overrides.
export AA_ROOT="$AA_ROOT"
# Order matters: the agent's own bin must win over the npm global prefix, so a
# wrapper here (the Claude Code launcher, for instance) shadows an npm shim of
# the same name without uninstalling anything.
# The guard keeps a re-sourced file from stacking duplicate PATH entries.
case ":\$PATH:" in
  *":\$AA_ROOT/bin:"*) ;;
  *) export PATH="\$AA_ROOT/bin:\$AA_ROOT/node/bin:\$PATH" ;;
esac

# Claude Code on Termux: the bundled ripgrep is a glibc binary and will not run
# under bionic. Use the Termux-native one from \`pkg install ripgrep\`.
export USE_BUILTIN_RIPGREP=0

# Keep agent scratch inside the agent tree rather than the shared \$TMPDIR.
export AA_TMPDIR="\$AA_ROOT/tmp"

[ -f "\$AA_ROOT/config/environment.local" ] && . "\$AA_ROOT/config/environment.local"
ENVEOF
chmod 600 "$ENV_FILE"
ok "wrote $ENV_FILE"

BASHRC="$HOME/.bashrc"
touch "$BASHRC"
if ! grep -q '# >>> android-harness >>>' "$BASHRC"; then
  {
    echo ''
    echo '# >>> android-harness >>>'
    echo "[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
    echo '# <<< android-harness <<<'
  } >> "$BASHRC"
  ok "added sourcing block to ~/.bashrc"
else
  ok "~/.bashrc already sources the agent environment"
fi

# Make the rest of this run see the agent bin dir too.
# shellcheck disable=SC1090
. "$ENV_FILE"

# ---------------------------------------------------------------------------
step "Python environment"
# ---------------------------------------------------------------------------
if have python; then
  PYV="$(python --version 2>&1)"
  if python -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)'; then
    ok "$PYV"
  else
    warn "$PYV is older than 3.9"
  fi
  python -m pip --version >/dev/null 2>&1 && ok "pip: $(python -m pip --version 2>&1 | cut -d' ' -f1-2)" || bad "pip not usable"
  if python -m venv --help >/dev/null 2>&1; then
    DEFAULT_VENV="$AA_ROOT/python/venvs/default"
    if [ ! -x "$DEFAULT_VENV/bin/python" ]; then
      say "   creating default venv at $DEFAULT_VENV"
      python -m venv "$DEFAULT_VENV" >>"$AA_ROOT/logs/install.log" 2>&1 \
        || warn "venv creation failed (see logs/install.log)"
    fi
    if "$DEFAULT_VENV/bin/python" -c 'print("venv-ok")' >/dev/null 2>&1; then
      ok "default venv works: $DEFAULT_VENV"
    else
      warn "default venv is not functional"
    fi
  else
    bad "python venv module unavailable"
  fi
else
  bad "python missing"
fi

# ---------------------------------------------------------------------------
step "Node.js environment"
# ---------------------------------------------------------------------------
if have node; then
  NODEV="$(node --version 2>/dev/null)"
  ok "node $NODEV  ($(command -v node))"
  say "   process.platform=$(node -p 'process.platform' 2>/dev/null) process.arch=$(node -p 'process.arch' 2>/dev/null)"
  MAJOR="${NODEV#v}"; MAJOR="${MAJOR%%.*}"
  case "$MAJOR" in
    ''|*[!0-9]*) warn "could not parse node major version from '$NODEV'" ;;
    *) [ "$MAJOR" -ge 18 ] && ok "node major $MAJOR is new enough for Claude Code" \
                           || warn "node $NODEV is older than 18; Claude Code needs >= 18" ;;
  esac
  have npm && ok "npm $(npm --version 2>/dev/null)" || bad "npm missing"
  # Keep global npm installs inside the agent tree; never write outside it.
  npm config set prefix "$AA_ROOT/node" >/dev/null 2>&1 \
    && ok "npm global prefix -> $AA_ROOT/node" \
    || warn "could not set npm prefix"
  # config/environment already puts $AA_ROOT/bin ahead of $AA_ROOT/node/bin;
  # mirror that order for the rest of this run.
  export PATH="$AA_ROOT/bin:$AA_ROOT/node/bin:$PATH"
else
  bad "node missing"
fi

# ---------------------------------------------------------------------------
step "Claude Code"
# ---------------------------------------------------------------------------
claude_works() { command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; }

if [ "$DO_CLAUDE" -eq 0 ]; then
  ok "skipped (--no-claude)"
elif ! have node; then
  bad "cannot install Claude Code without node"
elif claude_works; then
  ok "claude already functional: $(claude --version 2>&1 | head -1)"
else
  SPEC="@anthropic-ai/claude-code"
  [ "$CLAUDE_VERSION" = latest ] || SPEC="$SPEC@$CLAUDE_VERSION"
  say "   installing $SPEC (source: npm registry, official Anthropic package)"
  if npm install -g "$SPEC" >>"$AA_ROOT/logs/install.log" 2>&1; then
    ok "npm install completed"
  else
    warn "npm install reported errors (see logs/install.log)"
  fi

  if claude_works; then
    ok "claude functional: $(claude --version 2>&1 | head -1)"
  else
    # Diagnose rather than guess.
    #
    # What actually happens on Termux: node reports process.platform ===
    # 'android', so npm matches none of the package's per-platform optional
    # dependencies (darwin/linux/win32 only). The wrapper's bin/claude.exe stays
    # a stub that prints "native binary not installed", and there is no bundled
    # JS entry point to fall back to.
    #
    # Fix: fetch the Linux ARM64 native build explicitly and run it through
    # glibc-runner, which supplies the glibc loader bionic does not have.
    CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
    [ -n "$CLAUDE_BIN" ] && say "   claude resolves to: $(readlink -f "$CLAUDE_BIN")"
    say "   reason: $(claude --version 2>&1 | head -1)"

    WRAPPER_PKG="$(npm root -g 2>/dev/null)/@anthropic-ai/claude-code/package.json"
    NATIVE_VERSION=""
    [ -f "$WRAPPER_PKG" ] && NATIVE_VERSION="$(jq -r .version "$WRAPPER_PKG" 2>/dev/null)"
    [ -n "$NATIVE_VERSION" ] && [ "$NATIVE_VERSION" != null ] || NATIVE_VERSION="$CLAUDE_VERSION"

    case "$ARCH" in
      aarch64|arm64) NATIVE_PKG="@anthropic-ai/claude-code-linux-arm64" ;;
      x86_64)        NATIVE_PKG="@anthropic-ai/claude-code-linux-x64" ;;
      *)             NATIVE_PKG="" ;;
    esac

    if [ -z "$NATIVE_PKG" ]; then
      bad "no native Claude Code build for architecture '$ARCH'"
    else
      TOOLDIR="$AA_ROOT/tools/claude-code"
      mkdir -p "$TOOLDIR"
      SPEC_NATIVE="$NATIVE_PKG"
      [ "$NATIVE_VERSION" = latest ] || SPEC_NATIVE="$NATIVE_PKG@$NATIVE_VERSION"
      say "   fetching native build $SPEC_NATIVE from the npm registry (~200 MB)"

      if ( cd "$AA_TMPDIR" 2>/dev/null || cd "$AA_ROOT/tmp"; \
           rm -f ./*.tgz; \
           npm pack "$SPEC_NATIVE" >/dev/null 2>>"$AA_ROOT/logs/install.log" && \
           tar xzf ./*.tgz -C "$TOOLDIR" --strip-components=1 package/claude ) \
         >>"$AA_ROOT/logs/install.log" 2>&1 && [ -s "$TOOLDIR/claude" ]; then
        chmod 700 "$TOOLDIR/claude"
        rm -f "$AA_ROOT/tmp"/*.tgz
        ok "native binary: $(file -b "$TOOLDIR/claude" 2>/dev/null | cut -c1-60)"

        # glibc-runner lives in the glibc repo, which is itself a package.
        if ! have grun; then
          say "   installing glibc-runner (source: Termux glibc-repo)"
          pkg install -y glibc-repo >>"$AA_ROOT/logs/install.log" 2>&1
          pkg install -y glibc-runner >>"$AA_ROOT/logs/install.log" 2>&1
        fi

        if have grun; then
          cat > "$AA_ROOT/bin/claude" <<WRAP
#!/data/data/com.termux/files/usr/bin/env bash
# Claude Code launcher for Termux.
#
# Termux node reports process.platform === "android", so npm installs none of
# the package's per-platform native builds and bin/claude.exe stays a stub. The
# Linux ARM64 build is fetched separately and run through glibc-runner, which
# provides the glibc loader that bionic lacks.
exec grun "$TOOLDIR/claude" "\$@"
WRAP
          chmod 700 "$AA_ROOT/bin/claude"
          hash -r
          if "$AA_ROOT/bin/claude" --version >/dev/null 2>&1; then
            ok "claude works through glibc-runner: $("$AA_ROOT/bin/claude" --version 2>&1 | head -1)"
          else
            bad "glibc-runner wrapper still cannot run claude (see logs/install.log)"
          fi
        else
          bad "glibc-runner unavailable; Claude Code cannot run on this device yet"
        fi
      else
        bad "could not fetch $SPEC_NATIVE (see logs/install.log)"
      fi
    fi
  fi
fi

# Whatever else called itself `claude` on this device now points at the working
# launcher. Without this, a shell that has not sourced the agent environment —
# a Termux session opened before provisioning, say — still finds the npm stub
# earlier on PATH and prints "native binary not installed".
if [ "$DO_CLAUDE" -eq 1 ] && [ -x "$AA_ROOT/bin/claude" ] && "$AA_ROOT/bin/claude" --version >/dev/null 2>&1; then
  for stub in "$PREFIX/bin/claude" "$AA_ROOT/node/bin/claude"; do
    [ -e "$stub" ] || continue
    [ "$(readlink -f "$stub")" = "$(readlink -f "$AA_ROOT/bin/claude")" ] && continue
    # Only replace the known-broken wrapper stub, never a working binary.
    case "$(readlink -f "$stub")" in
      */@anthropic-ai/claude-code/bin/claude.exe)
        ln -sf "$AA_ROOT/bin/claude" "$stub" && ok "repointed stub $stub -> $AA_ROOT/bin/claude" ;;
      *) say "   left $stub alone (not the npm stub)" ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
step "Android bridge (Termux:API)"
# ---------------------------------------------------------------------------
if have termux-battery-status; then
  ok "termux-api helper binaries installed"
  if timeout 10 termux-battery-status >/dev/null 2>&1; then
    ok "Termux:API app responds"
  else
    warn "helpers present but the Termux:API app did not respond; install it and disable battery optimisation for it"
  fi
else
  warn "termux-api package not installed; Android bridge stays off"
fi

# ---------------------------------------------------------------------------
step "SSH control channel"
# ---------------------------------------------------------------------------
SSHD_CONF="$PREFIX/etc/ssh/sshd_config"
if [ -f "$SSHD_CONF" ]; then
  [ -f "$SSHD_CONF.aa-orig" ] || cp "$SSHD_CONF" "$SSHD_CONF.aa-orig"
  sed -i '/# >>> android-harness >>>/,/# <<< android-harness <<</d' "$SSHD_CONF"
  cat >> "$SSHD_CONF" <<'CONF'
# >>> android-harness >>>
# Owner-controlled agent channel. Loopback only: reachable from the Mac solely
# through `adb forward` over USB. Never bind 0.0.0.0 here.
ListenAddress 127.0.0.1
Port 8022
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
# <<< android-harness <<<
CONF
  ok "sshd_config pinned to 127.0.0.1:8022, pubkey-only"
  if [ -s "$HOME/.ssh/authorized_keys" ]; then
    chmod 700 "$HOME/.ssh"; chmod 600 "$HOME/.ssh/authorized_keys"
    ok "authorized_keys present ($(wc -l < "$HOME/.ssh/authorized_keys") key(s))"
  else
    warn "no authorized_keys — the Mac cannot connect until a public key is installed"
  fi
  "$AA_ROOT/bin/android-agent-server" restart >/dev/null 2>&1 \
    && ok "sshd restarted on 127.0.0.1:8022" \
    || warn "could not restart sshd (run: android-agent-server start)"
else
  bad "openssh is not installed; no control channel"
fi

# ---------------------------------------------------------------------------
step "Termux:Widget shortcuts"
# ---------------------------------------------------------------------------
# These are launcher entries, not persistence: Termux:Widget runs a script only
# when the owner taps it. Nothing here starts on boot. Opt-in via --shortcuts.
SHORTCUTS="$HOME/.shortcuts"
if [ "$DO_SHORTCUTS" -eq 1 ]; then
  mkdir -p "$SHORTCUTS"
  chmod 700 "$SHORTCUTS"

  write_shortcut() { # write_shortcut <name> <body>
    cat > "$SHORTCUTS/$1" <<SC
#!/data/data/com.termux/files/usr/bin/env bash
# android-harness shortcut — remove with uninstall.sh
. "$ENV_FILE"
$2
SC
    chmod 700 "$SHORTCUTS/$1"
  }

  write_shortcut "claude" 'cd "$AA_ROOT/workspace" && exec claude "$@"'
  write_shortcut "agent-status" 'android-agent-status; printf "\n[enter to close] "; read -r _'
  write_shortcut "agent-server-start" 'android-agent-server start; printf "\n[enter to close] "; read -r _'
  write_shortcut "agent-test" '"$AA_ROOT/tests/e2e.sh"; printf "\n[enter to close] "; read -r _'

  ok "shortcuts in $SHORTCUTS: $(ls "$SHORTCUTS" | tr '\n' ' ')"
  say "   add them to the home screen with the Termux:Widget widget"
elif [ -d "$SHORTCUTS" ]; then
  ok "shortcuts left alone (pass --shortcuts to (re)write them)"
else
  ok "no shortcuts (pass --shortcuts to create them)"
fi

# ---------------------------------------------------------------------------
step "Capability manifest"
# ---------------------------------------------------------------------------
if "$AA_ROOT/bin/android-agent-manifest" --refresh > "$AA_ROOT/logs/manifest-refresh.log" 2>&1; then
  ok "manifest written to $AA_ROOT/config/manifest.json"
  grep -A99 '"capabilities"' "$AA_ROOT/config/manifest.json" | sed 's/^/   /' | head -30
else
  warn "manifest refresh failed (see logs/manifest-refresh.log)"
fi

# ---------------------------------------------------------------------------
step "Summary"
# ---------------------------------------------------------------------------
if [ -n "$FAILED" ]; then
  printf '\nFAILURES:%b\n' "$FAILED"
fi
if [ -n "$WARNED" ]; then
  printf '\nWARNINGS:%b\n' "$WARNED"
fi

if [ -n "$FAILED" ]; then
  printf '\nINSTALL_RESULT=FAIL\n'
  exit 1
fi
printf '\nINSTALL_RESULT=OK\n'
printf 'Next: android-agent-status ; %s/tests/e2e.sh ; %s/security/audit.sh\n' "$AA_ROOT" "$AA_ROOT"
