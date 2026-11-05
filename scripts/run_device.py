#!/usr/bin/env python3
"""Build, install and launch OpenLens on a physical iPhone -- Xcode's Run button.

Note this installs com.nicolabeghin.OpenLens, the same identifier the App Store
build uses, so it replaces that install rather than sitting beside it. That is
the intended workflow for the app's own developer, but it is why this is a
separate script from the simulator runner rather than a flag on it.

Mirrors scripts/test_ios.py -- stdlib only, bounded waits, the same report
prefix style -- and keeps its own derived data so it never fights the copy Xcode
is using.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
SCHEME = "OpenLens"
DERIVED = ROOT / "build" / "device"


def report(message):
    print(f"[run-device] {message}", flush=True)


def run(command, timeout, check=True, capture=True):
    result = subprocess.run(
        command, capture_output=capture, text=True, timeout=timeout, cwd=ROOT
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip() if capture else ""
        raise RuntimeError(f"{' '.join(command[:4])}… failed ({result.returncode})\n{detail[-1500:]}")
    return result


def physical_devices():
    """Paired physical devices, newest listing first.

    devicectl's JSON output is the only stable form; the table is for humans.
    """
    out = DERIVED / "devices.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    run(
        ["xcrun", "devicectl", "list", "devices", "--json-output", str(out)],
        timeout=120,
    )
    payload = json.loads(out.read_text())
    devices = []
    for device in payload.get("result", {}).get("devices", []):
        hardware = device.get("hardwareProperties", {})
        if hardware.get("platform") != "iOS":
            continue
        # `reality` is the field that separates a real phone from a simulator; there is no
        # isSimulated key, and the simulators are listed right alongside the hardware.
        if hardware.get("reality") != "physical":
            continue
        devices.append(
            {
                "udid": hardware.get("udid") or device.get("identifier"),
                "name": device.get("deviceProperties", {}).get("name", "iPhone"),
                "state": device.get("connectionProperties", {}).get("tunnelState", "unknown"),
            }
        )
    return devices


def resolve_device(requested):
    devices = physical_devices()
    if not devices:
        raise RuntimeError(
            "No paired physical device. Connect the iPhone, unlock it, and make sure "
            "Developer Mode is on (Settings → Privacy & Security → Developer Mode)."
        )
    if requested:
        for device in devices:
            if device["udid"].lower() == requested.lower():
                return device
        known = ", ".join(f"{d['name']} ({d['udid']})" for d in devices)
        raise RuntimeError(f"Device {requested} is not paired. Paired: {known}")
    if len(devices) > 1:
        known = "\n  ".join(f"{d['name']}  {d['udid']}" for d in devices)
        raise RuntimeError(f"Several devices paired; pass --device.\n  {known}")
    return devices[0]


def built_app():
    candidates = sorted(
        DERIVED.glob("Build/Products/*-iphoneos/OpenLens.app"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise RuntimeError(f"No OpenLens.app under {DERIVED}/Build/Products")
    return candidates[0]


def bundle_id(app):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    identifier = info.get("CFBundleIdentifier")
    if not identifier:
        raise RuntimeError(f"No CFBundleIdentifier in {app}/Info.plist")
    return identifier


def arguments():
    parser = argparse.ArgumentParser(
        prog="scripts/run-device.sh",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Anything after -- is passed to the app as launch arguments, e.g.\n"
        "  scripts/run-device.sh -- SCREENSHOT_MODE SCREENSHOT_MULTI_SERVER",
    )
    parser.add_argument("--device", metavar="UDID", help="defaults to the only paired iPhone")
    parser.add_argument("--configuration", default="Debug")
    parser.add_argument("--skip-build", action="store_true", help="reuse the previous device build")
    parser.add_argument("--no-launch", action="store_true", help="install without launching")
    parser.add_argument("--build-timeout", type=float, default=900.0, metavar="SECONDS")
    parser.add_argument("launch_arguments", nargs="*", metavar="ARG")
    return parser.parse_args()


def main():
    args = arguments()
    device = resolve_device(args.device)
    report(f"Device: {device['name']} ({device['udid']}) — tunnel {device['state']}")
    if device["state"] != "connected":
        # Paired is not the same as reachable. devicectl will often bring the tunnel up on
        # demand, so this is a heads-up rather than a refusal.
        report("  Tunnel is not up; if install fails, unlock the phone and check the cable "
               "or that both are on the same network.")

    if not args.skip_build:
        report("Generating project")
        run(["xcodegen", "generate"], timeout=300)
        report(f"Building {SCHEME} ({args.configuration}); this takes a few minutes")
        run(
            [
                "xcodebuild",
                "-project", "OpenLens.xcodeproj",
                "-scheme", SCHEME,
                "-configuration", args.configuration,
                "-destination", f"platform=iOS,id={device['udid']}",
                "-derivedDataPath", str(DERIVED),
                "-allowProvisioningUpdates",
                "build",
            ],
            timeout=args.build_timeout,
        )

    app = built_app()
    identifier = bundle_id(app)
    report(f"Installing {identifier}")
    run(
        ["xcrun", "devicectl", "device", "install", "app", "--device", device["udid"], str(app)],
        timeout=600,
    )

    if args.no_launch:
        report("Installed. Not launching (--no-launch).")
        return 0

    launch = [
        "xcrun", "devicectl", "device", "process", "launch",
        "--device", device["udid"],
        "--terminate-existing",
        identifier,
    ]
    if args.launch_arguments:
        launch += args.launch_arguments
        report(f"Launching with: {' '.join(args.launch_arguments)}")
    else:
        report("Launching")

    result = run(launch, timeout=180, check=False)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "")
        # A locked phone is the common case and says nothing about the build: the install
        # already succeeded, so report what happened rather than a CoreDevice dump.
        if "unlocked" in detail or "Locked" in detail:
            report("Installed, but the phone is locked, so it could not be launched.")
            report("Unlock it, then: scripts/run-device.sh --skip-build")
            return 2
        raise RuntimeError(f"Launch failed ({result.returncode})\n{detail.strip()[-1500:]}")

    report("Running on device.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except subprocess.TimeoutExpired as expired:
        report(f"Timed out after {expired.timeout:.0f}s: {' '.join(expired.cmd[:4])}…")
        sys.exit(124)
    except RuntimeError as error:
        report(str(error))
        sys.exit(1)
