#!/bin/sh
set -eu
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_DIR=${DSH_SELECTION_TMP:-"$PACKAGE_DIR/build/.cache"}
OUTPUT_DIR=${1:-"$PACKAGE_DIR/build"}
APP_DIR="$OUTPUT_DIR/DSH Selection.app"
BUNDLE_ID=${DSH_SELECTION_BUNDLE_ID:-local.dsh.selection-toolbar}
case "$BUNDLE_ID" in
  ''|*[!A-Za-z0-9.-]*) printf '%s\n' 'Invalid application bundle identifier' >&2; exit 1 ;;
esac
mkdir -p "$TASK_DIR/swift-cache" "$APP_DIR/Contents/MacOS"
/usr/bin/swiftc -swift-version 5 -O -module-cache-path "$TASK_DIR/swift-cache" \
  -framework AppKit -framework ApplicationServices -framework WebKit \
  "$PACKAGE_DIR/native/ClipboardSelection.swift" "$PACKAGE_DIR/native/SelectionGeometry.swift" "$PACKAGE_DIR/native/Selection.swift" "$PACKAGE_DIR/native/Appearance.swift" "$PACKAGE_DIR/native/MarkdownView.swift" "$PACKAGE_DIR/native/main.swift" \
  -o "$APP_DIR/Contents/MacOS/DSHSelection"
cp "$PACKAGE_DIR/native/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Resources/Markdown"
cp "$PACKAGE_DIR/native/Markdown/"* "$APP_DIR/Contents/Resources/Markdown/"
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
"$APP_DIR/Contents/MacOS/DSHSelection" --self-test
printf 'Built: %s\n' "$APP_DIR"
