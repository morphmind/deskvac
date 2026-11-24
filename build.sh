#!/bin/zsh
# Builds DeskVac.app with plain swiftc (no Xcode project needed).
#   ./build.sh            build into build/DeskVac.app
#   ./build.sh --install  also copy to ~/Applications and launch
#   ./build.sh --zip      also make build/DeskVac.zip for a GitHub release
#   ./build.sh --notarize Developer ID sign, notarize with Apple, staple, then zip
#                         (needs a notarytool keychain profile, default "deskvac-notary")
set -euo pipefail
cd "${0:A:h}"

APP=build/DeskVac.app
BIN=build/DeskVac-bin
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

ARCH_FLAGS=(-target arm64-apple-macos15.0)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swiftc -O -swift-version 5 -target arm64-apple-macos15.0 Sources/*.swift -o build/DeskVac-arm64
  swiftc -O -swift-version 5 -target x86_64-apple-macos15.0 Sources/*.swift -o build/DeskVac-x86_64
  lipo -create build/DeskVac-arm64 build/DeskVac-x86_64 -output "$BIN"
else
  swiftc -O -swift-version 5 "${ARCH_FLAGS[@]}" Sources/*.swift -o "$BIN"
fi

"$BIN" --check-strings
"$BIN" --selftest

# App icon, drawn by the app's own robot painter.
"$BIN" --render-icon build/icon-1024.png
mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cp "$BIN" "$APP/Contents/MacOS/DeskVac"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Sign with Developer ID if there is one, then Apple Development, otherwise ad-hoc.
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY="${SIGN_IDENTITY:-$(print -r -- "$identities" | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:-$(print -r -- "$identities" | awk -F'"' '/Apple Development/ {print $2; exit}')}"
TIMESTAMP=()
[[ "$IDENTITY" == Developer\ ID* ]] && TIMESTAMP=(--timestamp)
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements DeskVac.entitlements --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ " $* " == *" --notarize "* ]]; then
  [[ "$IDENTITY" == Developer\ ID* ]] || { echo "notarize needs a Developer ID Application identity" >&2; exit 1; }
  rm -f build/DeskVac.zip
  ditto -c -k --keepParent "$APP" build/DeskVac.zip
  xcrun notarytool submit build/DeskVac.zip --keychain-profile "${NOTARY_PROFILE:-deskvac-notary}" --wait
  xcrun stapler staple "$APP"
  spctl -a -vv -t exec "$APP"
fi

if [[ " $* " == *" --zip "* || " $* " == *" --notarize "* ]]; then
  rm -f build/DeskVac.zip
  ditto -c -k --keepParent "$APP" build/DeskVac.zip
  echo "zipped build/DeskVac.zip"
fi

if [[ " $* " == *" --install "* ]]; then
  osascript -e 'tell application "DeskVac" to quit' >/dev/null 2>&1 || true
  sleep 0.5
  rm -rf ~/Applications/DeskVac.app
  mkdir -p ~/Applications
  cp -R "$APP" ~/Applications/DeskVac.app
  open ~/Applications/DeskVac.app
fi
