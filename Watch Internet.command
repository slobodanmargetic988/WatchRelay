#!/usr/bin/env python3
"""Switch the Mac's WatchRelay network tunnel on or off."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import signal
import runpy
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parent
CLI_SESSION = ROOT / "mac/wide/cli-session"
STATE = Path.home() / "Library/Application Support/WatchRelay/NetworkSwitch"
SCUTIL = "/usr/sbin/scutil"
PROVIDER = "io.nekohasekai.sfamt"
TUNNEL_IP = "198.18.245.1"
TUNNEL_DNS = "198.18.245.2"
SERVICE_ID = re.compile(r"\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b")
TRIAL = STATE / "trial"
WIDE_RELAY_PID = STATE / "wide-relay-pid"


def read_command(*command, timeout=6):
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)


def nc(*args):
    result = read_command(SCUTIL, "--nc", *args)
    if result.returncode:
        raise RuntimeError(f"macOS could not {args[0]} the sing-box VPN.")
    return result.stdout


def vpn_service(*, required=True):
    matches = []
    for line in nc("list").splitlines():
        match = SERVICE_ID.search(line)
        if not match or not (PROVIDER in line or '"sing-box' in line.casefold()):
            continue
        service = match.group()
        if PROVIDER in line or PROVIDER in nc("show", service):
            matches.append(service)
    if not matches and not required:
        return None
    if len(matches) != 1:
        raise RuntimeError("Set up the WatchRelay profile in sing-box first. See the WatchRelay setup guide.")
    return matches[0]


def vpn_status(service):
    return nc("status", service).partition("\n")[0].strip()


def tunnel_ready():
    selected = read_command("/sbin/route", "-n", "get", "-inet", "1.1.1.1").stdout
    match = re.search(r"^\s*interface:\s+(utun\d+)\s*$", selected, re.MULTILINE)
    if not match:
        return False
    interface = read_command("/sbin/ifconfig", match.group(1)).stdout
    dns = read_command(SCUTIL, "--dns").stdout
    return bool(re.search(rf"\binet {re.escape(TUNNEL_IP)}\s", interface)
                and re.search(rf"nameserver\[\d+\]\s*:\s*{re.escape(TUNNEL_DNS)}\b", dns))


def system_online():
    result = read_command(SCUTIL, "-r", "0.0.0.0")
    return (result.returncode == 0 and result.stdout.startswith("Reachable")
            and "Connection Required" not in result.stdout)


def check_https(proxy):
    result = read_command(
        "/usr/bin/curl", "-q", "--proxy", proxy, "--noproxy", "" if proxy else "*",
        "--connect-timeout", "12", "--max-time", "18", "--fail", "--silent",
        "--output", "/dev/null", "https://example.com/",
        timeout=20,
    )
    return result.returncode == 0


def prepare_relay():
    helper = runpy.run_path(str(ROOT / "WatchRelay.command"))
    port = 1080
    logs = helper["LOGS"]
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(logs / f"launcher-{port}.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = helper["running_helper"](port)
        expected = WIDE_RELAY_PID.read_text().strip() if WIDE_RELAY_PID.is_file() else ""
        if current is None and helper["listening"](port):
            raise RuntimeError("Port 1080 is in use by another process.")
        if current is None or str(current) != expected:
            if current is not None:
                os.kill(current, signal.SIGINT)
                deadline = time.monotonic() + 6
                while helper["running_helper"](port) is not None and time.monotonic() < deadline:
                    time.sleep(0.2)
                if helper["running_helper"](port) is not None or helper["listening"](port):
                    raise RuntimeError("The older WatchRelay helper did not stop.")
            print("Starting the WatchRelay helper. Use Auto-connect on the watch if it is stopped.", flush=True)
            process, _ = helper["start_helper"](helper["selected_watch"](), port, wide=True)
            WIDE_RELAY_PID.write_text(str(process.pid))
    deadline = time.monotonic() + 35
    while not helper["listening"](port) and time.monotonic() < deadline:
        time.sleep(0.25)
    # An idle watch can take one request to bring its cellular network up.
    proxy = "socks5h://127.0.0.1:1080"
    if not check_https(proxy) and not check_https(proxy):
        raise RuntimeError("The watch relay did not reach the internet. Check Auto-connect and watch mobile data.")


def clear_trial():
    TRIAL.unlink(missing_ok=True)


def arm_trial(seconds, service, announce=True):
    token = uuid.uuid4().hex
    temporary = STATE / token
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        file.write(token)
    temporary.replace(TRIAL)
    try:
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "_expire", token, service, str(seconds)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        clear_trial()
        raise
    if announce:
        print(f"Automatic switch back is armed for {seconds} seconds.", flush=True)


def lock_state():
    STATE.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(STATE / "lock", os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    lock = os.fdopen(fd, "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    return lock


def expire(token, service, seconds):
    time.sleep(int(seconds))
    with lock_state():
        if TRIAL.is_file() and TRIAL.read_text() == token:
            # Only stop the exact service that was armed for this trial.
            if vpn_service() == service:
                for _ in range(3):
                    try:
                        nc("stop", service)
                        break
                    except (RuntimeError, subprocess.TimeoutExpired):
                        time.sleep(1)
            clear_trial()
    return 0


def activate_sfm(service, trial):
    prepare_relay()
    arm_trial(trial or 60, service, announce=bool(trial))
    try:
        nc("start", service)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            status = vpn_status(service)
            if status == "Connected" and tunnel_ready():
                if check_https(""):
                    if not trial:
                        clear_trial()
                    print("Watch Internet is on. Use your existing apps as usual.")
                    return
                break
            if status == "Disconnected" and not read_command("/usr/sbin/scutil", "--nwi").stdout.split(
                "Network interfaces:", 1
            )[-1].strip():
                raise RuntimeError("macOS needs an active network before starting the sing-box VPN.")
            time.sleep(0.5)
        raise RuntimeError("Watch Internet did not pass its routing, DNS and HTTPS checks.")
    except (RuntimeError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt):
        nc("stop", service)
        clear_trial()
        raise


def cli_status():
    result = read_command(str(CLI_SESSION), "status")
    status = result.stdout.strip()
    if result.returncode not in (0, 1, 2) or not (
        status in ("OFF", "STARTING") or re.fullmatch(r"ACTIVE utun\d+", status)
    ):
        raise RuntimeError(result.stderr.strip() or "Could not check the Watch Internet tunnel.")
    return status


def cli_command(*args):
    # Inherit Terminal input so macOS can ask for the administrator password.
    if subprocess.run([str(CLI_SESSION), *args], check=False).returncode:
        raise RuntimeError(f"Could not {args[0]} the Watch Internet tunnel.")


def activate_cli(trial):
    service = vpn_service(required=False)
    if service and vpn_status(service) != "Disconnected":
        raise RuntimeError("Stop the active sing-box VPN before switching on Watch Internet.")
    prepare_relay()
    try:
        cli_command("on", "--trial", str(trial or 90))
        deadline = time.monotonic() + 12
        while not (tunnel_ready() and system_online()):
            if time.monotonic() >= deadline:
                raise RuntimeError("macOS did not recognize the Watch Internet route and resolver.")
            time.sleep(0.35)
        if not check_https(""):
            raise RuntimeError("Watch Internet could not load a page over the system route.")
        if trial is None:
            cli_command("keep")
            print("Watch Internet is on. Use your existing apps as usual.")
        else:
            print("The timed Watch Internet trial is active.")
    except (RuntimeError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt):
        if cli_status() != "OFF":
            cli_command("off")
        raise


def manage_cli(args):
    if args.action == "arm":
        raise RuntimeError("The arm command applies to the sing-box VPN. Use trial for offline testing.")
    status = cli_status()
    if args.action == "status":
        if status.startswith("ACTIVE ") and tunnel_ready() and system_online():
            print("Watch Internet is on.")
        else:
            print("Watch Internet is off." if status == "OFF" else "Watch Internet is starting or unverified.")
    elif args.action == "off" or (args.action == "toggle" and status != "OFF"):
        if status != "OFF":
            cli_command("off")
        print("Watch Internet is off. The Mac's usual routing is restored.")
    elif status != "OFF":
        raise RuntimeError("Watch Internet is already running. Switch it off before starting another session.")
    else:
        activate_cli(args.seconds if args.action == "trial" else None)


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "_expire":
        return expire(*sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("toggle", "on", "off", "status", "trial", "arm"),
                        nargs="?", default="toggle")
    parser.add_argument("--seconds", type=int, default=90, help="automatic rollback time for trial or arm")
    parser.add_argument("--engine", choices=("cli", "sfm"), default="cli",
                        help="use the offline-capable engine or the installed sing-box VPN")
    args = parser.parse_args()
    if not 60 <= args.seconds <= 300:
        parser.error("trial duration must be between 60 and 300 seconds")
    try:
        with lock_state():
            if args.engine == "cli":
                manage_cli(args)
                return 0
            if CLI_SESSION.exists() and cli_status() != "OFF":
                raise RuntimeError("Switch Watch Internet off before using the sing-box VPN.")
            service = vpn_service()
            status = vpn_status(service)
            if args.action == "status":
                ready = status == "Connected" and tunnel_ready()
                print("Watch Internet is on." if ready else f"Watch Internet is off or unverified ({status}).")
            elif args.action == "off" or (args.action == "toggle" and status != "Disconnected"):
                nc("stop", service)
                clear_trial()
                print("Switching back to the Mac's normal connection.")
            elif status != "Disconnected":
                raise RuntimeError("The sing-box VPN is already active. Switch it off before starting a trial.")
            elif args.action == "arm":
                arm_trial(args.seconds, service)
            else:
                activate_sfm(service, args.seconds if args.action == "trial" else None)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
