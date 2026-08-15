#!/usr/bin/env bash
set -euo pipefail

VERSION="2026.3.0"
BASE_URL="https://github.com/cloudflare/cloudflared/releases/download/$VERSION"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESOURCE_DIR="$SCRIPT_DIR/../Resources"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

fetch_arch() {
  local arch="$1"
  local expected_sha="$2"
  local archive="cloudflared-darwin-$arch.tgz"

  curl -fsSL "$BASE_URL/$archive" -o "$TEMP_DIR/$archive"
  local actual_sha
  actual_sha="$(shasum -a 256 "$TEMP_DIR/$archive" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    printf 'error: checksum mismatch for %s\n' "$archive" >&2
    exit 1
  fi

  mkdir -p "$TEMP_DIR/$arch"
  tar -xzf "$TEMP_DIR/$archive" -C "$TEMP_DIR/$arch"
  local binary
  binary="$(find "$TEMP_DIR/$arch" -type f -name cloudflared -print -quit)"
  if [[ -z "$binary" ]]; then
    printf 'error: cloudflared missing from %s\n' "$archive" >&2
    exit 1
  fi
  install -m 0755 "$binary" "$RESOURCE_DIR/cloudflared-$arch"
}

mkdir -p "$RESOURCE_DIR"
fetch_arch "arm64" "2aae4f69b0fc1c671b8353b4f594cbd902cd1e360c8eed2b8cad4602cb1546fb"
fetch_arch "amd64" "0f30140c4a5e213d22f951ef4c964cac5fb6a5f061ba6eba5ea932999f7c0394"

printf 'Embedded cloudflared %s for arm64 and amd64.\n' "$VERSION"
