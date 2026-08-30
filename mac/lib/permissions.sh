#!/usr/bin/env bash
# android-harness :: permission groups
#
# Sourced by mac/aa. Everything here runs through adb over USB, so every grant
# is owner-authorised, visible in Android Settings, and revocable with one
# command. Nothing is granted silently and nothing is granted that a group did
# not ask for.
#
# A group is one line: name|target|kind|items|risk|description
#   kind = perm    -> adb shell pm grant/revoke <target> <item>
#   kind = appop   -> adb shell appops set --uid <target> <item> allow|default
#   kind = builtin -> nothing to grant; Termux already has it. Listed so the
#                     report shows the whole picture rather than the gaps.
#   risk = safe | sensitive | dangerous

AA_PERM_GROUPS=(
  "storage|com.termux|builtin|READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE|safe|Shared storage: DCIM, Pictures, Download, Documents, Movies, Music"
  "notifications|com.termux.api|perm|android.permission.POST_NOTIFICATIONS|safe|Post notifications (android-notify)"
  "device-state|com.termux.api|builtin|-|safe|Battery, wifi info, volume, vibrate, clipboard, wake lock — no Android permission needed"

  "camera|com.termux.api|perm|android.permission.CAMERA|sensitive|Still capture (android-camera)"
  "location|com.termux.api|perm|android.permission.ACCESS_COARSE_LOCATION android.permission.ACCESS_FINE_LOCATION|sensitive|GPS and network location (android-location)"

  "microphone|com.termux.api|perm|android.permission.RECORD_AUDIO|sensitive|Audio recording"
  "sensors|com.termux.api|perm|android.permission.BODY_SENSORS|sensitive|Body sensors (heart rate and similar)"
  "contacts|com.termux.api|perm|android.permission.READ_CONTACTS|sensitive|Read the contact list"
  "telephony|com.termux.api|perm|android.permission.READ_PHONE_STATE android.permission.READ_CALL_LOG|sensitive|Phone state and call log"
  "write-settings|com.termux|appop|WRITE_SETTINGS|sensitive|Change system settings (android-brightness)"
  "usage-stats|com.termux|appop|GET_USAGE_STATS|sensitive|Which app is in the foreground"

  "sms|com.termux.api|perm|android.permission.READ_SMS android.permission.SEND_SMS|dangerous|Read AND send SMS — sending costs money"
  "all-files|com.termux|appop|MANAGE_EXTERNAL_STORAGE|dangerous|All-files access. Note: Android still blocks /Android/data and /Android/obb, so this usually changes nothing"
)

# Host-side adb capabilities. These are not Android permissions — they are
# switches on what this harness will do over the USB cable. Stored in
# state/features.conf and enforced by `aa`.
AA_FEATURE_GROUPS=(
  "adb-read|safe|Screenshots, UI hierarchy dumps, foreground/display state, package list (aa ui screenshot/dump/state/apps)"
  "adb-input|sensitive|Synthetic taps, swipes, text and key events, app launch (aa ui tap/swipe/text/key/launch)"
  "adb-grant|sensitive|Changing Android permissions from the host (aa grant, aa permissions)"
)

# Profiles. `default` is what a fresh install gets.
aa_profile_groups() {
  case "$1" in
    minimal)  echo "storage notifications device-state" ;;
    default)  echo "storage notifications device-state camera location" ;;
    extended) echo "storage notifications device-state camera location microphone sensors contacts telephony write-settings usage-stats" ;;
    full)     echo "storage notifications device-state camera location microphone sensors contacts telephony write-settings usage-stats sms all-files" ;;
    *)        return 1 ;;
  esac
}

aa_profile_features() {
  case "$1" in
    minimal)  echo "adb-read" ;;
    default)  echo "adb-read adb-input adb-grant" ;;
    extended) echo "adb-read adb-input adb-grant" ;;
    full)     echo "adb-read adb-input adb-grant" ;;
    *)        return 1 ;;
  esac
}

# --- group table access ----------------------------------------------------
aa_group_field() { # aa_group_field <name> <1..6>
  local g
  for g in "${AA_PERM_GROUPS[@]}"; do
    case "$g" in "$1|"*) printf '%s' "$(echo "$g" | cut -d'|' -f"$2")"; return 0 ;; esac
  done
  return 1
}

aa_group_names() {
  local g
  for g in "${AA_PERM_GROUPS[@]}"; do printf '%s\n' "${g%%|*}"; done
}

aa_feature_field() { # aa_feature_field <name> <1..3>
  local f
  for f in "${AA_FEATURE_GROUPS[@]}"; do
    case "$f" in "$1|"*) printf '%s' "$(echo "$f" | cut -d'|' -f"$2")"; return 0 ;; esac
  done
  return 1
}

# --- live state ------------------------------------------------------------
# Reads the real state from the device rather than trusting a stored file, so
# a permission revoked in Settings shows up here immediately.
aa_group_state() { # aa_group_state <name> -> granted | partial | denied | n/a
  local name="$1" target kind items item got=0 total=0
  target="$(aa_group_field "$name" 2)" || return 1
  kind="$(aa_group_field "$name" 3)"
  items="$(aa_group_field "$name" 4)"

  [ "$kind" = builtin ] && { echo "n/a"; return 0; }

  if [ "$kind" = appop ]; then
    local out
    # </dev/null matters: this runs inside `while read` loops, and adb would
    # otherwise swallow the loop's stdin and truncate the iteration.
    out="$(adb shell "appops get $target $items" </dev/null 2>/dev/null | tr -d '\r')"
    case "$out" in *": allow"*) echo granted ;; *) echo denied ;; esac
    return 0
  fi

  local dump
  dump="$(adb shell "dumpsys package $target" </dev/null 2>/dev/null | tr -d '\r')"
  for item in $items; do
    total=$((total+1))
    printf '%s\n' "$dump" | grep -q "$item: granted=true" && got=$((got+1))
  done
  if   [ "$got" -eq 0 ];      then echo denied
  elif [ "$got" -eq "$total" ];then echo granted
  else echo partial; fi
}

# --- apply -----------------------------------------------------------------
aa_group_apply() { # aa_group_apply <name> allow|deny
  local name="$1" action="$2" target kind items item rc=0
  target="$(aa_group_field "$name" 2)" || { echo "unknown group: $name" >&2; return 2; }
  kind="$(aa_group_field "$name" 3)"
  items="$(aa_group_field "$name" 4)"

  [ "$kind" = builtin ] && return 0

  if [ "$kind" = appop ]; then
    local mode=default
    [ "$action" = allow ] && mode=allow
    adb shell "appops set --uid $target $items $mode" </dev/null >/dev/null 2>&1 || rc=1
    return $rc
  fi

  for item in $items; do
    if [ "$action" = allow ]; then
      adb shell "pm grant $target $item" </dev/null >/dev/null 2>&1 || rc=1
    else
      adb shell "pm revoke $target $item" </dev/null >/dev/null 2>&1 || rc=1
    fi
  done
  return $rc
}

# --- host feature switches -------------------------------------------------
aa_features_load() {
  AA_FEATURES_ENABLED="$(cat "$STATE_DIR/features.conf" 2>/dev/null | tr '\n' ' ')"
  [ -n "${AA_FEATURES_ENABLED// /}" ] || AA_FEATURES_ENABLED="$(aa_profile_features default)"
}

aa_features_save() { # aa_features_save "name name ..."
  # Deliberate word splitting: one feature name per line.
  # shellcheck disable=SC2086
  printf '%s\n' $1 > "$STATE_DIR/features.conf"
  chmod 600 "$STATE_DIR/features.conf"
}

aa_feature_on() { # aa_feature_on <name>
  aa_features_load
  case " $AA_FEATURES_ENABLED " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# aa_require_feature <name> <what-was-attempted> — used to gate `aa` subcommands.
aa_require_feature() {
  aa_feature_on "$1" && return 0
  c_red "refused: '$2' needs the '$1' host feature, which is switched off." >&2
  c_dim "enable it with: aa permissions --enable $1" >&2
  exit 1
}
