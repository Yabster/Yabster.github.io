#!/bin/bash

# remove_pages.sh
# Removes the Apple Pages app from a Mac.
# Intended to run as a Jamf Pro policy script (executes as root).

APP="/Applications/Pages.app"

if [ -d "$APP" ]; then
    echo "Pages found. Removing $APP ..."
    rm -rf "$APP"
    if [ -d "$APP" ]; then
        echo "ERROR: Failed to remove Pages."
        exit 1
    fi
    echo "Pages removed successfully."
else
    echo "Pages is not installed. Nothing to do."
fi

exit 0
