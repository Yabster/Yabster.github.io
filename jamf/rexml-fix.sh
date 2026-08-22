#!/bin/bash
#
# rexml-fix.sh - clear vulnerable REXML gemspecs inside Homebrew's vendored
# portable-ruby. Runs as root from a Jamf policy.
#
# On this fleet every Tenable REXML finding (plugins 242630 / 210049) lives in
#   {/opt/homebrew,/usr/local}/Library/Homebrew/vendor/portable-ruby/<ver>/...
# i.e. Homebrew's PRIVATE Ruby - not system Ruby, rbenv, or a repo. Nothing pins
# to it, so patch mode fully cleans up with no opt-in flag:
#   brew update    -> current portable-ruby ships rexml >= 3.3.9
#   brew cleanup   -> removes stale old portable-ruby copies being flagged
#   then           -> delete any stale portable-ruby dir cleanup left behind
#                     (guarded: never the 'current' symlink target)
#
# Jamf parameter (also $1 by hand):
#   $4  MODE   report | patch    default: report
#
# Exit: 0 = no vulnerable REXML remains   1 = still present   2 = error
# Log: /var/log/rexmlfix.log   EA state: /Library/Application Support/NodePatch/rexml_last_run.txt

PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
umask 022

if [ -n "$4" ] || [ "$1" = "/" ]; then MODE="${4:-report}"; else MODE="${1:-report}"; fi
case "$MODE" in report|patch) ;; *) echo "bad MODE '$MODE' (report|patch)"; exit 2;; esac

FLOOR="3.3.9"
LOG=/var/log/rexmlfix.log
STATE_DIR="/Library/Application Support/NodePatch"
[ "$(id -u)" -eq 0 ] || { echo "rexml-fix.sh must run as root."; exit 2; }

log(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
ver_lt(){ local IFS=.; local -a a=($1) b=($2); local i x y
  for ((i=0;i<${#a[@]}||i<${#b[@]};i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}; x=${x//[!0-9]/}; y=${y//[!0-9]/}; x=${x:-0}; y=${y:-0}
    ((10#$x<10#$y)) && return 0; ((10#$x>10#$y)) && return 1
  done; return 1; }
specver(){ local b=${1##*/}; b=${b#rexml-}; echo "${b%.gemspec}"; }
asuser(){ local u=$1; shift; sudo -u "$u" -H "$@"; }

# echo each vulnerable "spec<TAB>version" under a prefix's portable-ruby
scan_vuln(){ local VDIR=$1 spec v
  [ -d "$VDIR" ] || return 0
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    v=$(specver "$spec"); case "$v" in ''|*[!0-9.]*) continue;; esac
    ver_lt "$v" "$FLOOR" && printf '%s\t%s\n' "$spec" "$v"
  done < <(find "$VDIR" -type f -name 'rexml-*.gemspec' 2>/dev/null)
}

REMAIN=0 PATCHED=0 FOUND=0
log "=== rexml-fix.sh start (MODE=$MODE) ==="

for PREFIX in /opt/homebrew /usr/local; do
  BREW="$PREFIX/bin/brew"; [ -x "$BREW" ] || continue
  VDIR="$PREFIX/Library/Homebrew/vendor/portable-ruby"
  OWNER=$(stat -f%Su "$PREFIX" 2>/dev/null); [ -n "$OWNER" ] || continue

  before=$(scan_vuln "$VDIR")
  [ -n "$before" ] || continue
  FOUND=1
  log "PREFIX $PREFIX (owner $OWNER): vulnerable REXML present:"
  printf '%s\n' "$before" | while IFS=$'\t' read -r s v; do
    pr=${s#*/portable-ruby/}; pr=${pr%%/*}; log "    portable-ruby/$pr = rexml $v"
  done

  if [ "$MODE" != patch ]; then
    REMAIN=1; log "  -> report only (fix: brew update && brew cleanup as $OWNER)"; continue
  fi

  log "  -> brew update (as $OWNER)"; asuser "$OWNER" "$BREW" update    >>"$LOG" 2>&1
  log "  -> brew cleanup --prune=all"; asuser "$OWNER" "$BREW" cleanup --prune=all >>"$LOG" 2>&1

  # Always remove any stale portable-ruby version dir cleanup left behind that
  # still carries a vulnerable rexml. Guarded: only inside .../portable-ruby/,
  # never the 'current' symlink target. Nothing pins to portable-ruby, so safe.
  after=$(scan_vuln "$VDIR")
  if [ -n "$after" ]; then
    cur=""; [ -L "$VDIR/current" ] && cur=$(basename "$(readlink "$VDIR/current")")
    printf '%s\n' "$after" | awk -F'\t' '{print $1}' | sort -u | while IFS= read -r s; do
      pr=${s#*/portable-ruby/}; pr=${pr%%/*}
      case "$pr" in ""|current) continue;; esac
      [ "$pr" = "$cur" ] && { log "    keeping current portable-ruby/$pr"; continue; }
      target="$VDIR/$pr"
      case "$target" in */Library/Homebrew/vendor/portable-ruby/*) ;; *) continue;; esac
      log "    removing stale $target"; rm -rf "$target"
    done
    after=$(scan_vuln "$VDIR")
  fi

  if [ -z "$after" ]; then
    PATCHED=1; log "  -> clear: no vulnerable REXML remains under $PREFIX"
  else
    REMAIN=1
    log "  -> STILL vulnerable under $PREFIX (current portable-ruby itself ships old rexml - run brew update again / upgrade Homebrew):"
    printf '%s\n' "$after" | while IFS=$'\t' read -r s v; do
      pr=${s#*/portable-ruby/}; pr=${pr%%/*}; log "       portable-ruby/$pr = rexml $v"
    done
  fi
done

mkdir -p "$STATE_DIR"
printf '%s  MODE=%s found=%s patched=%s remain=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$FOUND" "$PATCHED" "$REMAIN" \
  > "$STATE_DIR/rexml_last_run.txt"; chmod 644 "$STATE_DIR/rexml_last_run.txt"

if [ "$FOUND" -eq 0 ]; then log "No Homebrew portable-ruby REXML found."; log "=== end (clean) ==="; exit 0; fi
if [ "$REMAIN" -eq 1 ]; then log "RESULT: vulnerable REXML still present."; log "=== end (remaining) ==="; exit 1; fi
log "RESULT: REXML remediated."; log "=== end (clean) ==="; exit 0
