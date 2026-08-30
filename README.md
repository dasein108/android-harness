# android-harness

Turn an Android phone into a full agent environment — Python, Node, **Claude
Code**, camera, location, clipboard, notifications, shared storage, UI
automation — provisioned in one command from your Mac over USB.

Maximum local capability, minimum attack surface. The control channel is bound
to `127.0.0.1` on the phone and reachable only through the USB cable. Nothing
listens on the network, nothing starts at boot, nothing calls home. A security
audit runs at the end of every install and has to pass.

Verified on a Pixel 7a, Android 17, Termux 0.118.3: Claude Code 2.1.251, Python
3.14.6, Node v24.18.0, 23 capabilities, `SECURITY AUDIT: PASS`.

---

## Contents

- [What you get](#what-you-get)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Using it on the phone](#using-it-on-the-phone)
- [Using it from the Mac](#using-it-from-the-mac)
- [Permissions](#permissions)
- [Controlling it from the phone](#controlling-it-from-the-phone)
- [Architecture](#architecture)
- [Security model](#security-model)
- [Reset and recovery](#reset-and-recovery)
- [Troubleshooting](#troubleshooting)
- [Supply chain](#supply-chain)

---

## What you get

On the phone, under `~/android-agent`:

| | |
|---|---|
| **Claude Code** | working on Android, launched by tapping a home-screen icon or typing `claude` |
| **Python** | 3.x with pip and venv, plus a ready-made default venv |
| **Node.js** | with npm, global prefix kept inside the agent tree |
| **Android bridge** | 17 `android-*` commands: battery, wifi, location, camera, clipboard, notify, vibrate, volume, brightness, open, share, wake lock |
| **Shared storage** | DCIM, Pictures, Download, Documents, Movies, Music |
| **Diagnostics** | `android-agent-status`, a capability manifest, an end-to-end test suite, a security audit |

On the Mac, one CLI called `aa`:

| | |
|---|---|
| **Shell and files** | `aa shell`, `aa push`, `aa pull` |
| **Claude Code** | `aa claude` — runs it on the phone with a real TTY |
| **UI automation** | `aa ui screenshot / dump / state / tap / swipe / text / key / launch` |
| **Permissions** | `aa permissions` — a risk-labelled picker, not a wall of `pm grant` |
| **Verification** | `aa test`, `aa netaudit`, `aa audit`, `aa report` |

---

## Prerequisites

**On the Mac (or a Linux host):**

- `git`, `ssh`, `python3` — all preinstalled on macOS
- `adb` — the installer offers to `brew install --cask android-platform-tools` if it is missing
- A **data-capable** USB cable. Charge-only cables are the single most common cause of "device not found".

**On the phone:**

- **Termux** and **Termux:API**, both from **F-Droid** or the **GitHub releases** — never the Play Store builds, which are abandoned and broken.
  Install both from the *same* source or Android will reject the second one on a signature mismatch.
  - <https://f-droid.org/packages/com.termux/>
  - <https://f-droid.org/packages/com.termux.api/>
- Optional: **Termux:Widget**, for the one-tap home-screen launcher.
- **Developer options → USB debugging** enabled, and the "Allow USB debugging?" prompt approved when you plug in.
- Screen **unlocked** during install. One step types a command into Termux, and a lock screen blocks that.

You do **not** need root. Nothing here requires it, and nothing asks for it.

---

## Install

One command, from the Mac, with the phone plugged in and unlocked:

```bash
curl -fsSL https://raw.githubusercontent.com/dasein108/android-harness/main/install.sh -o aa-install.sh
less aa-install.sh          # read it — see "Supply chain" below
bash aa-install.sh
```

Or clone first, which amounts to the same thing:

```bash
git clone https://github.com/dasein108/android-harness.git
cd android-harness
./install.sh
```

The installer is idempotent — re-run it any time. It:

1. checks the host tools, offering to install `adb`
2. checks the phone is attached, authorised, and has Termux + Termux:API
3. generates a dedicated ed25519 key (the private half never leaves the Mac)
4. brings up the loopback SSH channel over USB
5. provisions packages, Python, Node, Claude Code, the Android bridge, shortcuts
6. applies a permission profile
7. runs the end-to-end suite and the security audit, and refuses to claim success if either fails

Options:

```bash
./install.sh --profile minimal    # no camera, no location
./install.sh --profile extended   # + microphone, contacts, telephony, sensors
./install.sh --media              # + imagemagick, ffmpeg, poppler
./install.sh --no-claude          # skip Claude Code
./install.sh --dir ~/code/ah      # clone somewhere specific
./install.sh --yes                # never stop to ask
```

Expect a few minutes, mostly downloading Claude Code's ~200 MB native binary and
the glibc runtime it needs.

---

## Using it on the phone

The Mac is only the provisioning console. Everything below works with the cable
unplugged.

### One tap: the home-screen shortcut

The installer writes `~/.shortcuts/`, which **Termux:Widget** turns into launcher
icons:

| shortcut | what it does |
|---|---|
| `claude` | opens a Termux session in the agent workspace and starts Claude Code |
| `agent-status` | full diagnostic report |
| `agent-test` | the end-to-end suite |
| `agent-server-start` | starts the SSH channel for the Mac |

To put `claude` on your home screen:

1. Install **Termux:Widget** (F-Droid, same signing source as Termux).
2. Long-press the home screen → **Widgets**.
3. Find **Termux:Widget**. Drag **"Termux shortcut"** on for a single one-tap
   icon, or the list widget to see all four.
4. Pick `claude`. Tapping it now opens Claude Code directly.

These are launcher entries, not background services: a script runs only when you
tap it. Nothing starts at boot.

### Or just type it

Open Termux:

```bash
claude                    # first run: /login
android-agent-status
android-battery
android-camera photo.jpg
```

Everything is on `PATH` in a normal Termux session.

### First run: logging in

Claude Code ships logged out. Inside it:

```
/login
```

It prints a URL — open it in any browser, sign in, paste the code back.

Prefer an API key? Put it in the one file the installer never overwrites:

```bash
printf 'export ANTHROPIC_API_KEY=%s\n' 'sk-ant-...' >> ~/android-agent/config/environment.local
chmod 600 ~/android-agent/config/environment.local
```

That keeps it out of shell history and out of git.

### Long jobs

Android's doze will suspend Termux mid-task. Hold a wake lock around anything
long-running:

```bash
android-wake on
claude -p "refactor everything in ./src"
android-wake off
```

---

## Using it from the Mac

```bash
aa claude                        # Claude Code on the phone, with a TTY
aa shell                         # interactive shell
aa shell android-battery         # one command
aa push report.md '~/android-agent/workspace/'
aa pull '~/android-agent/output/photo.jpg' .
aa status                        # device diagnostics
aa ui screenshot shot.png
aa test --full
aa audit
aa help
```

`aa` lives at `mac/aa`; the installer offers to symlink it into `~/.local/bin`.

### UI automation

Screen capture and input are driven from the Mac over adb, not from Termux. On
an unrooted device `screencap` and `input` live in the shell/system domain and
Termux:API exposes no bridge to them. The alternative would be an accessibility
service — exactly the kind of silent, powerful, hard-to-audit component this
project refuses to install.

```bash
aa ui screenshot [OUT.png]      aa ui dump [OUT.xml]     aa ui state
aa ui tap X Y                   aa ui swipe X1 Y1 X2 Y2 [MS]
aa ui text "hello"              aa ui key BACK
aa ui launch com.example.app    aa ui apps [filter]
```

A full loop — launch an app, read the view hierarchy, tap, type, screenshot the
result — works today; the reference device was driven through Settings this way.

The device-side `android-screenshot` exists and exits `3` pointing at
`aa ui screenshot`, so an agent on the phone gets a clear answer instead of a
mysterious failure.

---

## Permissions

You choose what the agent may do. Nothing sensitive is granted without you
saying so.

```bash
aa permissions              # live state, read from the device
aa permissions --pick       # interactive, safe defaults preselected
aa permissions --profile default
aa permissions --grant camera,location
aa permissions --revoke sms
aa permissions --groups     # every group, with the exact Android permissions
```

### Groups

| group | risk | what it unlocks |
|---|---|---|
| `storage` | safe | shared storage — built in, nothing to grant |
| `notifications` | safe | `android-notify` |
| `device-state` | safe | battery, wifi, volume, vibrate, clipboard, wake lock — no Android permission needed |
| `camera` | sensitive | `android-camera` |
| `location` | sensitive | `android-location` |
| `microphone` | sensitive | audio recording |
| `sensors` | sensitive | body sensors |
| `contacts` | sensitive | read contacts |
| `telephony` | sensitive | phone state, call log |
| `write-settings` | sensitive | `android-brightness` |
| `usage-stats` | sensitive | which app is in the foreground |
| `sms` | **dangerous** | read **and send** SMS — sending costs money |
| `all-files` | **dangerous** | all-files access (see the note below) |

### Profiles

| profile | groups |
|---|---|
| `minimal` | storage, notifications, device-state |
| `default` | minimal + camera + location ← fresh installs |
| `extended` | default + microphone, sensors, contacts, telephony, write-settings, usage-stats |
| `full` | extended + sms + all-files — requires typing `FULL` to confirm |

### Host features

Separately from Android's permissions, you control what the harness itself will
do over the cable:

| feature | risk | gates |
|---|---|---|
| `adb-read` | safe | `aa ui screenshot / dump / state / apps` |
| `adb-input` | sensitive | `aa ui tap / swipe / text / key / launch` |
| `adb-grant` | sensitive | `aa grant`, `aa permissions` — changing Android permissions at all |

```bash
aa permissions --disable adb-input     # look at the screen, never type on it
```

Switched-off features are refused with an explanation, not silently ignored.

### The agent cannot grant itself anything

Worth stating plainly, because it is the property the whole permission model
rests on. From the Termux uid:

```
$ pm grant com.termux.api android.permission.RECORD_AUDIO
java.lang.SecurityException: grantRuntimePermission: Neither user 10337 nor
current process has android.permission.GRANT_RUNTIME_PERMISSIONS.
```

Granting needs a system-signed caller. Termux is not one and cannot become one
without root. So every sensitive Android permission is under your exclusive
control, whether you set it from `aa permissions` or from Android Settings.

> **Note on `all-files`.** Since Android 11, all-files access still excludes
> `/Android/data` and `/Android/obb` — no app, no permission, no appop gets in
> without root. Termux already reaches everything else through legacy storage.
> On the reference device this grant changed nothing measurable, so `default`
> leaves it off.

---

## Controlling it from the phone

Everything the agent owns, the agent can rewrite — its own config, shortcuts,
even `sshd_config`. So the trustworthy controls are the ones owned by someone
else, and both are usable without a computer:

**Android Settings**, which the agent provably cannot reach:

| screen | what it controls |
|---|---|
| Settings → Apps → **Termux:API** → Permissions | camera, location, microphone, contacts, phone, SMS |
| Settings → Apps → **Termux** → Permissions | storage, all-files access |
| Settings → Apps → **Termux** → Force stop | stops the agent and its SSH channel now |
| Settings → **Developer options** → Revoke USB debugging authorisations | cuts the Mac off entirely |
| Settings → Apps → **Termux** → Battery → Restricted | no background execution at all |

Jump straight there from the Mac with `aa settings termux-api | termux | privacy | devopts`.

**The Mac**, which is not the phone. The host feature switches
(`state/features.conf`) and the config baseline (`state/policy.sha256`) live
here, so a compromised phone cannot alter either:

```bash
aa policy save     # baseline a device you trust
aa policy check    # detect any drift since — exits non-zero if something moved
```

`check` hashes `sshd_config`, `~/.bashrc`, `authorized_keys`, every shortcut and
every agent command, then asserts the invariants: loopback-only listener,
password auth off, `GatewayPorts` off, no Termux:Boot scripts. Tested against a
real tamper — flipping `ListenAddress` to `0.0.0.0` is caught by the hash, by the
invariant, and independently by `android-agent-server`, which refuses to start.

The full reasoning, including why this project installs no accessibility service
and no helper APK, is in [docs/ON-DEVICE-CONTROL.md](docs/ON-DEVICE-CONTROL.md).

---

## Architecture

```
   Mac                                       Android phone
 ┌──────────────────────────┐              ┌─────────────────────────────────┐
 │  you, or an LLM agent    │              │  Termux (bionic, aarch64)       │
 │    │                     │              │                                 │
 │    ▼                     │              │   sshd  ← 127.0.0.1:8022        │
 │  mac/aa  ──ssh──► 127.0.0.1:8022        │     │     pubkey-only           │
 │              │           │              │     ▼                           │
 │              └── adb forward ──USB──────┼──►  ~/android-agent/            │
 │                                          │       bin/    android-* commands│
 │  adb (screenshot, input,                 │       python/ venvs             │
 │       permission grants) ─────USB───────┼──►    node/   npm global prefix  │
 └──────────────────────────┘              │       tools/  claude-code binary │
                                           │       workspace/ logs/ output/   │
                                           └─────────────────────────────────┘
```

Two channels, both over the USB cable:

| channel | used for | binding |
|---|---|---|
| ssh over `adb forward` | shell, provisioning, files, Android bridge | phone `127.0.0.1:8022`, pubkey-only |
| adb directly | screenshots, UI automation, permission grants | USB, no network at all |

There is no third channel.

### Layout

```
android-harness/
  install.sh                one-shot setup, run on the Mac
  mac/aa                    the control CLI
  mac/lib/                  permission groups, the /proc/net decoder
  keys/                     dedicated ed25519 key — gitignored, never leaves the Mac
  state/                    known_hosts, device facts, feature switches — gitignored
  device/                   everything copied to the phone
    bootstrap.sh            one-shot: brings up the loopback ssh channel
    install.sh              the idempotent provisioner
    uninstall.sh            soft / full reset
    CLAUDE.md               instructions for the agent running on the phone
    lib/aa-common.sh        shared helpers, exit-code contract
    bin/android-*           the Android bridge
    tests/e2e.sh            functional end-to-end suite
    security/audit.sh       exposure and persistence audit
  docs/
    MAC-AGENT.md            the workflow an LLM agent on the Mac should follow
    ON-DEVICE-CONTROL.md    controlling the agent with tools it cannot reach
    CLAUDE-CODE.md          how Claude Code is made to run on Termux, and why
```

### Exit codes

Every `android-*` command uses the same contract:

| code | meaning |
|---|---|
| 0 | success |
| 2 | usage error |
| 3 | capability unavailable (no Termux:API, no such API) |
| 4 | Android permission denied |
| 5 | the call ran and failed |

An unavailable capability fails loudly. It is never reported as an empty
success.

---

## Security model

The agent is trusted **inside your Termux environment**: it installs packages,
writes files, runs scripts, manages venvs, uses the Android APIs. That trust
stops at the network.

- sshd binds `127.0.0.1` only, and `android-agent-server` **refuses to start**
  with a config that binds anything else or enables password auth.
- Public-key authentication only. The private key stays on the Mac; the audit
  fails if private key material ever turns up under the agent tree.
- No boot persistence. Nothing in `~/.termux/boot`, no cron entry, no runit
  service. The audit flags any that appear, whoever created them.
- No reverse tunnel, relay, UPnP mapping, ngrok/localtunnel/serveo/Tor exposure,
  no hard-coded external control endpoint.
- No `curl … | bash`. External code comes from Termux's signed repositories and
  the official npm registry, and the installer logs what it fetched.
- Secrets are never printed. `android-clipboard-set` logs a byte count, not a
  value; `android-clipboard-get` refuses to echo private-key material.
- **The listener check runs on the host.** Android denies an untrusted_app uid
  both the netlink socket `ss` needs and `/proc/net/tcp`, so a device-side check
  sees an empty table and would pass vacuously. `aa netaudit` reads `/proc/net`
  through adb and attributes every socket to a uid and package name. The
  device-side audit reports that blind spot instead of claiming all-clear.

### Deliberate persistent components

The complete list. Anything else the audit finds is unexpected by definition.

| component | what it is | when it runs | how to stop it |
|---|---|---|---|
| `sshd` | OpenSSH on `127.0.0.1:8022` | only when started by `android-agent-server` | `aa server stop` |
| `~/.bashrc` block | sources `~/android-agent/config/environment` | interactive shells | `uninstall.sh --soft` |
| `sshd_config` block | pins loopback + pubkey-only | read by sshd at start | `uninstall.sh --soft` (original at `sshd_config.aa-orig`) |
| `~/.shortcuts/*` | Termux:Widget launcher entries | only when you tap one | `uninstall.sh --soft` |

### What was already on your phone

The audit reports pre-existing components rather than quietly ignoring them. On
the reference device that meant runit service directories for `sshd` and
`ssh-agent` (both disabled, `runsvdir` not running) and non-loopback listeners
belonging to Play Services, networkstack and YouTube. None are the harness's,
and it does not touch them — it names them so the report is honest.

---

## Reset and recovery

```bash
aa reset --soft                    # config, logs, tmp, output, shortcuts, shell + sshd blocks
aa reset --full                    # + agent binaries, tools, venvs, npm prefix
aa reset --full --purge-workspace  # + the workspace, only when asked explicitly
```

Never touched by any reset: Android shared storage, photos, documents,
downloads, and anything under `$HOME` outside `~/android-agent` apart from the
marked blocks the installer wrote.

The authorised key is left in place on purpose — locking the Mac out is a
separate, deliberate act:

```bash
aa shell "$EDITOR ~/.ssh/authorized_keys"
```

Recovery after a soft reset is `aa bootstrap && aa provision`. That path is
tested, not assumed.

---

## Troubleshooting

| symptom | cause and fix |
|---|---|
| `no single authorized device` | charge-only cable, USB debugging off, or the prompt not approved. `adb devices` should list one line ending in `device`. |
| bootstrap times out | the phone was locked, or Termux was not in the foreground. Unlock and re-run; the log is at `/sdcard/Download/aa-bootstrap.log`. |
| `claude` says "native binary not installed" | you are in a shell that predates provisioning, hitting the npm stub. Open a new Termux session, or re-run `aa provision`, which repoints the stub at the working launcher. |
| `android-*` exits 3 | `pkg install termux-api` missing, or the Termux:API **app** is not installed. |
| `android-*` hangs then times out | Termux:API killed by battery optimisation — exempt it in Android Settings. |
| `android-*` exits 4 | the runtime permission is not granted. `aa permissions --pick`. |
| camera writes an empty file | Android blocks the camera for background apps. Bring Termux to the foreground (`aa ui launch com.termux`). |
| `no ~/storage` | run `termux-setup-storage` in Termux and approve the dialog. |
| Mac cannot ssh in | `aa forward`, then `aa server start`. |
| `aa server start` refuses | the sshd config no longer binds loopback. That refusal is the safety net working — inspect the config. |
| `no-external-listener` SKIP | expected. The device cannot enumerate sockets; run `aa netaudit`. |
| `aa shell` hangs or says the channel is down | Android killed Termux, taking sshd with it. `aa server start` restarts it by typing into Termux over adb; `aa bootstrap` rebuilds the channel from scratch. |
| `aa policy check` reports drift | something changed a tracked file. If it was you, `aa policy save`. If it was not, read [docs/ON-DEVICE-CONTROL.md](docs/ON-DEVICE-CONTROL.md). |
| everything is confused | `aa reset --full`, then `aa bootstrap && aa provision`. |

Diagnostics, in order of usefulness:

```bash
aa doctor                                   # host, device, key, channel
aa status                                   # what exists on the phone
aa shell 'android-agent-manifest --refresh' # re-probe every capability
aa test --full
aa shell 'tail -n 100 ~/android-agent/logs/install.log'
```

---

## Supply chain

| component | source | verification |
|---|---|---|
| Termux, Termux:API, Termux:Widget | F-Droid / GitHub releases, installed by you | Android APK signatures |
| Termux packages | the Termux project's own apt repositories, preconfigured | apt signature checking, unchanged |
| `@anthropic-ai/claude-code` | official npm registry package | npm registry integrity hashes; pin with `--claude-version` |
| `@anthropic-ai/claude-code-linux-arm64` | official npm registry package, version matched to the wrapper | npm registry integrity hashes |
| `glibc-runner` | the Termux `glibc-repo` package repository | apt signature checking |
| `adb` | `brew install --cask android-platform-tools` | Homebrew cask checksum |

The only repository added beyond Termux's defaults is `glibc-repo`, and only
because Claude Code needs a glibc loader — see
[docs/CLAUDE-CODE.md](docs/CLAUDE-CODE.md) for exactly why.

Nothing is downloaded from a raw URL and executed. That applies to this
project's own installer too: the command above downloads it to a file so you can
read it before running it, rather than piping it into a shell.

---

## Why Claude Code needs special handling

Short version: `npm install -g @anthropic-ai/claude-code` on Termux installs a
stub that prints *"native binary not installed"*. Node on Termux reports
`process.platform === 'android'`, so npm matches none of the package's
per-platform native builds, and there is no bundled JS to fall back on. The
Linux ARM64 build is fetched explicitly and run through `glibc-runner`, which
supplies the loader bionic lacks.

The full story, with the measurements behind it, is in
[docs/CLAUDE-CODE.md](docs/CLAUDE-CODE.md).

---

## Licence

MIT.
