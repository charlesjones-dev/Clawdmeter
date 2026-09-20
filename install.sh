#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="claude-usage-daemon"
SERVICE_FILE="$SCRIPT_DIR/daemon/$SERVICE_NAME.service"
USER_SERVICE_DIR="$HOME/.config/systemd/user"
CONFIG_FILE="$HOME/.config/claude-usage-monitor/config"

# Render an absolute path under $HOME back to a ~ form for tidy config entries.
_tilde() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}";; *) echo "$1";; esac; }

# Echo the current value of a config key (trimmed), or empty if unset.
current_config_value() {
    [ -f "$CONFIG_FILE" ] || return 0
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG_FILE" | tail -1 \
        | tr -d '\r' \
        | sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//; s/[[:space:]]*(#.*)?$//"
}

# Insert or replace `key = value`, preserving every other key in the file.
upsert_config_key() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    touch "$CONFIG_FILE"
    grep -vE "^[[:space:]]*$key[[:space:]]*=" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "$key = $value" >> "$CONFIG_FILE"
}

# Detect ~/.claude* config dirs that hold credentials and, if more than one is
# found, let the user pick which plans to show. The daemon polls all chosen dirs
# and displays whichever is active. Writes the `config_dirs` key, preserving any
# other keys already in the config file. No-op (default ~/.claude) if only one
# dir exists or the user opts out.
configure_config_dirs() {
    local -a candidates=()
    local d
    for d in "$HOME"/.claude*; do
        [ -d "$d" ] && [ -f "$d/.credentials.json" ] && candidates+=("$d")
    done

    if [ ${#candidates[@]} -le 1 ]; then
        echo "  One Claude config dir found — using the default (~/.claude)."
        return 0
    fi

    echo "  Found multiple Claude config dirs. The daemon can poll several plans"
    echo "  and show whichever one you're actively using."
    if [ ! -t 0 ]; then
        local list=""
        for d in "${candidates[@]}"; do list="${list:+$list, }$(_tilde "$d")"; done
        echo "  Non-interactive shell — skipping. To enable, add to $CONFIG_FILE:"
        echo "    config_dirs = $list"
        return 0
    fi

    local -a selected=()
    local ans
    for d in "${candidates[@]}"; do
        if [ "$d" = "$HOME/.claude" ]; then
            read -r -p "  Poll $(_tilde "$d")? [Y/n] " ans || ans=""
            if [[ ! "$ans" =~ ^[Nn]$ ]]; then selected+=("$d"); fi
        else
            read -r -p "  Also poll $(_tilde "$d")? [y/N] " ans || ans=""
            if [[ "$ans" =~ ^[Yy]$ ]]; then selected+=("$d"); fi
        fi
    done

    if [ ${#selected[@]} -eq 0 ]; then
        echo "  Nothing selected — leaving the default (~/.claude)."
        return 0
    fi
    if [ ${#selected[@]} -eq 1 ] && [ "${selected[0]}" = "$HOME/.claude" ]; then
        echo "  Default (~/.claude) only — no config change needed."
        return 0
    fi

    local joined="" sd
    for sd in "${selected[@]}"; do joined="${joined:+$joined, }$(_tilde "$sd")"; done

    upsert_config_key config_dirs "$joined"
    echo "  Wrote: config_dirs = $joined"
    echo "  -> $CONFIG_FILE"
}

# Offer the optional clock display (shown in place of the "Usage" title). Only
# writes the key when it actually changes the current/default value, so a user
# pressing Enter through the installer never clutters the config with defaults.
configure_clock() {
    [ -t 0 ] || return 0
    local ans cur
    cur=$(current_config_value clock)
    read -r -p "  Show a clock instead of the \"Usage\" title? [off/auto/12/24] (default off) " ans || ans=""
    ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [ -z "$ans" ] && ans="off"
    case "$ans" in
        off|auto|12|24) ;;
        *) echo "  Unrecognized '$ans' — leaving clock unchanged."; return 0 ;;
    esac
    if [ "$ans" = "off" ] && { [ -z "$cur" ] || [ "$cur" = "off" ]; }; then
        echo "  Clock off (default)."
        return 0
    fi
    upsert_config_key clock "$ans"
    echo "  Set: clock = $ans"
}

# Validate a key name with the daemon's own parser (KEYMAP_PY heredoc in
# claude-usage-daemon.sh) so the installer and daemon can never disagree.
validate_key_spec() {
    if [ -z "${KEYMAP_PY:-}" ]; then
        eval "$(awk '/^read -r -d .. KEYMAP_PY <<.PYEOF.$/{f=1} f{print} f&&/^PYEOF$/{exit}' "$SCRIPT_DIR/daemon/claude-usage-daemon.sh")"
    fi
    python3 -c "$KEYMAP_PY" "$1" >/dev/null 2>&1
}

# Offer custom key bindings for the two side buttons (boards with one button
# only use the left one). Names: space, tab, enter, esc, backspace, letters,
# digits, f1-f12, arrows (up/down/left/right), home/end/pageup/pagedown, and
# chords with ctrl/shift/alt/cmd, e.g. ctrl+shift+p. "none" disables a button.
# Only writes a key when it differs from the current/default value.
configure_buttons() {
    [ -t 0 ] || return 0
    echo "  The side buttons each send a key over Bluetooth (chords OK, e.g. ctrl+shift+p;"
    echo "  'none' disables a button). Press Enter to keep the value in brackets."
    local side label def cur ans
    for side in left right; do
        case "$side" in
            left)  label="Left";  def="space" ;;
            *)     label="Right"; def="shift+tab" ;;
        esac
        cur=$(current_config_value "button_$side")
        read -r -p "  $label button key [${cur:-$def}]: " ans || ans=""
        ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        [ -z "$ans" ] && ans="${cur:-$def}"
        if ! validate_key_spec "$ans"; then
            echo "  Unrecognized '$ans' — leaving button_$side unchanged."
            continue
        fi
        if [ "$ans" = "$cur" ]; then
            echo "  $label button: $ans (unchanged)."
        elif [ -z "$cur" ] && [ "$ans" = "$def" ]; then
            echo "  $label button: $def (default)."
        else
            upsert_config_key "button_$side" "$ans"
            echo "  Set: button_$side = $ans"
        fi
    done
}

# Offer the optional session-reset chime (sound through the board speaker).
configure_chime() {
    [ -t 0 ] || return 0
    local ans cur
    cur=$(current_config_value chime)
    read -r -p "  Chime through the speaker when your 5h session limit resets? [y/N] " ans || ans=""
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        upsert_config_key chime on
        echo "  Set: chime = on"
    elif [ "$cur" = "on" ]; then
        upsert_config_key chime off
        echo "  Set: chime = off"
    else
        echo "  Chime off (default)."
    fi
}

echo "=== Claude Usage Tracker - Install ==="
echo ""

# Check dependencies
echo "[1/4] Checking dependencies..."
for cmd in curl awk python3 bluetoothctl busctl; do
    command -v "$cmd" >/dev/null || { echo "Error: $cmd is required but not installed"; exit 1; }
done
echo "  All dependencies found"
echo ""

# Install systemd user service with resolved path
echo "[2/4] Installing systemd user service..."
mkdir -p "$USER_SERVICE_DIR"
DAEMON_BIN="$SCRIPT_DIR/daemon/$SERVICE_NAME.sh"
sed "s|DAEMON_PATH|${DAEMON_BIN}|g" "$SERVICE_FILE" > "$USER_SERVICE_DIR/$SERVICE_NAME.service"
systemctl --user daemon-reload

# Interactive daemon configuration: which plans to poll, plus the optional
# clock display and session-reset chime. All re-read by the daemon each poll.
echo "[3/4] Configuring the daemon..."
configure_config_dirs
configure_clock
configure_chime
configure_buttons
echo ""

# Enable service
echo "[4/4] Enabling service..."
systemctl --user enable "$SERVICE_NAME"

echo ""
echo "=== Done! ==="
echo ""
echo "The daemon will now start automatically when you log in"
echo "and connect to the SC01 Plus over Bluetooth Low Energy."
echo ""
echo "First-time Bluetooth pairing:"
echo "  1. Power on the SC01 Plus"
echo "  2. Run: bluetoothctl scan le"
echo "  3. Find 'Clawdmeter' and note the MAC address"
echo "  4. Run: bluetoothctl pair <MAC>"
echo "  5. Run: bluetoothctl trust <MAC>"
echo "  6. Start the daemon: systemctl --user start $SERVICE_NAME"
echo ""
echo "Useful commands:"
echo "  systemctl --user status $SERVICE_NAME    # check status"
echo "  journalctl --user -u $SERVICE_NAME -f    # view logs"
echo "  systemctl --user restart $SERVICE_NAME   # restart"
echo "  systemctl --user stop $SERVICE_NAME      # stop"
echo ""
