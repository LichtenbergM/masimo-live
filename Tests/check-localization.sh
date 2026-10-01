#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="$PWD/Masimo Live.app"
TEST_APP_PATH="$PWD/.build/LocalizationTests.app"
mkdir -p "$TEST_APP_PATH/Contents/MacOS" "$TEST_APP_PATH/Contents/Resources"

# Foundation resolves secondary bundle languages using the main bundle's languages.
# Run the test executable in an app bundle with the actual packaged resources.
cp .build/localization-tests "$TEST_APP_PATH/Contents/MacOS/MasimoLive"
cp "$APP_PATH/Contents/Info.plist" "$TEST_APP_PATH/Contents/Info.plist"
cp -R "$APP_PATH/Contents/Resources/." "$TEST_APP_PATH/Contents/Resources/"

for language in en de; do
  "$TEST_APP_PATH/Contents/MacOS/MasimoLive" --app-bundle "$APP_PATH" --expect-language "$language" -AppleLanguages "($language)"
done
"$TEST_APP_PATH/Contents/MacOS/MasimoLive" --app-bundle "$APP_PATH" --expect-language en -AppleLanguages '(fr)'
