#!/usr/bin/env bash
#
# Remove the gitchecker launchd service and installed files.
# Leaves your config and database (~/Library/Application Support/gitchecker) intact.

set -euo pipefail

LABEL="com.user.gitchecker"
UID_NUM="$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/.local/bin/gitchecker"

echo "==> Stopping and unloading the service"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true

echo "==> Removing files"
rm -f "$PLIST" "$BIN"
for app in /Applications/GitCheckerBar.app "$HOME/Applications/GitCheckerBar.app"; do
    [ -e "$app" ] && rm -rf "$app" && echo "    removed $app"
done

cat <<EOF

✅ Uninstalled.
   • If you enabled "Start at login", also turn it off (it may linger in
     System Settings → General → Login Items).
   • Config + database were left in ~/Library/Application Support/gitchecker
     (delete manually if you want a clean slate).
EOF
