#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
CODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(dirname "$CODE_DIR")"
APP="$PROJECT_DIR/Builds/MeetingScribe.app"
cd "$CODE_DIR"
if /usr/bin/pgrep -x MeetingScribe >/dev/null 2>&1; then
  echo 'MeetingScribe is running. Save/stop any recording and quit it before rebuilding.' >&2
  exit 1
fi
"$CODE_DIR/script/build_icon.sh"
swift build
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MeetingScribe" "$APP/Contents/MacOS/MeetingScribe"
cp "$CODE_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$CODE_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/MeetingScribe"
/usr/bin/codesign --force --sign - --identifier local.MeetingScribe --entitlements "$CODE_DIR/Resources/MeetingScribe.entitlements" "$APP"
/usr/bin/codesign --verify --strict "$APP"
case "$MODE" in
  --build|build) echo "$APP" ;;
  run) /usr/bin/open -n "$APP" ;;
  --verify|verify) /usr/bin/open -n "$APP"; sleep 1; /usr/bin/pgrep -x MeetingScribe >/dev/null ;;
  --qa|qa) mkdir -p "$PROJECT_DIR/Validation/Library"; /usr/bin/open -n "$APP" --args --library "$PROJECT_DIR/Validation/Library" ;;
  --debug|debug) /usr/bin/lldb -- "$APP/Contents/MacOS/MeetingScribe" ;;
  --logs|--telemetry) /usr/bin/open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "MeetingScribe"' ;;
  *) echo 'usage: build_and_run.sh [run|--build|--qa|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;;
esac
