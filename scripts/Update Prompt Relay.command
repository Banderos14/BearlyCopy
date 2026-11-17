#!/bin/bash
# Double-click in Finder to update BearlyCopy from THIS checkout (Phase 16).
#
# It runs scripts/install-local.sh, which shows what is installed and what
# would be installed, asks before changing anything, keeps the old app as a
# backup and verifies the new one after launch. It does not pull, download or
# change any code, and never deletes backups. Close the window to cancel.
cd "$(dirname "$0")/.." || exit 1
clear
echo "BearlyCopy — update from this folder"
echo "   $(pwd)"
echo "   branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'), commit $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo
scripts/install-local.sh --status
echo
printf 'Build and check a new copy now (nothing is installed without a second yes)? [y/N] '
read -r go
case "$go" in
    y|Y|yes|YES) scripts/install-local.sh ;;
    *) echo "Nothing changed." ;;
esac
status=$?
echo
if [ $status -ne 0 ]; then
    echo "Not updated (see the message above). Your installed app was not changed unless it says so."
    echo "To go back to the previous version later: scripts/install-local.sh --rollback"
fi
printf 'Press Return to close this window. '
read -r _
