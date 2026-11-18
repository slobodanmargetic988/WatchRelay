#!/usr/bin/env python3
"""Start or reuse WatchRelay and open its separate Chrome profile."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import time


ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "mac/build/WatchRelay.app/Contents/MacOS/watchrelay"
LOGS = Path.home() / "Library/Logs/WatchRelay"


def listening(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.15):
            return True
    except OSError:
        return False


def running_helper(port):
    listing = subprocess.run(
        ["/bin/ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True, check=True,
    ).stdout
    prefix = f"{HELPER} auto "
    for line in listing.splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or not fields[1].startswith(prefix):
            continue
        arguments = fields[1][len(prefix):].split()
        if (len(arguments) == 1 and port == 1080) or (
            len(arguments) == 2 and arguments[-1] == str(port)
        ):
            return int(fields[0])
    return None


def selected_watch():
    result = subprocess.run([HELPER, "devices"], capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Could not read the Mac's paired Bluetooth devices.")
    addresses = set(re.findall(
        r"^\d+\. [^\n]*Galaxy Watch[^\n]* \[([0-9A-Fa-f:-]+)\] paired$",
        result.stdout, re.MULTILINE | re.IGNORECASE,
    ))
    if len(addresses) != 1:
        raise RuntimeError("Choose a paired watch from the Mac helper's devices list and pass --device.")
    return addresses.pop()


def start_helper(device, port, *, wide=False):
    path = LOGS / f"launcher-{port}.log"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as log:
        environment = dict(os.environ, WATCHRELAY_WIDE="1") if wide else None
        process = subprocess.Popen(
            [HELPER, "auto", device, str(port)], stdin=subprocess.DEVNULL, stdout=log,
            stderr=subprocess.STDOUT, start_new_session=True, env=environment,
        )
    return process, path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="paired watch number or Bluetooth address")
    parser.add_argument("--port", type=int, default=1080)
    parser.add_argument("--url", default="https://example.com/")
    parser.add_argument("--stop", action="store_true", help="stop the running Mac helper")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")

    LOGS.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = LOGS / f"launcher-{args.port}.lock"
    lock_fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    process = None
    log_path = None
    with os.fdopen(lock_fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        pid = running_helper(args.port)
        if args.stop:
            if pid is None:
                print("WatchRelay's Mac helper is stopped.")
            else:
                try:
                    os.kill(pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                print("WatchRelay's Mac helper is stopping.")
            return 0
        if not HELPER.is_file():
            parser.error("build the Mac helper with scripts/build first")
        if pid is None and listening(args.port):
            parser.error("the port is in use by another process")
        if pid is not None and args.device:
            parser.error("stop the current Mac helper before selecting another watch")
        if pid is None:
            try:
                process, log_path = start_helper(args.device or selected_watch(), args.port)
            except (OSError, RuntimeError) as error:
                parser.error(str(error))
    print("Start Auto-connect on the watch if it is stopped. Waiting for its Bluetooth connection.", flush=True)
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if process is not None and process.poll() is not None:
                print(f"WatchRelay's Mac helper stopped. See {log_path}.")
                return process.returncode or 1
            if listening(args.port):
                return subprocess.run(
                    [ROOT / "scripts/open-browser", "--port", str(args.port), args.url],
                    check=False,
                ).returncode
            time.sleep(0.2)
        print("WatchRelay is still waiting. Check Auto-connect and reopen the launcher when the watch is near.")
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
