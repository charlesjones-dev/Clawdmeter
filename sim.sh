#!/bin/bash
# Build (if needed) and run the desktop simulator — an SDL2 window running the
# real firmware loop against firmware/sim/scenario.jsonl playback.
#
#   ./sim.sh                 build if missing, then run
#   ./sim.sh --build         force a rebuild first (after editing firmware/)
#   ./sim.sh --usage         boot straight to the usage view (skip the splash)
#   ./sim.sh --scenario F    play a different .jsonl (default firmware/sim/scenario.jsonl)
#   ./sim.sh --size 368x448  build for another panel geometry (368x448 or 240x240;
#                            rebuilds the sim env in place — run --size 480x480 to go back)
#
# Controls: mouse = touch · space = play/pause · ←/→ step · 1-9 jump · d = BLE
# toggle · b/n = buttons · p = PWR · c/-/= battery · s = screenshot · esc = quit.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$HERE/firmware"
BIN="$FW/.pio/build/sim/program"

build=false
while [ $# -gt 0 ]; do
    case "$1" in
        --build)    build=true ;;
        --usage)    export SIM_BOOT_SCREEN=usage ;;
        --scenario) shift; export SIM_SCENARIO="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" ;;
        --size)     shift
                    w="${1%x*}"; h="${1#*x}"
                    export PLATFORMIO_BUILD_FLAGS="-DLCD_WIDTH=$w -DLCD_HEIGHT=$h"
                    build=true ;;
        -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Launch from firmware/ so the default scenario path resolves.
cd "$FW"
exec "$BIN"
