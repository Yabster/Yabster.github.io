#!/bin/bash
# Jamf Pro policy script: uninstall Foxit PDF Reader.
#
# macOS ships Preview, which handles PDFs natively, so Foxit PDF Reader is
# usually redundant on a managed Mac fleet. Removing it closes the finding
# permanently instead of re-patching every Foxit CVE.
#
# Removes the app bundle, its package receipts, and its application-support and
# preference files for every user. It does NOT touch any PDF documents.

set -o pipefail

app="/Applications/Foxit PDF Reader.app"
removed=0

# Quit the app first so files are not in use.
if /usr/bin/pgrep -x "Foxit PDF Reader" >/dev/null 2>&1; then
	echo "Quitting Foxit PDF Reader..."
	/usr/bin/pkill -x "Foxit PDF Reader" 2>/dev/null
	sleep 3
	/usr/bin/pkill -9 -x "Foxit PDF Reader" 2>/dev/null
fi

if [[ -d "${app}" ]]; then
	version="$(/usr/bin/defaults read "${app}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)"
	echo "Removing ${app} (version ${version:-unknown})"
	/bin/rm -rf "${app}" || { echo "ERROR: failed to remove ${app}"; exit 1; }
	removed=1
else
	echo "Foxit PDF Reader is not installed at ${app}"
fi

# Forget any Foxit package receipts so future installs are clean.
while read -r pkgid; do
	[[ -z "${pkgid}" ]] && continue
	echo "Forgetting receipt: ${pkgid}"
	/usr/sbin/pkgutil --forget "${pkgid}" >/dev/null 2>&1
done < <(/usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -iE 'foxit')

# System-level support files.
for path in \
	"/Library/Application Support/Foxit Software" \
	"/Library/Internet Plug-Ins/Foxit Reader Plugin.plugin"
do
	[[ -e "${path}" ]] && echo "Removing ${path}" && /bin/rm -rf "${path}"
done

# Per-user preferences and support files. Only touches Foxit's own files.
for userHome in /Users/*; do
	[[ -d "${userHome}" ]] || continue
	[[ "$(/usr/bin/basename "${userHome}")" == "Shared" ]] && continue

	[[ -d "${userHome}/Library/Application Support/Foxit Software" ]] && \
		/bin/rm -rf "${userHome}/Library/Application Support/Foxit Software"

	/usr/bin/find "${userHome}/Library/Preferences" -maxdepth 1 \
		-iname "com.foxit*" -print -delete 2>/dev/null

	/usr/bin/find "${userHome}/Library/Caches" -maxdepth 1 \
		-iname "com.foxit*" -print -exec /bin/rm -rf {} + 2>/dev/null
done

if [[ ${removed} -eq 1 ]]; then
	echo "SUCCESS: Foxit PDF Reader removed."
else
	echo "SUCCESS: nothing to remove (already absent); leftover files cleaned."
fi
exit 0
