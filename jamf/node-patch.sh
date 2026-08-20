#!/bin/bash
#
# node-patch.sh - detect how Node.js was installed on a Mac and remediate it.
# Runs as root from a Jamf policy. Does nothing on Macs without Node.js.
#
# Jamf script parameters (also accepted as $1-$3 when run by hand):
#   $4  MODE       report | patch            default: report
#   $5  VM_ACTION  report | upgrade | prune  default: report   (per-user version managers)
#   $6  FLOORS     override the floor table, e.g. "20:20.20.2 22:22.23.2"
#
# Patched automatically in `patch` mode - machine-wide, root-owned installs:
#   Homebrew (both prefixes), the nodejs.org .pkg, MacPorts.
# Only touched when VM_ACTION says so - per-developer version managers:
#   nvm / fnm / volta / asdf / nodenv / n. Changing these breaks projects that pin
#   a version, so the default is to report and let the developer act.
#
# Exit codes:  0 = no vulnerable Node remains   1 = vulnerable Node remains   2 = error
#
# Log: /var/log/nodepatch.log     EA state: /Library/Application Support/NodePatch/last_run.txt

PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
umask 022

# ------------------------------------------------------------------ parameters
if [ -n "$4" ] || [ "$1" = "/" ]; then
  MODE="${4:-report}"; VM_ACTION="${5:-report}"; FLOORS_IN="$6"
else
  MODE="${1:-report}"; VM_ACTION="${2:-report}"; FLOORS_IN="$3"
fi

# major:minimum-fixed-version. Update this table when a new advisory lands.
FLOORS="${FLOORS_IN:-20:20.20.2 22:22.23.2 24:24.18.1 25:25.8.2 26:26.5.1}"

LOG=/var/log/nodepatch.log
STATE_DIR="/Library/Application Support/NodePatch"

case "$MODE" in report|patch) ;; *) echo "bad MODE '$MODE' (report|patch)"; exit 2;; esac
case "$VM_ACTION" in report|upgrade|prune) ;; *) echo "bad VM_ACTION '$VM_ACTION'"; exit 2;; esac

log(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

[ "$(id -u)" -eq 0 ] || { echo "node-patch.sh must run as root."; exit 2; }

FOUND=0 REMAIN=0 PATCHED=0 DEVACTION=0 INDEX=""
SUMMARY=$(mktemp /tmp/nodepatch-summary.XXXXXX) || exit 2
trap 'rm -f "$SUMMARY" "$INDEX"' EXIT

# ------------------------------------------------------------------- utilities
# Numeric, component-wise "$1 < $2". Returns 0 when strictly less.
ver_lt(){ local IFS=.; local -a a=($1) b=($2); local i x y
  for ((i=0;i<${#a[@]}||i<${#b[@]};i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}; x=${x//[!0-9]/}; y=${y//[!0-9]/}; x=${x:-0}; y=${y:-0}
    ((10#$x<10#$y)) && return 0; ((10#$x>10#$y)) && return 1
  done; return 1; }

floor_for(){ local t; for t in $FLOORS; do [ "${t%%:*}" = "$1" ] && { echo "${t#*:}"; return 0; }; done; return 1; }

max_major(){ local t m=0; for t in $FLOORS; do [ "${t%%:*}" -gt "$m" ] && m=${t%%:*}; done; echo "$m"; }

# echoes ok | vuln | eol | unknown
node_status(){
  local v=${1#v} maj floor
  [ -n "$v" ] || { echo unknown; return; }
  maj=${v%%.*}
  case "$maj" in ''|*[!0-9]*) echo unknown; return;; esac
  if floor=$(floor_for "$maj"); then
    if ver_lt "$v" "$floor"; then echo vuln; else echo ok; fi
  elif [ "$maj" -gt "$(max_major)" ]; then
    echo unknown            # newer than the floor table - leave alone, update FLOORS
  else
    echo eol                # unsupported major (18, 21, 23, ...) - no patches exist for it
  fi
}

nver(){ [ -x "$1" ] && "$1" --version 2>/dev/null | tr -d '\r'; }

# Follow a symlink chain without relying on `readlink -f` (not on older macOS).
resolve(){ local p=$1 t n=0
  while [ -L "$p" ] && [ $n -lt 40 ]; do
    t=$(readlink "$p"); case "$t" in /*) p=$t;; *) p=$(dirname "$p")/$t;; esac; n=$((n+1))
  done; echo "$p"; }

record(){ FOUND=1; printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$SUMMARY"; }

# Real login accounts only: uid >= 500 with an existing home directory.
list_users(){ dscl . -list /Users UniqueID 2>/dev/null | awk '$NF>=500 && $NF<60000 {print $1}'; }
home_of(){ dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p'; }
asuser(){ local u=$1; shift; sudo -u "$u" -H "$@"; }   # -H so HOME is the user's, not root's

# ------------------------------------------- release data from nodejs.org/dist
# index.json is newest-first, one flat object per release, no nested braces.
node_index(){
  [ -n "$INDEX" ] && { cat "$INDEX"; return 0; }
  local f; f=$(mktemp /tmp/nodepatch-index.XXXXXX) || return 1
  if curl -fsSL --max-time 30 --retry 3 -o "$f" https://nodejs.org/dist/index.json && [ -s "$f" ]; then
    INDEX=$f; cat "$f"; return 0
  fi
  rm -f "$f"; return 1
}

# $1 = major, or empty for "newest LTS on any line".  $2 = "pkg" to require a macOS .pkg.
_releases(){
  local o; o=$(node_index | grep -o '{[^}]*}') || return 1
  [ -n "$2" ] && o=$(printf '%s\n' "$o" | grep 'osx-x64-pkg')
  if [ -n "$1" ]; then printf '%s\n' "$o" | grep "\"version\":\"v$1\\."
  else                 printf '%s\n' "$o" | grep '"lts":"'; fi
}
_pick(){ head -1 | sed -n 's/.*"version":"v\([0-9][0-9.]*\)".*/\1/p'; }

# Choose an upgrade target for a currently-installed version.
#   Supported major -> newest release on that same line (25/26 are Current, not LTS,
#                      so filtering on LTS here would silently downgrade the machine).
#   EOL major       -> newest LTS, since that line gets no more releases.
# Never returns something older than what is installed.
target_for(){ # $1 = current version   $2 = optional "pkg"
  local cur=${1#v} maj t=""
  maj=${cur%%.*}
  if floor_for "$maj" >/dev/null 2>&1; then t=$(_releases "$maj" "$2" | _pick); fi
  [ -n "$t" ] || t=$(_releases "" "$2" | _pick)
  [ -n "$t" ] || return 1
  ver_lt "$cur" "$t" || return 1   # only ever move forward
  echo "$t"
}

# ------------------------------------------------- nodejs.org .pkg installation
install_node_pkg(){ # $1 = bare version, e.g. 24.19.0
  local v=$1 tmp base want got rc
  tmp=$(mktemp -d /tmp/nodepatch.XXXXXX) || return 1
  base="https://nodejs.org/dist/v$v"
  if ! curl -fsSL --max-time 600 --retry 3 -o "$tmp/node.pkg" "$base/node-v$v.pkg" \
    || ! curl -fsSL --max-time 60 --retry 3 -o "$tmp/sums" "$base/SHASUMS256.txt"; then
    log "    download of node-v$v.pkg failed"; rm -rf "$tmp"; return 1
  fi
  want=$(awk -v f="node-v$v.pkg" '$2==f {print $1}' "$tmp/sums")
  got=$(shasum -a 256 "$tmp/node.pkg" | awk '{print $1}')
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    log "    CHECKSUM MISMATCH for node-v$v.pkg - refusing to install"; rm -rf "$tmp"; return 1
  fi
  installer -pkg "$tmp/node.pkg" -target / >>"$LOG" 2>&1; rc=$?
  rm -rf "$tmp"; return $rc
}

log "=== node-patch.sh start (MODE=$MODE VM_ACTION=$VM_ACTION) ==="

# ================================================================== 1. Homebrew
# Both prefixes can coexist (Apple Silicon native + Rosetta). Run brew as the
# account that owns the prefix, not as the console user and not as root.
for PREFIX in /opt/homebrew /usr/local; do
  BREW="$PREFIX/bin/brew"; [ -x "$BREW" ] || continue
  OWNER=$(stat -f%Su "$PREFIX" 2>/dev/null); [ -n "$OWNER" ] || continue
  UPDATED=0
  for f in $(asuser "$OWNER" "$BREW" list --formula 2>/dev/null | grep -E '^node(@[0-9]+)?$'); do
    bnode=$(asuser "$OWNER" "$BREW" --prefix "$f" 2>/dev/null)/bin/node
    [ -x "$bnode" ] || bnode="$PREFIX/opt/$f/bin/node"
    v=$(nver "$bnode"); st=$(node_status "$v")
    log "HOMEBREW ($PREFIX, owner $OWNER): $f = ${v:-unreadable} [$st]"

    case "$st" in
      unknown) record unknown "brew:$f@$PREFIX" "${v:-unreadable}" "not classified - left alone"
               log "  -> version unreadable or newer than the floor table; not patching"; continue;;
      ok)      record ok "brew:$f@$PREFIX" "$v" ""; continue;;
    esac

    if [ "$MODE" != patch ]; then
      REMAIN=1; record "$st" "brew:$f@$PREFIX" "${v:-?}" "run: brew upgrade $f"
      log "  -> $st (fix: brew upgrade $f)"; continue
    fi

    [ $UPDATED -eq 0 ] && { asuser "$OWNER" "$BREW" update >>"$LOG" 2>&1; UPDATED=1; }
    log "  -> upgrading $f"
    asuser "$OWNER" "$BREW" upgrade "$f" >>"$LOG" 2>&1

    v2=$(nver "$bnode"); st2=$(node_status "$v2")
    if [ "$st2" = ok ]; then
      PATCHED=1; record patched "brew:$f@$PREFIX" "$v2" "was $v"; log "  -> now $v2 [ok]"
    else
      # Pinned formulae (node@18, node@20) go deprecated; upgrading cannot reach the floor.
      REMAIN=1; record "$st2" "brew:$f@$PREFIX" "${v2:-?}" "upgrade did not clear it; migrate to 'brew install node'"
      log "  -> STILL $st2 at ${v2:-?}. Formula is likely deprecated - migrate: brew uninstall $f && brew install node"
    fi
  done
done

# =========================================================== 2. nodejs.org .pkg
if pkgutil --pkgs 2>/dev/null | grep -qiE '^org\.nodejs'; then
  PKGNODE=/usr/local/bin/node
  # Only the pkg's if it does not resolve into a Homebrew Cellar. Checking the
  # resolved path is what makes this correct on Apple Silicon, where a brew node
  # at /opt/homebrew and a pkg node at /usr/local are two separate installs.
  if [ -x "$PKGNODE" ] && case "$(resolve "$PKGNODE")" in */Cellar/*) false;; *) true;; esac; then
    v=$(nver "$PKGNODE"); st=$(node_status "$v")
    log "OFFICIAL PKG: $PKGNODE = ${v:-unreadable} [$st]"
    if [ "$st" = unknown ]; then
      record unknown "pkg:org.nodejs" "${v:-unreadable}" "not classified - left alone"
      log "  -> not classified; not patching"
    elif [ "$st" = ok ]; then
      record ok "pkg:org.nodejs" "$v" ""
    elif [ "$MODE" != patch ]; then
      REMAIN=1; record "$st" "pkg:org.nodejs" "${v:-?}" "install a current Node .pkg"
      log "  -> $st (fix: install a current Node .pkg)"
    elif ! target=$(target_for "$v" pkg); then
      REMAIN=1; record "$st" "pkg:org.nodejs" "${v:-?}" "no newer .pkg found (offline, or already newest)"
      log "  -> could not pick an upgrade target from nodejs.org; skipping"
    else
      log "  -> installing node-v$target.pkg from nodejs.org (verifying SHA-256)"
      if install_node_pkg "$target"; then
        v2=$(nver "$PKGNODE"); st2=$(node_status "$v2")
        if [ "$st2" = ok ]; then PATCHED=1; record patched "pkg:org.nodejs" "$v2" "was $v"; log "  -> now $v2 [ok]"
        else REMAIN=1; record "$st2" "pkg:org.nodejs" "${v2:-?}" "install completed but still $st2"; log "  -> STILL $st2 at ${v2:-?}"; fi
      else
        REMAIN=1; record "$st" "pkg:org.nodejs" "${v:-?}" "pkg install failed - see $LOG"; log "  -> install failed"
      fi
    fi
  fi
fi

# ================================================================== 3. MacPorts
if [ -x /opt/local/bin/port ] && [ -x /opt/local/bin/node ]; then
  v=$(nver /opt/local/bin/node); st=$(node_status "$v")
  log "MACPORTS: /opt/local/bin/node = ${v:-unreadable} [$st]"
  ports=$(/opt/local/bin/port -q installed 2>/dev/null | awk '{print $1}' | grep -E '^nodejs[0-9]+$' | sort -u)
  if [ "$st" = unknown ]; then
    record unknown "macports" "${v:-unreadable}" "not classified - left alone"
  elif [ "$st" = ok ]; then
    record ok "macports" "$v" ""
  elif [ "$MODE" != patch ]; then
    REMAIN=1; record "$st" "macports" "${v:-?}" "sudo port selfupdate && sudo port upgrade ${ports:-nodejsXX}"
    log "  -> $st (fix: port selfupdate && port upgrade ${ports:-nodejsXX})"
  else
    /opt/local/bin/port -N selfupdate >>"$LOG" 2>&1
    for p in $ports; do log "  -> port upgrade $p"; /opt/local/bin/port -N upgrade "$p" >>"$LOG" 2>&1; done
    v2=$(nver /opt/local/bin/node); st2=$(node_status "$v2")
    if [ "$st2" = ok ]; then PATCHED=1; record patched "macports" "$v2" "was $v"; log "  -> now $v2 [ok]"
    else
      REMAIN=1; record "$st2" "macports" "${v2:-?}" "install a newer nodejsXX port, then 'port select --set nodejs'"
      log "  -> STILL $st2. The installed port line is EOL; install a newer nodejsXX port."
    fi
  fi
fi

# ================================================ 4. per-user version managers
# Developer-owned. Upgrading or removing a version breaks projects that pin it,
# so nothing here is touched unless VM_ACTION asks for it.
#
# Mac developers use zsh, so `bash -lc` never sources the rc file that puts fnm /
# volta / asdf / nodenv on PATH. Put the standard install locations there ourselves.
# (nvm is a shell function, not a binary - its commands source nvm.sh explicitly.)
VM_PRELUDE='export PATH="$HOME/.volta/bin:$HOME/.fnm:$HOME/.local/share/fnm:$HOME/.asdf/bin:$HOME/.asdf/shims:$HOME/.nodenv/bin:$HOME/.nodenv/shims:$HOME/n/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$PATH"; '

# handle_vm <user> <label> <hint> <install-cmd> <remove-cmd> <candidate binaries...>
#   %V in install-cmd = chosen target version;  %U in remove-cmd = version being removed.
handle_vm(){
  local u=$1 label=$2 hint=$3 upcmd=$4 rmcmd=$5; shift 5
  local b v st tgt
  for b in "$@"; do
    [ -x "$b" ] || continue                       # unmatched globs land here harmlessly
    v=$(nver "$b"); st=$(node_status "$v")
    log "$label ($u): $b = ${v:-unreadable} [$st]"
    case "$st" in
      ok)      record ok "$label:$u" "$v" ""; continue;;
      unknown) record unknown "$label:$u" "${v:-unreadable}" "not classified"; continue;;
    esac

    if [ "$VM_ACTION" = report ]; then
      DEVACTION=1; REMAIN=1
      record "$st" "$label:$u" "$v" "developer action: $hint"
      log "  -> $st, developer-owned. Ask $u to run: $hint"
      continue
    fi

    if ! tgt=$(target_for "$v"); then
      DEVACTION=1; REMAIN=1
      record "$st" "$label:$u" "$v" "no upgrade target available; $hint"
      log "  -> could not pick an upgrade target; leaving alone"; continue
    fi

    log "  -> installing Node $tgt for $u via $label"
    if asuser "$u" /bin/bash -lc "$VM_PRELUDE${upcmd//%V/$tgt}" >>"$LOG" 2>&1; then
      PATCHED=1; record patched "$label:$u" "$tgt" "installed and set as default"
    else
      DEVACTION=1; REMAIN=1
      record "$st" "$label:$u" "$v" "automatic upgrade failed: $hint"
      log "  -> upgrade command failed; see $LOG"; continue
    fi

    if [ "$VM_ACTION" = prune ] && [ -n "$rmcmd" ]; then
      log "  -> removing vulnerable $v for $u"
      if asuser "$u" /bin/bash -lc "$VM_PRELUDE${rmcmd//%U/$v}" >>"$LOG" 2>&1; then
        record pruned "$label:$u" "$v" "removed"
      else
        REMAIN=1; record "$st" "$label:$u" "$v" "could not remove; remove by hand"
        log "  -> removal failed"
      fi
    else
      # Upgraded, but the old copy is still on disk and a scanner will still flag it.
      REMAIN=1
      record "$st" "$label:$u" "$v" "old version still on disk; re-run with VM_ACTION=prune"
      log "  -> $tgt installed, but $v remains on disk (VM_ACTION=prune removes it)"
    fi
  done
}

for U in $(list_users); do
  H=$(home_of "$U"); [ -n "$H" ] && [ -d "$H" ] || continue

  [ -d "$H/.nvm" ] && handle_vm "$U" NVM \
    'nvm install --lts && nvm alias default "lts/*"' \
    'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm install %V && nvm alias default %V' \
    'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm uninstall %U' \
    "$H"/.nvm/versions/node/*/bin/node

  { [ -d "$H/.fnm" ] || [ -d "$H/Library/Application Support/fnm" ]; } && handle_vm "$U" FNM \
    'fnm install --lts && fnm default lts-latest' \
    'fnm install %V && fnm default %V' \
    'fnm uninstall %U' \
    "$H"/.fnm/node-versions/*/installation/bin/node \
    "$H"/Library/Application\ Support/fnm/node-versions/*/installation/bin/node

  [ -d "$H/.volta" ] && handle_vm "$U" VOLTA \
    'volta install node@lts' \
    'volta install node@%V' \
    'rm -rf "$HOME/.volta/tools/image/node/%U"' \
    "$H"/.volta/tools/image/node/*/bin/node

  [ -d "$H/.asdf" ] && handle_vm "$U" ASDF \
    'asdf install nodejs latest && asdf set -u nodejs latest' \
    'asdf install nodejs %V && { asdf set -u nodejs %V || asdf global nodejs %V; }' \
    'asdf uninstall nodejs %U' \
    "$H"/.asdf/installs/nodejs/*/bin/node

  [ -d "$H/.nodenv" ] && handle_vm "$U" NODENV \
    'nodenv install <latest> && nodenv global <latest>' \
    'nodenv install -s %V && nodenv global %V' \
    'nodenv uninstall -f %U' \
    "$H"/.nodenv/versions/*/bin/node

  [ -d "$H/n" ] && handle_vm "$U" N \
    'n lts' \
    'N_PREFIX="$HOME/n" n install %V' \
    'N_PREFIX="$HOME/n" n rm %U' \
    "$H"/n/bin/node
done

# ===================================================================== summary
if [ "$FOUND" -eq 0 ]; then
  log "No Node.js installation found on this Mac. Nothing to do."
  mkdir -p "$STATE_DIR"
  { printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"; printf 'none|no-node||\n'; } > "$STATE_DIR/last_run.txt"
  chmod 644 "$STATE_DIR/last_run.txt"
  log "=== node-patch.sh end (clean) ==="
  exit 0
fi

log "--- summary ---"
sort -u "$SUMMARY" | while IFS='|' read -r st label ver note; do
  log "  [$st] $label ${ver:-?}${note:+  -- $note}"
done

mkdir -p "$STATE_DIR"
{ printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"; sort -u "$SUMMARY"; } > "$STATE_DIR/last_run.txt"
chmod 644 "$STATE_DIR/last_run.txt"

if [ "$REMAIN" -eq 1 ]; then
  [ "$DEVACTION" -eq 1 ] && log "Some vulnerable copies live in per-user version managers (VM_ACTION=$VM_ACTION)."
  log "RESULT: vulnerable Node.js still present."
  log "=== node-patch.sh end (remaining) ==="
  exit 1
fi

if [ "$PATCHED" -eq 1 ]; then log "RESULT: all vulnerable Node.js installs were patched."
else                          log "RESULT: all Node.js installs already at or above the floor."; fi
log "=== node-patch.sh end (clean) ==="
exit 0
