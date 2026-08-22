#!/bin/bash
#
# Jamf Extension Attribute - "Node.js Status"    Data Type: String    Input: Script
#
# Read-only and offline: safe to run at every inventory collection. Never modifies
# anything and never touches the network, so it cannot slow down or fail a recon.
#
# First line of the result is the verdict, for smart-group scoping:
#   None | OK | Unknown | EOL | Vulnerable
# Remaining lines list each install found, for reporting.
#
# Suggested smart groups:
#   "Macs with Node.js"            -> Node.js Status  not like  None
#   "Macs with vulnerable Node.js" -> Node.js Status      like  Vulnerable
# Scope the node-patch.sh policy to the second one.

PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH

# Keep this table identical to the one in node-patch.sh.
FLOORS="20:20.20.2 22:22.23.2 24:24.18.1 25:25.8.2 26:26.5.1"

ver_lt(){ local IFS=.; local -a a=($1) b=($2); local i x y
  for ((i=0;i<${#a[@]}||i<${#b[@]};i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}; x=${x//[!0-9]/}; y=${y//[!0-9]/}; x=${x:-0}; y=${y:-0}
    ((10#$x<10#$y)) && return 0; ((10#$x>10#$y)) && return 1
  done; return 1; }

floor_for(){ local t; for t in $FLOORS; do [ "${t%%:*}" = "$1" ] && { echo "${t#*:}"; return 0; }; done; return 1; }
max_major(){ local t m=0; for t in $FLOORS; do [ "${t%%:*}" -gt "$m" ] && m=${t%%:*}; done; echo "$m"; }

node_status(){
  local v=${1#v} maj floor
  [ -n "$v" ] || { echo unknown; return; }
  maj=${v%%.*}
  case "$maj" in ''|*[!0-9]*) echo unknown; return;; esac
  if floor=$(floor_for "$maj"); then
    if ver_lt "$v" "$floor"; then echo vuln; else echo ok; fi
  elif [ "$maj" -gt "$(max_major)" ]; then echo unknown
  else echo eol; fi
}

nver(){ [ -x "$1" ] && "$1" --version 2>/dev/null | tr -d '\r'; }
resolve(){ local p=$1 t n=0
  while [ -L "$p" ] && [ $n -lt 40 ]; do
    t=$(readlink "$p"); case "$t" in /*) p=$t;; *) p=$(dirname "$p")/$t;; esac; n=$((n+1))
  done; echo "$p"; }

list_users(){ dscl . -list /Users UniqueID 2>/dev/null | awk '$NF>=500 && $NF<60000 {print $1}'; }
home_of(){ dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p'; }

LINES=""; WORST=none
note(){ # note <label> <version> <status>
  LINES="${LINES}$1 $2 [$3]
"
  case "$3" in
    vuln)    WORST=vuln;;
    eol)     [ "$WORST" != vuln ] && WORST=eol;;
    unknown) [ "$WORST" != vuln ] && [ "$WORST" != eol ] && WORST=unknown;;
    ok)      [ "$WORST" = none ] && WORST=ok;;
  esac
}

# ---- Homebrew (both prefixes) ----
for PREFIX in /opt/homebrew /usr/local; do
  BREW="$PREFIX/bin/brew"; [ -x "$BREW" ] || continue
  OWNER=$(stat -f%Su "$PREFIX" 2>/dev/null); [ -n "$OWNER" ] || continue
  for f in $(sudo -u "$OWNER" -H "$BREW" list --formula 2>/dev/null | grep -E '^node(@[0-9]+)?$'); do
    b=$(sudo -u "$OWNER" -H "$BREW" --prefix "$f" 2>/dev/null)/bin/node
    [ -x "$b" ] || b="$PREFIX/opt/$f/bin/node"
    v=$(nver "$b"); [ -n "$v" ] || continue
    note "homebrew($PREFIX):$f" "$v" "$(node_status "$v")"
  done
done

# ---- nodejs.org .pkg (only if /usr/local/bin/node is not a Homebrew Cellar link) ----
if pkgutil --pkgs 2>/dev/null | grep -qiE '^org\.nodejs'; then
  if [ -x /usr/local/bin/node ] && case "$(resolve /usr/local/bin/node)" in */Cellar/*) false;; *) true;; esac; then
    v=$(nver /usr/local/bin/node); [ -n "$v" ] && note "pkg:org.nodejs" "$v" "$(node_status "$v")"
  fi
fi

# ---- MacPorts ----
if [ -x /opt/local/bin/port ] && [ -x /opt/local/bin/node ]; then
  v=$(nver /opt/local/bin/node); [ -n "$v" ] && note "macports" "$v" "$(node_status "$v")"
fi

# ---- per-user version managers ----
scan(){ local label=$1 user=$2; shift 2; local b v
  for b in "$@"; do [ -x "$b" ] || continue
    v=$(nver "$b"); [ -n "$v" ] || continue
    note "$label:$user" "$v" "$(node_status "$v")"
  done; }

for U in $(list_users); do
  H=$(home_of "$U"); [ -n "$H" ] && [ -d "$H" ] || continue
  scan nvm    "$U" "$H"/.nvm/versions/node/*/bin/node
  scan fnm    "$U" "$H"/.fnm/node-versions/*/installation/bin/node \
                   "$H"/Library/Application\ Support/fnm/node-versions/*/installation/bin/node
  scan volta  "$U" "$H"/.volta/tools/image/node/*/bin/node
  scan asdf   "$U" "$H"/.asdf/installs/nodejs/*/bin/node
  scan nodenv "$U" "$H"/.nodenv/versions/*/bin/node
  scan n      "$U" "$H"/n/bin/node
done

case "$WORST" in
  none)    echo "<result>None</result>";;
  ok)      printf '<result>OK\n%s</result>\n' "$LINES";;
  unknown) printf '<result>Unknown\n%s</result>\n' "$LINES";;
  eol)     printf '<result>EOL\n%s</result>\n' "$LINES";;
  vuln)    printf '<result>Vulnerable\n%s</result>\n' "$LINES";;
esac
exit 0
