#!/bin/bash
# Jamf Pro Extension Attribute: super status (full detail)
#
#   Data Type:  String
#   Input Type: Script
#
# Reports the complete S.U.P.E.R.M.A.N. (super) state for each Mac by reading its
# local property list at /Library/Management/super/com.macjutsu.super.plist
# (preference domain com.macjutsu.super), where super v5.x records its version,
# last status, current update target, deferral counters, and workflow state.
#
# Output is a readable SUMMARY block (the values you'll filter Smart Groups on)
# followed by a FULL DUMP of every key in the plist, wrapped in the <result>
# tags Jamf expects.
#
# Credential-adjacent fields (account names, Jamf API client id) are REDACTED —
# passwords/secrets are never stored here (they live in the System keychain), but
# account names and the client id don't belong in inventory. To see them raw,
# remove the `redact` filter near the bottom.

superBin="/usr/local/bin/super"
superPlist="/Library/Management/super/com.macjutsu.super.plist"
superDomain="/Library/Management/super/com.macjutsu.super"   # `defaults` wants no .plist
osVersion="$(/usr/bin/sw_vers -productVersion 2>/dev/null)"
osBuild="$(/usr/bin/sw_vers -buildVersion 2>/dev/null)"
arch="$(/usr/bin/uname -m)"   # arm64 = Apple silicon, x86_64 = Intel

# Read a single key from the super plist; print $2 (default) if absent/empty.
readKey() {
	local val
	val="$(/usr/bin/defaults read "${superDomain}" "${1}" 2>/dev/null)"
	if [[ -z "${val}" ]]; then printf '%s' "${2:-—}"; else printf '%s' "${val}"; fi
}

# --- Not installed / never run: report clearly and stop. -------------------
if [[ ! -x "${superBin}" && ! -f "${superPlist}" ]]; then
	echo "<result>super: NOT INSTALLED | macOS ${osVersion} (${osBuild}) | ${arch}</result>"
	exit 0
fi
if [[ ! -f "${superPlist}" ]]; then
	binVer="$("${superBin}" --version 2>/dev/null | /usr/bin/head -n 1)"
	echo "<result>super: installed (${binVer:-unknown}) but has not run yet — no status plist | macOS ${osVersion} (${osBuild}) | ${arch}</result>"
	exit 0
fi

# --- Pull the headline values. --------------------------------------------
superVersion="$(readKey SuperVersion unknown)"
superStatus="$(readKey SuperStatus)"
workflowTarget="$(readKey WorkflowTarget)"
targetTimestamp="$(readKey WorkflowTargetTimestamp)"
lastCheck="$(readKey LastSuccessfulCheckDate)"
nextLaunch="$(/usr/bin/defaults read "${superDomain}" NextAutoLaunch 2>/dev/null)"
[[ -z "${nextLaunch}" ]] && nextLaunch="—"
deferHard="$(readKey DeadlineCounterHard 0)"
deferSoft="$(readKey DeadlineCounterSoft 0)"
deferFocus="$(readKey DeadlineCounterFocus 0)"
installerDownloaded="$(readKey MacOSInstallerDownloaded No)"
scheduledInstall="$(readKey WorkflowScheduledInstall)"

# --- Build the SUMMARY block. ---------------------------------------------
summary="super ${superVersion} | macOS ${osVersion} (${osBuild}) | ${arch}
Last status:      ${superStatus}
Update target:    ${workflowTarget}  (set: ${targetTimestamp})
Deferrals used:   hard=${deferHard} soft=${deferSoft} focus=${deferFocus}
Installer cached: ${installerDownloaded}
Scheduled install:${scheduledInstall:+ ${scheduledInstall}}
Last good check:  ${lastCheck}
Next auto-launch: ${nextLaunch}"

# --- FULL DUMP of the plist, with credential-adjacent values redacted. -----
# Redact the VALUE of any key whose name matches an account/client identifier.
fullDump="$(/usr/bin/defaults read "${superDomain}" 2>/dev/null | /usr/bin/sed -E \
	's/^([[:space:]]*(AuthJamfClient|AuthJamfAccount|AuthJamfManagementID|AuthJamfComputerID|AuthLocalAccount|AuthServiceAccount|JamfAccount|LocalAccount|SuperAccount)[[:space:]]*=).*/\1 "<redacted>";/')"

printf '<result>%s\n\n--- full plist (credentials redacted) ---\n%s</result>\n' "${summary}" "${fullDump}"
exit 0
