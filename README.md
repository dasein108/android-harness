# android-harness

Run **Claude Code** on your Android phone, with Python, Node, the camera,
location, clipboard, notifications and shared storage wired up around it.

Install it from the phone itself. No computer, no cable, no adb.

```bash
pkg install curl
curl -fsSL https://raw.githubusercontent.com/dasein108/android-harness/main/phone-install.sh -o install.sh
less install.sh          # read it before running it
bash install.sh
```

Verified on a Pixel 7a, Android 17, Termux 0.118.3: Claude Code 2.1.251, Python
3.14.6, Node v24.18.0, 23 capabilities, 23/23 checks passing, `SECURITY AUDIT:
PASS`, and **zero listening sockets** — unless you opt into
[on-device ADB](#optional-on-device-adb-powerful-and-it-costs-you-something),
which trades exactly that away for screenshots and UI automation.

---

## Contents

- [Before you start](#before-you-start)
- [Install](#install)
- [Daily use](#daily-use)
- [Permissions](#permissions)
- [Optional: on-device ADB](#optional-on-device-adb-powerful-and-it-costs-you-something)
- [What is running, and what is not](#what-is-running-and-what-is-not)
- [Reset](#reset)
- [Troubleshooting](#troubleshooting)
- [Optional: drive it from a computer](#optional-drive-it-from-a-computer)
- [How it works](#how-it-works)

---

## Before you start

Install these on the phone, **both from the same source** — F-Droid or the
GitHub releases. Android rejects the second one if the signatures differ, and
the Play Store builds are abandoned.

| app | why |
|---|---|
| **Termux** | the Linux environment everything runs in — <https://f-droid.org/packages/com.termux/> |
| **Termux:API** | the bridge to camera, location, clipboard, notifications — <https://f-droid.org/packages/com.termux.api/> |
| **Termux:Widget** *(optional)* | the one-tap Claude Code icon on your home screen |

You also need about 1 GB free, most of it Claude Code's native binary and the
glibc runtime it needs.

No root. Nothing here asks for it.

---

## Install

In Termux:

```bash
pkg install curl
curl -fsSL https://raw.githubusercontent.com/dasein108/android-harness/main/phone-install.sh -o install.sh
less install.sh
bash install.sh
```

It fetches the harness, installs the packages, Python, Node and Claude Code,
writes the home-screen shortcuts, then runs an end-to-end suite and a security
audit. It will not claim success if either fails.

Re-run it any time; every step detects what is already there.

```bash
bash install.sh --media        # + imagemagick, ffmpeg, poppler
bash install.sh --no-claude    # skip Claude Code
bash install.sh --with-server  # also set up SSH, for a computer to connect later
```

Then **open a new Termux session** so the commands are on your `PATH`.

### First run

```bash
claude
```

Then `/login` inside it — it prints a URL, you sign in, you paste the code back.

Prefer an API key? Put it in the one file the installer never overwrites:

```bash
printf 'export ANTHROPIC_API_KEY=%s\n' 'sk-ant-...' >> ~/android-agent/config/environment.local
chmod 600 ~/android-agent/config/environment.local
```

### One tap from the home screen

The installer writes `~/.shortcuts/`. With **Termux:Widget** installed:

1. Long-press the home screen → **Widgets**
2. Find **Termux:Widget**, drag **"Termux shortcut"** onto the screen
3. Pick **`claude`**

Tapping it opens Claude Code in the agent workspace. The other shortcuts are
`agent-status` and `agent-test`.

These are launcher entries, not services. A script runs when you tap it and at
no other time — nothing starts at boot.

---

## Daily use

```bash
claude                           # Claude Code, in ~/android-agent/workspace
claude -p "summarise notes.md"   # one-shot, prints and exits

android-agent-status         # Android version, RAM, storage, battery, versions
android-permissions          # what the agent may do, and how to change it
android-battery              # JSON
android-wifi
android-location
android-camera photo.jpg
android-clipboard-get / android-clipboard-set "text"
android-notify "done"
android-share file.pdf
android-open https://example.com
android-wake on / off        # hold a wake lock so doze cannot kill a long job

android-adb status           # is on-device adb on? (off by default)
android-screenshot           # needs on-device adb, or a USB host
android-ui state / dump / tap / text / key / launch / apps

~/android-agent/tests/e2e.sh      # prove it still works
~/android-agent/security/audit.sh # prove nothing is exposed
```

Long jobs need the wake lock — Android will otherwise suspend Termux mid-task:

```bash
android-wake on
claude -p "refactor everything in ./src"
android-wake off
```

Every `android-*` command uses the same exit codes, so failures are never
silent:

| code | meaning |
|---|---|
| 0 | success |
| 2 | usage error |
| 3 | capability unavailable (Termux:API missing) |
| 4 | Android permission denied |
| 5 | the call ran and failed |

### Where things live

```
~/android-agent/
    workspace/   your working area — put project files here
    output/      generated files: photos, exports
    config/      environment, manifest.json, environment.local
    logs/        agent.log, install.log
    python/      venvs/default, plus any venv you create
    bin/         the android-* commands
```

---

## Permissions

```bash
android-permissions              # the groups and what each unlocks
android-permissions setup        # guided walk through the sensitive ones
android-permissions check camera # probe one for real
android-permissions open camera  # jump straight to the Settings screen
```

**Termux cannot grant itself anything**, and that is the point — the agent
cannot quietly widen its own reach. Measured on the device:

```
$ pm grant com.termux.api android.permission.CAMERA
java.lang.SecurityException: Neither user 10337 nor current process has
android.permission.GRANT_RUNTIME_PERMISSIONS.

$ appops set --uid com.termux MANAGE_EXTERNAL_STORAGE allow
bash: appops: command not found
```

Only Android Settings can grant, so `android-permissions` takes you there and
tells you what happened. (The one way to change that is
[on-device ADB](#optional-on-device-adb-powerful-and-it-costs-you-something),
which you have to turn on deliberately and which the audit then reports.) It cannot read permission state either — `dumpsys` is
not available to an app uid — so `check` establishes state by *using* the API
and reading the error Termux:API returns. Camera and microphone probes are
intrusive (a photo, a one-second recording) and only run when you ask.

| group | risk | unlocks |
|---|---|---|
| `location` | sensitive | `android-location` |
| `camera` | sensitive | `android-camera` |
| `microphone` | sensitive | audio recording |
| `contacts` | sensitive | reading contacts |
| `telephony` | sensitive | phone state, call log |
| `sms` | **dangerous** | read **and send** SMS — sending costs money |

Battery, wifi, clipboard, notifications, vibration, volume and the wake lock
need no Android permission at all. Shared storage is granted once by
`termux-setup-storage` during install.

### The controls the agent cannot touch

All in Android Settings, all on your phone:

| screen | what it does |
|---|---|
| Apps → **Termux:API** → Permissions | revoke camera, location, mic, contacts, SMS |
| Apps → **Termux** → Permissions | storage, all-files access |
| Apps → **Termux** → **Force stop** | stops the agent immediately |
| Apps → **Termux** → Battery → Restricted | no background execution at all |

---

## Optional: on-device ADB (powerful, and it costs you something)

Screenshots and UI automation need shell-uid access, which an app uid does not
have. You can grant it on the phone alone by pairing it with its own adb:

```bash
android-adb enable      # walks you through Wireless debugging pairing
android-screenshot
android-ui tap 540 715
android-ui dump
android-adb disable     # when you are done
```

**Read what this costs.** Everywhere else, this project leans on one property:
the agent cannot grant itself Android permissions. `pm grant` throws
`SecurityException` and only Settings can widen its reach. Enabling on-device
adb removes that. With adb connected the agent *can* grant itself camera,
microphone, location, contacts and SMS with no dialog and no notification. It
can also read the screen, drive the UI, and install packages.

It opens a real network port too: Android's Wireless debugging binds to your
Wi-Fi interface, not loopback. Pairing is required to use it — but the port is
open regardless, and it stays open until you turn Wireless debugging off in
Settings.

So it is off by default, never enabled by the installer, requires typing
`ENABLE` to confirm, and **`security/audit.sh` reports it as a finding for as
long as it is on**. That is not a bug in the audit. It is an accurate
description of a phone that now trusts its own agent with shell-level power.

The on-device `CLAUDE.md` tells the agent plainly that being *able* to
self-grant is not permission to do it.

Verified on the reference device: the phone paired with its own adb, took a
2400x1080 screenshot of itself, drove its own UI, and the manifest grew from 23
capabilities to 26 (`screenshot`, `ui-automation`, `adb-shell`). `android-adb
disable` returned it to 23, one loopback listener, and `SECURITY AUDIT: PASS`.

The pairing handshake itself is verified too: `Successfully paired to
127.0.0.1:44583`, then connected, then a screenshot the phone took of itself.

Two things about the pairing that the flow tells you, and which are easy to get
wrong:

* **The two ports are different, and on different screens.** The pairing port is
  in the "Pair device with pairing code" dialog next to the code; the connect
  port is on the Wireless debugging screen behind it. Both change every time you
  toggle Wireless debugging.
* **The code expires in about a minute.** Have the dialog open before you start.

Termux's adb has no mDNS support — `adb mdns services` answers `unknown host
service` — so it cannot discover those ports for you the way desktop adb can.
The command detects that and asks, rather than pretending to look.

One more quirk: a phone connected to its own adb registers **twice**, as
`127.0.0.1:PORT` and `emulator-NNNN`, so a bare `adb shell` fails with "more
than one device/emulator". The harness resolves the authorised transport itself;
your own `adb` calls will need `-s`.

---

## What is running, and what is not

A phone-only install runs **no network listener**. The SSH channel exists only
so a computer can connect over USB; with no computer, it is not configured and
not started. Confirmed from a host after a real phone-only install:

```
OK: all 0 listener(s) owned by this harness (uid 10337) are loopback-only
```

Zero, not "loopback-only" — the surface is absent, not merely unused.

Also absent, and checked by `security/audit.sh` on every run: no boot
persistence (`~/.termux/boot` stays empty), no cron entry, no runit service, no
reverse tunnel, no relay, no external callback URL, no `curl … | bash`, and no
credentials in scripts, logs or shell history.

The complete list of what this installs that survives a reboot:

| what | when it runs | remove with |
|---|---|---|
| `~/.bashrc` block | interactive shells, to set `PATH` | `uninstall.sh --soft` |
| `~/.shortcuts/*` | only when you tap one | `uninstall.sh --soft` |

That is all of it. Anything else the audit finds is unexpected by definition and
fails the audit.

---

## Reset

```bash
~/android-harness-src/device/uninstall.sh --soft
~/android-harness-src/device/uninstall.sh --full
~/android-harness-src/device/uninstall.sh --full --purge-workspace
```

`--soft` removes generated config, logs and the shell block. `--full` also
removes the agent's binaries, tools and venvs. `--purge-workspace` is opt-in and
still never touches your files.

**Never touched by any reset:** shared storage, photos, documents, downloads,
and anything under `$HOME` outside `~/android-agent`.

---

## Troubleshooting

| symptom | fix |
|---|---|
| `claude: command not found` | open a new Termux session, or `. ~/android-agent/config/environment` |
| `claude` says "native binary not installed" | an old session is hitting the npm stub. New session, or re-run the installer. |
| `android-*` exits 3 | the Termux:API **app** is not installed — the package alone is not enough |
| `android-*` hangs, then times out | Termux:API is being killed by battery optimisation; exempt it in Settings |
| `android-*` exits 4 | the permission is not granted: `android-permissions setup` |
| camera writes an empty file | Android blocks the camera for background apps — bring Termux to the foreground |
| `no ~/storage` | run `termux-setup-storage` and approve the dialog |
| Claude Code dies mid-task | doze suspended Termux: `android-wake on` first |
| clipboard test SKIPs | Android 10+ only lets the foreground app read the clipboard — bring Termux forward |
| `android-screenshot` exits 3 | needs shell uid: `android-adb enable`, or `aa ui screenshot` from a computer |
| adb says "more than one device/emulator" | a phone on its own adb registers twice (`127.0.0.1:PORT` and `emulator-NNNN`); the harness handles it, but your own `adb` calls need `-s` |
| audit FAILs on adb | expected while on-device adb is on. `android-adb disable`, then turn Wireless debugging off in Settings |

Diagnostics:

```bash
android-agent-status
android-agent-manifest --refresh     # re-probe every capability
~/android-agent/tests/e2e.sh --full
tail -n 100 ~/android-agent/logs/install.log
```

---

## Optional: drive it from a computer

A Mac or Linux host adds four things the phone cannot do for itself:
**screenshots**, **UI automation**, granting permissions without tapping, and an
**authoritative listener audit** (Android denies an app uid both `/proc/net/tcp`
and the netlink socket `ss` needs, so on-device socket checks are blind).

```bash
git clone https://github.com/dasein108/android-harness.git
cd android-harness
./install.sh
```

Prerequisites: `git`, `ssh`, `python3`, `adb` (the installer offers to
`brew install --cask android-platform-tools`), a **data-capable** USB cable,
USB debugging enabled, and the screen unlocked during setup.

```bash
aa claude                      # Claude Code on the phone, with a TTY
aa shell                       # a shell on the phone
aa push / aa pull              # files both ways
aa ui screenshot shot.png      # adb screencap
aa ui dump / tap / text / key / launch
aa permissions --pick          # grant without tapping through Settings
aa netaudit                    # every socket, attributed to a package
aa policy save / check         # tamper baseline kept off the phone
aa test --full ; aa audit ; aa report
```

The channel is SSH on the phone's `127.0.0.1:8022`, reachable only through
`adb forward` over USB, public-key only, started on demand. See
[docs/MAC-AGENT.md](docs/MAC-AGENT.md) and
[docs/ON-DEVICE-CONTROL.md](docs/ON-DEVICE-CONTROL.md).

---

## How it works

### Claude Code on Termux

`npm install -g @anthropic-ai/claude-code` on Termux installs a **stub** that
prints *"native binary not installed"*. Node on Termux reports
`process.platform === 'android'`, so npm matches none of the package's
per-platform native builds, and the package has no bundled JS to fall back on.

So the installer fetches `@anthropic-ai/claude-code-linux-arm64` explicitly at
the matching version and runs it through `glibc-runner`, which supplies the
loader bionic lacks. It also points the leftover npm stubs at that launcher, so
`claude` works in any shell. Full detail, with the measurements, in
[docs/CLAUDE-CODE.md](docs/CLAUDE-CODE.md).

### Layout

```
android-harness/
  phone-install.sh          run this in Termux
  install.sh                run this on a Mac
  device/                   everything that ends up on the phone
    install.sh              the idempotent provisioner
    uninstall.sh            soft / full reset
    CLAUDE.md               instructions for the agent running on the phone
    bin/android-*           the Android bridge (incl. android-permissions,
                            android-adb, android-ui)
    tests/e2e.sh            functional end-to-end suite
    security/audit.sh       exposure and persistence audit
  mac/aa                    the host CLI
  docs/
    CLAUDE-CODE.md          why Claude Code needs special handling
    MAC-AGENT.md            the workflow for an LLM agent driving a phone
    ON-DEVICE-CONTROL.md    controlling the agent with tools it cannot reach
```

### Supply chain

| component | source |
|---|---|
| Termux, Termux:API, Termux:Widget | F-Droid / GitHub releases, installed by you |
| Termux packages | the Termux project's own signed apt repositories |
| `@anthropic-ai/claude-code` and its `linux-arm64` build | the official npm registry |
| `glibc-runner` | the Termux `glibc-repo` repository |

`glibc-repo` is the only repository added beyond Termux's defaults. Nothing is
downloaded from a raw URL and executed — including this project's own installer,
which the command at the top saves to a file so you can read it first.

---

## Licence

MIT.
