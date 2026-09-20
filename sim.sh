#!/bin/bash
# Build (if needed) and run the desktop simulator — an SDL2 window running the
# real firmware loop. By default it shows LIVE data: the daemon mirrors every
# payload to ~/.config/claude-usage-monitor/latest.json and the window follows
# it, so you see what the board shows (with the board off, the daemon keeps
# polling and the window still updates).
#
#   ./sim.sh                 live mode, boots to the usage view (build if missing)
#   ./sim.sh --top           …and keep the window above others
#   ./sim.sh --splash        live mode, but boot to the splash like hardware
#   ./sim.sh --demo          scenario playback from firmware/sim/scenario.jsonl
#   ./sim.sh --scenario F    scenario playback from another .jsonl
#   ./sim.sh --build         force a rebuild first (after editing firmware/)
#   ./sim.sh --size 368x448  build for another panel geometry (368x448 or 240x240;
#                            rebuilds the sim env in place — run --size 480x480 to go back)
#
# Controls: mouse = touch · d = link toggle · b/n = buttons · p = PWR ·
# c/-/= battery · s = screenshot · esc = quit. In demo mode also: space =
# play/pause · ←/→ step · 1-9 jump.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$HERE/firmware"
BIN="$FW/.pio/build/sim/program"

build=false
mode=live
boot=usage
while [ $# -gt 0 ]; do
    case "$1" in
        --build)    build=true ;;
        --top)      export SIM_ALWAYS_ON_TOP=1 ;;
        --splash)   boot=splash ;;
        --usage)    boot=usage ;;
        --demo)     mode=scenario ;;
        --scenario) shift; mode=scenario
                    export SIM_SCENARIO="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" ;;
        --size)     shift
                    w="${1%x*}"; h="${1#*x}"
                    export PLATFORMIO_BUILD_FLAGS="-DLCD_WIDTH=$w -DLCD_HEIGHT=$h"
                    build=true ;;
        -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

PIO="$(command -v pio || true)"
[ -z "$PIO" ] && [ -x "$HOME/.platformio/penv/bin/pio" ] && PIO="$HOME/.platformio/penv/bin/pio"
[ -z "$PIO" ] && { echo "PlatformIO not found (brew install platformio)"; exit 1; }
command -v sdl2-config >/dev/null || { echo "SDL2 dev headers not found (brew install sdl2 / apt install libsdl2-dev)"; exit 1; }

if $build || [ ! -x "$BIN" ]; then
    echo "Building sim..."
    "$PIO" run -d "$FW" -e sim
fi

if [ "$mode" = live ]; then
    export SIM_MODE=live
    [ -f "$HOME/.config/claude-usage-monitor/latest.json" ] || \
        echo "Note: no latest.json yet — start the daemon (install-mac.sh / install.sh) and the window will fill in."
else
    unset SIM_MODE
fi
[ "$boot" = usage ] && export SIM_BOOT_SCREEN=usage

# Launch from firmware/ so the default scenario path resolves.
cd "$FW"
exec "$BIN"
