#!/bin/bash
# Linux uninstaller for Clawdmeter: removes everything install.sh set up.
#
#   ./uninstall.sh            uninstall
#   ./uninstall.sh --dry-run  show what would be removed; change nothing
#
# Stops and disables the systemd user service, deletes its unit file, and
# deletes ~/.config/claude-usage-monitor (config, cached BLE address,
# latest.json). No sudo. Safe to re-run: anything already gone is skipped.
#
# Not touched: the repository, your Claude Code login (~/.claude), the
# journal's past log lines, and the Bluetooth pairing (the command to remove
# it is printed at the end).
set -e

SERVICE_NAME="claude-usage-daemon"
USER_SERVICE_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$USER_SERVICE_DIR/$SERVICE_NAME.service"
WANTS_LINK="$USER_SERVICE_DIR/default.target.wants/$SERVICE_NAME.service"
CONFIG_DIR="$HOME/.config/claude-usage-monitor"
DAEMON_PATTERN="daemon/claude-usage-daemon\.sh"

DRY_RUN=false
for a in "$@"; do
    case "$a" in
        -n|--dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a"; exit 1 ;;
    esac
done

# Render an absolute path under $HOME back to a ~ form for tidy output.
_tilde() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}";; *) echo "$1";; esac; }

# Delete a file, symlink (even a dangling one), or directory, or say it's
# already gone.
remove() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        echo "  Not found: $(_tilde "$1") (skipping)"
    elif $DRY_RUN; then
        echo "  Would delete $(_tilde "$1")"
    else
        rm -rf "$1"
        echo "  Deleted $(_tilde "$1")"
    fi
}

HAVE_SYSTEMD=true
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    HAVE_SYSTEMD=false
fi

echo "=== Clawdmeter Linux uninstall ==="
$DRY_RUN && echo "(dry run: nothing will be changed)"
echo ""

echo "[1/3] Stopping the daemon..."
if ! $HAVE_SYSTEMD; then
    echo "  No systemd user session (skipping; files are still removed below)"
elif systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null \
        || systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    if $DRY_RUN; then
        echo "  Would stop and disable $SERVICE_NAME"
    else
        # Disable while the unit file still exists so systemd can find its
        # [Install] section and drop the default.target.wants link.
        systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null \
            || systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
        echo "  Stopped and disabled $SERVICE_NAME"
    fi
else
    echo "  Service not enabled or running (skipping)"
fi
# A foreground run (./daemon/claude-usage-daemon.sh) isn't managed by systemd.
# SIGTERM runs the daemon's cleanup trap, which also stops its dbus-monitor.
if ! $DRY_RUN && pgrep -f "$DAEMON_PATTERN" >/dev/null 2>&1; then
    pkill -f "$DAEMON_PATTERN" || true
    echo "  Stopped a leftover daemon process"
fi
echo ""

echo "[2/3] Removing the systemd unit..."
remove "$UNIT_FILE"
remove "$WANTS_LINK"
if $HAVE_SYSTEMD && ! $DRY_RUN; then
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user reset-failed "$SERVICE_NAME" 2>/dev/null || true
fi
echo ""

echo "[3/3] Deleting config and cached state..."
# Read the cached device address first so the unpair hint can name it.
MAC=""
[ -f "$CONFIG_DIR/ble-address" ] && MAC=$(tr -d '[:space:]' < "$CONFIG_DIR/ble-address")
remove "$CONFIG_DIR"
echo ""

echo "=== Done ==="
echo ""
echo "Left in place:"
if [ -n "$MAC" ]; then
    echo "  - Bluetooth pairing: bluetoothctl remove $MAC"
else
    echo "  - Bluetooth pairing: bluetoothctl devices (find Clawdmeter), then bluetoothctl remove <MAC>"
fi
echo "  - The repo"
