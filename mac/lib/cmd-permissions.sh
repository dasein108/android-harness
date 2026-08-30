#!/usr/bin/env bash
# android-harness :: `aa permissions` — inspect and change what the agent may do.
# Sourced by mac/aa.

aa_perm_usage() {
  cat <<'USAGE'
usage: aa permissions [show]                 what is granted right now (default)
       aa permissions --profile NAME         apply a profile
       aa permissions --pick                 interactive picker, defaults preselected
       aa permissions --grant  a,b,c         grant these groups
       aa permissions --revoke a,b,c         revoke these groups
       aa permissions --enable  adb-input    switch a host feature on
       aa permissions --disable adb-input    switch a host feature off
       aa permissions --groups               list every group with its risk level

profiles:
  minimal    storage, notifications, device state. Nothing sensitive.
  default    minimal + camera + location.            <- fresh installs get this
  extended   default + microphone, sensors, contacts, telephony,
             write-settings, usage-stats.
  full       extended + sms + all-files. Asks for confirmation.

Everything is applied over USB with adb, shows up in Android Settings, and is
revocable. `aa permissions --revoke NAME` or `--profile minimal` undoes it.
USAGE
}

aa_perm_risk_colour() {
  case "$1" in
    safe)      printf '\033[32m%-9s\033[0m' "$1" ;;
    sensitive) printf '\033[33m%-9s\033[0m' "$1" ;;
    dangerous) printf '\033[31m%-9s\033[0m' "$1" ;;
    *)         printf '%-9s' "$1" ;;
  esac
}

aa_perm_state_mark() {
  case "$1" in
    granted) printf '\033[32m%-8s\033[0m' "granted" ;;
    partial) printf '\033[33m%-8s\033[0m' "partial" ;;
    denied)  printf '\033[2m%-8s\033[0m'  "denied"  ;;
    n/a)     printf '\033[2m%-8s\033[0m'  "built-in";;
    *)       printf '%-8s' "$1" ;;
  esac
}

aa_perm_show() {
  need adb; adb_one
  echo "Android permission groups (live state, read from the device)"
  printf '  %-15s %-8s %-9s %s\n' GROUP STATE RISK WHAT
  local n st risk desc
  while read -r n; do
    [ -n "$n" ] || continue
    st="$(aa_group_state "$n")"
    risk="$(aa_group_field "$n" 5)"
    desc="$(aa_group_field "$n" 6)"
    printf '  %-15s %s %s %s\n' "$n" "$(aa_perm_state_mark "$st")" "$(aa_perm_risk_colour "$risk")" "$desc"
  done < <(aa_group_names)

  echo
  echo "Host adb features (what this harness will do over the cable)"
  aa_features_load
  printf '  %-15s %-8s %-9s %s\n' FEATURE STATE RISK WHAT
  local f fn frisk fdesc fstate
  for f in "${AA_FEATURE_GROUPS[@]}"; do
    fn="${f%%|*}"
    frisk="$(aa_feature_field "$fn" 2)"
    fdesc="$(aa_feature_field "$fn" 3)"
    if aa_feature_on "$fn"; then fstate=granted; else fstate=denied; fi
    printf '  %-15s %s %s %s\n' "$fn" "$(aa_perm_state_mark "$fstate")" "$(aa_perm_risk_colour "$frisk")" "$fdesc"
  done
  echo
  c_dim "change with: aa permissions --pick | --profile NAME | --grant a,b | --revoke a,b"
}

c_dim_s() { printf '\033[2m%s\033[0m' "$*"; }

aa_perm_groups_list() {
  local g
  for g in "${AA_PERM_GROUPS[@]}"; do
    printf '  %-15s %s  %s\n' "${g%%|*}" "$(aa_perm_risk_colour "$(echo "$g" | cut -d'|' -f5)")" "$(echo "$g" | cut -d'|' -f6)"
    local items; items="$(echo "$g" | cut -d'|' -f4)"
    [ "$items" = "-" ] || printf '  %-15s %s\n' "" "$(c_dim_s "$items")"
  done
}

# aa_perm_apply_set "<groups to have>" — grants what is listed, revokes the rest.
aa_perm_apply_set() {
  need adb; adb_one
  aa_require_feature adb-grant "changing Android permissions"
  local want=" $1 " n risk changed=0
  while read -r n; do
    [ -n "$n" ] || continue
    [ "$(aa_group_field "$n" 3)" = builtin ] && continue
    case "$want" in
      *" $n "*)
        if [ "$(aa_group_state "$n")" = granted ]; then
          c_dim "  = $n already granted"
        else
          if aa_group_apply "$n" allow; then c_grn "  + $n granted"; changed=1
          else c_red "  ! $n could not be granted (Android may require a manual toggle in Settings)"; fi
        fi ;;
      *)
        if [ "$(aa_group_state "$n")" = denied ]; then
          :
        else
          if aa_group_apply "$n" deny; then c_dim "  - $n revoked"; changed=1
          else c_red "  ! $n could not be revoked"; fi
        fi ;;
    esac
  done < <(aa_group_names)
  [ "$changed" -eq 1 ] || c_dim "  (nothing to change)"

  # The manifest advertises only what actually works, so re-probe after a change.
  if [ -n "$AA_USER" ]; then
    ensure_forward
    dev_ssh "source '$AA_HOME/android-agent/config/environment' 2>/dev/null; android-agent-manifest --refresh >/dev/null 2>&1" 2>/dev/null \
      && c_dim "  manifest refreshed on the device"
  fi
}

aa_perm_pick() {
  need adb; adb_one
  local defaults; defaults=" $(aa_profile_groups default) "
  local chosen="" n st risk desc mark ans

  echo "Pick what the agent may do. Enter = keep the suggestion in [brackets]."
  echo

  while read -r n; do
    [ -n "$n" ] || continue
    if [ "$(aa_group_field "$n" 3)" = builtin ]; then continue; fi
    risk="$(aa_group_field "$n" 5)"
    desc="$(aa_group_field "$n" 6)"
    st="$(aa_group_state "$n")"

    # Suggest the safe default, but never silently drop something already granted.
    case "$defaults" in
      *" $n "*) mark=y ;;
      *) [ "$st" = granted ] && mark=y || mark=n ;;
    esac

    printf '\n  %s  (%s)\n  %s\n' "$n" "$(aa_perm_risk_colour "$risk" | tr -d ' ')" "$desc"
    printf '  currently: %s   grant? [%s] ' "$st" "$mark"
    read -r ans </dev/tty
    [ -z "$ans" ] && ans="$mark"
    case "$ans" in y|Y|yes) chosen="$chosen $n" ;; esac
  done < <(aa_group_names)

  echo
  echo "Applying: ${chosen:-<none>}"
  aa_perm_apply_set "$chosen"

  # Host features
  echo
  aa_features_load
  local f fn feats=""
  for f in "${AA_FEATURE_GROUPS[@]}"; do
    fn="${f%%|*}"
    aa_feature_on "$fn" && mark=y || mark=n
    printf '\n  %s  (%s)\n  %s\n  enable? [%s] ' \
      "$fn" "$(aa_feature_field "$fn" 2)" "$(aa_feature_field "$fn" 3)" "$mark"
    read -r ans </dev/tty
    [ -z "$ans" ] && ans="$mark"
    case "$ans" in y|Y|yes) feats="$feats $fn" ;; esac
  done
  aa_features_save "$feats"
  c_grn "host features: ${feats:-<none>}"
}

cmd_permissions() {
  local action="${1:-show}"
  case "$action" in
    ""|show) aa_perm_show ;;
    -h|--help) aa_perm_usage ;;
    --groups) aa_perm_groups_list ;;

    --profile)
      local p="${2:?--profile needs a name}"
      local groups; groups="$(aa_profile_groups "$p")" || die "unknown profile '$p' (minimal|default|extended|full)"
      if [ "$p" = full ]; then
        c_red "profile 'full' includes sms (read AND send) and all-files access."
        printf 'type FULL to confirm: '
        local c; read -r c </dev/tty
        [ "$c" = FULL ] || die "aborted"
      fi
      echo "applying profile '$p': $groups"
      aa_perm_apply_set "$groups"
      aa_features_save "$(aa_profile_features "$p")"
      c_grn "host features: $(aa_profile_features "$p")" ;;

    --pick) aa_perm_pick ;;

    --grant|--revoke)
      local list="${2:?$action needs a comma-separated group list}"
      need adb; adb_one
      aa_require_feature adb-grant "changing Android permissions"
      local g mode=allow
      [ "$action" = --revoke ] && mode=deny
      for g in ${list//,/ }; do
        aa_group_field "$g" 1 >/dev/null || die "unknown group '$g' (aa permissions --groups)"
        if aa_group_apply "$g" "$mode"; then
          [ "$mode" = allow ] && c_grn "  + $g granted" || c_dim "  - $g revoked"
        else
          c_red "  ! $g failed"
        fi
      done ;;

    --enable|--disable)
      local f="${2:?$action needs a feature name}"
      aa_feature_field "$f" 1 >/dev/null || die "unknown feature '$f'"
      aa_features_load
      local new=""
      for x in "${AA_FEATURE_GROUPS[@]}"; do
        local xn="${x%%|*}"
        if [ "$xn" = "$f" ]; then
          [ "$action" = --enable ] && new="$new $xn"
        elif aa_feature_on "$xn"; then
          new="$new $xn"
        fi
      done
      aa_features_save "$new"
      c_grn "host features: ${new:-<none>}" ;;

    *) aa_perm_usage; return 2 ;;
  esac
}
