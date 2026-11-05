#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
exec python3 "$script_dir/run_device.py" "$@"
