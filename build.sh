#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP_PATH="$PWD/Masimo Live.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" .build
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path .build/module-cache -swift-version 5 -parse-as-library \
  Sources/Protocol.swift Sources/Capture.swift Sources/LiveExport.swift Sources/ScreenReading.swift Sources/Localization.swift Sources/USBReader.swift Sources/App.swift \
  -framework SwiftUI -framework CoreBluetooth -framework AppKit -framework AVFoundation -framework CoreMediaIO -framework Vision \
  -o "$APP_PATH/Contents/MacOS/MasimoLive"
cp Info.plist "$APP_PATH/Contents/Info.plist"
cp -R Resources/. "$APP_PATH/Contents/Resources/"
codesign --force --sign - "$APP_PATH"
printf 'Built app: %s\n' "$APP_PATH"
