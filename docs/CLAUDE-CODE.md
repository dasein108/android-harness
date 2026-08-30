# Claude Code on Termux

Termux is not a Linux distribution. It runs on **bionic**, Android's libc, with
no `/lib64/ld-linux-aarch64.so.1`, no `/usr`, and a prefix of
`/data/data/com.termux/files/usr`. A binary built for glibc Linux ARM64 will not
load, and the error it produces is unhelpful.

So the rule for this component is: **verify, never assume**.

```bash
uname -m                    # aarch64
uname -a
node -p 'process.platform'  # android  <- not 'linux', and that is the whole problem
node -p 'process.arch'      # arm64
command -v node npm claude
file -b "$(readlink -f "$(command -v claude)")"
```

That last line is the one that matters. It answers the only question that
decides the install strategy: is the thing on my PATH a JavaScript entry point
run by Node, or a native ELF binary?

---

## What actually goes wrong (measured, not guessed)

On the reference device — Pixel 7a, Android 17, Termux 0.118.3, node v24.18.0 —
`npm install -g @anthropic-ai/claude-code` succeeds and then `claude` prints:

```
Error: claude native binary not installed.
```

The cause is not glibc, at least not yet. Recent versions of the package are a
thin wrapper: the real product ships as a per-platform native binary listed in
`optionalDependencies`, and a postinstall script copies the matching one over
`bin/claude.exe`. The list is:

```
darwin-arm64  darwin-x64  linux-x64  linux-arm64
linux-x64-musl  linux-arm64-musl  win32-x64  win32-arm64
```

Termux's node reports `process.platform === 'android'`, so npm matches **none**
of them and installs no native build at all. The package's own platform map does
name `linux-arm64-android`, but no such package is published, so there is nothing
for the postinstall to find. There is no bundled JS entry point to fall back to —
the package contains only `install.cjs`, `cli-wrapper.cjs` and type definitions.

Then the glibc problem arrives. Both ARM64 Linux builds are dynamically linked:

```
linux-arm64       interpreter /lib/ld-linux-aarch64.so.1     (glibc)
linux-arm64-musl  interpreter /lib/ld-musl-aarch64.so.1      (musl)
```

Bionic provides neither loader, and an unrooted device cannot write `/lib`. Hence
the two-part fix below: fetch a native build explicitly, then give it a loader.

## Strategy

`device/install.sh` does this, in order:

1. **Check Node first.** Claude Code needs Node ≥ 18. The installer reports the
   version, platform and arch, and warns rather than silently upgrading — an
   existing working Node is not replaced.

2. **Keep npm globals inside the agent tree.** `npm config set prefix
   ~/android-agent/node`, with `~/android-agent/node/bin` added to PATH. Global
   installs never write outside the agent's own directory, which also makes
   `uninstall.sh --full` complete.

3. **Install the official package.**
   `npm install -g @anthropic-ai/claude-code` from the npm registry. Pin it when
   reproducibility matters: `aa provision --claude-version X.Y.Z`.

4. **Test functionally.** `claude --version` must exit 0. Nothing about the
   install output is trusted.

5. **On failure, fetch the native build explicitly.** The version is read from
   the installed wrapper's `package.json`, so the binary always matches:

   ```bash
   npm pack @anthropic-ai/claude-code-linux-arm64@<same version>
   tar xzf *.tgz --strip-components=1 -C ~/android-agent/tools/claude-code package/claude
   ```

   That is ~95 MB compressed, ~204 MB on disk.

6. **Give it a loader.** `glibc-runner` provides one, and it lives in Termux's
   `glibc-repo` — which is itself a package, not a repo you add by hand:

   ```bash
   pkg install glibc-repo
   pkg install glibc-runner        # provides `grun`
   ```

   (`tur-repo` does **not** carry `glibc-runner`; installing it and expecting
   `glibc-runner` to appear fails with `E: Unable to locate package`.)

7. **Write the wrapper** at `~/android-agent/bin/claude`:

   ```bash
   #!/data/data/com.termux/files/usr/bin/env bash
   exec grun "$HOME/android-agent/tools/claude-code/claude" "$@"
   ```

   `~/android-agent/bin` sits ahead of the npm global prefix on PATH, so this
   shadows the broken npm shim without uninstalling anything.

8. **Re-test.** If it still fails, the installer records a FAIL. It never claims
   Claude Code works when it does not.

Verified end state on the reference device:

```
$ which claude
/data/data/com.termux/files/home/android-agent/bin/claude
$ claude --version
2.1.251 (Claude Code)
```

---

## The ripgrep problem

Claude Code ships a prebuilt ripgrep for file search. The bundled binary is
glibc-linked and dies on bionic. The fix is one environment variable plus the
Termux-native package, both of which the installer sets up:

```bash
pkg install ripgrep
export USE_BUILTIN_RIPGREP=0     # written into ~/android-agent/config/environment
```

Symptom if this is missing: Claude Code starts, then every search or file-listing
operation fails or hangs.

---

## PATH and execution

Order matters. `~/android-agent/bin` comes first, then
`~/android-agent/node/bin`, then the Termux prefix:

```bash
export PATH="$AA_ROOT/bin:$AA_ROOT/node/bin:$PATH"
```

This is what lets the glibc wrapper shadow the npm shim without uninstalling
anything. Get the order wrong — put the npm prefix first — and `claude` resolves
to the stub again and prints "native binary not installed" even though a working
binary is sitting right there.

Two Termux-specific execution notes:

* **`termux-exec`** is installed as a core package. It rewrites `#!/bin/sh` and
  `#!/usr/bin/env` shebangs at exec time, which is what allows scripts written by
  Claude Code — which assume a normal Linux layout — to run at all.
* **`CLAUDE_CODE_EXECPATH`**, if a release requires it, should point at the
  wrapper that actually starts Claude Code, not at the npm shim. Set it in
  `~/android-agent/config/environment.local`, which `install.sh` never
  overwrites. Only set it if a concrete failure calls for it.

Arguments containing spaces survive the wrapper because it uses `exec … "$@"`.
Do not "simplify" that to `$*`.

---

## Verifying an install

```bash
claude --version                       # exits 0
claude --help >/dev/null               # runs with no network and no API key
~/android-agent/tests/e2e.sh           # claude-version + claude-invoke tests
```

The e2e suite deliberately stops at `--help`. A real prompt needs credentials
and network, which is a separate, owner-driven step:

```bash
./mac/aa shell -t 'claude'             # interactive; sign in on first run
```

Credentials live wherever Claude Code puts them under `$HOME`. They are never
copied into this repo, never printed, and never sent to the Mac.

---

## If it cannot be made to work

That is a legitimate outcome, and the harness treats it as one. The manifest
simply omits the `claude` capability, `android-agent-status` shows
`claude  not-installed`, and everything else — shell, Python, Node, the Android
bridge, UI automation — keeps working. Record what `file` said about the binary
and what the log showed, and revisit on the next release.
