# Controlling the agent from the phone, with tools it cannot reach

The agent runs as the Termux Android user. Everything that user owns — the agent
tree, `~/.bashrc`, `~/.shortcuts`, even `sshd_config` — is writable **by the
agent**. So no on-device script, config file or shortcut can be a trustworthy
control surface: whatever you write there, the agent can rewrite.

What the agent cannot touch is anything owned by a *different* Android user.
That gives two real control planes, plus one switch that deliberately gives the
power away.

---

## 1. Android Settings — the OS owns this, and it is on your phone

This is the answer to "manage permissions on mobile with a tool the agent cannot
access". It is already installed, already enforced by the kernel and the
framework, and the agent has no path to it.

**Measured on the reference device**, the agent attempting to grant itself a
permission:

```
$ pm grant com.termux.api android.permission.RECORD_AUDIO
java.lang.SecurityException: grantRuntimePermission: Neither user 10337 nor
current process has android.permission.GRANT_RUNTIME_PERMISSIONS.
```

and the appop tool is not even present in Termux:

```
$ appops set --uid com.termux MANAGE_EXTERNAL_STORAGE allow
bash: appops: command not found
```

Granting requires a system-signed caller. The Termux uid is not one, and cannot
become one without root. **Every camera, location, microphone, contacts,
telephony and SMS permission is therefore already under your exclusive control.**
The agent can only *ask* — through a Termux:API call that raises an Android
dialog you answer.

> **One exception, and it is yours to make.** `android-adb enable` pairs the
> phone with its own adb, which runs as the `shell` uid (2000) — and *that* uid
> can call `pm grant`. While on-device adb is connected, everything in this
> section stops being true: the agent can grant itself any of those permissions
> with no dialog. It is off by default, needs you to type `ENABLE`, and
> `security/audit.sh` fails for as long as it is on. Verified on hardware:
> `android-adb shell whoami` → `shell`, uid 2000.
>
> If you want the guarantees in this document to hold, keep on-device adb off
> and use a USB host for screenshots instead.

### Where to go on the phone

**Settings → Apps → Termux:API → Permissions**

Toggle anything there and it takes effect immediately; the next
`android-camera` or `android-location` call fails with exit code 4. Also useful:

| screen | what it controls |
|---|---|
| Settings → Apps → **Termux:API** → Permissions | camera, location, microphone, contacts, phone, SMS |
| Settings → Apps → **Termux** → Permissions | storage; also "All files access" under Special app access |
| Settings → **Privacy** → Permission manager | the same grants, grouped by permission instead of by app |
| Settings → Apps → **Termux** → Force stop | stops the agent and its sshd immediately |
| Settings → **Developer options** → Revoke USB debugging authorisations | cuts the Mac's adb channel entirely |
| Settings → Apps → **Termux** → Battery → Restricted | stops Termux running in the background at all |

From the Mac you can jump straight to these:

```bash
aa settings termux-api     # the permission screen for Termux:API
aa settings termux         # Termux itself
aa settings privacy        # the permission manager
aa settings devopts        # Developer options
```

### The kill switch

Two taps, no computer, no command line:

1. **Settings → Apps → Termux → Force stop** — the agent and its SSH channel
   stop instantly.
2. **Settings → Developer options → Revoke USB debugging authorisations** — the
   Mac can no longer talk to the phone at all until you re-approve it.

Neither can be undone from inside Termux.

---

## 2. The Mac — physically outside the phone

The harness's own switches do not live on the phone at all:

| control | where it lives | why the agent cannot change it |
|---|---|---|
| `adb-read`, `adb-input`, `adb-grant` | `state/features.conf` on the Mac | different machine |
| the permission baseline | `state/policy.sha256` on the Mac | different machine |
| the SSH private key | `keys/` on the Mac | never copied to the phone |

So `aa permissions --disable adb-input` is enforced by a file the agent has no
route to. Even a fully compromised phone cannot re-enable it.

### Detecting tampering

The agent *can* rewrite its own config — for example, re-pointing sshd at
`0.0.0.0` to expose the control channel to the LAN. It cannot rewrite the record
of what those files should look like, because that record is on the Mac:

```bash
aa policy save     # baseline a device you trust
aa policy check    # compare, and say exactly what moved
```

`check` hashes `sshd_config`, `~/.bashrc`, `~/.ssh/authorized_keys`, every
shortcut and every agent command, and separately asserts the invariants that
matter: loopback-only listener, password auth off, `GatewayPorts` off, no
Termux:Boot scripts. It exits non-zero on drift.

Verified by actually doing it — with `ListenAddress` flipped to `0.0.0.0`:

```
config drift since the baseline
  changed or added: bf76003…  /usr/etc/ssh/sshd_config
invariants
  sshd ListenAddress is not loopback-only (0 of 1 lines)
POLICY DRIFT
```

There is a second, independent guard on the same failure: `android-agent-server`
reads the config before starting and refuses outright.

```
refusing to start: ListenAddress '0.0.0.0' is not loopback.
```

That refusal leaves sshd stopped, which is the safe direction. `aa server start`
recovers by typing the start command into Termux over adb, and `aa bootstrap`
rewrites the config block from scratch if it comes to that.

Run `aa policy check` whenever you want assurance — it is cheap, and it is the
only check in the system the phone cannot influence.

---

---

## 3. On-device ADB — maximum power, minimum guarantee

`android-adb enable` is the other direction entirely: instead of adding a
control plane above the agent, it hands the agent shell-uid power. Screenshots
and UI automation start working on the phone alone, and in exchange the boundary
in section 1 disappears.

Verified on the reference device: the phone paired with its own adb, took a
2400x1080 screenshot of itself, drove its own UI, and the manifest grew from 23
capabilities to 26. Disabling returned it to 23 and the audit to PASS.

Pairing is a guided, manual handshake by necessity: Termux's adb build has no
mDNS support (`adb mdns services` answers `unknown host service`), so it cannot
discover the randomised ports the way desktop adb does. `android-adb enable`
asks for them and tells you which screen each one is on.

Three things to know if you use it:

* **It appears twice.** A phone connected to its own adb shows as both
  `127.0.0.1:PORT` and `emulator-NNNN`, so a bare `adb shell` fails with "more
  than one device/emulator". The harness resolves the authorised transport and
  targets it with `-s`; if you call adb by hand, do the same.
* **Wireless debugging binds to Wi-Fi, not loopback.** `android-adb disable`
  drops the connection but deliberately cannot close that port — only you can,
  in Settings > Developer options. The audit keeps reporting it until you do.
* **The adb server is itself a listener**, on `127.0.0.1:5037`. Nothing in the
  harness starts it unless you have enabled on-device adb: capability probes are
  gated on that, because `adb devices` silently forks a server and a status
  check must not create a service. `pkill -x adb` stops a stray one.

## 4. A separate app — stronger on-device control, with a caveat

If you want on-device control beyond what Settings exposes — appops, disabling
packages, per-permission auditing without a computer — the usual route is
**Shizuku** plus a manager app such as App Ops or Canta. Shizuku runs as the
`shell` uid (2000), a different Android user from Termux, started once per boot
over wireless debugging.

Not installed on this phone, and worth thinking about before you do:

- **It cuts both ways.** Shizuku is an IPC service any app can request access to,
  Termux included. If you ever grant Termux access to Shizuku, the agent inherits
  shell-level power and can then grant itself every permission on this page. That
  would demolish the boundary the previous two sections rely on.
- If you install it, **never approve a Shizuku permission request from Termux**.
- Shizuku needs re-starting after every reboot unless you have root.

Note that on-device adb (section 3) gives the agent the same shell uid Shizuku
would, so if you have enabled that, this caveat has already applied.

Settings plus `aa policy check` covers everything this project needs. Shizuku is
worth it only if you want to manage permissions on the phone with no computer
anywhere in the loop, and are willing to keep that one rule.

---

## What this project deliberately does not do

- **No accessibility service.** It would be invisible in normal use, hard to
  audit, and would hand any process in Termux the ability to read and drive every
  screen. UI automation is done from the Mac over adb instead.
- **No helper APK.** A signed app of our own would be another uid to trust, and
  another thing to keep updated. Android Settings already is that app.
- **No root.** Nothing here needs it, and it would erase the uid boundary that
  makes section 1 true.

---

## Summary

All of the below assume on-device adb is **off**. With it on, the agent holds
the shell uid and the first four rows no longer hold.

| you want to... | use | agent can interfere? |
|---|---|---|
| revoke camera / location / mic / SMS | Settings → Apps → Termux:API → Permissions | **no** — provably, `pm grant` throws |
| stop the agent right now | Settings → Apps → Termux → Force stop | **no** |
| cut the Mac off | Developer options → Revoke USB debugging | **no** |
| stop background execution | Settings → Apps → Termux → Battery → Restricted | **no** |
| limit what the harness itself does | `aa permissions --disable adb-input` | **no** — the file is on the Mac |
| notice that config was tampered with | `aa policy check` | **no** — the baseline is on the Mac |
| edit shortcuts or the agent tree | on-device files | **yes** — same uid, treat as untrusted |
