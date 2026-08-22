#!/bin/bash
#
# pycharm-cleanup.sh - remove stale/duplicate PyCharm .app bundles that Jamf
# App Installers will NOT adopt (non-standard names), so Tenable stops flagging
# them. Runs as root from a Jamf policy. Scope to the machines that have them.
#
# App Installers manages the canonical bundles and updates them in place:
#     /Applications/PyCharm.app        (PyCharm)
#     /Applications/PyCharm CE.app     (PyCharm Community)
# This script NEVER touches those. It only removes OTHER /Applications/*PyCharm*.app
# copies (e.g. "PyCharm 2.app", "PyCharm CE with Anaconda plugin.app") and only
# when their version is below the fixed floor - so a current copy is never deleted.
#
# Jamf parameter (also $1 by hand):
#   $4  MODE   report | remove    default: report
#
# Exit: 0 = nothing stale remains   1 = stale remains (report, or a removal failed)   2 = error
# Log: /var/log/pycharm-cleanup.log

PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
umask 022

if [ -n "$4" ] || [ "$1" = "/" ]; then MODE="${4:-report}"; else MODE="${1:-report}"; fi
case "$MODE" in report|remove) ;; *) echo "bad MODE '$MODE' (report|remove)"; exit 2;; esac

FLOOR="2026.1.4"     # PyCharm fixed version (plugin 331337, the most serious CVE)
LOG=/var/log/pycharm-cleanup.log
[ "$(id -u)" -eq 0 ] || { echo "pycharm-cleanup.sh must run as root."; exit 2; }

log(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
ver_lt(){ local IFS=.; local -a a=($1) b=($2); local i x y
  for ((i=0;i<${#a[@]}||i<${#b[@]};i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}; x=${x//[!0-9]/}; y=${y//[!0-9]/}; x=${x:-0}; y=${y:-0}
    ((10#$x<10#$y)) && return 0; ((10#$x>10#$y)) && return 1
  done; return 1; }
appver(){ /usr/bin/defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null; }

REMAIN=0 REMOVED=0 FOUND=0
log "=== pycharm-cleanup.sh start (MODE=$MODE, floor $FLOOR) ==="

# Enumerate PyCharm bundles directly in /Applications (not recursive - avoids
# matching caches or nested copies we don't intend to touch).
shopt -s nullglob
for app in /Applications/*PyCharm*.app; do
  base=${app##*/}
  # Never touch the canonical App-Installer-managed bundles.
  case "$base" in
    "PyCharm.app"|"PyCharm CE.app") log "KEEP  $app (App Installers manages this)"; continue;;
  esac

  FOUND=1
  v=$(appver "$app")
  if [ -z "$v" ]; then
    REMAIN=1
    log "SKIP  $app (version unreadable) - leaving for manual review"
    continue
  fi
  if ! ver_lt "$v" "$FLOOR"; then
    log "KEEP  $app ($v >= $FLOOR, already fixed)"
    continue
  fi

  # non-canonical + below floor -> remove
  if [ "$MODE" != remove ]; then
    REMAIN=1; log "WOULD REMOVE  $app ($v)"; continue
  fi

  # guarded removal
  case "$app" in
    /Applications/*PyCharm*.app) ;;                 # must be an /Applications PyCharm bundle
    *) log "REFUSE $app (failed path guard)"; REMAIN=1; continue;;
  esac
  log "REMOVING  $app ($v)"
  if rm -rf "$app"; then REMOVED=1; log "  -> removed"
  else REMAIN=1; log "  -> removal FAILED (in use? try again / remove by hand)"; fi
done
shopt -u nullglob

if [ "$FOUND" -eq 0 ]; then log "No non-canonical PyCharm bundles present."; log "=== end (clean) ==="; exit 0; fi
if [ "$REMAIN" -eq 1 ]; then log "RESULT: stale PyCharm bundle(s) still present."; log "=== end (remaining) ==="; exit 1; fi
log "RESULT: stale PyCharm bundles cleaned up."; log "=== end (clean) ==="; exit 0
