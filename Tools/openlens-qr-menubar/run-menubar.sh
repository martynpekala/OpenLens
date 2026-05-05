#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="OpenLensQRMenubar"
DERIVED_DATA_DIR="$SCRIPT_DIR/.derived-data"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"

if ! command -v tuist >/dev/null 2>&1; then
  printf 'error: tuist is required. Install it first.\n' >&2
  exit 1
fi

"$SCRIPT_DIR/stop-menubar.sh" >/dev/null 2>&1 || true

TUIST_SKIP_UPDATE_CHECK=1 tuist generate --no-open
TUIST_SKIP_UPDATE_CHECK=1 tuist xcodebuild build \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR"

open -na "$APP_PATH"
