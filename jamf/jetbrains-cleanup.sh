#!/bin/bash
#
# jetbrains-cleanup.sh - remove stale/duplicate JetBrains IDE .app bundles that
# Jamf App Installers can't adopt (old Community "CE" apps and oddly-named copies),
# so Tenable stops flagging them. Runs as root from a Jamf policy.
#
# App Installers installs/updates the canonical Unified bundles in place and keeps
# them current going forward:
#     /Applications/PyCharm.app          (JetBrains PyCharm Unified)
#     /Applications/IntelliJ IDEA.app    (JetBrains IntelliJ IDEA Unified)
# This script NEVER removes those. It removes every OTHER matching bundle
# (e.g. "PyCharm CE.app", "IntelliJ IDEA CE.app", "PyCharm 2.app",
# "PyCharm CE with Anaconda plugin.app") whose version is below the fixed floor.
#
# NOTE: this removes a below-floor copy even if it is the machine's only IDE.
# On the two CE-only Macs the user must reinstall the Unified IDE from Self
# Service afterward (notify them). This is the deliberate fast-path choice.
#
# Jamf parameter (also $1 by hand):
#   $4  MODE   report | remove    default: report   (dry-run safety for a delete)
#
# Exit: 0 = nothing stale remains   1 = stale remains / failed   2 = error
# Log: /var/log/jetbrains-cleanup.log

PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
umask 022

if [ -n "$4" ] || [ "$1" = "/" ]; then MODE="${4:-report}"; else MODE="${1:-report}"; fi
case "$MODE" in report|remove) ;; *) echo "bad MODE '$MODE' (report|remove)"; exit 2;; esac

LOG=/var/log/jetbrains-cleanup.log
[ "$(id -u)" -eq 0 ] || { echo "jetbrains-cleanup.sh must run as root."; exit 2; }

log(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
ver_lt(){ local IFS=.; local -a a=($1) b=($2); local i x y
  for ((i=0;i<${#a[@]}||i<${#b[@]};i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}; x=${x//[!0-9]/}; y=${y//[!0-9]/}; x=${x:-0}; y=${y:-0}
    ((10#$x<10#$y)) && return 0; ((10#$x>10#$y)) && return 1
  done; return 1; }
appver(){ /usr/bin/defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null; }

REMAIN=0 REMOVED=0 FOUND=0

# process_family <name-glob> <canonical basename> <fixed floor>
process_family(){
  local pat=$1 canonical=$2 floor=$3
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    base=${app##*/}
    if [ "$base" = "$canonical" ]; then
      log "KEEP  $app (canonical - App Installers manages/updates it)"; continue
    fi
    FOUND=1
    v=$(appver "$app")
    if [ -z "$v" ]; then REMAIN=1; log "SKIP  $app (version unreadable - manual review)"; continue; fi
    if ! ver_lt "$v" "$floor"; then log "KEEP  $app ($v >= $floor, already fixed)"; continue; fi

    if [ "$MODE" != remove ]; then
      REMAIN=1; log "WOULD REMOVE  $app ($v)"; continue
    fi
    case "$app" in /Applications/*.app) ;; *) log "REFUSE $app (path guard)"; REMAIN=1; continue;; esac
    log "REMOVING  $app ($v)"
    if rm -rf "$app"; then REMOVED=1; log "  -> removed"
    else REMAIN=1; log "  -> removal FAILED (in use? retry / remove by hand)"; fi
  done < <(find /Applications -maxdepth 1 -type d -name "$pat" 2>/dev/null)
}

log "=== jetbrains-cleanup.sh start (MODE=$MODE) ==="
process_family "*PyCharm*.app"        "PyCharm.app"        "2026.1.4"
process_family "*IntelliJ IDEA*.app"  "IntelliJ IDEA.app"  "2026.2.1"

if [ "$FOUND" -eq 0 ]; then log "No non-canonical JetBrains IDE bundles present."; log "=== end (clean) ==="; exit 0; fi
if [ "$REMAIN" -eq 1 ]; then log "RESULT: stale bundle(s) still present (removed=$REMOVED)."; log "=== end (remaining) ==="; exit 1; fi
log "RESULT: stale JetBrains bundles cleaned up (removed=$REMOVED)."; log "=== end (clean) ==="; exit 0
