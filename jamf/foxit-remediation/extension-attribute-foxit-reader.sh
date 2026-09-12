#!/bin/bash
# Jamf Pro Extension Attribute: Foxit PDF Reader version
#
#   Data Type:  String
#   Input Type: Script
#
# Reports the installed Foxit PDF Reader version so you can scope remediation
# and watch the affected count drain. Reads CFBundleShortVersionString from the
# app bundle, which is the value vulnerability scanners compare against.

app="/Applications/Foxit PDF Reader.app"
plist="${app}/Contents/Info.plist"

if [[ ! -d "${app}" ]]; then
	echo "<result>Not installed</result>"
	exit 0
fi

version="$(/usr/bin/defaults read "${plist}" CFBundleShortVersionString 2>/dev/null)"
[[ -z "${version}" ]] && version="$(/usr/bin/defaults read "${plist}" CFBundleVersion 2>/dev/null)"
[[ -z "${version}" ]] && version="unknown"

# Last-used date helps decide whether anyone actually needs this app.
lastUsed="$(/usr/bin/mdls -name kMDItemLastUsedDate -raw "${app}" 2>/dev/null)"
[[ -z "${lastUsed}" || "${lastUsed}" == "(null)" ]] && lastUsed="never recorded"

echo "<result>${version} | last used: ${lastUsed}</result>"
exit 0
