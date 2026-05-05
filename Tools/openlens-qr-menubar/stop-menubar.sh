#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OpenLensQRMenubar"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME"

  for _ in {1..30}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
fi
