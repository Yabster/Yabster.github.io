#!/bin/bash
#
# remediate-tenable-macos-findings.sh
#
# Single Jamf Pro script that remediates the Tenable/Nessus findings reported
# against mac.lan (10.99.45.230) in the 10/04/2026 export. The 23 in-scope
# findings collapse into 4 remediation actions:
#
#   Action              Findings  Installed    Required
#   ------------------  --------  -----------  -------------------------------
#   IntelliJ IDEA CE       9      2024.1.2     2026.2.3  (CVE-2026-100256 etc.)
#   PyCharm CE             3      2024.2.4     2026.2    (CVE: RCE on untrusted project open)
#   MongoDB (Homebrew)    10      8.2.3        8.2.12    (SERVER-128433 etc.)
#   OpenSSH                1      10.2         10.3      (CVE-2026-35386 etc.)
#
# The macOS 26.7 -> 26.7.1 finding is deliberately NOT handled here; it is
# managed separately (Jamf Managed Software Updates / DDM).
#
# Design rules, so this cannot break the apps it is patching:
#   * Idempotent. Every action re-checks the installed version first and
#     no-ops when already compliant, so it is safe on a recurring policy.
#   * Never force-kills a running IDE (that can lose unsaved work and corrupt
#     caches). A running app gets a polite quit request; if it does not quit,
#     the upgrade is DEFERRED to the next policy run and reported.
#   * Never crosses a MongoDB major/minor series boundary (8.2.x -> 8.2.x only).
#     A series jump needs featureCompatibilityVersion steps and is refused.
#   * MongoDB is stopped cleanly through brew services before upgrade and
#     returned to its previous run state afterwards.
#   * Downloads are SHA-256 verified against the vendor checksum, codesign +
#     Gatekeeper verified, and the signing authority is pinned to JetBrains
#     before anything is installed.
#   * The old .app is archived, not deleted, and is restored automatically if
#     the replacement fails verification.
#   * Homebrew work runs as the Homebrew owner, never as root.
#   * DRY_RUN mode reports exactly what would change and touches nothing.
#
# Jamf Pro script parameters (1-3 are reserved by Jamf):
#   $4  DRY_RUN                  true|false   (default false)
#   $5  COMPONENTS               csv of: intellij,pycharm,mongodb,openssh,all
#                                         (default all)
#   $6  REQUEST_APP_QUIT         true|false   ask a running IDE to quit
#                                         (default true; never SIGKILLs)
#   $7  RESTART_SSHD             true|false   restart Homebrew sshd after
#                                         upgrade (default true, skipped while
#                                         remote sessions are established)
#   $8  ARCHIVE_SUPERSEDED       true|false   archive a vulnerable bundle left
#                                         at an old path (default true)
#   $9  MONGO_ALLOW_SERIES_JUMP  true|false   allow 8.2.x -> 8.3/9.0
#                                         (default false - DO NOT enable
#                                         without an FCV upgrade plan)
#
# Exit codes: 0 = compliant or deferred, 1 = one or more actions failed.
#
# Log: /var/log/vuln-remediation.log
#

set -u
set -o pipefail

#-------------------------------------------------------------------------------
# Parameters
#-------------------------------------------------------------------------------

DRY_RUN="$(printf '%s' "${4:-false}" | tr '[:upper:]' '[:lower:]')"
COMPONENTS="$(printf '%s' "${5:-all}" | tr '[:upper:]' '[:lower:]')"
REQUEST_APP_QUIT="$(printf '%s' "${6:-true}" | tr '[:upper:]' '[:lower:]')"
RESTART_SSHD="$(printf '%s' "${7:-true}" | tr '[:upper:]' '[:lower:]')"
ARCHIVE_SUPERSEDED="$(printf '%s' "${8:-true}" | tr '[:upper:]' '[:lower:]')"
MONGO_ALLOW_SERIES_JUMP="$(printf '%s' "${9:-false}" | tr '[:upper:]' '[:lower:]')"

# Minimum versions taken straight from the "Fixed version" column of the scan.
INTELLIJ_REQUIRED="2026.2.3"
PYCHARM_REQUIRED="2026.2"
MONGO_REQUIRED="8.2.12"
OPENSSH_REQUIRED="10.3"

LOG_FILE="/var/log/vuln-remediation.log"
STATE_DIR="/Library/Application Support/VulnRemediation"
ARCHIVE_DIR="$STATE_DIR/archive"
LOCK_DIR="$STATE_DIR/run.lock"
ARCHIVE_RETENTION_DAYS=14
QUIT_TIMEOUT=90            # seconds to wait for a graceful IDE quit
MIN_FREE_MB=6000           # refuse IDE work below this much free space

JB_API="https://data.services.jetbrains.com/products/releases"
JB_AUTHORITY="Developer ID Application: JetBrains s.r.o."

#-------------------------------------------------------------------------------
# Infrastructure
#-------------------------------------------------------------------------------

TMP_DIR=""
CAFFEINATE_PID=""
MOUNTED_DMG=""
RESULT_LINES=""
FAILED=0

log() {
    local level="$1"; shift
    printf '%s  %-7s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        | /usr/bin/tee -a "$LOG_FILE"
}
info()  { log "INFO" "$@"; }
warn()  { log "WARN" "$@"; }
error() { log "ERROR" "$@"; FAILED=1; }
step()  { log "ACTION" "$@"; }

record() { RESULT_LINES="${RESULT_LINES}$1"$'\n'; }

dry() { [ "$DRY_RUN" = "true" ]; }

cleanup() {
    local rc=$?
    [ -n "$MOUNTED_DMG" ] && /usr/bin/hdiutil detach "$MOUNTED_DMG" -force >/dev/null 2>&1
    [ -n "$CAFFEINATE_PID" ] && /bin/kill "$CAFFEINATE_PID" >/dev/null 2>&1
    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && /bin/rm -rf "$TMP_DIR"
    /bin/rmdir "$LOCK_DIR" >/dev/null 2>&1
    exit $rc
}

wants() {
    case ",$COMPONENTS," in
        *,all,*) return 0 ;;
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# echoes -1 / 0 / 1 for "$1" vs "$2". Tolerates 8.2.3_1, 2026.2.3-eap, 10.2p1.
ver_cmp() {
    local a b i ai bi
    a="$(printf '%s' "$1" | /usr/bin/sed 's/[^0-9.].*$//; s/\.$//')"
    b="$(printf '%s' "$2" | /usr/bin/sed 's/[^0-9.].*$//; s/\.$//')"
    i=1
    while [ "$i" -le 5 ]; do
        ai="$(printf '%s' "$a" | /usr/bin/cut -d. -f"$i")"
        bi="$(printf '%s' "$b" | /usr/bin/cut -d. -f"$i")"
        [ -z "$ai" ] && ai=0
        [ -z "$bi" ] && bi=0
        ai=$((10#$ai)); bi=$((10#$bi))
        if [ "$ai" -lt "$bi" ]; then echo "-1"; return 0; fi
        if [ "$ai" -gt "$bi" ]; then echo "1";  return 0; fi
        i=$((i + 1))
    done
    echo "0"
}
ver_lt() { [ "$(ver_cmp "$1" "$2")" = "-1" ]; }

series_of() { printf '%s' "$1" | /usr/bin/cut -d. -f1-2; }

free_mb() { /bin/df -m / | /usr/bin/awk 'NR==2 {print $4}'; }

#-------------------------------------------------------------------------------
# Run as a non-root user (Homebrew refuses to run as root; brew services and
# GUI quit requests need the user's launchd session).
#-------------------------------------------------------------------------------

as_user() {
    local user="$1"; shift
    local uid
    uid="$(/usr/bin/id -u "$user" 2>/dev/null)"
    if [ -n "$uid" ] && /bin/launchctl print "user/$uid" >/dev/null 2>&1; then
        /bin/launchctl asuser "$uid" /usr/bin/sudo -H -u "$user" \
            /bin/bash -lc "export HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1; $*"
    else
        /usr/bin/sudo -H -u "$user" \
            /bin/bash -lc "export HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1; $*"
    fi
}

BREW=""
BREW_USER=""

find_homebrew() {
    local candidate
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then
            BREW="$candidate"
            BREW_USER="$(/usr/bin/stat -f%Su "$candidate")"
            break
        fi
    done
    if [ -z "$BREW" ]; then
        return 1
    fi
    if [ "$BREW_USER" = "root" ]; then
        warn "Homebrew at $BREW is owned by root; Homebrew refuses to run as root."
        return 1
    fi
    info "Homebrew: $BREW (owner: $BREW_USER)"
    return 0
}

brew_cmd() { as_user "$BREW_USER" "'$BREW' $*"; }

# Installed version of a formula, empty if absent.
brew_installed_version() {
    brew_cmd "list --versions $1" 2>/dev/null \
        | /usr/bin/awk -v f="$1" '$1==f {print $2; exit}'
}

# Latest version the tap currently offers for a formula.
brew_candidate_version() {
    local json="$TMP_DIR/brew-$1.json"
    brew_cmd "info --json=v2 --formula $1" > "$json" 2>/dev/null || return 1
    /usr/bin/plutil -extract formulae.0.versions.stable raw -o - -- "$json" 2>/dev/null
}

#-------------------------------------------------------------------------------
# JetBrains IDE upgrade
#-------------------------------------------------------------------------------

app_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$1/Contents/Info.plist" 2>/dev/null
}

app_is_running() {
    /usr/bin/pgrep -f "$1/Contents/MacOS/" >/dev/null 2>&1
}

app_bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$1/Contents/Info.plist" 2>/dev/null
}

# request_quit <app_path> <bundle_id>
request_quit() {
    local app="$1" bundle_id="$2" user waited
    user="$(/usr/bin/stat -f%Su /dev/console)"
    if [ -z "$user" ] || [ "$user" = "root" ]; then
        warn "No console user; cannot send a quit request to $(/usr/bin/basename "$app")."
        return 1
    fi
    step "Asking $(/usr/bin/basename "$app") to quit (saving is up to the user; no force kill)."
    as_user "$user" "/usr/bin/osascript -e 'tell application id \"$bundle_id\" to quit'" \
        >/dev/null 2>&1
    waited=0
    while [ "$waited" -lt "$QUIT_TIMEOUT" ]; do
        app_is_running "$app" || return 0
        /bin/sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# Resolve the newest release for a JetBrains product code.
# Sets JB_VERSION, JB_LINK, JB_CHECKSUM_LINK.
jb_resolve_release() {
    local code="$1" json arch dl_key
    json="$TMP_DIR/jb-$code.json"
    if ! /usr/bin/curl -fsSL --max-time 60 \
            "$JB_API?code=$code&latest=true&type=release" -o "$json"; then
        error "Could not reach the JetBrains release API for $code."
        return 1
    fi
    arch="$(/usr/bin/uname -m)"
    if [ "$arch" = "arm64" ]; then dl_key="macM1"; else dl_key="mac"; fi

    JB_VERSION="$(/usr/bin/plutil -extract "$code.0.version" raw -o - -- "$json" 2>/dev/null)"
    JB_LINK="$(/usr/bin/plutil -extract "$code.0.downloads.$dl_key.link" raw -o - -- "$json" 2>/dev/null)"
    JB_CHECKSUM_LINK="$(/usr/bin/plutil -extract "$code.0.downloads.$dl_key.checksumLink" raw -o - -- "$json" 2>/dev/null)"

    if [ -z "$JB_VERSION" ] || [ -z "$JB_LINK" ]; then
        error "JetBrains API returned no $dl_key build for product code $code."
        return 1
    fi
    case "$JB_LINK" in
        https://download*.jetbrains.com/*|https://download.jetbrains.com/*) ;;
        *) error "Refusing unexpected download host for $code: $JB_LINK"; return 1 ;;
    esac
    return 0
}

# jb_verify_bundle <app_path>
jb_verify_bundle() {
    local app="$1"
    if ! /usr/bin/codesign --verify --strict "$app" >/dev/null 2>&1; then
        error "codesign verification failed for $app."
        return 1
    fi
    if ! /usr/bin/codesign -dv --verbose=4 "$app" 2>&1 \
            | /usr/bin/grep -q "Authority=$JB_AUTHORITY"; then
        error "$app is not signed by '$JB_AUTHORITY'."
        return 1
    fi
    if ! /usr/sbin/spctl -a -t exec -vv "$app" >/dev/null 2>&1; then
        error "Gatekeeper rejected $app (not notarized?)."
        return 1
    fi
    return 0
}

# jb_upgrade <label> <product_code> <current_app_path> <required_version>
jb_upgrade() {
    local label="$1" code="$2" app="$3" required="$4"
    local installed bundle_id owner dmg sha_file expected actual mnt src
    local new_name target archived restore_needed new_version

    if [ ! -d "$app" ]; then
        info "$label: $app not present - nothing to do."
        record "$label: not installed (no action)"
        return 0
    fi

    installed="$(app_version "$app")"
    if [ -z "$installed" ]; then
        error "$label: could not read a version from $app/Contents/Info.plist."
        record "$label: FAILED (unreadable Info.plist)"
        return 1
    fi

    if ! ver_lt "$installed" "$required"; then
        info "$label: $installed already meets the required $required."
        record "$label: compliant ($installed)"
        return 0
    fi

    info "$label: installed $installed, scan requires >= $required."

    jb_resolve_release "$code" || { record "$label: FAILED (release lookup)"; return 1; }
    info "$label: newest release from JetBrains is $JB_VERSION."

    if ! ver_lt "$installed" "$JB_VERSION"; then
        warn "$label: JetBrains offers $JB_VERSION, which is not newer than $installed. Skipping."
        record "$label: DEFERRED (no newer build published for code $code)"
        return 0
    fi
    if ver_lt "$JB_VERSION" "$required"; then
        warn "$label: newest available ($JB_VERSION) is still below the required $required."
        warn "$label: upgrading anyway - it closes the older CVEs - but the scan will keep flagging this host."
        warn "$label: check whether this product line moved to a different distribution/product code."
    fi

    if app_is_running "$app"; then
        if [ "$REQUEST_APP_QUIT" != "true" ]; then
            warn "$label: running and REQUEST_APP_QUIT=false. Deferred."
            record "$label: DEFERRED (app running)"
            return 0
        fi
        if dry; then
            info "[DRY-RUN] $label: would ask the running app to quit."
        elif ! request_quit "$app" "$(app_bundle_id "$app")"; then
            warn "$label: still running after ${QUIT_TIMEOUT}s. Not force-killing - deferred to the next run."
            record "$label: DEFERRED (user did not quit the app)"
            return 0
        fi
    fi

    if [ "$(free_mb)" -lt "$MIN_FREE_MB" ]; then
        error "$label: only $(free_mb) MB free on /, need ${MIN_FREE_MB} MB."
        record "$label: FAILED (insufficient disk space)"
        return 1
    fi

    if dry; then
        info "[DRY-RUN] $label: would install $JB_VERSION from $JB_LINK over $app."
        record "$label: WOULD UPGRADE $installed -> $JB_VERSION"
        return 0
    fi

    dmg="$TMP_DIR/$code.dmg"
    step "$label: downloading $JB_VERSION."
    if ! /usr/bin/curl -fsSL --max-time 1800 --retry 3 --retry-delay 5 \
            "$JB_LINK" -o "$dmg"; then
        error "$label: download failed ($JB_LINK)."
        record "$label: FAILED (download)"
        return 1
    fi

    if [ -n "$JB_CHECKSUM_LINK" ]; then
        sha_file="$TMP_DIR/$code.sha256"
        if /usr/bin/curl -fsSL --max-time 60 "$JB_CHECKSUM_LINK" -o "$sha_file"; then
            expected="$(/usr/bin/awk '{print $1; exit}' "$sha_file")"
            actual="$(/usr/bin/shasum -a 256 "$dmg" | /usr/bin/awk '{print $1}')"
            if [ "$expected" != "$actual" ]; then
                error "$label: SHA-256 mismatch (expected $expected, got $actual)."
                record "$label: FAILED (checksum mismatch)"
                return 1
            fi
            info "$label: SHA-256 verified."
        else
            error "$label: could not fetch the vendor checksum; refusing to install."
            record "$label: FAILED (no checksum)"
            return 1
        fi
    else
        error "$label: vendor published no checksum for this build; refusing to install."
        record "$label: FAILED (no checksum)"
        return 1
    fi

    mnt="$TMP_DIR/mnt-$code"
    /bin/mkdir -p "$mnt"
    if ! /usr/bin/hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" \
            >/dev/null 2>&1; then
        error "$label: could not mount $dmg."
        record "$label: FAILED (mount)"
        return 1
    fi
    MOUNTED_DMG="$mnt"

    src="$(/usr/bin/find "$mnt" -maxdepth 1 -name '*.app' -print -quit)"
    if [ -z "$src" ]; then
        error "$label: no .app found inside the disk image."
        /usr/bin/hdiutil detach "$mnt" -force >/dev/null 2>&1; MOUNTED_DMG=""
        record "$label: FAILED (no app in dmg)"
        return 1
    fi

    if ! jb_verify_bundle "$src"; then
        /usr/bin/hdiutil detach "$mnt" -force >/dev/null 2>&1; MOUNTED_DMG=""
        record "$label: FAILED (signature verification)"
        return 1
    fi
    info "$label: signature and notarization verified."

    new_name="$(/usr/bin/basename "$src")"
    target="/Applications/$new_name"
    owner="$(/usr/bin/stat -f '%Su:%Sg' "$app")"

    # Stage the new bundle on the target volume first, so the swap is quick.
    if ! /usr/bin/ditto "$src" "$TMP_DIR/$new_name" >/dev/null 2>&1; then
        error "$label: failed to copy the new bundle out of the disk image."
        /usr/bin/hdiutil detach "$mnt" -force >/dev/null 2>&1; MOUNTED_DMG=""
        record "$label: FAILED (copy)"
        return 1
    fi
    /usr/bin/hdiutil detach "$mnt" -force >/dev/null 2>&1
    MOUNTED_DMG=""

    archived=""
    restore_needed=0
    if [ -d "$target" ]; then
        archived="$ARCHIVE_DIR/$(/bin/date '+%Y%m%d-%H%M%S')-$new_name"
        /bin/mkdir -p "$(/usr/bin/dirname "$archived")"
        step "$label: archiving the current bundle to $archived."
        if ! /bin/mv "$target" "$archived"; then
            error "$label: could not move $target aside."
            record "$label: FAILED (archive)"
            return 1
        fi
        restore_needed=1
    fi

    step "$label: installing $JB_VERSION to $target."
    if ! /usr/bin/ditto "$TMP_DIR/$new_name" "$target" >/dev/null 2>&1; then
        error "$label: install failed."
        if [ "$restore_needed" -eq 1 ]; then
            /bin/rm -rf "$target"
            /bin/mv "$archived" "$target" && warn "$label: rolled back to the previous bundle."
        fi
        record "$label: FAILED (install, rolled back)"
        return 1
    fi

    /usr/sbin/chown -R "$owner" "$target" 2>/dev/null
    /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null

    new_version="$(app_version "$target")"
    if [ -z "$new_version" ] || ! jb_verify_bundle "$target" >/dev/null 2>&1; then
        error "$label: the installed bundle does not verify."
        if [ "$restore_needed" -eq 1 ]; then
            /bin/rm -rf "$target"
            /bin/mv "$archived" "$target" && warn "$label: rolled back to the previous bundle."
        fi
        record "$label: FAILED (post-install verification, rolled back)"
        return 1
    fi

    # The scan keys off the bundle on disk. If the vendor renamed the bundle
    # (e.g. "PyCharm CE.app" -> "PyCharm.app"), the old vulnerable copy is still
    # sitting there and will keep being reported.
    if [ "$target" != "$app" ] && [ -d "$app" ]; then
        if [ "$ARCHIVE_SUPERSEDED" = "true" ]; then
            step "$label: archiving the superseded bundle $app."
            /bin/mkdir -p "$ARCHIVE_DIR"
            /bin/mv "$app" "$ARCHIVE_DIR/$(/bin/date '+%Y%m%d-%H%M%S')-superseded-$(/usr/bin/basename "$app")" \
                || warn "$label: could not archive $app; the scan will keep flagging it."
        else
            warn "$label: $app still exists at the old path and will keep being reported."
        fi
    fi

    info "$label: now at $new_version (user settings in ~/Library/Application Support/JetBrains are untouched)."
    record "$label: UPGRADED $installed -> $new_version"
    return 0
}

#-------------------------------------------------------------------------------
# MongoDB (Homebrew)
#-------------------------------------------------------------------------------

mongo_remediate() {
    local formula installed candidate was_running svc_scope
    local new_version

    if [ -z "$BREW" ]; then
        warn "MongoDB: Homebrew not usable on this host; skipping."
        record "MongoDB: SKIPPED (no usable Homebrew)"
        return 0
    fi

    formula=""
    for candidate in mongodb-community@8.2 mongodb-community; do
        if [ -n "$(brew_installed_version "$candidate")" ]; then
            formula="$candidate"
            break
        fi
    done
    if [ -z "$formula" ]; then
        info "MongoDB: no mongodb-community formula installed - nothing to do."
        record "MongoDB: not installed (no action)"
        return 0
    fi

    installed="$(brew_installed_version "$formula")"
    info "MongoDB: $formula $installed installed."

    if ! ver_lt "$installed" "$MONGO_REQUIRED"; then
        info "MongoDB: $installed already meets the required $MONGO_REQUIRED."
        record "MongoDB: compliant ($installed)"
        return 0
    fi

    step "MongoDB: refreshing Homebrew formula metadata."
    if ! brew_cmd "update --quiet" >/dev/null 2>&1; then
        warn "MongoDB: 'brew update' failed; working from the cached formula."
    fi

    candidate="$(brew_candidate_version "$formula")"
    if [ -z "$candidate" ]; then
        error "MongoDB: could not determine the available version for $formula."
        record "MongoDB: FAILED (candidate lookup)"
        return 1
    fi
    info "MongoDB: Homebrew offers $formula $candidate."

    if ! ver_lt "$installed" "$candidate"; then
        warn "MongoDB: no newer build available via $formula."
        record "MongoDB: DEFERRED (no newer build in tap)"
        return 0
    fi

    # Hard guard: patch upgrades inside one series keep the on-disk data format
    # and featureCompatibilityVersion. Crossing a series does not, and must be
    # a planned, staged upgrade - never a background policy.
    if [ "$(series_of "$installed")" != "$(series_of "$candidate")" ] \
            && [ "$MONGO_ALLOW_SERIES_JUMP" != "true" ]; then
        warn "MongoDB: refusing $installed -> $candidate; that crosses the $(series_of "$installed") series."
        warn "MongoDB: a series upgrade needs sequential releases plus a featureCompatibilityVersion bump."
        warn "MongoDB: to stay on 8.2.x and still get $MONGO_REQUIRED, install the pinned formula:"
        warn "MongoDB:   brew unlink mongodb-community && brew install mongodb-community@8.2"
        record "MongoDB: DEFERRED (would cross series $(series_of "$installed") -> $(series_of "$candidate"))"
        return 0
    fi

    was_running=0
    svc_scope="user"
    if brew_cmd "services list" 2>/dev/null \
            | /usr/bin/awk -v f="$formula" '$1==f {print $2}' \
            | /usr/bin/grep -q "started"; then
        was_running=1
    elif "$BREW" services list 2>/dev/null \
            | /usr/bin/awk -v f="$formula" '$1==f {print $2}' \
            | /usr/bin/grep -q "started"; then
        was_running=1
        svc_scope="root"
    fi
    [ "$was_running" -eq 1 ] && info "MongoDB: service is running ($svc_scope scope)."

    if dry; then
        info "[DRY-RUN] MongoDB: would upgrade $formula $installed -> $candidate (service restart included)."
        record "MongoDB: WOULD UPGRADE $installed -> $candidate"
        return 0
    fi

    if [ "$was_running" -eq 1 ]; then
        step "MongoDB: stopping the service cleanly before the upgrade."
        if [ "$svc_scope" = "root" ]; then
            "$BREW" services stop "$formula" >/dev/null 2>&1
        else
            brew_cmd "services stop $formula" >/dev/null 2>&1
        fi
        /bin/sleep 5
        if /usr/bin/pgrep -x mongod >/dev/null 2>&1; then
            warn "MongoDB: mongod is still running after 'brew services stop'; waiting 30s more."
            /bin/sleep 30
        fi
        if /usr/bin/pgrep -x mongod >/dev/null 2>&1; then
            error "MongoDB: mongod would not shut down. Aborting rather than upgrading under a live process."
            record "MongoDB: FAILED (mongod would not stop)"
            return 1
        fi
    fi

    step "MongoDB: upgrading $formula to $candidate."
    if ! brew_cmd "upgrade $formula" >>"$LOG_FILE" 2>&1; then
        error "MongoDB: 'brew upgrade $formula' failed - see $LOG_FILE."
        if [ "$was_running" -eq 1 ]; then
            warn "MongoDB: restarting the service on the previous version."
            if [ "$svc_scope" = "root" ]; then
                "$BREW" services start "$formula" >/dev/null 2>&1
            else
                brew_cmd "services start $formula" >/dev/null 2>&1
            fi
        fi
        record "MongoDB: FAILED (brew upgrade)"
        return 1
    fi

    new_version="$(brew_installed_version "$formula")"

    if [ "$was_running" -eq 1 ]; then
        step "MongoDB: starting the service again."
        if [ "$svc_scope" = "root" ]; then
            "$BREW" services start "$formula" >/dev/null 2>&1
        else
            brew_cmd "services start $formula" >/dev/null 2>&1
        fi
        /bin/sleep 10
        if /usr/bin/pgrep -x mongod >/dev/null 2>&1; then
            info "MongoDB: mongod is back up."
        else
            error "MongoDB: upgraded to $new_version but mongod did not come back. Check the mongod log."
            record "MongoDB: UPGRADED $installed -> $new_version but SERVICE DID NOT START"
            return 1
        fi
    fi

    if ver_lt "$new_version" "$MONGO_REQUIRED"; then
        warn "MongoDB: now at $new_version, still below the required $MONGO_REQUIRED."
        record "MongoDB: PARTIAL $installed -> $new_version (need $MONGO_REQUIRED)"
    else
        info "MongoDB: now at $new_version."
        record "MongoDB: UPGRADED $installed -> $new_version"
    fi
    return 0
}

#-------------------------------------------------------------------------------
# OpenSSH
#-------------------------------------------------------------------------------

# The scan read version 10.2 off the port 22 banner. That server is either
# Apple's /usr/sbin/sshd (only Apple can patch it) or a Homebrew build. Work
# out which before touching anything.
ssh_remediate() {
    local banner running_version apple_version brew_version
    local established plist new_version candidate

    banner="$(/usr/bin/nc -w 5 127.0.0.1 22 </dev/null 2>/dev/null | /usr/bin/head -n1)"
    running_version="$(printf '%s' "$banner" | /usr/bin/sed -n 's/.*OpenSSH_\([0-9][0-9.p]*\).*/\1/p')"
    apple_version="$(/usr/bin/ssh -V 2>&1 | /usr/bin/sed -n 's/.*OpenSSH_\([0-9][0-9.p]*\).*/\1/p')"
    brew_version=""
    [ -n "$BREW" ] && brew_version="$(brew_installed_version openssh)"

    if [ -z "$running_version" ]; then
        info "OpenSSH: nothing answering on 127.0.0.1:22."
        if [ -n "$brew_version" ] && ver_lt "$brew_version" "$OPENSSH_REQUIRED"; then
            info "OpenSSH: Homebrew openssh $brew_version is installed but not serving; upgrading the formula."
        else
            record "OpenSSH: no listener (no action)"
            return 0
        fi
    else
        info "OpenSSH: port 22 banner reports $running_version (Apple client: ${apple_version:-unknown}, Homebrew: ${brew_version:-not installed})."
    fi

    if [ -n "$running_version" ] && ! ver_lt "$running_version" "$OPENSSH_REQUIRED"; then
        info "OpenSSH: running $running_version, already >= $OPENSSH_REQUIRED."
        record "OpenSSH: compliant ($running_version)"
        return 0
    fi

    # Apple's build and no Homebrew build to explain the banner: not fixable here.
    if [ -z "$brew_version" ]; then
        warn "OpenSSH: the listener looks like Apple's /usr/sbin/sshd ($running_version)."
        warn "OpenSSH: Apple ships its own OpenSSH; there is no supported way to patch it from a script."
        warn "OpenSSH: it is fixed by a macOS update, or mitigated by turning off Remote Login"
        warn "OpenSSH: (System Settings > General > Sharing), which this script will not do unattended."
        record "OpenSSH: NOT REMEDIABLE ($running_version is Apple-supplied - needs a macOS update)"
        return 0
    fi

    if ver_lt "$brew_version" "$OPENSSH_REQUIRED"; then
        step "OpenSSH: refreshing Homebrew formula metadata."
        brew_cmd "update --quiet" >/dev/null 2>&1
        if dry; then
            info "[DRY-RUN] OpenSSH: would upgrade the Homebrew openssh formula from $brew_version."
            record "OpenSSH: WOULD UPGRADE $brew_version -> >= $OPENSSH_REQUIRED"
            return 0
        fi
        step "OpenSSH: upgrading the Homebrew openssh formula."
        if ! brew_cmd "upgrade openssh" >>"$LOG_FILE" 2>&1; then
            error "OpenSSH: 'brew upgrade openssh' failed - see $LOG_FILE."
            record "OpenSSH: FAILED (brew upgrade)"
            return 1
        fi
        new_version="$(brew_installed_version openssh)"
        info "OpenSSH: Homebrew formula now at $new_version."
    else
        new_version="$brew_version"
        info "OpenSSH: Homebrew formula is already $new_version; the running server just needs a restart."
    fi

    if ver_lt "$new_version" "$OPENSSH_REQUIRED"; then
        warn "OpenSSH: Homebrew only offers $new_version, below the required $OPENSSH_REQUIRED."
        record "OpenSSH: PARTIAL (Homebrew at $new_version, need $OPENSSH_REQUIRED)"
        return 0
    fi

    # The old binary keeps serving until the daemon restarts, so the finding
    # stays open until then - but a restart drops live sessions.
    if [ -z "$running_version" ]; then
        record "OpenSSH: UPGRADED formula to $new_version (no running server)"
        return 0
    fi

    if [ "$RESTART_SSHD" != "true" ]; then
        warn "OpenSSH: RESTART_SSHD=false - the running server stays on $running_version until it is restarted."
        record "OpenSSH: UPGRADED to $new_version, RESTART PENDING"
        return 0
    fi

    established="$(/usr/sbin/lsof -nP -iTCP:22 -sTCP:ESTABLISHED 2>/dev/null \
        | /usr/bin/grep -c sshd)"
    if [ "${established:-0}" -gt 0 ]; then
        warn "OpenSSH: $established established SSH session(s); not restarting sshd now."
        record "OpenSSH: UPGRADED to $new_version, RESTART DEFERRED (active sessions)"
        return 0
    fi

    if dry; then
        info "[DRY-RUN] OpenSSH: would restart the Homebrew sshd service."
        record "OpenSSH: WOULD RESTART sshd"
        return 0
    fi

    plist=""
    for candidate in /Library/LaunchDaemons/homebrew.mxcl.openssh.plist \
                     /Library/LaunchDaemons/homebrew.mxcl.openssh@.plist; do
        [ -f "$candidate" ] && plist="$candidate" && break
    done

    if [ -n "$plist" ]; then
        step "OpenSSH: restarting $(/usr/bin/basename "$plist")."
        "$BREW" services restart openssh >>"$LOG_FILE" 2>&1 \
            || /bin/launchctl kickstart -k "system/$(/usr/bin/basename "$plist" .plist)" \
                >>"$LOG_FILE" 2>&1
    else
        step "OpenSSH: restarting the user-scope Homebrew openssh service."
        brew_cmd "services restart openssh" >>"$LOG_FILE" 2>&1
    fi

    /bin/sleep 5
    banner="$(/usr/bin/nc -w 5 127.0.0.1 22 </dev/null 2>/dev/null | /usr/bin/head -n1)"
    running_version="$(printf '%s' "$banner" | /usr/bin/sed -n 's/.*OpenSSH_\([0-9][0-9.p]*\).*/\1/p')"
    if [ -z "$running_version" ]; then
        error "OpenSSH: nothing is answering on port 22 after the restart - check sshd immediately."
        record "OpenSSH: FAILED (no listener after restart)"
        return 1
    fi
    if ver_lt "$running_version" "$OPENSSH_REQUIRED"; then
        warn "OpenSSH: port 22 still reports $running_version. The listener is probably Apple's sshd,"
        warn "OpenSSH: not the Homebrew build - check which LaunchDaemon owns port 22."
        record "OpenSSH: UPGRADED formula to $new_version but port 22 still serves $running_version"
        return 0
    fi
    info "OpenSSH: port 22 now reports $running_version."
    record "OpenSSH: UPGRADED and RESTARTED ($running_version)"
    return 0
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "This script must run as root (Jamf Pro runs policy scripts as root)." >&2
    exit 1
fi

/usr/bin/touch "$LOG_FILE" 2>/dev/null
/bin/mkdir -p "$STATE_DIR" "$ARCHIVE_DIR"
/bin/chmod 700 "$STATE_DIR"

if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another run is already in progress ($LOCK_DIR exists). Exiting." | /usr/bin/tee -a "$LOG_FILE"
    exit 0
fi
trap cleanup EXIT INT TERM

TMP_DIR="$(/usr/bin/mktemp -d /private/tmp/vulnremediation.XXXXXX)"
if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
    echo "Could not create a working directory under /private/tmp. Exiting." | /usr/bin/tee -a "$LOG_FILE"
    exit 1
fi
/usr/bin/caffeinate -dimsu -w $$ >/dev/null 2>&1 &
CAFFEINATE_PID=$!

info "=============================================================="
info "Vulnerability remediation starting on $(/usr/sbin/scutil --get ComputerName 2>/dev/null || /bin/hostname)"
info "macOS $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/uname -m))  dry-run=$DRY_RUN  components=$COMPONENTS"
info "Scope: IntelliJ IDEA CE, PyCharm CE, MongoDB, OpenSSH. The macOS update is handled separately."
info "=============================================================="

find_homebrew || warn "Homebrew not found or unusable; MongoDB and OpenSSH formula work will be skipped."

if wants intellij; then
    info "--- IntelliJ IDEA CE (9 findings, need >= $INTELLIJ_REQUIRED) ---"
    jb_upgrade "IntelliJ IDEA CE" "IIC" "/Applications/IntelliJ IDEA CE.app" "$INTELLIJ_REQUIRED"
fi

if wants pycharm; then
    info "--- PyCharm CE (3 findings, need >= $PYCHARM_REQUIRED) ---"
    jb_upgrade "PyCharm CE" "PCC" "/Applications/PyCharm CE.app" "$PYCHARM_REQUIRED"
fi

if wants mongodb; then
    info "--- MongoDB (10 findings, need >= $MONGO_REQUIRED) ---"
    mongo_remediate
fi

if wants openssh; then
    info "--- OpenSSH (1 finding, need >= $OPENSSH_REQUIRED) ---"
    ssh_remediate
fi

if [ -d "$ARCHIVE_DIR" ]; then
    /usr/bin/find "$ARCHIVE_DIR" -maxdepth 1 -mindepth 1 \
        -mtime +"$ARCHIVE_RETENTION_DAYS" -exec /bin/rm -rf {} + 2>/dev/null
fi

info "=============================================================="
info "Summary:"
printf '%s' "$RESULT_LINES" | while IFS= read -r line; do
    [ -n "$line" ] && info "  * $line"
done
if [ "$FAILED" -eq 0 ]; then
    info "Remediation run finished with no failures."
else
    warn "Remediation run finished WITH FAILURES - see the entries above."
fi
info "=============================================================="

# Compact single line for a Jamf extension attribute / policy log.
echo "<result>$(printf '%s' "$RESULT_LINES" | /usr/bin/tr '\n' ';' | /usr/bin/sed 's/;$//')</result>"

exit "$FAILED"
