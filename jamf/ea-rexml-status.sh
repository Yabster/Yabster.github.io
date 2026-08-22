#!/bin/bash
#
# Jamf Extension Attribute - "REXML Status"    Data Type: String    Input: Script
#
# Read-only. Finds every vulnerable REXML gemspec inside Homebrew's vendored
# "portable-ruby" (the Ruby Homebrew ships to run itself) under both prefixes,
# and classifies against the fixed floor. Safe to run at every inventory.
#
# First result line is the verdict for smart-group scoping:
#   None | OK | Vulnerable
#
# Why only portable-ruby: on this fleet every Tenable REXML finding (plugins
# 242630 / 210049) resolved to .../Homebrew/vendor/portable-ruby/. That Ruby is
# Homebrew-managed; the fix is `brew update && brew cleanup`, never `gem install`.

PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
FLOOR="3.3.9"     # REXML >= 3.3.9 clears both the <3.3.6 DoS and <3.3.9 ReDoS plugins

ver_lt(){ local IFS=.; local -a a=($1) b=($2); local i x y
  for ((i=0;i<${#a[@]}||i<${#b[@]};i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}; x=${x//[!0-9]/}; y=${y//[!0-9]/}; x=${x:-0}; y=${y:-0}
    ((10#$x<10#$y)) && return 0; ((10#$x>10#$y)) && return 1
  done; return 1; }

# version out of a gemspec filename: rexml-3.2.5.gemspec -> 3.2.5
specver(){ local b=${1##*/}; b=${b#rexml-}; echo "${b%.gemspec}"; }

LINES=""; WORST=none
for PREFIX in /opt/homebrew /usr/local; do
  VDIR="$PREFIX/Library/Homebrew/vendor/portable-ruby"
  [ -d "$VDIR" ] || continue
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    v=$(specver "$spec"); case "$v" in ''|*[!0-9.]*) continue;; esac
    if ver_lt "$v" "$FLOOR"; then
      WORST=vuln
      # show the portable-ruby version dir, not the whole path, to keep it short
      pr=${spec#*/portable-ruby/}; pr=${pr%%/*}
      LINES="${LINES}${PREFIX##*/}:portable-ruby/$pr rexml $v [vuln]
"
    else
      [ "$WORST" = none ] && WORST=ok
      LINES="${LINES}${PREFIX##*/} rexml $v [ok]
"
    fi
  done < <(find "$VDIR" -type f -name 'rexml-*.gemspec' 2>/dev/null)
done

case "$WORST" in
  none) echo "<result>None</result>";;
  ok)   printf '<result>OK\n%s</result>\n' "$LINES";;
  vuln) printf '<result>Vulnerable\n%s</result>\n' "$LINES";;
esac
exit 0
