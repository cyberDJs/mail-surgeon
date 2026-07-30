#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/.build/app/MailSurgeon.app"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/MailSurgeon"
BUNDLE_IDENTIFIER="com.cyberdjs.mailsurgeon"

is_running() {
  [[ "$(/usr/bin/osascript -e "application id \"$BUNDLE_IDENTIFIER\" is running")" == "true" ]]
}

if [[ ! -x "$EXECUTABLE_PATH" ]] || [[ -n "$(find "$REPO_ROOT/Package.swift" "$REPO_ROOT/Sources" -newer "$EXECUTABLE_PATH" -print -quit)" ]]; then
  "$SCRIPT_DIR/build-app.sh" debug
fi

if is_running; then
  /usr/bin/osascript -e "tell application id \"$BUNDLE_IDENTIFIER\" to quit" >/dev/null 2>&1 || true

  for _ in {1..50}; do
    if ! is_running; then
      break
    fi

    sleep 0.1
  done

  if is_running; then
    echo "error: timed out waiting for Mail Surgeon to terminate" >&2
    exit 1
  fi
fi

/usr/bin/open "$APP_DIR"

echo "Launched $APP_DIR"
