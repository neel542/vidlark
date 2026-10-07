#!/bin/bash
# Builds dist/Vidlark.app. Run: bash Tools/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Vidlark
FINISH=1
swift build -c release --product vidlark-finish || { FINISH=0; echo "warning: vidlark-finish did not build; recordings will save without finishing"; }
BIN="$(swift build -c release --show-bin-path)"

APP="dist/Vidlark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Vidlark" "$APP/Contents/MacOS/Vidlark"
[ "$FINISH" = 1 ] && cp "$BIN/vidlark-finish" "$APP/Contents/MacOS/vidlark-finish"
cp Tools/Info.plist "$APP/Contents/Info.plist"

# The icon is drawn by the app itself, then packed into an .icns.
TMP="$(mktemp -d)"
"$APP/Contents/MacOS/Vidlark" --render-icon "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

# Signing. macOS 15 and later refuse screen recording to ad hoc signed apps, so an Apple
# Development certificate is needed (free: Xcode > Settings > Accounts, add your Apple ID,
# then Manage Certificates > + > Apple Development). It also keeps permissions across rebuilds.
IDENTITY="$(security find-identity -v -p codesigning | grep -m1 -E '"Apple Development|"Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  [ "$FINISH" = 1 ] && codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/vidlark-finish"
  codesign --force --sign "$IDENTITY" --identifier app.vidlark.mac "$APP"
  echo "Signed with: $IDENTITY"
else
  [ "$FINISH" = 1 ] && codesign --force --sign - "$APP/Contents/MacOS/vidlark-finish"
  codesign --force --sign - --identifier app.vidlark.mac \
    --requirements '=designated => identifier "app.vidlark.mac"' "$APP"
  echo "warning: no Apple Development certificate found. Signed ad hoc, so screen recording will be refused."
fi
echo "Built $APP"
