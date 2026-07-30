#!/bin/bash
set -euo pipefail

APP_DIR="${1:-}"

if [[ -z "$APP_DIR" ]]; then
  echo "error: usage: $0 path/to/MailSurgeon.app" >&2
  exit 64
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: app bundle does not exist: $APP_DIR" >&2
  exit 1
fi

INFO_PLIST="$APP_DIR/Contents/Info.plist"

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: Info.plist does not exist: $INFO_PLIST" >&2
  exit 1
fi

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

read_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

PACKAGE_TYPE="$(read_plist_value CFBundlePackageType)"
if [[ "$PACKAGE_TYPE" != "APPL" ]]; then
  echo "error: CFBundlePackageType must be APPL, got: $PACKAGE_TYPE" >&2
  exit 1
fi

BUNDLE_IDENTIFIER="$(read_plist_value CFBundleIdentifier)"
if [[ "$BUNDLE_IDENTIFIER" != "com.cyberdjs.mailsurgeon" ]]; then
  echo "error: CFBundleIdentifier must be com.cyberdjs.mailsurgeon, got: $BUNDLE_IDENTIFIER" >&2
  exit 1
fi

LSUI_ELEMENT="$(read_plist_value LSUIElement)"
if [[ "$LSUI_ELEMENT" != "false" ]]; then
  echo "error: LSUIElement must be false, got: $LSUI_ELEMENT" >&2
  exit 1
fi

EXECUTABLE_NAME="$(read_plist_value CFBundleExecutable)"
if [[ -z "$EXECUTABLE_NAME" ]]; then
  echo "error: CFBundleExecutable is empty" >&2
  exit 1
fi

EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -f "$EXECUTABLE_PATH" ]]; then
  echo "error: executable does not exist: $EXECUTABLE_PATH" >&2
  exit 1
fi

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "error: executable does not have execute permission: $EXECUTABLE_PATH" >&2
  exit 1
fi

echo "Validated $APP_DIR"
