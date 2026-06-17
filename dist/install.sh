#!/usr/bin/env bash
#
# Install gitchecker on macOS:
#   - the Rust server as a launchd LaunchAgent (starts at login, restarts on crash)
#   - the SwiftUI menu bar app into /Applications (or ~/Applications)
#
# Re-run any time to upgrade to the latest build. Safe to run repeatedly.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.user.gitchecker"
UID_NUM="$(id -u)"

BIN_DST="$HOME/.local/bin/gitchecker"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/gitchecker.log"

echo "==> Building the server (release)…"
( cd "$REPO" && cargo build --release )

echo "==> Installing server binary → $BIN_DST"
mkdir -p "$HOME/.local/bin"
install -m 755 "$REPO/target/release/gitchecker" "$BIN_DST"

echo "==> Rendering LaunchAgent → $PLIST_DST"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed -e "s|__BIN__|$BIN_DST|g" -e "s|__LOG__|$LOG|g" \
    "$REPO/dist/$LABEL.plist" > "$PLIST_DST"

echo "==> (Re)loading the service via launchctl"
# Stop any previous instance of the agent, then load fresh. Ignore "not loaded".
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "==> Waiting for the API to come up…"
for _ in $(seq 1 20); do
    if curl -fsS http://127.0.0.1:7878/healthz >/dev/null 2>&1; then
        echo "    server is up (http://127.0.0.1:7878)"
        break
    fi
    sleep 0.5
done

# --- GUI app -----------------------------------------------------------------
echo "==> Building the menu bar app…"
"$REPO/clients/menubar/package-app.sh"

APP_SRC="$REPO/clients/menubar/build/GitCheckerBar.app"
if cp -R "$APP_SRC" /Applications/ 2>/dev/null; then
    APP_DST="/Applications/GitCheckerBar.app"
else
    mkdir -p "$HOME/Applications"
    cp -R "$APP_SRC" "$HOME/Applications/"
    APP_DST="$HOME/Applications/GitCheckerBar.app"
fi
# Replace an existing copy cleanly.
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$(dirname "$APP_DST")/"
echo "==> Installed app → $APP_DST"

open "$APP_DST"

cat <<EOF

✅ Done.
   • Server runs as a launchd service (label: $LABEL). Logs: $LOG
   • Menu bar app launched from $APP_DST
   • To start the app at login: open its menu (⚠/✓ icon) and toggle
     "Start at login".

   Uninstall any time with: dist/uninstall.sh
EOF
