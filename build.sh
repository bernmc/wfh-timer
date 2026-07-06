#!/bin/zsh
# Build WFH Timer.app from main.swift. Usage:
#   ./build.sh            build only (app/build/WFH Timer.app)
#   ./build.sh --install  build and copy to ~/Applications, then launch
set -e
cd "$(dirname "$0")"

APP="build/WFH Timer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

echo "Compiling…"
# Pin the deployment target: the beta toolchain otherwise targets a newer
# macOS than the installed one and Launch Services refuses to open the app.
# Universal binary so it runs on both Apple Silicon and Intel Macs.
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift -o "$APP/Contents/MacOS/wfh-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macos14.0 main.swift -o "$APP/Contents/MacOS/wfh-x86_64"
lipo -create -output "$APP/Contents/MacOS/WFH Timer" "$APP/Contents/MacOS/wfh-arm64" "$APP/Contents/MacOS/wfh-x86_64"
rm "$APP/Contents/MacOS/wfh-arm64" "$APP/Contents/MacOS/wfh-x86_64"

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  # Quit a running copy so the binary can be replaced cleanly.
  pkill -x "WFH Timer" 2>/dev/null || true
  sleep 1
  rm -rf ~/Applications/"WFH Timer.app"
  ditto "$APP" ~/Applications/"WFH Timer.app"
  echo "Installed to ~/Applications/WFH Timer.app — launching…"
  open ~/Applications/"WFH Timer.app"
fi
