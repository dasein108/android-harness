# CLAUDE.md — Android Agent (Termux)

You are running inside Termux on the owner's Android phone.

You are trusted by the device owner and may perform broad local operations
required to accomplish the user's task. You must not create hidden external
access, expose control services to untrusted networks, install backdoors, or
establish undocumented persistence. Keep control local and owner-authorized.

---

## Where you are

| | |
|---|---|
| Platform | Android, Termux (bionic libc, not glibc) |
| Architecture | `aarch64` (ARM64) — confirm with `uname -m` |
| Termux prefix | `/data/data/com.termux/files/usr` (`$PREFIX`) |
| Home | `/data/data/com.termux/files/home` (`$HOME`) |
| Agent root | `~/android-agent` (`$AA_ROOT`) |
| Shared storage | `~/storage/shared` → `/sdcard` |

Agent tree:

```
~/android-agent/
    bin/         android-* commands (on your PATH)
    lib/         aa-common.sh, shared shell helpers
    scripts/     scripts you write
    config/      environment, manifest.json
    logs/        agent.log, sshd.log, install.log
    workspace/   your working area — put project files here
    tools/       tools you build or fetch
    python/      python/venvs/default and any venvs you create
    node/        npm global prefix (bin/ is on PATH)
    tmp/         scratch
    output/      generated artefacts (photos, reports, exports)
    tests/       e2e.sh
    security/    audit.sh
```

Environment is loaded from `~/android-agent/config/environment` via a marked
block in `~/.bashrc`. Put your own overrides in `config/environment.local`;
`install.sh` will not overwrite that file.

---

## Available commands

Android bridge (needs the `termux-api` package **and** the Termux:API app):

```
android-battery [--percent]         battery status as JSON
android-wifi [--scan]               connection info, or a scan
android-location [-p gps|network] [-r once|last]
android-camera [-c ID] [OUT.jpg]    still capture; --list enumerates cameras
                                    (Android blocks the camera for background
                                     apps: Termux must be in the foreground)
android-clipboard-get               read clipboard
android-clipboard-set TEXT          write clipboard (also reads stdin)
android-notify [-t TITLE] TEXT      post a notification
android-vibrate [MS] [--force]
android-volume [STREAM LEVEL]       no args prints all streams
android-brightness 0-255|auto
android-open FILE|URL               hand off to the default Android handler
android-share [-t TITLE] FILE       Android share sheet
android-wake on|off                 wake lock for long jobs
android-screenshot                  NOT available on-device — see UI automation
```

Agent management:

```
android-agent-status [--json]       full diagnostic report
android-agent-manifest [--refresh]  capability manifest (only verified caps)
android-agent-server start|stop|restart|status|logs|config
~/android-agent/tests/e2e.sh [--full]
~/android-agent/security/audit.sh
```

Exit-code contract for every `android-*` command:

| code | meaning |
|---|---|
| 0 | success |
| 2 | usage error |
| 3 | capability unavailable (no Termux:API, no such API) |
| 4 | Android permission denied |
| 5 | the call ran and failed |

A capability that is unavailable **fails loudly**. Never read an empty result as
a success.

---

## Python

`python` is Termux's Python 3. `pip` and `venv` both work.

```bash
python -m venv ~/android-agent/python/venvs/myproject
~/android-agent/python/venvs/myproject/bin/pip install requests
```

Prefer a venv over installing into the Termux global site-packages. Packages
with C extensions may need `pkg install build-essential python-dev` first; some
wheels have no ARM64/Termux build and must be compiled.

A default venv exists at `~/android-agent/python/venvs/default`.

## Node.js

`node` and `npm` come from the Termux `nodejs-lts` package. The npm global
prefix is set to `~/android-agent/node`, so `npm install -g` writes inside the
agent tree and `~/android-agent/node/bin` is on your PATH.

Do not reinstall or switch the Node version unless something is actually broken;
check `node --version`, `node -p 'process.platform'`, `node -p 'process.arch'`
first.

## Claude Code

`claude` here is **not** the npm shim. Node on Termux reports
`process.platform === 'android'`, so npm matches none of the package's
per-platform native builds and the shim it installs is a stub that only prints
"native binary not installed". What actually runs:

```
~/android-agent/bin/claude          a wrapper: exec grun <binary> "$@"
~/android-agent/tools/claude-code/claude   the Linux ARM64 native build (~204 MB)
grun                                glibc-runner, supplies the loader bionic lacks
```

`~/android-agent/bin` is ahead of the npm global prefix on PATH, which is what
makes the wrapper win. Two more things matter:

* **ripgrep** — the bundled one is glibc-linked and dies under bionic.
  `USE_BUILTIN_RIPGREP=0` is exported in `config/environment` and the
  Termux-native `ripgrep` package is installed.
* **Do not `npm install -g @anthropic-ai/claude-code` and expect it to fix
  anything.** It reinstalls the same stub. If `claude` breaks, re-run the
  provisioner from the Mac (`aa provision`), which rebuilds this path.

Check what you actually have before changing anything:

```bash
which claude && file -b "$(readlink -f "$(which claude)")"
claude --version          # expect: 2.1.251 (Claude Code) or later
```

---

## Screenshots and UI automation

An unrooted Android device gives Termux no way to capture the screen or inject
input: `screencap` and `input` live in the shell/system domain and Termux:API
exposes no bridge for them. So these are **host-side capabilities**, driven from
the Mac over the USB/adb channel:

```
aa ui screenshot [OUT.png]     adb exec-out screencap -p
aa ui dump                     uiautomator XML view hierarchy
aa ui tap X Y                  adb shell input tap
aa ui text "hello"             adb shell input text
aa ui key BACK|HOME|ENTER|...  adb shell input keyevent
aa ui launch <package>         adb shell monkey -p <pkg> 1
aa ui state                    foreground activity + display state
```

No accessibility service is installed and no helper APK is pushed to the device.
If you need on-device UI control, say so and let the owner decide — do not
install an accessibility service on your own.

---

## The control channel

The Mac reaches this device through:

```
Mac  --ssh-->  127.0.0.1:8022 (Mac)  --adb forward over USB-->  127.0.0.1:8022 (phone)  -->  sshd
```

* sshd binds **loopback only** (`ListenAddress 127.0.0.1`), so nothing on the
  LAN or the Internet can reach it.
* Authentication is **SSH public key only**; passwords are disabled.
* The private key lives on the Mac and is never copied here.
* sshd is started on demand by `android-agent-server`. There is no boot hook.

`android-agent-server status` prints the bind address and the auth settings.

It cannot print a real listener table, and neither can you: Android denies an
untrusted_app uid both the netlink socket `ss` needs and `/proc/net/tcp`, so
every socket listing from in here comes back empty. That is a blind spot, not an
all-clear — never report "nothing is listening" on the strength of it. The
authoritative check runs on the Mac: `aa netaudit` reads `/proc/net` through adb
and names the app that owns every socket.

---

## Security rules — non-negotiable

You may install software, write files, run scripts, create venvs, manage the
agent's own services and use the Android APIs. You may **not**:

* bind any service to `0.0.0.0` or a LAN address;
* create reverse shells, reverse SSH tunnels, ngrok/localtunnel/serveo/Tor
  exposure, or any relay that lets an outside party send commands in;
* add UPnP or router port mappings;
* install boot persistence (`~/.termux/boot`), cron jobs or background services
  that were not explicitly requested and documented;
* embed credentials, private keys or tokens in scripts, logs or shell history;
* add a remote update mechanism that fetches and executes arbitrary code;
* pipe an unreviewed remote script into a shell (`curl … | bash`). Download with
  `curl -fL URL -o file`, read it, then run it;
* exfiltrate clipboard contents, session tokens, browser data or photos to any
  external service.

Outbound network use is fine for package installs, API calls and tasks the user
asked for. Nothing may accept unsolicited inbound commands.

If a task seems to require any of the above, stop and ask the owner.

## Data rules

* Never delete user data. `~/storage/shared`, DCIM, Pictures, Documents,
  Download, Movies, Music belong to the owner.
* Write your own artefacts to `~/android-agent/output` or `workspace`.
* `uninstall.sh --soft|--full` removes agent state only; `--purge-workspace` is
  opt-in and still never touches shared storage.

---

## Diagnosing failures

```bash
android-agent-status                 # what exists, what runs, what is missing
android-agent-manifest --refresh     # re-probe every capability
~/android-agent/tests/e2e.sh --full  # functional end-to-end suite
~/android-agent/security/audit.sh    # exposure and persistence audit
tail -n 100 ~/android-agent/logs/install.log
android-agent-server logs 100
```

Common causes:

| symptom | cause |
|---|---|
| `android-*` exits 3 | `pkg install termux-api` missing, or the Termux:API app is not installed |
| `android-camera` writes an empty file | Termux is not in the foreground — Android denies background apps the camera, and Termux:API reports it as an empty file rather than an error |
| `android-*` hangs then times out | Termux:API app killed by battery optimisation — exempt it |
| exit 4 | the Android runtime permission is not granted to Termux:API |
| no `~/storage` | run `termux-setup-storage` and approve the dialog |
| `claude` not found after install | `~/android-agent/node/bin` missing from PATH — re-source `config/environment` |
| ripgrep errors from Claude Code | `USE_BUILTIN_RIPGREP=0` not exported |
| Mac cannot ssh in | `adb forward` not set up on the Mac, or sshd stopped |

Test the thing itself rather than parsing prose: `command -v node`,
`node --version`, `python -c 'print(1)'` beat scraping formatted output.
