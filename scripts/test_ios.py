#!/usr/bin/env python3
"""Run hosted iOS tests with bounded waits and simulator startup recovery."""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SIMULATOR = "F323E9E4-4B39-4EB6-A42B-AB9E203A3E9A"
LAUNCH_FAILURE = "Simulator device failed to launch "
TEST_STARTED = re.compile(r"Test run started\.|Test Suite .+ started at|◇ (?:Test|Suite) ")


def report(message):
    print(f"[test-ios] {message}", flush=True)


class RunInterrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, _frame):
    raise RunInterrupted(signum)


@contextmanager
def simulator_lock(simulator):
    # Keep the file: unlinking an advisory lock can let two runners lock
    # different inodes. The OS releases this lock when the runner exits.
    path = Path("/tmp") / f"openlens-simulator-{os.getuid()}-{simulator}.lock"
    with path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f"Another test runner is using simulator {simulator}. Lock: {path}")
        lock.seek(0)
        lock.truncate()
        lock.write(f"{os.getpid()}\n")
        lock.flush()
        yield


def stop_process(process):
    # Each command owns a new process group. Leave other builds and shared
    # CoreSimulator services alone, including commands started by Xcode.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait(timeout=5)
        return
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        process.poll()  # Reap the parent even if a descendant ignores SIGTERM.
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


@dataclass
class CommandResult:
    returncode: int
    timed_out: bool = False
    launch_failed: bool = False
    tests_started: bool = False

    @property
    def succeeded(self):
        return self.returncode == 0 and not self.timed_out and not self.launch_failed

    @property
    def exit_code(self):
        return 124 if self.timed_out else (self.returncode if self.returncode > 0 else 1)

    @property
    def can_retry_startup(self):
        return not self.tests_started and (self.launch_failed or self.timed_out)


def run_command(command, log_path, timeout, monitor_startup=False):
    report(f"Running {log_path.stem}; limit {timeout:g}s. Log: {log_path}")
    result = CommandResult(returncode=1)
    with log_path.open("wb") as output, log_path.open(errors="replace") as reader:
        process = subprocess.Popen(
            command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True
        )
        deadline = time.monotonic() + timeout
        tail = ""

        def observe_output():
            nonlocal tail
            text = tail + reader.read()
            if monitor_startup:
                result.launch_failed |= LAUNCH_FAILURE in text
                result.tests_started |= TEST_STARTED.search(text) is not None
            tail = text[-8192:]

        try:
            while True:
                observe_output()
                if process.poll() is not None:
                    break
                if monitor_startup and result.launch_failed and not result.tests_started:
                    report("Application launch failed; stopping this test runner.")
                    stop_process(process)
                    break
                if time.monotonic() >= deadline:
                    result.timed_out = True
                    report(f"Time limit exceeded; stopping {log_path.stem}.")
                    stop_process(process)
                    break
                time.sleep(0.25)
            observe_output()
            result.returncode = process.wait()
        finally:
            if process.poll() is None:
                stop_process(process)
    if not result.succeeded:
        text = log_path.read_text(errors="replace")
        errors = [line for line in text.splitlines() if "error:" in line.lower() or "✘" in line]
        details = "\n".join(errors[:8]) if errors else text[-4000:]
        report(f"Failed: {log_path}. Output:\n{details}")
    return result


def positive_seconds(value):
    seconds = float(value)
    if not 0 < seconds < float("inf"):
        raise argparse.ArgumentTypeError("time limits must be finite and greater than zero")
    return seconds


def arguments():
    parser = argparse.ArgumentParser(prog="scripts/test-ios.sh", description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="reuse the previous build-for-testing")
    parser.add_argument("--only-testing", action="append", default=[], metavar="TARGET/SUITE",
                        help="run only this test identifier; may be repeated")
    parser.add_argument("--simulator", type=lambda value: str(uuid.UUID(value)).upper(), default=DEFAULT_SIMULATOR,
                        metavar="UDID", help="simulator ID (default: local iPhone 18 Pro)")
    parser.add_argument("--test-timeout", type=positive_seconds, default=120, metavar="SECONDS")
    parser.add_argument("--build-timeout", type=positive_seconds, default=600, metavar="SECONDS")
    parser.add_argument("--simulator-timeout", type=positive_seconds, default=90, metavar="SECONDS")
    return parser.parse_args()


def verify(args, logs):
    base = [
        "xcodebuild", "-project", "OpenLens.xcodeproj", "-scheme", "OpenLens",
        "-destination", f"platform=iOS Simulator,id={args.simulator}", "CODE_SIGNING_ALLOWED=NO",
    ]
    if not args.skip_build:
        for command, name in [(["xcodegen", "generate"], "generate"), (base + ["build-for-testing"], "build")]:
            result = run_command(command, logs / f"{name}.log", args.build_timeout)
            if not result.succeeded:
                return result.exit_code

    boot = ["xcrun", "simctl", "bootstatus", args.simulator, "-b"]
    result = run_command(boot, logs / "boot.log", args.simulator_timeout)
    if not result.succeeded:
        return result.exit_code

    for attempt in (1, 2):
        command = base + [
            "test-without-building", "-parallel-testing-enabled", "NO",
            "-resultBundlePath", str(logs / f"test-attempt-{attempt}.xcresult"),
        ] + [f"-only-testing:{identifier}" for identifier in args.only_testing]
        result = run_command(command, logs / f"test-attempt-{attempt}.log", args.test_timeout,
                             monitor_startup=True)
        if result.succeeded:
            report("Tests passed. Simulator stays booted.")
            return 0
        if attempt == 2 or not result.can_retry_startup:
            return result.exit_code

        report("Recovering simulator startup; one retry remains.")
        for command, name in [(["xcrun", "simctl", "shutdown", args.simulator], "shutdown"),
                              (boot, "boot-retry")]:
            recovery = run_command(command, logs / f"{name}.log", args.simulator_timeout)
            if not recovery.succeeded:
                return recovery.exit_code
    return 1


def main():
    args = arguments()
    for tool in ["xcrun", "xcodebuild"] + ([] if args.skip_build else ["xcodegen"]):
        if shutil.which(tool) is None:
            report(f"Required tool not found: {tool}")
            return 1
    try:
        with simulator_lock(args.simulator):
            directory = ROOT / "build" / "test-runs"
            directory.mkdir(parents=True, exist_ok=True)
            prefix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
            logs = Path(tempfile.mkdtemp(prefix=prefix, dir=directory))
            report(f"Logs and result bundles: {logs}")
            return verify(args, logs)
    except RunInterrupted as interrupted:
        report("Interrupted; stopped this runner's command.")
        return 128 + interrupted.signum
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        report(str(error))
        return 1


if __name__ == "__main__":
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    sys.exit(main())
