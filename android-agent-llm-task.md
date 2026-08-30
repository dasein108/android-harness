# Task: Build a Full-Featured, Secure Android Agent Harness for Termux

## Mission

Modify and extend the existing `termux-claude-code` installation approach so that an LLM coding agent running on a Mac can connect to an Android phone over a deliberately configured local/USB channel and fully provision, operate, test, and maintain a **full-featured Android Agent**.

The end state should be a powerful local agent with broad control over the phone, its filesystem, Termux, Linux userland, Python, Node.js, and Android-facing APIs — while being **strictly protected against unsolicited external access, remote exposure, persistence mechanisms, hidden backdoors, and accidental network exposure**.

The owner explicitly trusts the agent and wants the agent to have broad/full operational rights on the device. This trust applies only to the owner-controlled agent path. It does **not** authorize opening inbound access to the Internet, exposing services publicly, weakening Android security controls unnecessarily, installing covert persistence, or creating any backdoor.

---

# 1. Server / Agent Infrastructure

Build a robust local server/harness layer that allows an authorized LLM agent on the Mac to control the Android-side environment.

## Requirements

### 1.1 Transport

Support a secure owner-controlled connection such as:

- USB-connected Mac ↔ Android
- SSH over an explicitly configured USB/local tunnel
- ADB port forwarding where appropriate
- Localhost-only listeners where possible

Prefer **USB/local transport over LAN/Internet exposure**.

Do not expose an agent control port on `0.0.0.0` unless there is a compelling technical reason and the exposure is explicitly documented and protected.

Default to:

- `127.0.0.1`
- USB forwarding
- ADB forwarding
- Unix domain sockets where practical

### 1.2 Authentication

The server must require explicit authentication.

Preferred:

- SSH public-key authentication
- device-local credentials/keys
- cryptographically strong random tokens if an HTTP API is unavoidable

Never use:

- hard-coded passwords
- default passwords
- predictable tokens
- unauthenticated control endpoints

The provisioning script must generate credentials/keys securely when required and set restrictive permissions.

### 1.3 Network security

The agent server must be safe against external access.

Requirements:

- no public Internet listener
- no UPnP port mapping
- no automatic router configuration
- no reverse tunnel to an external server
- no hidden relay
- no telemetry/control channel unless explicitly required and documented
- no cloud callback used for command execution
- no hard-coded external command-and-control endpoint
- no silently opened firewall ports
- no DNS-based command/control
- no download-and-execute behavior from arbitrary remote URLs

If a network service is needed, bind it to the narrowest possible interface.

### 1.4 Process isolation

Separate the control server from the agent execution environment where practical.

Provide:

- explicit environment variables
- controlled PATH
- predictable working directories
- clear process ownership
- PID/status commands
- clean start/stop/restart operations
- logs stored locally

Avoid unnecessary root execution.

Where Android/Termux permissions permit, use the minimum OS privileges necessary for each component. The agent itself can have broad access within the owner's Termux environment.

### 1.5 Agent execution

The LLM agent should be able to:

- execute shell commands
- run Python
- run Node.js
- run arbitrary scripts created by the owner/agent
- install packages
- create files/directories
- edit configuration
- inspect processes
- inspect logs
- interact with Termux
- invoke Android-facing APIs
- start/stop its own services
- build/install its own tooling

The design should not artificially cripple the trusted agent inside the owner-controlled environment.

However, the agent must not interpret "full rights" as permission to create external persistence or network access.

---

# 2. Android Phone Harness

Create a structured Android harness exposing the capabilities needed by an LLM agent.

## 2.1 Filesystem

Provide reliable access to:

### Termux private filesystem

- `$HOME`
- configuration
- installed tools
- scripts
- logs
- agent workspace

### Android shared storage

After explicit Android storage permission:

- `~/storage/shared`
- `DCIM`
- `Pictures`
- `Download`
- `Documents`
- `Movies`
- `Music`

The agent should be able to:

- read files
- create files
- modify files
- rename/move files
- delete files
- search files
- inspect metadata
- process images/videos/documents
- generate output files

Do not delete or reset user storage during provisioning.

---

# 2.2 Python environment

Install and configure a usable Python environment.

Requirements:

- Python 3
- pip
- venv
- ability to create isolated environments
- ability to execute arbitrary Python scripts created by the trusted agent
- useful standard CLI tooling

Example:

```text
~/agent/
~/agent/work/
~/agent/scripts/
~/agent/venvs/
~/agent/output/
~/agent/logs/
```

The agent should be able to create a venv:

```bash
python -m venv ~/agent/venvs/project
```

and install packages as required.

Avoid globally installing arbitrary Python packages when a venv is sufficient.

---

# 2.3 Node.js

Install/configure Node.js and npm.

Requirements:

- current stable/LTS version compatible with the target tools
- npm
- ability to execute Node scripts
- global package installation when required
- project-local npm packages
- npm scripts

Do not blindly upgrade/downgrade an existing working Node installation. Detect the current environment first.

---

# 2.4 Claude Code

Modify the existing `termux-claude-code` approach so Claude Code runs correctly on Android/Termux.

Important:

Anthropic's native Claude Code package may expect a Linux binary that is not directly compatible with Android's execution environment.

Use the proven Termux compatibility strategy:

- glibc userspace where required
- glibc runner/loader
- official Linux ARM64 Claude Code binary where appropriate
- correct PATH handling
- correct executable resolution
- correct shell/tool execution
- correct handling of arguments and spaces
- correct `CLAUDE_CODE_EXECPATH` behavior if required

Do NOT accidentally install the Android-incompatible native package and assume it works.

Before changing anything:

```bash
uname -m
uname -a
node -p 'process.platform'
node -p 'process.arch'
which node
which npm
which claude
```

Verify every assumption.

---

# 2.5 Termux:API / Android bridge

Provide a clean command layer for Android functionality.

At minimum investigate and, where available, support:

- battery status
- Wi-Fi information
- location
- camera
- screenshot
- clipboard read/write
- notifications
- vibration
- volume
- brightness
- opening URLs/files
- sharing files
- waking/unwaking the device

Create predictable commands such as:

```text
android-battery
android-location
android-camera
android-screenshot
android-clipboard-get
android-clipboard-set
android-notify
android-vibrate
android-wifi
android-open
android-share
android-volume
android-brightness
```

Each command should:

- return useful exit codes
- print machine-readable output where appropriate
- avoid leaking secrets
- fail clearly if Termux:API or Android permissions are unavailable

---

# 2.6 Android UI control

Investigate a safe owner-controlled UI automation layer.

Potential technologies:

- ADB
- Android Accessibility
- Termux:API
- Android intents
- `input` / shell commands where legitimately available
- dedicated local helper applications if necessary

Goal:

The trusted agent should eventually be able to:

1. inspect the current device state
2. capture a screenshot
3. identify UI elements
4. launch an application
5. interact with supported UI controls
6. enter text
7. press buttons
8. navigate
9. capture the resulting state
10. continue autonomously

Do not bypass Android security protections unnecessarily.

Do not install hidden accessibility services.

Any helper application must be transparent, locally installed, auditable, and clearly documented.

---

# 2.7 Device information

Expose useful read-only diagnostics:

- Android version
- device model
- architecture
- battery
- storage
- memory
- CPU
- thermal state where available
- network state
- Wi-Fi state
- current foreground app where legitimately accessible
- Termux version
- API availability
- Python version
- Node version
- Claude Code version

Create a command such as:

```bash
android-agent-status
```

that outputs a concise diagnostic report.

---

# 3. Installation / Provisioning System

Create one robust installer/provisioner.

The installer must be **idempotent**.

It must be safe to run repeatedly.

It must:

1. detect existing installations
2. preserve working components
3. avoid duplicate configuration
4. avoid reinstalling things unnecessarily
5. validate every major step
6. stop on serious errors
7. provide actionable diagnostics
8. never claim success if a component is broken

Do not determine state by fragile parsing of human-readable output when a direct functional test is available.

Example:

```bash
command -v node
node --version
python --version
```

is preferable to parsing arbitrary formatted output.

For containers, services, binaries, and APIs, test the actual functionality.

---

# 4. Reset / Recovery

Provide a safe reset mechanism.

Separate:

### Soft reset

Removes only agent-generated configuration and temporary state.

### Full agent reset

Removes:

- agent configuration
- agent binaries
- generated launchers
- agent workspaces if explicitly requested

But preserves:

- Android shared storage
- user photos
- user documents
- unrelated Termux data unless explicitly requested

Never silently run:

```text
rm -rf ~/storage/shared
```

or equivalent.

Never reset Android or wipe the device.

---

# 5. Security Model

This is a core requirement.

## The trusted agent has broad rights

Inside the owner-controlled environment, the agent may:

- install software
- modify files
- run scripts
- configure services
- use Python
- use Node
- interact with Android APIs
- manage its own environment

## But the infrastructure must not create backdoors

Explicitly prohibit:

- hidden reverse shells
- persistent remote shells
- undocumented listening ports
- Internet-exposed agent APIs
- hard-coded C2 servers
- arbitrary external callback URLs
- reverse SSH tunnels created automatically
- Tor/onion exposure
- UPnP exposure
- embedded credentials
- hard-coded private keys
- secret admin accounts
- hidden users
- stealth persistence
- cryptocurrency miners
- undisclosed telemetry
- credential harvesting
- browser/session-token exfiltration
- remote kill switches
- remote update mechanisms that execute arbitrary code
- downloading arbitrary scripts and executing them without verification

External network access should be **outbound-only and only when needed for legitimate package installation, API access, or user-requested tasks**.

No service should accept unsolicited commands from the Internet.

---

# 6. Supply-chain Security

Do not blindly trust downloaded installation scripts.

For every external component:

1. identify its source
2. inspect the installation logic
3. record the URL/repository
4. prefer official releases
5. verify checksums/signatures when available
6. pin versions where practical
7. avoid unnecessary third-party binaries

The installer should make external dependencies visible.

Do not implement:

```bash
curl URL | bash
```

for arbitrary/unreviewed sources unless there is no practical alternative and the source has been inspected.

Prefer:

```bash
curl -fL URL -o file
```

then inspect/verify before execution.

---

# 7. Configuration / Environment

Create a clear directory structure.

Suggested:

```text
~/android-agent/
    bin/
    scripts/
    config/
    logs/
    workspace/
    tools/
    python/
    node/
    tmp/
```

Keep generated files separated from user files.

Create a clear environment file if necessary:

```text
~/android-agent/config/environment
```

Do not place secrets in shell history.

Do not print tokens/passwords/private keys in logs.

Set restrictive permissions:

```bash
chmod 700
chmod 600
```

where appropriate.

---

# 8. Agent Manifest

Create a machine-readable manifest describing available capabilities.

For example:

```json
{
  "name": "android-agent",
  "version": "1.0.0",
  "platform": "android-termux",
  "capabilities": [
    "filesystem",
    "python",
    "node",
    "shell",
    "camera",
    "screenshot",
    "clipboard",
    "notifications",
    "battery",
    "wifi",
    "location",
    "ui-automation"
  ]
}
```

The actual manifest should only advertise capabilities that are verified as working.

---

# 9. Claude Instructions

Create a `CLAUDE.md` specifically for the Android Agent.

It should explain:

- device architecture
- agent root
- filesystem paths
- Android shared storage path
- available commands
- Python environment
- Node environment
- Claude Code execution model
- how to inspect device state
- how to capture screenshots
- how to use Android APIs
- how to start/stop the server
- security rules
- no external exposure
- no hidden persistence
- no backdoors
- how to diagnose failures

The instructions should tell the agent:

> You are trusted by the device owner and may perform broad local operations required to accomplish the user's task. You must not create hidden external access, expose control services to untrusted networks, install backdoors, or establish undocumented persistence. Keep control local/owner-authorized.

---

# 10. Mac-Side Control Agent

Create a documented workflow for the Mac-side LLM agent.

Goal:

The Mac agent should be able to connect to a freshly provisioned Android phone and perform the entire setup autonomously.

Expected workflow:

```text
Mac LLM Agent
      |
      | USB / ADB / SSH
      v
Android / Termux
      |
      v
Provisioner
      |
      +--> Termux packages
      +--> Python
      +--> Node
      +--> Claude Code
      +--> glibc compatibility
      +--> Android bridge
      +--> filesystem
      +--> UI automation
      +--> diagnostics
      |
      v
Full Android Agent
```

The Mac agent should:

1. inspect the current device state
2. back up relevant configuration if appropriate
3. detect existing components
4. install missing components
5. configure them
6. validate each component
7. repair failures
8. run an end-to-end test
9. produce a final report
10. leave the phone in a reproducible state

The Mac agent should not blindly reset working components.

---

# 11. End-to-End Test Suite

Create automated tests.

At minimum:

### Shell

```bash
echo hello
```

### Filesystem

Create/read/modify/delete a test file.

### Shared storage

Read and write a temporary test file under:

```text
~/storage/shared/
```

### Python

```bash
python -c 'print("python-ok")'
```

### Node

```bash
node -e 'console.log("node-ok")'
```

### Termux:API

Test available APIs individually.

### Camera

If permission exists, capture a test image.

### Screenshot

Capture a test screenshot.

### Clipboard

Write/read a test value.

### Notification

Generate a test notification.

### Claude

Run:

```bash
claude --version
```

and then a minimal non-destructive Claude invocation.

### Connectivity

Verify that no unintended listening service is exposed.

Check:

```bash
ss -lntup
```

or the appropriate Android/Termux equivalent.

The final test should explicitly report:

- listeners
- bind addresses
- exposed ports
- active agent processes
- external connections where observable

---

# 12. Final Security Audit

Before declaring the project complete, audit the resulting installation.

Search for:

- unexpected network listeners
- suspicious shell startup entries
- unknown cron/background jobs
- unexpected Termux boot persistence
- unknown binaries
- hard-coded credentials
- private keys
- external callback URLs
- reverse tunnels
- suspicious downloads
- undocumented services

Document every intentional persistent component.

The final report must state:

```text
LOCAL ACCESS:
YES/NO

INTERNET-EXPOSED CONTROL:
YES/NO

LISTENING PORTS:
...

PERSISTENT SERVICES:
...

ANDROID CAPABILITIES:
...

PYTHON:
...

NODE:
...

CLAUDE:
...

SHARED STORAGE:
...

UI AUTOMATION:
...

SECURITY AUDIT:
PASS/FAIL
```

Do not declare PASS if any unexplained external listener or persistence mechanism exists.

---

# 13. Deliverables

Produce:

1. Updated installer
2. Uninstaller/reset script
3. Android Agent launcher
4. Server/control layer
5. Android command harness
6. Python environment setup
7. Node.js setup
8. Claude Code integration
9. Android UI automation integration where feasible
10. `CLAUDE.md`
11. machine-readable capability manifest
12. diagnostics command
13. automated test suite
14. security audit script
15. Mac-side setup/control instructions
16. README with architecture and recovery procedures

All scripts must be readable and auditable.

Avoid unnecessary complexity.

---

# 14. Engineering Rules

Before changing the system:

```bash
uname -a
uname -m
id
pwd
echo "$PATH"
command -v node
command -v npm
command -v python
command -v claude
```

Inspect the actual environment.

Do not assume:

- Ubuntu exists
- Node is installed
- Node is in `/usr/bin`
- Claude is installed
- Termux PATH is normal
- Android storage is available
- Termux:API permissions exist
- ADB is configured
- Accessibility is enabled

Every assumption must be tested.

Prefer functional checks over parsing human-readable command output.

Do not use destructive commands unless explicitly required.

Before destructive operations, distinguish:

- user data
- system/tool data
- agent-generated data

Never delete user data as part of normal setup.

---

# Definition of Done

The project is complete when a trusted LLM agent on the Mac can connect to the Android phone through an owner-controlled USB/local channel and, from a clean Termux installation, autonomously provision and verify:

- secure local server/control channel
- Termux
- Android shared storage access
- Python + pip + venv
- Node.js + npm
- Claude Code using a working Android/Termux-compatible Linux ARM64 execution strategy
- Termux:API Android bridge
- camera
- screenshots
- clipboard
- notifications
- battery
- Wi-Fi
- location where permitted
- file operations
- arbitrary trusted Python scripts
- arbitrary trusted Node scripts
- shell execution
- UI automation where technically feasible
- diagnostics
- automated tests

And, critically:

**The resulting installation must not expose an unauthenticated or externally reachable control interface, must not create a hidden backdoor, and must not establish undocumented remote persistence.**

The owner wants maximum local agent capability with minimum external attack surface.

When choosing between a more powerful implementation and a more exposed implementation, choose the powerful **local** implementation.
