#!/bin/bash
# Builds "Fresh Music Player.app" (macOS 11+). Requires Xcode command line tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"
NAME="Fresh Music Player"
APP="$NAME.app"
rm -rf "$APP" Lumen.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macos11.0" -framework Cocoa -framework WebKit -framework CoreAudio main.swift -o "$APP/Contents/MacOS/$NAME"
cp ../player.html "$APP/Contents/Resources/player.html"
# App icon: icon-1024.png -> AppIcon.icns (sips + iconutil ship with macOS)
# No PNG in a fresh checkout? Render it from icon.svg with Quick Look.
if [ ! -f icon-1024.png ] && [ -f icon.svg ]; then
  qlmanage -t -s 1024 -o . icon.svg >/dev/null 2>&1 && mv -f icon.svg.png icon-1024.png
fi
if [ -f icon-1024.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  cp icon-1024.png "$APP/Contents/Resources/icon-1024.png"
  rm -rf "$(dirname "$ICONSET")"
else
  echo "warning: icon-1024.png missing — app will have a generic icon" >&2
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.raanan.freshmusicplayer</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.3</string>
  <key>CFBundleVersion</key><string>15</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Audio File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.mp3</string>
        <string>com.microsoft.waveform-audio</string>
        <string>public.mpeg-4-audio</string>
        <string>com.apple.m4a-audio</string>
        <string>public.aiff-audio</string>
        <string>public.aifc-audio</string>
        <string>org.xiph.flac</string>
        <string>public.audio</string>
      </array>
    </dict>
  </array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" 2>/dev/null || true
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Refresh LaunchServices/Dock icon cache for this bundle (harmless if already registered)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
touch "$APP"
echo "Built $(pwd)/$APP  —  open it with: open \"$APP\""
