#!/bin/bash
# macOS uninstaller for Clawdmeter: removes everything install-mac.sh set up,
# plus the simulator app that `./make-app.sh --install` copies to ~/Applications.
#
#   ./uninstall-mac.sh            uninstall
#   ./uninstall-mac.sh --dry-run  show what would be removed; change nothing
#
# Stops and removes the LaunchAgent, deletes daemon/.venv, the daemon's logs in
# ~/Library/Logs, and ~/.config/claude-usage-monitor (config, cached BLE
# address, latest.json). No sudo. Safe to re-run: anything already gone is
# skipped.
#
# Not touched: the repository (including dist/), your Claude Code login
# (Keychain), blueutil, Bluetooth permission grants, and the Bluetooth pairing.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_LABEL="com.user.claude-usage-daemon"
PLIST_DST="$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"
VENV_DIR="$SCRIPT_DIR/daemon/.venv"
LOG_DIR="$HOME/Library/Logs"
CONFIG_DIR="$HOME/.config/claude-usage-monitor"
APP="$HOME/Applications/Clawdmeter.app"
BUNDLE_ID="dev.charlesjones.clawdmeter"   # make-app.sh's; guards the app delete
DAEMON_PATTERN="daemon/claude_usage_daemon\.py"

DRY_RUN=false
for a in "$@"; do
    case "$a" in
        -n|--dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a"; exit 1 ;;
    esac
done

# Render an absolute path under $HOME back to a ~ form for tidy output.
_tilde() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}";; *) echo "$1";; esac; }

# Delete a file or directory, or say it's already gone.
remove() {
    if [ ! -e "$1" ]; then
        echo "  Not found: $(_tilde "$1") (skipping)"
    elif $DRY_RUN; then
        echo "  Would delete $(_tilde "$1")"
    else
        rm -rf "$1"
        echo "  Deleted $(_tilde "$1")"
    fi
}

echo "=== Clawdmeter macOS uninstall ==="
$DRY_RUN && echo "(dry run: nothing will be changed)"
echo ""

echo "[1/5] Stopping the daemon..."
# Unload before killing anything: the LaunchAgent restarts a daemon that dies
# with a non-zero exit (KeepAlive/SuccessfulExit=false).
if launchctl list "$SERVICE_LABEL" >/dev/null 2>&1; then
    if $DRY_RUN; then
        echo "  Would unload $SERVICE_LABEL"
    else
        launchctl bootout "gui/$(id -u)/$SERVICE_LABEL" 2>/dev/null \
            || launchctl unload "$PLIST_DST" 2>/dev/null || true
        echo "  Unloaded $SERVICE_LABEL"
    fi
else
    echo "  LaunchAgent not loaded (skipping)"
fi
# A foreground run (e.g. the installer's permission-priming scan) isn't
# managed by launchd.
if ! $DRY_RUN && pgrep -f "$DAEMON_PATTERN" >/dev/null; then
    pkill -f "$DAEMON_PATTERN" || true
    echo "  Stopped a leftover daemon process"
fi
echo ""

echo "[2/5] Removing the LaunchAgent and its logs..."
remove "$PLIST_DST"
remove "$LOG_DIR/claude-usage-daemon.out.log"
remove "$LOG_DIR/claude-usage-daemon.err.log"
echo ""

echo "[3/5] Deleting the Python virtualenv..."
remove "$VENV_DIR"
echo ""

echo "[4/5] Deleting config and cached state..."
remove "$CONFIG_DIR"
echo ""

echo "[5/5] Removing the desktop simulator app..."
if [ -d "$APP" ]; then
    app_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
    if [ "$app_id" = "$BUNDLE_ID" ]; then
        if ! $DRY_RUN && pgrep -f "$APP/Contents/MacOS/" >/dev/null; then
            pkill -f "$APP/Contents/MacOS/" || true
            echo "  Quit the running app"
        fi
        remove "$APP"
    else
        echo "  $(_tilde "$APP") isn't the Clawdmeter simulator (bundle id '${app_id}'), leaving it"
    fi
else
    echo "  Not found: $(_tilde "$APP") (skipping)"
fi
echo ""

echo "=== Done ==="
echo ""
echo "Left in place:"
echo "  - Bluetooth pairing: System Settings → Bluetooth → Clawdmeter → Forget This Device"
echo "  - blueutil: brew uninstall blueutil (if nothing else uses it)"
echo "  - The repo, including dist/ (make-app.sh build output)"
