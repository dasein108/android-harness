#!/usr/bin/env bash
# android-harness :: `aa policy` — tamper detection for the device-side config.
# Sourced by mac/aa.
#
# Why this exists. The agent runs as the Termux uid, so every file it depends on
# — sshd_config, ~/.bashrc, ~/.shortcuts, the agent tree — is writable by the
# agent itself. Nothing stored on the phone can be made tamper-proof against it.
#
# What is out of its reach is this Mac. The baseline lives here, in state/, and
# the comparison runs here. An agent that quietly re-pointed sshd at 0.0.0.0 or
# rewrote a shortcut cannot also edit the record of what those files should be.
#
# This detects tampering. It does not prevent it — prevention for Android
# permissions is Android's own job, and the agent provably cannot grant itself
# any (pm grant fails with SecurityException from the Termux uid).

AA_POLICY_FILE="$STATE_DIR/policy.sha256"

aa_policy_collect() {
  ensure_forward
  dev_ssh '
    for f in "$PREFIX/etc/ssh/sshd_config" "$HOME/.bashrc" "$HOME/.ssh/authorized_keys"; do
      [ -f "$f" ] && sha256sum "$f"
    done
    for f in "$HOME"/.shortcuts/* "$HOME"/android-agent/bin/*; do
      [ -f "$f" ] && sha256sum "$f"
    done
    [ -d "$HOME/.termux/boot" ] && for f in "$HOME"/.termux/boot/*; do
      [ -f "$f" ] && sha256sum "$f"
    done
    exit 0
  ' 2>/dev/null | sed 's#/data/data/com.termux/files##' | sort -k2
}

# Invariants that must hold no matter what the hashes say.
aa_policy_invariants() {
  ensure_forward
  dev_ssh '
    conf="$PREFIX/etc/ssh/sshd_config"
    # No `|| echo 0` here: `grep -c` already prints 0 when it matches nothing,
    # and also exits 1, so the fallback would append a second line and split the
    # summary across three lines.
    la="$(grep -icE "^[[:space:]]*ListenAddress[[:space:]]+(127\.0\.0\.1|::1)$" "$conf" 2>/dev/null)"
    other="$(grep -icE "^[[:space:]]*ListenAddress[[:space:]]+" "$conf" 2>/dev/null)"
    pw="$(grep -icE "^[[:space:]]*PasswordAuthentication[[:space:]]+yes" "$conf" 2>/dev/null)"
    gw="$(grep -icE "^[[:space:]]*GatewayPorts[[:space:]]+yes" "$conf" 2>/dev/null)"
    boot="$(ls -A "$HOME/.termux/boot" 2>/dev/null | wc -l)"
    keys="$(wc -l < "$HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)"
    echo "loopback_listen=${la:-0} other_listen=${other:-0} password_auth=${pw:-0} gateway_ports=${gw:-0} boot_scripts=${boot:-0} authorized_keys=${keys:-0}"
  ' 2>/dev/null
}

cmd_policy() {
  case "${1:-check}" in
    -h|--help)
      cat <<'USAGE'
usage: aa policy save     record what the device config looks like right now
       aa policy check    compare the device against that record (default)
       aa policy show     print the stored baseline

The baseline lives on this Mac, in state/policy.sha256 — outside the agent's
reach. `check` is how you find out whether anything on the phone changed the
files that decide what the harness can do.
USAGE
      ;;

    save)
      local now; now="$(aa_policy_collect)"
      [ -n "$now" ] || die "could not read the device config"
      printf '%s\n' "$now" > "$AA_POLICY_FILE"
      chmod 600 "$AA_POLICY_FILE"
      c_grn "baseline saved: $(printf '%s\n' "$now" | grep -c .) files -> $AA_POLICY_FILE"
      aa_policy_invariants | sed 's/^/  /' ;;

    show)
      [ -f "$AA_POLICY_FILE" ] || die "no baseline yet (aa policy save)"
      cat "$AA_POLICY_FILE" ;;

    check)
      [ -f "$AA_POLICY_FILE" ] || die "no baseline yet — run 'aa policy save' on a device you trust"
      local now rc=0
      now="$(aa_policy_collect)"
      [ -n "$now" ] || die "could not read the device config"

      echo "config drift since the baseline"
      local diff_out
      diff_out="$(diff <(cat "$AA_POLICY_FILE") <(printf '%s\n' "$now") || true)"
      if [ -z "$diff_out" ]; then
        c_grn "  none — every tracked file matches"
      else
        printf '%s\n' "$diff_out" | while read -r l; do
          case "$l" in
            "> "*) c_red   "  changed or added: ${l#> }" ;;
            "< "*) c_dim   "  was:              ${l#< }" ;;
          esac
        done
        rc=1
      fi

      echo
      echo "invariants"
      local inv; inv="$(aa_policy_invariants)"
      local loopback other pw gw boot keys
      loopback="$(printf '%s' "$inv" | sed -n 's/.*loopback_listen=\([0-9]*\).*/\1/p')"
      other="$(printf '%s' "$inv"    | sed -n 's/.*other_listen=\([0-9]*\).*/\1/p')"
      pw="$(printf '%s' "$inv"       | sed -n 's/.*password_auth=\([0-9]*\).*/\1/p')"
      gw="$(printf '%s' "$inv"       | sed -n 's/.*gateway_ports=\([0-9]*\).*/\1/p')"
      boot="$(printf '%s' "$inv"     | sed -n 's/.*boot_scripts=\([0-9]*\).*/\1/p')"
      keys="$(printf '%s' "$inv"     | sed -n 's/.*authorized_keys=\([0-9]*\).*/\1/p')"

      if [ "${loopback:-0}" -ge 1 ] && [ "${loopback:-0}" = "${other:-0}" ]; then
        c_grn "  sshd binds loopback only"
      else
        c_red "  sshd ListenAddress is not loopback-only ($loopback of $other lines)"; rc=1
      fi
      [ "${pw:-0}" = 0 ] && c_grn "  password auth off" || { c_red "  password auth is ON"; rc=1; }
      [ "${gw:-0}" = 0 ] && c_grn "  GatewayPorts off" || { c_red "  GatewayPorts is ON"; rc=1; }
      [ "${boot:-0}" = 0 ] && c_grn "  no Termux:Boot scripts" || { c_red "  $boot Termux:Boot script(s) present"; rc=1; }
      c_dim "  authorized keys: ${keys:-?}"

      echo
      if [ "$rc" -eq 0 ]; then
        c_grn "POLICY OK"
      else
        c_red "POLICY DRIFT — review the changes above."
        c_dim "If you made them, re-baseline with: aa policy save"
      fi
      return "$rc" ;;

    *) die "usage: aa policy save|check|show" ;;
  esac
}

# ---------------------------------------------------------------------------
# `aa settings` — open the Android screens where the owner, not the agent,
# decides what is allowed. These are system-owned UIs; nothing in Termux can
# change what they set.
cmd_settings() {
  need adb; adb_one
  local what="${1:-help}"
  local act="" dat=""
  case "$what" in
    termux-api) act=android.settings.APPLICATION_DETAILS_SETTINGS; dat="package:com.termux.api" ;;
    termux)     act=android.settings.APPLICATION_DETAILS_SETTINGS; dat="package:com.termux" ;;
    apps)       act=android.settings.MANAGE_APPLICATIONS_SETTINGS ;;
    privacy)    act=android.settings.PRIVACY_SETTINGS ;;
    devopts)    act=android.settings.APPLICATION_DEVELOPMENT_SETTINGS ;;
    *)
      cat <<'USAGE'
usage: aa settings termux-api | termux | apps | privacy | devopts

Opens the Android screen on the phone. These are the controls the agent cannot
touch — the OS owns them:

  termux-api   permissions for the Termux:API app (camera, location, mic, ...)
  termux       permissions and battery settings for Termux itself
  apps         the full app list
  privacy      privacy dashboard: permission manager, usage
  devopts      Developer options — revoke USB debugging authorisations here to
               cut the Mac's adb channel entirely
USAGE
      return 2 ;;
  esac

  if [ -n "$dat" ]; then
    adb shell am start -a "$act" -d "$dat" >/dev/null 2>&1 || die "could not open that screen"
  else
    adb shell am start -a "$act" >/dev/null 2>&1 || die "could not open that screen"
  fi
  c_grn "opened on the phone: $what"
}
