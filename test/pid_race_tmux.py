#!/usr/bin/env python3
"""Fault peer: keep a real pidfd target while controlling the two identity replies."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

sequence = 0
identities = 0
mode = os.environ["LIBTMUX_TEST_PID_RACE"]
child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.buffer.read(1)"],
                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop(*_):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


def frame(body):
    global sequence
    sequence += 1
    guard = f"1 {sequence} 1".encode()
    sys.stdout.buffer.write(b"%begin " + guard + b"\n" + body + b"%end " + guard + b"\n")
    sys.stdout.buffer.flush()


signal.signal(signal.SIGTERM, stop)
try:
    frame(b"")
    for command in sys.stdin.buffer:
        if mode == "malformed-after-write" and command.startswith(b"wait-for "):
            sys.stdout.buffer.write(b"%begin 1 900 1\n%end 1 901 1\n")
            sys.stdout.buffer.flush()
        elif b"libtmux" in command and b"probe" in command:
            frame(b"libtmux\rprobe\n")
        elif b"#{q:pid}" in command:
            identities += 1
            if (mode == "exit-before-open" and identities == 1) or (mode == "exit-before-recheck" and identities == 2):
                child.terminate()
                child.wait(timeout=1)
            pid = child.pid + (1 if mode == "changed-pid" and identities == 2 else 0)
            frame(f"{pid}|3.3=\n".encode())
        else:
            marker = re.search(rb"libtmux-ocaml-[0-9a-f]{64}", command)
            assert marker is not None, command
            frame(marker[0] + b"\n")
finally:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child.stdin.close()
    child.wait(timeout=1)
    Path(os.environ["LIBTMUX_TEST_PID_RECEIPT"]).write_text(json.dumps({
        "identities": identities, "pid": child.pid, "reaped": True, "mode": mode,
    }))
