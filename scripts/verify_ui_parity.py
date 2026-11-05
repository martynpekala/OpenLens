#!/usr/bin/env python3
"""Capture fixture screens and compare them against committed baselines.

The single-server rule says that while only one server is saved, OpenLens looks
exactly as it did before multi-server existed. That is a claim about pixels, and
no unit test can check it: the suite stayed green through two layout regressions
that this comparison caught.

Mirrors scripts/test_ios.py deliberately -- stdlib only, bounded waits, the same
per-simulator lock -- so there is one way to run things in this repo, not two.
"""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SIMULATOR = "A2A555E1-94A1-41D1-99EA-70919AB319EB"
BUNDLE_ID = "com.nicolabeghin.OpenLens"
BASELINES = ROOT / ".interface-design" / "baselines"

# The status bar carries a live clock, so it can never match. Everything below
# this row is app content and is compared.
MASK_TOP = 160

# Rows that differ are grouped into bands, and a gap smaller than this joins two
# groups into one. An animating gradient does not differ on every row it covers --
# a few rows coincidentally match and would otherwise split one shimmer into two
# bands, failing the band count while the percentage went *down*. A real layout
# shift separates its bands by tens of rows (a measured one gave gaps of 32+), so
# this sits well below that and well above the handful an animation produces.
BAND_GAP = 16

# Above this, treat the capture as suspect rather than the layout as changed.
IMPLAUSIBLE_DIFFERENCE = 20.0


@dataclass(frozen=True)
class Scenario:
    name: str
    # Launch arguments, passed positionally after the bundle id. simctl launch
    # has no --setenv, and argument-only fixture flags (SCREENSHOT_EXECUTION_
    # OUTCOMES, SCREENSHOT_UNREAD_RESULTS) are unreachable any other way.
    arguments: list
    baseline: str = ""
    # Why a scenario is not held at 0.000: the sessions list renders a busy row
    # whose shimmer animates, so two captures of an identical layout differ by
    # one text-line band. Measured at ~0.25%; 0.60 leaves room for the animation
    # phase without hiding a layout shift, which moves whole rows and measured
    # 8.569% when it happened.
    tolerance: float = 0.60
    # A layout regression shifts several regions; an animation disturbs one.
    max_bands: int = 1
    compare: bool = True


SCENARIOS = [
    Scenario(
        name="single-default",
        arguments=["SCREENSHOT_MODE"],
        baseline="baseline-single-default.png",
    ),
    Scenario(
        name="single-states",
        arguments=[
            "SCREENSHOT_MODE",
            "SCREENSHOT_EXECUTION_OUTCOMES",
            "SCREENSHOT_UNREAD_RESULTS",
        ],
        baseline="baseline-single-states.png",
    ),
    # Review material rather than a gate: there is no "before" to be identical to.
    # SCREENSHOT_MULTI_SERVER seeds three servers: Mac Studio (connected, active), Devbox
    # (reconnecting, shares /workspace/OpenLens with Mac Studio) and ci-runner (error).
    # multi-default is therefore the aggregated list with a failing server: two same-named
    # project sections told apart by tag, plus ci-runner's per-section failure notice.
    Scenario(
        name="multi-default",
        arguments=["SCREENSHOT_MODE", "SCREENSHOT_MULTI_SERVER"],
        compare=False,
    ),
    Scenario(
        name="multi-states",
        arguments=[
            "SCREENSHOT_MODE",
            "SCREENSHOT_MULTI_SERVER",
            "SCREENSHOT_EXECUTION_OUTCOMES",
            "SCREENSHOT_UNREAD_RESULTS",
        ],
        compare=False,
    ),
    # The Servers screen showing all three connection states at once.
    Scenario(
        name="servers",
        arguments=["SCREENSHOT_MODE", "SCREENSHOT_MULTI_SERVER", "SCREENSHOT_SERVERS"],
        compare=False,
    ),
]


def report(message):
    print(f"[ui-parity] {message}", flush=True)


@contextmanager
def simulator_lock(simulator):
    # Same lock file as test_ios.py, so a capture and a test run cannot fight
    # over one simulator. Keep the file: unlinking an advisory lock can let two
    # runners lock different inodes.
    path = Path("/tmp") / f"openlens-simulator-{os.getuid()}-{simulator}.lock"
    with path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(
                f"Another runner is using simulator {simulator}. Lock: {path}"
            )
        lock.seek(0)
        lock.truncate()
        lock.write(f"{os.getpid()}\n")
        lock.flush()
        yield


def run(command, timeout, check=True):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"{' '.join(command[:3])}… failed ({result.returncode}): "
            f"{(result.stderr or result.stdout).strip()[:400]}"
        )
    return result


def built_app():
    derived = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    candidates = sorted(
        derived.glob("OpenLens-*/Build/Products/Debug-iphonesimulator/OpenLens.app"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise RuntimeError(
            "No built OpenLens.app in DerivedData. Run ./scripts/test-ios.sh first "
            "so there is a fresh build to install."
        )
    return candidates[0]


def raw_pixels(png, work):
    """Decode a PNG to raw RGBA via sips, which ships with macOS.

    sips writes uncompressed TIFF, so the tail of the file is the pixel buffer
    and a byte comparison is a pixel comparison. Keeps this script dependency
    free, like test_ios.py.
    """
    out = work / f"{png.stem}-{uuid.uuid4().hex[:8]}.tiff"
    run(["sips", "-s", "format", "tiff", str(png), "--out", str(out)], timeout=60)
    return out.read_bytes()


def dimensions(png):
    result = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(png)], timeout=30)
    width = height = None
    for line in result.stdout.splitlines():
        key, _, value = line.strip().partition(":")
        if key == "pixelWidth":
            width = int(value)
        elif key == "pixelHeight":
            height = int(value)
    if not width or not height:
        raise RuntimeError(f"Could not read dimensions of {png}")
    return width, height


def compare(baseline, shot, work):
    width, height = dimensions(baseline)
    if (width, height) != dimensions(shot):
        raise RuntimeError(
            f"{shot.name} is {dimensions(shot)}, baseline is {(width, height)}. "
            "Capture on the same simulator the baseline came from."
        )
    count = width * height * 4
    a = raw_pixels(baseline, work)[-count:]
    b = raw_pixels(shot, work)[-count:]

    rows = {}
    for index in range(0, count, 4):
        if a[index : index + 4] != b[index : index + 4]:
            pixel = index // 4
            y = pixel // width
            if y < MASK_TOP:
                continue
            row = rows.setdefault(y, [0, width, 0])
            row[0] += 1
            x = pixel % width
            row[1] = min(row[1], x)
            row[2] = max(row[2], x)

    differing = sum(row[0] for row in rows.values())
    compared = width * (height - MASK_TOP)
    bands = []
    if rows:
        ordered = sorted(rows)
        start = previous = ordered[0]
        for y in ordered[1:]:
            if y - previous > BAND_GAP:
                bands.append((start, previous))
                start = y
            previous = y
        bands.append((start, previous))
    return differing / compared * 100.0, bands, rows


def capture(scenario, simulator, settle, out_dir, timeout):
    # Arguments go through argv as a list. Building them in a shell is how they
    # get silently collapsed -- zsh does not word-split unquoted variables, so
    # `set -- $args` yields one argument and the app launches with no flags at
    # all, producing a valid-looking screenshot of the wrong screen.
    run(["xcrun", "simctl", "terminate", simulator, BUNDLE_ID], timeout=60, check=False)
    run(
        ["xcrun", "simctl", "launch", "--terminate-running-process", simulator, BUNDLE_ID]
        + scenario.arguments,
        timeout=timeout,
    )
    time.sleep(settle)
    shot = out_dir / f"{scenario.name}.png"
    run(["xcrun", "simctl", "io", simulator, "screenshot", str(shot)], timeout=timeout)
    if not shot.exists() or shot.stat().st_size == 0:
        raise RuntimeError(f"{scenario.name}: screenshot was not written")
    return shot


def arguments():
    parser = argparse.ArgumentParser(
        prog="scripts/verify-ui-parity.sh", description=__doc__
    )
    parser.add_argument("--simulator", default=DEFAULT_SIMULATOR)
    parser.add_argument("--scenario", action="append", default=[], metavar="NAME")
    parser.add_argument(
        "--settle",
        type=float,
        default=15.0,
        metavar="SECONDS",
        help="wait before capturing; 7s once photographed a blank list",
    )
    parser.add_argument("--timeout", type=float, default=120.0, metavar="SECONDS")
    parser.add_argument(
        "--update-baselines",
        action="store_true",
        help="rewrite the committed baselines; only for a reviewed design change",
    )
    parser.add_argument(
        "--skip-install",
        action="store_true",
        help="reuse the installed app instead of installing the latest build",
    )
    return parser.parse_args()


def main():
    args = arguments()
    selected = SCENARIOS
    if args.scenario:
        names = set(args.scenario)
        unknown = names - {s.name for s in SCENARIOS}
        if unknown:
            report(f"Unknown scenario(s): {', '.join(sorted(unknown))}")
            return 2
        selected = [s for s in SCENARIOS if s.name in names]

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = ROOT / "build" / "ui-parity" / stamp
    out_dir.mkdir(parents=True, exist_ok=True)
    work = out_dir / "work"
    work.mkdir(exist_ok=True)
    report(f"Captures: {out_dir}")

    failures = []
    with simulator_lock(args.simulator):
        run(["xcrun", "simctl", "bootstatus", args.simulator, "-b"], timeout=180)
        if not args.skip_install:
            app = built_app()
            report(f"Installing {app}")
            run(["xcrun", "simctl", "install", args.simulator, str(app)], timeout=300)

        for scenario in selected:
            shot = capture(scenario, args.simulator, args.settle, out_dir, args.timeout)

            if not scenario.compare:
                report(f"{scenario.name}: captured (review material, not gated)")
                continue

            baseline = BASELINES / scenario.baseline
            if args.update_baselines:
                baseline.write_bytes(shot.read_bytes())
                report(f"{scenario.name}: baseline updated")
                continue
            if not baseline.exists():
                failures.append(f"{scenario.name}: no baseline at {baseline}")
                continue

            percent, bands, _ = compare(baseline, shot, work)

            # A capture that differs this much is almost never a layout change: the app was
            # still painting when the shot was taken, which system.md records as a known
            # hazard ("7s once photographed a blank list"). Re-capture once before failing,
            # the way the test runner retries a startup failure, so a slow frame does not
            # read as a regression.
            if percent > IMPLAUSIBLE_DIFFERENCE:
                report(f"{scenario.name}: {percent:.3f}% differing; re-capturing once")
                shot = capture(scenario, args.simulator, args.settle * 2, out_dir, args.timeout)
                percent, bands, _ = compare(baseline, shot, work)

            detail = ", ".join(f"y {s}-{e}" for s, e in bands) or "none"
            line = f"{scenario.name}: {percent:.3f}% differing, bands: {detail}"

            if percent > scenario.tolerance:
                # A big difference usually means the capture is of the wrong
                # screen -- the app launched without its fixture flags -- not
                # that the layout moved by that much.
                hint = (
                    "  (still this large after a re-capture, so the app may not have "
                    "launched in fixture mode)"
                    if percent > IMPLAUSIBLE_DIFFERENCE
                    else ""
                )
                failures.append(f"{line} > {scenario.tolerance:.3f}%{hint}")
                report(f"FAIL {line}")
            elif len(bands) > scenario.max_bands:
                failures.append(
                    f"{line}: {len(bands)} bands, expected at most "
                    f"{scenario.max_bands}. One band is the animating busy row; "
                    "more than one means something moved."
                )
                report(f"FAIL {line}")
            else:
                report(f"ok   {line}")

    if failures:
        report("")
        for failure in failures:
            report(f"FAILED {failure}")
        report("")
        report(
            "Single-server parity is the rule that one saved server changes nothing. "
            "Compare the capture with its baseline before assuming the baseline is stale."
        )
        return 1

    report("All compared scenarios within tolerance.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except RuntimeError as error:
        report(str(error))
        sys.exit(1)
