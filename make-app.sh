#!/bin/bash
# Build a macOS .app bundle around the desktop simulator so it gets a Dock icon,
# a Cmd-Tab entry, and a Spotlight launch. Output: dist/Clawdmeter.app (ignored
# by git — build it locally; an unsigned bundle copied between Macs would trip
# Gatekeeper, so it is deliberately not distributed).
#
#   ./make-app.sh            build the sim and the bundle
#   ./make-app.sh --open     …then launch it
#   ./make-app.sh --install  …then copy it to ~/Applications
#
# The app launches the sim in LIVE mode on the usage view, following the
# daemon's latest.json mirror. Set CLAWDMETER_ALWAYS_ON_TOP=1 in the
# environment (or edit the launcher inside the bundle) to keep it above other
# windows; CLAWDMETER_DEMO=1 plays the scenario file instead of live data.
#
# Requires: PlatformIO + SDL2 (brew install sdl2) for the sim build, the daemon
# venv (install-mac.sh) for the icon step (Pillow is installed into it if
# missing), plus iconutil / install_name_tool / codesign from Xcode's CLT.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$HERE/firmware"
BIN="$FW/.pio/build/sim/program"
DIST="$HERE/dist"
APP="$DIST/Clawdmeter.app"
NAME="Clawdmeter"
BUNDLE_ID="dev.charlesjones.clawdmeter"
VENV_PY="$HERE/daemon/.venv/bin/python"
ICON_SRC="$HERE/research/clawd-official/Clawd-Still.png"   # official Clawd art
VERSION="$(git -C "$HERE" describe --tags --always 2>/dev/null || echo dev)"

open_after=false; install_after=false
for a in "$@"; do
    case "$a" in
        --open) open_after=true ;;
        --install) install_after=true ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a"; exit 1 ;;
    esac
done

for t in iconutil install_name_tool codesign sips; do
    command -v "$t" >/dev/null || { echo "Missing $t (install Xcode Command Line Tools)"; exit 1; }
done
PIO="$(command -v pio || true)"
[ -z "$PIO" ] && [ -x "$HOME/.platformio/penv/bin/pio" ] && PIO="$HOME/.platformio/penv/bin/pio"
[ -z "$PIO" ] && { echo "PlatformIO not found (brew install platformio)"; exit 1; }
[ -x "$VENV_PY" ] || { echo "Daemon venv not found — run ./install-mac.sh first (needed for the icon)"; exit 1; }

echo "[1/5] Building the simulator (480x480)..."
# The bundle always ships the default geometry; clear any leftover override.
PLATFORMIO_BUILD_FLAGS="" "$PIO" run -d "$FW" -e sim | grep -E "error|SUCCESS|FAILED" || true
[ -x "$BIN" ] || { echo "sim build failed"; exit 1; }

echo "[2/5] Laying out $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/clawdmeter-sim"
cp "$FW/sim/scenario.jsonl" "$APP/Contents/Resources/scenario.jsonl"

# Launcher: LaunchServices starts apps with cwd=/ and a minimal environment,
# so set the sim's mode here and cd next to the resources.
cat > "$APP/Contents/MacOS/$NAME" <<'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/../Resources"
if [ "${CLAWDMETER_DEMO:-0}" != "0" ]; then
    unset SIM_MODE
    export SIM_SCENARIO="$DIR/../Resources/scenario.jsonl"
else
    export SIM_MODE=live
fi
export SIM_BOOT_SCREEN=usage
[ "${CLAWDMETER_ALWAYS_ON_TOP:-0}" != "0" ] && export SIM_ALWAYS_ON_TOP=1
exec "$DIR/clawdmeter-sim"
LAUNCHER
chmod +x "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$NAME</string>
    <key>CFBundleDisplayName</key>     <string>$NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>$NAME</string>
    <key>CFBundleIconFile</key>        <string>$NAME</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "[3/5] Bundling SDL2 so the app runs without Homebrew on PATH..."
SDL_PATH="$(otool -L "$BIN" | awk '/libSDL2/ {print $1}' | head -1)"
[ -n "$SDL_PATH" ] && [ -f "$SDL_PATH" ] || { echo "Could not locate libSDL2 via otool"; exit 1; }
SDL_NAME="$(basename "$SDL_PATH")"
cp "$SDL_PATH" "$APP/Contents/Frameworks/$SDL_NAME"
chmod u+w "$APP/Contents/Frameworks/$SDL_NAME"
install_name_tool -id "@executable_path/../Frameworks/$SDL_NAME" "$APP/Contents/Frameworks/$SDL_NAME"
install_name_tool -change "$SDL_PATH" "@executable_path/../Frameworks/$SDL_NAME" "$APP/Contents/MacOS/clawdmeter-sim"

echo "[4/5] Icon from the official Clawd still..."
"$VENV_PY" -c "import PIL" 2>/dev/null || "$VENV_PY" -m pip install --quiet pillow
ICONSET="$DIST/$NAME.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$VENV_PY" - "$ICON_SRC" "$ICONSET" <<'PY'
import sys
from PIL import Image, ImageDraw
src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
# Trim to the sprite (the still has a big empty stage around Clawd).
bbox = im.getchannel("A").getbbox() or im.getbbox()
sprite = im.crop(bbox)
S = 1024
# macOS-style rounded tile in the device's background colour, sprite ~60% wide,
# nudged up a touch so the feet don't sit on the edge.
tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(tile).rounded_rectangle((60, 60, S - 60, S - 60), radius=200, fill=(0x1f, 0x1f, 0x1e, 255))   # THEME_PANEL
w = int(S * 0.60); h = int(sprite.height * w / sprite.width)
sprite = sprite.resize((w, h), Image.NEAREST)   # keep the pixel-art edges crisp
tile.alpha_composite(sprite, ((S - w) // 2, (S - h) // 2 - 10))
for px in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        size = px * scale
        name = f"icon_{px}x{px}" + ("@2x" if scale == 2 else "") + ".png"
        tile.resize((size, size), Image.LANCZOS).save(f"{out}/{name}")
PY
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$NAME.icns"
rm -rf "$ICONSET"

echo "[5/5] Ad-hoc signing (required on Apple silicon after patching the binary)..."
codesign --force --sign - "$APP/Contents/Frameworks/$SDL_NAME"
codesign --force --sign - "$APP/Contents/MacOS/clawdmeter-sim"
codesign --force --sign - "$APP"

echo ""
echo "Built $APP ($VERSION)"
if $install_after; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$NAME.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/$NAME.app"
fi
if $open_after; then
    if $install_after; then open "$HOME/Applications/$NAME.app"; else open "$APP"; fi
fi
exit 0
