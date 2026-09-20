# Desktop simulator (`-e sim`) — usage

The native desktop simulator runs the full firmware loop in an SDL2 window
standing in for the 480×480 AMOLED — `main.cpp`, `ui.cpp`, `splash.cpp`, idle
fade, pair gesture, JSON parsing, and usage-rate/chime logic all run
unmodified. Only `ble.cpp`/`chime.cpp` are swapped for stubs. Sources live in
`firmware/src/boards/sim/` (HAL against SDL2 + Arduino shims in `shim/`), with
scenario data in `firmware/sim/`.

It has two data sources:

- **Live** (the `./sim.sh` default): the daemon mirrors every payload it sends
  to `~/.config/claude-usage-monitor/latest.json` (Windows:
  `%LOCALAPPDATA%\Clawdmeter\latest.json`), and the window follows that
  file — you see what the board shows, updated once a minute. The macOS daemon
  keeps polling and writing the file when no board is reachable, so the window
  works with the device off. If the file is older than three minutes at
  startup the sim waits for a fresh write instead of showing stale numbers.
- **Demo** (`--demo` / `--scenario FILE`): loops a `.jsonl` scenario for UI
  iteration and CI screenshots.

## Build & run

```bash
sudo apt install libsdl2-dev        # one-time (macOS: brew install sdl2)
./sim.sh                            # live data, usage view (builds if needed)
./sim.sh --top                      # …kept above other windows
./sim.sh --demo                     # scenario playback instead
```

`./sim.sh --build` forces a rebuild after firmware edits, `--splash` boots to
the splash like hardware, `--scenario FILE` plays another `.jsonl`, and
`--size 368x448` (or `240x240`) builds for another panel geometry. The
manual equivalent is:

```bash
pio run -d firmware -e sim
cd firmware && .pio/build/sim/program
```

Launch from the `firmware/` directory — the default scenario path
(`sim/scenario.jsonl`) is resolved relative to it.

## Controls

| Key | Action |
|---|---|
| mouse / left-drag | touch (tap toggles splash ↔ usage) |
| `space` | play/pause scenario playback |
| `←` / `→` | step one scenario state (pauses playback) |
| `1`–`9` | jump to scenario state N (pauses playback) |
| `d` | toggle BLE connected/disconnected |
| `b` (hold) | PRIMARY button (BOOT — HID Space PTT on hardware) |
| `n` (hold) | SECONDARY button (HID Shift+Tab on hardware) |
| `p` | PWR button (short press; hold ~3s + release = pair gesture) |
| `c` | toggle charging |
| `-` / `=` | battery down / up 5% |
| `s` | save screenshot BMP to the current directory |
| `esc` / window close | quit |

Full, authoritative map: `firmware/src/boards/sim/board.h`.

## Scenarios

`firmware/sim/scenario.jsonl` plays in a loop — one JSON object per line, the
daemon payload plus two optional keys:

- `"name"` — shown in the window title
- `"hold_ms"` — time on this state (default 3000)

Quota payloads with `"m"`/`"mr"`/`"ml"` (a model-scoped weekly window, e.g.
Fable) switch the usage view to its three-row layout; without them it stays
on two rows. The default scenario has states for both.

Lines starting with `#` are comments. Lines containing an `"ss"` array are
**session payloads** (issue #135 wire format) and go out on the session
characteristic path; everything else is a quota payload.

Session row format:

```
[sid, label, state, ctx%, elapsed_s, model, tool, ntools, nagents, tdone, ttotal, tok]
```

States: 0 starting · 1 idle · 2 thinking · 3 responding · 4 running-tool ·
5 compacting · 6 needs-permission · 7 asking-you · 8 needs-input · 9 error.
`tok` is context tokens in 1k units (190 = 190k); `-1`/absent = unknown.

Override the scenario file with `SIM_SCENARIO=<path>`. If the file is missing,
a small built-in state list is used.

## Headless screenshots (CI-friendly)

```bash
SDL_VIDEODRIVER=dummy SIM_AUTOSHOT_MS=6000 .pio/build/sim/program
```

Saves `sim-autoshot.bmp` (override with `SIM_AUTOSHOT_PATH`) after the given
delay and exits. Combine with `SIM_SCENARIO` pointing at a single-state file
to capture any specific screen. The sim boots on the splash like hardware;
add `SIM_BOOT_SCREEN=usage` to jump straight to the usage view so the
screenshot shows the panels without a button press or a `main.cpp` edit.

## Other panel sizes

The sim defaults to the 480×480 geometry. To check the compact (368×448) or
small (240×240) layout breakpoints without hardware, override the panel size
at build time (this rebuilds the `sim` env in place; build again without the
override to return to 480):

```bash
PLATFORMIO_BUILD_FLAGS="-DLCD_WIDTH=368 -DLCD_HEIGHT=448" pio run -d firmware -e sim
PLATFORMIO_BUILD_FLAGS="-DLCD_WIDTH=240 -DLCD_HEIGHT=240" pio run -d firmware -e sim
```

## macOS app bundle

`./make-app.sh` builds `dist/Clawdmeter.app`: the sim binary with SDL2 bundled
inside, a launcher that starts live mode on the usage view, and an icon made
from the official Clawd still. `--install` copies it to `~/Applications`,
`--open` launches it. `dist/` is git-ignored on purpose — the bundle is only
ad-hoc signed, so build it on the Mac that runs it rather than copying it
around (Gatekeeper would refuse a copied one). `CLAWDMETER_ALWAYS_ON_TOP=1`
and `CLAWDMETER_DEMO=1` in the environment change the launcher's behaviour.

## Caveat

The sim mirrors the S3 2.16 geometry but renders with desktop LVGL and fake
data. It's ideal for iterating UI layouts, but panel-level behavior — column
offsets, rotation, flush rounding — lives in the hardware board folders, so
always do a final check on real hardware before merging panel-related changes.
