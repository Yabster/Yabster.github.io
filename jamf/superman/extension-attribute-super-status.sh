#!/bin/bash
# Jamf Pro Extension Attribute: super status
#
# Data Type: String
# Input Type: Script
#
# Reports whether S.U.P.E.R.M.A.N. (super) is installed, its version, and the
# current on-device macOS version. Use it to build a Smart Group / dashboard that
# tracks the 26.6.2 enforcement (e.g. "super installed AND OS still < 26.6.2").
#
# Output is wrapped in the <result></result> tags Jamf expects.

superBin="/usr/local/bin/super"
osVersion="$(/usr/bin/sw_vers -productVersion 2>/dev/null)"

if [[ -x "${superBin}" ]]; then
	# super --version prints just the version string.
	superVersion="$("${superBin}" --version 2>/dev/null | /usr/bin/head -n 1)"
	[[ -z "${superVersion}" ]] && superVersion="unknown"
	result="Installed ${superVersion}; macOS ${osVersion}"
else
	result="Not installed; macOS ${osVersion}"
fi

echo "<result>${result}</result>"
exit 0
