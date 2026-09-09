#!/bin/bash
# Jamf Pro Extension Attribute: Node.js version and install source
#
#   Data Type:  String
#   Input Type: Script
#
# Reports the installed Node.js version AND how it was installed, because the
# remediation differs: the official nodejs.org .pkg is upgraded by installing a
# newer .pkg, while a Homebrew install must be upgraded with brew as the owning
# user (installing the .pkg over it creates a conflicting second copy).
#
# Use the version string to build a Smart Group of machines needing remediation.

report() { echo "<result>$1</result>"; exit 0; }

# Look in the usual places; PATH is minimal when Jamf runs a script as root.
nodeBin=""
for candidate in /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/node; do
	[[ -x "${candidate}" ]] && nodeBin="${candidate}" && break
done

[[ -z "${nodeBin}" ]] && report "Not installed"

version="$("${nodeBin}" --version 2>/dev/null | /usr/bin/tr -d 'v')"
[[ -z "${version}" ]] && version="unknown"

# Resolve symlinks to work out who owns this install.
realPath="$(/usr/bin/readlink -f "${nodeBin}" 2>/dev/null || echo "${nodeBin}")"
case "${realPath}" in
	*/Cellar/*|/opt/homebrew/*) source="Homebrew" ;;
	*/.nvm/*)                   source="nvm (per-user)" ;;
	/usr/local/*)
		# The official .pkg records a receipt; Homebrew on Intel does not.
		if /usr/sbin/pkgutil --pkg-info org.nodejs.node.pkg >/dev/null 2>&1; then
			source="official pkg"
		else
			source="/usr/local (unknown installer)"
		fi
		;;
	*) source="other" ;;
esac

report "${version} | ${source} | ${nodeBin}"
