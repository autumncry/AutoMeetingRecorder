#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
CODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(dirname "$CODE_DIR")"
APP="$PROJECT_DIR/Builds/AutoMeetingRecorder.app"
cd "$CODE_DIR"
RUNNING=0
/usr/bin/pgrep -f '/AutoMeetingRecorder\.app/Contents/MacOS/AutoMeetingRecorder([[:space:]]|$)' >/dev/null 2>&1 || RUNNING=$?
case "$RUNNING" in
  0) echo 'AMR is running. Save/stop any recording and quit before rebuilding.' >&2; exit 1 ;;
  1) ;;
  *) echo 'Cannot verify AMR process state; refusing to replace its bundle.' >&2; exit 1 ;;
esac
"$CODE_DIR/script/build_icon.sh"
swift build
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p "$PROJECT_DIR/Builds"
STAGING="$PROJECT_DIR/Builds/.AMR-staging-$(/usr/bin/uuidgen).app"
trap 'if [[ -d "$STAGING" ]]; then rm -rf "$STAGING"; fi' EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_DIR/AutoMeetingRecorder" "$STAGING/Contents/MacOS/AutoMeetingRecorder"
cp "$CODE_DIR/Resources/Info.plist" "$STAGING/Contents/Info.plist"
cp "$CODE_DIR/Resources/AppIcon.icns" "$STAGING/Contents/Resources/AppIcon.icns"
chmod +x "$STAGING/Contents/MacOS/AutoMeetingRecorder"
/usr/bin/codesign --force --sign - --identifier local.MeetingScribe --entitlements "$CODE_DIR/Resources/AutoMeetingRecorder.entitlements" "$STAGING"
/usr/bin/codesign --verify --deep --strict "$STAGING"
if [[ -d "$APP" ]]; then
  mkdir -p "$PROJECT_DIR/Backups"
  /usr/bin/ditto -c -k --keepParent "$APP" "$PROJECT_DIR/Backups/build-$(date +%Y%m%d-%H%M%S)-$(/usr/bin/uuidgen).zip"
  rm -rf "$APP"
fi
mv "$STAGING" "$APP"
touch "$APP"
case "$MODE" in
  --build|build) echo "$APP" ;;
  run) /usr/bin/open -n "$APP" ;;
  --verify|verify) /usr/bin/open -n "$APP"; sleep 1; /usr/bin/pgrep -f '/AutoMeetingRecorder\.app/Contents/MacOS/AutoMeetingRecorder' >/dev/null ;;
  --qa|qa) mkdir -p "$PROJECT_DIR/Validation/Library"; /usr/bin/open -n "$APP" --args --library "$PROJECT_DIR/Validation/Library" ;;
  --debug|debug) /usr/bin/lldb -- "$APP/Contents/MacOS/AutoMeetingRecorder" ;;
  --logs|--telemetry) /usr/bin/open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "AutoMeetingRecorder"' ;;
  *) echo 'usage: build_and_run.sh [run|--build|--qa|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;;
esac
