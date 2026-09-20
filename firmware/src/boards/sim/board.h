#pragma once

// Native desktop simulator "board" — an SDL2 window standing in for the
// 480×480 AMOLED so shared code (main.cpp, ui.cpp, splash.cpp) can be
// developed without hardware. No pins here, just geometry and the key map.
//
//   mouse / left-drag    touch (tap toggles splash <-> usage)
//   space                play/pause scenario playback
//   left / right         step one scenario state (pauses playback)
//   1..9                 jump to scenario state N (pauses playback)
//   d                    toggle BLE connected/disconnected
//   b (hold)             PRIMARY button  (BOOT — HID Space PTT on hardware)
//   n (hold)             SECONDARY button (HID Shift+Tab on hardware)
//   p                    PWR button (short press; hold ~3s + release = pair)
//   c                    toggle charging       - / =   battery down / up 5%
//   s                    save screenshot BMP to the current directory
//   esc / window close   quit
//
// Scenario: sim/scenario.jsonl (relative to the firmware/ dir), overridable
// with SIM_SCENARIO=<path>. One JSON object per line — the daemon payload
// plus optional "name" and "hold_ms" (default 3000). Lines starting with #
// are comments. Missing file → a small built-in state list.
//
// Headless / CI: SDL_VIDEODRIVER=dummy SIM_AUTOSHOT_MS=<ms> saves a
// screenshot (SIM_AUTOSHOT_PATH, default sim-autoshot.bmp) after <ms> and
// exits.

// Geometry defaults to the 480×480 AMOLED-2.16. Other breakpoints can be QA'd
// without hardware by overriding at build time, e.g. the 1.8" or 1.54" panels:
//   PLATFORMIO_BUILD_FLAGS="-DLCD_WIDTH=368 -DLCD_HEIGHT=448" pio run -d firmware -e sim
//   PLATFORMIO_BUILD_FLAGS="-DLCD_WIDTH=240 -DLCD_HEIGHT=240" pio run -d firmware -e sim
// (rebuilds the sim env in place; run without the override to go back to 480).
//
// Headless QA: SIM_BOOT_SCREEN=usage skips the splash at boot so SIM_AUTOSHOT_MS
// captures the usage view without a button press or a main.cpp edit.
//
// Live mode: SIM_MODE=live follows the daemon's latest.json mirror
// (~/.config/claude-usage-monitor/latest.json, override with SIM_LIVE_FILE)
// instead of the scenario — the window shows what the board shows.
// SIM_ALWAYS_ON_TOP=1 keeps the window above others. `./sim.sh` sets these.

#define BOARD_NAME  "Simulator"
#ifndef LCD_WIDTH
#define LCD_WIDTH   480
#endif
#ifndef LCD_HEIGHT
#define LCD_HEIGHT  480
#endif
