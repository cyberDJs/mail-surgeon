#!/bin/bash
set -euo pipefail

CONFIGURATION="${1:-debug}"

case "$CONFIGURATION" in
  debug | release)
    ;;
  *)
    echo "error: configuration must be 'debug' or 'release'" >&2
    exit 64
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/$CONFIGURATION"
APP_DIR="$REPO_ROOT/.build/app/MailSurgeon.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_SOURCE="$BUILD_DIR/MailSurgeon"
EXECUTABLE_DESTINATION="$MACOS_DIR/MailSurgeon"
INFO_PLIST="$CONTENTS_DIR/Info.plist"

cd "$REPO_ROOT"

swift build --configuration "$CONFIGURATION"

if [[ ! -f "$EXECUTABLE_SOURCE" ]]; then
  echo "error: compiled executable not found at $EXECUTABLE_SOURCE" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE_SOURCE" "$EXECUTABLE_DESTINATION"
chmod 755 "$EXECUTABLE_DESTINATION"

/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Mail Surgeon" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Mail Surgeon" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string MailSurgeon" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.cyberdjs.mailsurgeon" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1.0" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool false" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.utilities" "$INFO_PLIST"

"$SCRIPT_DIR/validate-app-bundle.sh" "$APP_DIR"

echo "Built $APP_DIR"
