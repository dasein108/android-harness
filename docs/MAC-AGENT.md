# Mac-side agent workflow

This is the procedure an LLM agent on the Mac follows to take a phone from
"Termux is installed" to "verified, reproducible agent environment", and to keep
it that way afterwards.

Everything below runs over the USB cable. Nothing needs the phone and the Mac to
share a network.

---

## 0. Preconditions to verify, not assume

```bash
command -v adb || brew install --cask android-platform-tools
adb devices -l                 # exactly one line ending in `device`
```

If the device shows `unauthorized`, the owner must approve the USB debugging
prompt on the phone. If it shows nothing, it is the cable or the USB mode.

On the phone: Termux and Termux:API installed (F-Droid or GitHub releases, and
they must be from the *same* source or the signatures will not match), screen
**unlocked** — `bootstrap` types into the Termux UI and a keyguard blocks it:

```bash
adb shell dumpsys window | grep -m1 isKeyguardShowing     # want: false
adb shell dumpsys power  | grep -m1 mWakefulness=         # want: Awake
```

## 1. Inspect the current state

```bash
./mac/aa doctor
```

`doctor` reports the host tools, the device identity, Android version and ABI,
whether the Termux packages are present, the control key's fingerprint, the adb
forward and whether ssh actually answers. It does not change anything.

If the harness has run before, `state/device.env` already holds the phone's
Termux login name and ssh works immediately — skip straight to step 4.

## 2. Back up what you are about to touch

The installer only ever modifies two files outside its own tree, and it backs up
the one that matters:

* `$PREFIX/etc/ssh/sshd_config` → copied to `sshd_config.aa-orig` on first run.
* `~/.bashrc` → gains one marked block, removed cleanly by `uninstall.sh`.

If you want a wider safety net before a first provision:

```bash
./mac/aa shell 'tar czf ~/pre-harness-backup.tgz ~/.bashrc ~/.termux 2>/dev/null; ls -l ~/pre-harness-backup.tgz'
```

## 3. Bootstrap the control channel (first run only)

```bash
./mac/aa bootstrap
```

What it does, in order: pushes `device/bootstrap.sh` and the **public** key to
`/sdcard/Download`; launches Termux; types
`bash /sdcard/Download/aa-bootstrap.sh` and Enter; polls
`/sdcard/Download/aa-bootstrap.log` for a result line; reads the phone's Termux
username out of that log; deletes both pushed files; sets up `adb forward`; and
proves the channel with a round-trip `echo`.

The phone may show a storage-permission dialog on the very first run. It needs a
human tap. If `bootstrap` times out, open Termux and read what is on screen —
the same output is in `/sdcard/Download/aa-bootstrap.log`.

Why typing into the UI at all: Termux's `RUN_COMMAND` service requires the
`com.termux.permission.RUN_COMMAND` permission, which the adb `shell` user does
not hold, and `/data/data/com.termux` is unreadable to it. Typing one command is
the only bootstrap path that needs no root and no extra app.

## 4. Provision

```bash
./mac/aa provision            # add --media for imagemagick/ffmpeg/poppler
```

`install.sh` is idempotent: it detects what already works, installs only what is
missing, and validates each component functionally. Re-run it freely — after a
Termux upgrade, after a failed step, or to pick up harness changes.

It prints a numbered step log and ends with `INSTALL_RESULT=OK` or `FAIL`
followed by the specific failures. A failure never gets reported as success.

## 5. Grant the permissions the owner wants

Camera and location are runtime permissions on Termux:API and start denied:

```bash
./mac/aa grant camera
./mac/aa grant location
./mac/aa shell 'android-agent-manifest --refresh'
```

These are owner-authorized grants through adb. They are visible in Android's
Settings and revocable with `adb shell pm revoke com.termux.api <permission>`.

## 6. Validate

```bash
./mac/aa test           # non-intrusive
./mac/aa test --full    # also camera, notification, vibration, clipboard
./mac/aa audit          # host listener audit + device security audit
```

Two of these checks can only be trusted from the host, and the device-side suite
says so rather than passing vacuously:

* **listeners** — an untrusted_app uid cannot read `/proc/net/tcp` or open the
  netlink socket `ss` needs, so the device sees an empty table. `aa netaudit`
  reads `/proc/net` via adb and attributes every socket to a package.
* **camera** — Android denies the camera to background apps, and Termux:API
  signals that as an empty file, not an error. Run `aa ui launch com.termux`
  before `aa test --full` if the camera test skips.

`test` is functional throughout: it writes and reads real files, runs a real
Python script and a real Node script, exercises the Android bridge, and checks
that no listener binds beyond loopback. Capabilities that are genuinely
unavailable report `SKIP` with the reason.

## 7. Repair

| test failure | first thing to try |
|---|---|
| `python` / `node` FAIL | `./mac/aa provision` again; read `~/android-agent/logs/install.log` |
| every `termux-*` SKIPs | Termux:API app missing, or battery optimisation is killing it |
| `camera` SKIP | `./mac/aa grant camera`, then `./mac/aa ui launch com.termux` — Android blocks the camera for background apps |
| `location` SKIP | `./mac/aa grant location`, and the phone needs a last-known fix |
| `shared-storage` SKIP | `./mac/aa shell termux-setup-storage`, then approve on the phone |
| `claude-version` FAIL | see `docs/CLAUDE-CODE.md` — check `file` on the resolved binary |
| `sshd` FAIL | `./mac/aa server start`; if it refuses, the config no longer binds loopback |
| `no-external-listener` SKIP | expected: the device cannot enumerate sockets. Run `./mac/aa netaudit` for the real answer |
| `netaudit` FAIL | a harness-owned socket bound beyond loopback — stop and investigate before anything else |

Re-run `./mac/aa test` after each repair rather than assuming the fix took.

## 8. Final report

```bash
./mac/aa report > report.txt
```

Combines the host view, the device status, the capability manifest, the test
suite and the security audit, ending with the audit's report block:

```
LOCAL ACCESS: ...
INTERNET-EXPOSED CONTROL: ...
LISTENING PORTS: ...
PERSISTENT SERVICES: ...
ANDROID CAPABILITIES: ...
PYTHON / NODE / CLAUDE / SHARED STORAGE / UI AUTOMATION: ...
SECURITY AUDIT: PASS|FAIL
```

Do not report success while the audit says FAIL.

## 9. Leave it reproducible

The phone's state is fully described by this repo plus two facts in
`state/device.env`. Re-running `bootstrap` + `provision` on a wiped Termux
reproduces it. Nothing depends on manual steps that are not in `install.sh`.

---

## Rules for the Mac-side agent

* Test assumptions instead of trusting them: `command -v`, `--version`, an
  actual round-trip. Never parse prose when a functional check exists.
* Do not reset components that already work. `provision` is the safe verb;
  `reset` is not.
* Never widen the listener. If something needs to be reachable from the LAN,
  stop and ask the owner — the answer is almost always another `adb forward`.
* Do not delete user data. Shared storage, DCIM, Documents and Downloads belong
  to the owner; the harness only writes to `~/android-agent`.
* UI automation moves a real phone that a person may be holding. Capture state
  before and after (`aa ui screenshot`, `aa ui dump`), and stay out of anything
  that spends money or sends messages unless that is the task.
