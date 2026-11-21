#!/bin/zsh
# Construit MySpotify.app dans ./build  (option: ./build.sh install → copie dans /Applications)
set -e
cd "$(dirname "$0")"
APP=build/MySpotify.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.4 \
  -o "$APP/Contents/MacOS/MySpotify" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MySpotify</string>
  <key>CFBundleDisplayName</key><string>MySpotify</string>
  <key>CFBundleIdentifier</key><string>local.myspotify.vinyl</string>
  <key>CFBundleExecutable</key><string>MySpotify</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>MySpotify lit la musique en cours dans Spotify pour afficher la pochette.</string>
  <key>NSAudioCaptureUsageDescription</key><string>MySpotify écoute le son de Spotify pour animer l'onde autour du disque.</string>
</dict>
</plist>
PLIST

cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Certificat local stable → macOS garde les autorisations entre deux compilations
if security find-certificate -c "MySpotify Local Signing" >/dev/null 2>&1; then
  codesign --force --sign "MySpotify Local Signing" "$APP"
else
  echo "(certificat local absent : signature ad-hoc)"
  codesign --force --sign - "$APP"
fi
echo "✓ $APP construit"

if [[ "$1" == "install" ]]; then
  pkill -x MySpotify 2>/dev/null || true
  for i in {1..50}; do pgrep -x MySpotify >/dev/null || break; sleep 0.1; done
  rm -rf /Applications/MySpotify.app
  cp -R "$APP" /Applications/
  echo "✓ Installé dans /Applications"
  open /Applications/MySpotify.app
fi
