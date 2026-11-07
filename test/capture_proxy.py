#!/usr/bin/env python3
"""Delay one real tmux command at an externally controlled cancellation boundary."""
import os
import selectors
import signal
import socket
import subprocess
import sys

signal.signal(signal.SIGTERM, lambda *_: None)
barrier = None
process = subprocess.Popen([os.environ["LIBTMUX_TEST_BINARY"], *sys.argv[1:]],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr)
pending = b""
held = False
try:
    with selectors.DefaultSelector() as ready:
        ready.register(sys.stdin, selectors.EVENT_READ)
        ready.register(process.stdout, selectors.EVENT_READ)
        while True:
            events = ready.select()
            stopped = False
            for key, _ in events:
                data = os.read(key.fd, 65536)
                if not data:
                    stopped = True
                    break
                if key.fileobj is process.stdout:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                else:
                    pending += data
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        if not held and line.startswith(os.environ["LIBTMUX_TEST_CAPTURE_STEP"].encode() + b" "):
                            held = True
                            barrier = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                            barrier.connect(os.environ["LIBTMUX_TEST_BARRIER"])
                            barrier.sendall(b"HELD\n")
                            if barrier.recv(1) != b"G":
                                raise RuntimeError("controller closed capture barrier")
                        process.stdin.write(line + b"\n")
                        process.stdin.flush()
            if stopped:
                break
finally:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if barrier is not None:
        barrier.close()
    process.stdin.close()
    process.terminate()
    process.wait(timeout=1)
    process.stdout.close()
