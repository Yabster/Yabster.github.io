#!/bin/bash
# Jamf Pro policy script: upgrade Node.js to a fixed version.
#
#   Script Parameter 4 (optional): target version, e.g. 24.21.0
#                                  Defaults to DEFAULT_VERSION below.
#
# Downloads the official nodejs.org universal .pkg, verifies it against the
# official SHASUMS256.txt published alongside it, installs it, and confirms the
# resulting version. Exits non-zero on any failure so the Jamf policy reports it.
#
# NOTE: this remediates an install that came from the official .pkg. It refuses
# to run against a Homebrew-managed Node, because laying the .pkg over Homebrew
# leaves two copies and an ambiguous PATH. See the README for that case.

set -o pipefail

DEFAULT_VERSION="24.21.0"
targetVersion="${4:-${DEFAULT_VERSION}}"

# Accept only a plain semver so a bad parameter can't build a surprise URL.
if ! [[ "${targetVersion}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "ERROR: invalid target version '${targetVersion}' (expected e.g. 24.21.0)"
	exit 1
fi

pkgName="node-v${targetVersion}.pkg"
baseURL="https://nodejs.org/dist/v${targetVersion}"
workDir="$(/usr/bin/mktemp -d /tmp/node-remediate.XXXXXX)"
trap '/bin/rm -rf "${workDir}"' EXIT

currentBin=""
for candidate in /usr/local/bin/node /opt/homebrew/bin/node; do
	[[ -x "${candidate}" ]] && currentBin="${candidate}" && break
done

if [[ -n "${currentBin}" ]]; then
	currentVersion="$("${currentBin}" --version 2>/dev/null | /usr/bin/tr -d 'v')"
	echo "Current Node: ${currentVersion:-unknown} at ${currentBin}"

	realPath="$(/usr/bin/readlink -f "${currentBin}" 2>/dev/null || echo "${currentBin}")"
	case "${realPath}" in
		*/Cellar/*|/opt/homebrew/*)
			echo "ERROR: Node is Homebrew-managed (${realPath})."
			echo "Upgrade it with 'brew upgrade node' as the owning user, not this script."
			exit 1
			;;
	esac

	# Nothing to do if we are already at or past the target.
	newest="$(printf '%s\n%s\n' "${currentVersion}" "${targetVersion}" | /usr/bin/sort -t. -k1,1n -k2,2n -k3,3n | /usr/bin/tail -1)"
	if [[ "${currentVersion}" == "${targetVersion}" || ( "${newest}" == "${currentVersion}" && "${currentVersion}" != "${targetVersion}" ) ]]; then
		echo "Already at ${currentVersion} (>= ${targetVersion}); nothing to do."
		exit 0
	fi
else
	echo "Node not currently installed; installing ${targetVersion}."
fi

echo "Downloading ${pkgName}..."
if ! /usr/bin/curl -fsSL --max-time 600 -o "${workDir}/${pkgName}" "${baseURL}/${pkgName}"; then
	echo "ERROR: failed to download ${baseURL}/${pkgName}"
	exit 1
fi

echo "Verifying checksum..."
if ! /usr/bin/curl -fsSL --max-time 120 -o "${workDir}/SHASUMS256.txt" "${baseURL}/SHASUMS256.txt"; then
	echo "ERROR: failed to download SHASUMS256.txt"
	exit 1
fi

expected="$(/usr/bin/grep " ${pkgName}\$" "${workDir}/SHASUMS256.txt" | /usr/bin/awk '{print $1}')"
actual="$(/usr/bin/shasum -a 256 "${workDir}/${pkgName}" | /usr/bin/awk '{print $1}')"

if [[ -z "${expected}" ]]; then
	echo "ERROR: no checksum published for ${pkgName}"
	exit 1
fi
if [[ "${expected}" != "${actual}" ]]; then
	echo "ERROR: checksum mismatch — refusing to install."
	echo "  expected: ${expected}"
	echo "  actual:   ${actual}"
	exit 1
fi
echo "Checksum verified: ${actual}"

echo "Installing ${pkgName}..."
if ! /usr/sbin/installer -pkg "${workDir}/${pkgName}" -target / ; then
	echo "ERROR: installer failed."
	exit 1
fi

installedVersion="$(/usr/local/bin/node --version 2>/dev/null | /usr/bin/tr -d 'v')"
if [[ "${installedVersion}" != "${targetVersion}" ]]; then
	echo "ERROR: post-install version is '${installedVersion}', expected '${targetVersion}'."
	exit 1
fi

echo "SUCCESS: Node.js is now ${installedVersion}"
exit 0
